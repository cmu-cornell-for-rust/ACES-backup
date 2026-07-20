//! Combine BSAN per-crate node logs into one CSV keyed by source line location.
//!
//! Rust port of ../combine_node_profile.py -- same behaviour, built for huge
//! inputs (multi-GB): streaming aggregation, bounded by the number of distinct
//! line locations rather than total rows.
//!
//! Usage: combine_node_profile_rs [-o OUT.csv] <dir_or_csv> [<dir_or_csv> ...]
//!
//! Reads every <crate>.csv / <crate>.csv.gz written via BSAN_NODE_LOG (one file
//! per crate, as laid out by profile_bsan_dataset.sh) and combines rows that
//! share an origin line location, summing the alloc ids (roots) and nodes:
//!
//!     origin_file,origin_line,alloc_ids,nodes,rows,origin_source,tests
//!
//! Rows are grouped by (origin_file, origin_line) -- columns are folded
//! together. `alloc_ids`/`nodes` are the sums of the `num_alloc_ids`/`num_nodes`
//! columns across every matching run; `rows` counts the folded input runs.
//! `tests` is a space-separated list of the distinct `test_file:test_line`
//! frames seen at that origin (first-seen order; empty test locations dropped).
//! Output is sorted by nodes descending.
//!
//! The leading `test` column that profile_bsan_dataset.sh adds is optional;
//! files with or without it are both accepted (columns are looked up by name).

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use flate2::read::MultiGzDecoder;

struct Entry {
    alloc_ids: u64,
    nodes: u64,
    rows: u64,
    source: String,
    tests: Vec<String>,
    seen_tests: HashSet<String>,
}

impl Default for Entry {
    fn default() -> Self {
        Entry {
            alloc_ids: 0,
            nodes: 0,
            rows: 0,
            source: String::new(),
            tests: Vec::new(),
            seen_tests: HashSet::new(),
        }
    }
}

fn main() -> ExitCode {
    let mut output: Option<String> = None;
    let mut inputs: Vec<String> = Vec::new();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-o" | "--output" => match args.next() {
                Some(v) => output = Some(v),
                None => {
                    eprintln!("{}: missing value", arg);
                    return ExitCode::from(2);
                }
            },
            "-h" | "--help" => {
                eprintln!(
                    "usage: combine_node_profile_rs [-o OUT.csv] <dir_or_csv> [...]"
                );
                return ExitCode::SUCCESS;
            }
            _ => inputs.push(arg),
        }
    }

    // ── Collect input files ─────────────────────────────────────────────────
    let mut paths: Vec<PathBuf> = Vec::new();
    for inp in &inputs {
        let p = PathBuf::from(inp);
        if p.is_dir() {
            let mut csvs: Vec<PathBuf> = Vec::new();
            let mut gzs: Vec<PathBuf> = Vec::new();
            let entries = match fs::read_dir(&p) {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("skip {}: {}", p.display(), e);
                    continue;
                }
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
                if name.ends_with(".csv.gz") {
                    gzs.push(path);
                } else if name.ends_with(".csv") {
                    csvs.push(path);
                }
            }
            csvs.sort();
            gzs.sort();
            paths.extend(csvs);
            paths.extend(gzs);
        } else {
            paths.push(p);
        }
    }

    if paths.is_empty() {
        eprintln!("no input .csv/.csv.gz files found");
        return ExitCode::from(1);
    }

    // ── Aggregate by (origin_file, origin_line) ─────────────────────────────
    let mut agg: HashMap<(String, String), Entry> = HashMap::new();
    let mut files_read: u64 = 0;
    let mut rows_read: u64 = 0;

    for path in &paths {
        let file = match File::open(path) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("skip {}: {}", path.display(), e);
                continue;
            }
        };
        let is_gz = path.to_str().map(|s| s.ends_with(".gz")).unwrap_or(false);
        let reader: Box<dyn io::Read> = if is_gz {
            Box::new(MultiGzDecoder::new(BufReader::new(file)))
        } else {
            Box::new(BufReader::new(file))
        };
        let mut rdr = csv::ReaderBuilder::new()
            .has_headers(true)
            .flexible(true)
            .from_reader(reader);

        // Locate columns by name so the optional leading `test` column works.
        let headers = match rdr.headers() {
            Ok(h) => h,
            Err(e) => {
                eprintln!("skip {}: {}", path.display(), e);
                continue;
            }
        };
        let idx = |name: &str| headers.iter().position(|h| h == name);
        let (i_na, i_nn, i_of, i_ol, i_os) = match (
            idx("num_alloc_ids"),
            idx("num_nodes"),
            idx("origin_file"),
            idx("origin_line"),
            idx("origin_source"),
        ) {
            (Some(a), Some(b), Some(c), Some(d), Some(e)) => (a, b, c, d, e),
            _ => {
                eprintln!("skip {}: unexpected header {:?}", path.display(), headers);
                continue;
            }
        };
        let i_tf = idx("test_file");
        let i_tl = idx("test_line");

        files_read += 1;

        let mut record = csv::StringRecord::new();
        loop {
            match rdr.read_record(&mut record) {
                Ok(true) => {}
                Ok(false) => break,
                Err(e) => {
                    eprintln!("{}: {}", path.display(), e);
                    break;
                }
            }
            if record.len() <= i_os {
                continue;
            }
            rows_read += 1;

            let na: u64 = record.get(i_na).unwrap_or("").parse().unwrap_or(0);
            let nn: u64 = record.get(i_nn).unwrap_or("").parse().unwrap_or(0);
            let key = (
                record.get(i_of).unwrap_or("").to_string(),
                record.get(i_ol).unwrap_or("").to_string(),
            );
            let entry = agg.entry(key).or_default();
            entry.alloc_ids += na;
            entry.nodes += nn;
            entry.rows += 1;
            if entry.source.is_empty() {
                entry.source = record.get(i_os).unwrap_or("").to_string();
            }
            let tf = i_tf.and_then(|i| record.get(i)).unwrap_or("");
            if !tf.is_empty() {
                let tl = i_tl.and_then(|i| record.get(i)).unwrap_or("");
                let loc = format!("{}:{}", tf, tl);
                if entry.seen_tests.insert(loc.clone()) {
                    entry.tests.push(loc);
                }
            }
        }
    }

    // ── Emit ────────────────────────────────────────────────────────────────
    let mut rows: Vec<(&(String, String), &Entry)> = agg.iter().collect();
    rows.sort_by(|a, b| b.1.nodes.cmp(&a.1.nodes));

    let writer: Box<dyn Write> = match &output {
        Some(p) => match File::create(p) {
            Ok(f) => Box::new(BufWriter::new(f)),
            Err(e) => {
                eprintln!("cannot write {}: {}", p, e);
                return ExitCode::from(1);
            }
        },
        None => Box::new(BufWriter::new(io::stdout())),
    };
    let mut w = csv::Writer::from_writer(writer);
    if let Err(e) = w.write_record([
        "origin_file",
        "origin_line",
        "alloc_ids",
        "nodes",
        "rows",
        "origin_source",
        "tests",
    ]) {
        eprintln!("write error: {}", e);
        return ExitCode::from(1);
    }
    for ((of, ol), entry) in rows {
        if let Err(e) = w.write_record([
            of,
            ol,
            &entry.alloc_ids.to_string(),
            &entry.nodes.to_string(),
            &entry.rows.to_string(),
            &entry.source,
            &entry.tests.join(" "),
        ]) {
            eprintln!("write error: {}", e);
            return ExitCode::from(1);
        }
    }
    if let Err(e) = w.flush() {
        eprintln!("flush error: {}", e);
        return ExitCode::from(1);
    }

    eprintln!(
        "read {} rows from {} files -> {} line locations",
        rows_read,
        files_read,
        agg.len()
    );
    ExitCode::SUCCESS
}
