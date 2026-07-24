use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;

use flate2::read::GzDecoder;
use regex::Regex;

// ── File reading (streams line-by-line, transparently gunzipping .gz) ──────────
//
// Returns a buffered reader rather than the whole file: a large trace (or a small
// gzip that explodes when decompressed) is processed one line at a time, so peak
// memory is bounded by the event maps, not by the file size.

fn open_reader(path: &Path) -> std::io::Result<Box<dyn BufRead>> {
    let file = fs::File::open(path)?;
    if path.extension().and_then(|e| e.to_str()) == Some("gz") {
        Ok(Box::new(BufReader::new(GzDecoder::new(file))))
    } else {
        Ok(Box::new(BufReader::new(file)))
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn format_comma(n: u64) -> String {
    // simple thousands-separator formatter
    let s = n.to_string();
    let mut result = String::new();
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            result.push(',');
        }
        result.push(c);
    }
    result.chars().rev().collect()
}

// ── Regex bundle (compiled once) ──────────────────────────────────────────────
//
// The BorrowSanitizer event grammar (BSAN_NODE_LOG). Differs from the Miri
// tree_tracing grammar in three ways handled here:
//   * E2 parents / E3 / E4 tags may be the wildcard `tw` (no owning tree).
//   * E5 (access) and E7 (prune) are keyed by ALLOC id, not by tag.
//   * there is an E8 "exposed" event and no E1a "memory kind" event.
//
//     E1: Root Tag(alloc3, t3)        new allocation, root tag created
//     E2: Reborrow(t4, t3, s4)        reborrow -> child tag (parent may be `tw`)
//     E3: Read(t10)  / E3: Read(tw)   read access via a tag (`tw` = wildcard)
//     E4: Write(t3)  / E4: Write(tw)  write access via a tag
//     E5: Access(alloc3, 2, 0)        per-alloc access: nodes visited, skipped
//     E5: WC Access(alloc3, 2, 0)     wildcard-access variant (same shape)
//     E6: GC                          one garbage-collection cycle
//     E7: Pruned(alloc3, 5)           nodes removed from an alloc during a prune
//     E8: Exposed (t483, alloc83)     tag exposed (ptr->int)
struct Patterns {
    e1: Regex,
    e2: Regex,
    e3: Regex,
    e4: Regex,
    e5: Regex,
    e6: Regex,
    e7: Regex,
    e8: Regex,
}

impl Patterns {
    fn new() -> Self {
        Self {
            e1: Regex::new(r"E1[^(]*\(alloc(\d+), t(\d+)\)").unwrap(),
            e2: Regex::new(r"E2[^(]*\(t(\d+), (t\d+|tw), s(\d+)\)").unwrap(),
            e3: Regex::new(r"E3[^(]*\((t\d+|tw)\)").unwrap(),
            e4: Regex::new(r"E4[^(]*\((t\d+|tw)\)").unwrap(),
            e5: Regex::new(r"E5[^(]*\(alloc(\d+), (\d+), (\d+)\)").unwrap(),
            e6: Regex::new(r"E6.*GC").unwrap(),
            e7: Regex::new(r"E7[^(]*\(alloc(\d+), (\d+)\)").unwrap(),
            e8: Regex::new(r"E8[^(]*\(t(\d+), alloc(\d+)\)").unwrap(),
        }
    }
}

// Parse the tag out of a `t<digits>` / `tw` capture. `tw` (wildcard) yields None
// so callers can skip it -- a wildcard access has no owning tree.
fn parse_tag(s: &str) -> Option<u64> {
    if s == "tw" {
        None
    } else {
        s.strip_prefix('t').and_then(|d| d.parse().ok())
    }
}

// ── CSV header ──────────────────────────────────────────────────────────────

fn build_header_main() -> Vec<String> {
    vec![
        "crate", "trees", "nodes", "avg_nodes", "read", "avg_read (max)", "write",
        "avg_write (max)", "visited", "avg_visited (max)", "skipped", "avg_skipped (max)",
        "gc_invoked", "gc_pruned", "avg_gc_pruned", "exposures",
    ]
    .into_iter()
    .map(|s| s.to_string())
    .collect()
}

// ── Tree-size distribution bucket ────────────────────────────────────────────
//
// One bucket per distinct tree size (node count). `count` is how many trees have
// that size; the rest are sums of each per-tree event across those trees, from
// which the distribution CSV derives the averages (sum / count).

#[derive(Default)]
struct SizeAgg {
    count: u64,
    reads: u64,
    writes: u64,
    visited: u64,
    skipped: u64,
    gc_pruned: u64,
    exposures: u64,
}

// ── Per-project analysis ──────────────────────────────────────────────────────
//
// Reduce one project's trace file (a <project>.csv.gz whose decompressed content
// is the BSAN event stream) to a single CSV row, and write that project's
// tree-size distribution into `dist_dir`. All state is local to this function so
// projects can be processed independently.

fn process_file(
    pat: &Patterns,
    crate_name: &str,
    file_path: &Path,
    dist_dir: &Path,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    // ── per-project accumulators ──────────────────────────────────────
    let mut trees: u64 = 0;
    let mut nodes: u64 = 0;
    let mut reads: u64 = 0;
    let mut writes: u64 = 0;
    let mut visited: u64 = 0;
    let mut skipped: u64 = 0;
    let mut gc_invoked: u64 = 0;
    let mut gc_pruned: u64 = 0;
    let mut exposures: u64 = 0;

    let mut max_nodes: u64 = 0;
    let mut max_reads: u64 = 0;
    let mut max_writes: u64 = 0;
    let mut max_visited: u64 = 0;
    let mut max_skipped: u64 = 0;
    let mut max_gc_pruned: u64 = 0;

    // tree-size distribution: maps a tree's node count -> aggregate stats over
    // all trees of that size.
    let mut tree_size_dist: HashMap<u64, SizeAgg> = HashMap::new();

    // ── per-tree maps for this project's trace ────────────────────────
    let mut tag_root: HashMap<u64, u64> = HashMap::new();
    // alloc id -> its (most recent) root tag: E5/E7 arrive keyed by alloc,
    // so we resolve them back to a tree through this map.
    let mut alloc_root: HashMap<u64, u64> = HashMap::new();
    let mut tree_nodes: HashMap<u64, u64> = HashMap::new();
    let mut tree_reads: HashMap<u64, u64> = HashMap::new();
    let mut tree_writes: HashMap<u64, u64> = HashMap::new();
    let mut tree_visited: HashMap<u64, u64> = HashMap::new();
    let mut tree_skipped: HashMap<u64, u64> = HashMap::new();
    let mut tree_gc_pruned: HashMap<u64, u64> = HashMap::new();
    let mut tree_exposures: HashMap<u64, u64> = HashMap::new();

    // Stream the trace one line at a time; never materialize the whole file.
    let reader = open_reader(file_path)?;
    for line in reader.lines() {
        let line = line?;
        let e = line.trim();
        if e.is_empty() {
            continue;
        }
        if e.starts_with("E1") {
            if let Some(caps) = pat.e1.captures(e) {
                let alloc_id: u64 = caps[1].parse()?;
                let tag: u64 = caps[2].parse()?;
                alloc_root.insert(alloc_id, tag);
                tag_root.insert(tag, tag);
                trees += 1;
                nodes += 1;
                *tree_nodes.entry(tag).or_default() += 1;
            }
        } else if e.starts_with("E2") {
            if let Some(caps) = pat.e2.captures(e) {
                let child: u64 = caps[1].parse()?;
                // Wildcard parent (`tw`) roots a subtree in an allocation
                // this event can't name; skip rather than guess.
                if let Some(parent) = parse_tag(&caps[2]) {
                    if let Some(&root) = tag_root.get(&parent) {
                        tag_root.insert(child, root);
                        nodes += 1;
                        *tree_nodes.entry(root).or_default() += 1;
                    }
                }
            }
        } else if e.starts_with("E3") {
            if let Some(caps) = pat.e3.captures(e) {
                if let Some(tag) = parse_tag(&caps[1]) {
                    if let Some(&root) = tag_root.get(&tag) {
                        reads += 1;
                        *tree_reads.entry(root).or_default() += 1;
                    }
                }
            }
        } else if e.starts_with("E4") {
            if let Some(caps) = pat.e4.captures(e) {
                if let Some(tag) = parse_tag(&caps[1]) {
                    if let Some(&root) = tag_root.get(&tag) {
                        writes += 1;
                        *tree_writes.entry(root).or_default() += 1;
                    }
                }
            }
        } else if e.starts_with("E5") {
            // Keyed by alloc id (not tag); covers both `Access` and the
            // `WC Access` wildcard variant.
            if let Some(caps) = pat.e5.captures(e) {
                let alloc_id: u64 = caps[1].parse()?;
                let v: u64 = caps[2].parse()?;
                let s: u64 = caps[3].parse()?;
                if let Some(&root) = alloc_root.get(&alloc_id) {
                    visited += v;
                    skipped += s;
                    *tree_visited.entry(root).or_default() += v;
                    *tree_skipped.entry(root).or_default() += s;
                }
            }
        } else if e.starts_with("E6") {
            // Count "E6: GC" invocations; the "E6 ... start" sentinel has no "GC".
            if pat.e6.is_match(e) {
                gc_invoked += 1;
            }
        } else if e.starts_with("E7") {
            // Keyed by alloc id (not tag).
            if let Some(caps) = pat.e7.captures(e) {
                let alloc_id: u64 = caps[1].parse()?;
                let r: u64 = caps[2].parse()?;
                gc_pruned += r;
                if let Some(&root) = alloc_root.get(&alloc_id) {
                    *tree_gc_pruned.entry(root).or_default() += r;
                }
            }
        } else if e.starts_with("E8") {
            // Exposed(tag, alloc): attribute to the tag's tree if known.
            if let Some(caps) = pat.e8.captures(e) {
                let tag: u64 = caps[1].parse()?;
                exposures += 1;
                if let Some(&root) = tag_root.get(&tag) {
                    *tree_exposures.entry(root).or_default() += 1;
                }
            }
        }
    }

    let mx = |m: &HashMap<u64, u64>| m.values().copied().max().unwrap_or(0);
    max_nodes = max_nodes.max(mx(&tree_nodes));
    max_reads = max_reads.max(mx(&tree_reads));
    max_writes = max_writes.max(mx(&tree_writes));
    max_visited = max_visited.max(mx(&tree_visited));
    max_skipped = max_skipped.max(mx(&tree_skipped));
    max_gc_pruned = max_gc_pruned.max(mx(&tree_gc_pruned));

    // tree_nodes keys are roots, values their node counts: bin each root
    // by size and fold in its per-tree event totals.
    let get = |m: &HashMap<u64, u64>, k: &u64| m.get(k).copied().unwrap_or(0);
    for (&root, &size) in &tree_nodes {
        let agg = tree_size_dist.entry(size).or_default();
        agg.count += 1;
        agg.reads += get(&tree_reads, &root);
        agg.writes += get(&tree_writes, &root);
        agg.visited += get(&tree_visited, &root);
        agg.skipped += get(&tree_skipped, &root);
        agg.gc_pruned += get(&tree_gc_pruned, &root);
        agg.exposures += get(&tree_exposures, &root);
    }

    // ── tree-size distribution CSV, written into the output dir ────────────
    // One file per project (output_tree_size_dist_<project>.csv), sorted by size.
    // Skipped when the project has no tree data, so we never leave an empty
    // header-only file.
    if !tree_size_dist.is_empty() {
        let dist_path = dist_dir.join(format!("output_tree_size_dist_{}.csv", crate_name));
        let mut dist_wtr = csv::Writer::from_path(&dist_path)?;
        dist_wtr.write_record([
            "tree_size", "count",
            "reads", "avg_reads", "writes", "avg_writes",
            "visited", "avg_visited", "skipped", "avg_skipped",
            "gc_pruned", "avg_gc_pruned", "exposures", "avg_exposures",
        ])?;
        let mut sizes: Vec<(&u64, &SizeAgg)> = tree_size_dist.iter().collect();
        sizes.sort_by_key(|(size, _)| **size);
        for (size, agg) in sizes {
            // Averages are per tree of this size (sum / count); count > 0 here.
            let avg = |n: u64| n as f64 / agg.count as f64;
            dist_wtr.write_record([
                size.to_string(),
                agg.count.to_string(),
                agg.reads.to_string(),     format!("{:.2}", avg(agg.reads)),
                agg.writes.to_string(),    format!("{:.2}", avg(agg.writes)),
                agg.visited.to_string(),   format!("{:.2}", avg(agg.visited)),
                agg.skipped.to_string(),   format!("{:.2}", avg(agg.skipped)),
                agg.gc_pruned.to_string(), format!("{:.2}", avg(agg.gc_pruned)),
                agg.exposures.to_string(), format!("{:.2}", avg(agg.exposures)),
            ])?;
        }
        dist_wtr.flush()?;
        eprintln!("wrote {}", dist_path.display());
    }

    // ── derived scalars ───────────────────────────────────────────────

    let avg = |n: u64, d: u64| if d > 0 { n as f64 / d as f64 } else { 0.0 };
    let avg_nodes = avg(nodes, trees);
    let avg_reads = avg(reads, trees);
    let avg_writes = avg(writes, trees);
    let avg_visited = avg(visited, trees);
    let avg_skipped = avg(skipped, trees);
    let avg_gc_pruned = avg(gc_pruned, trees);

    // ── build the row ─────────────────────────────────────────────────

    Ok(vec![
        crate_name.to_string(),
        format_comma(trees),
        format_comma(nodes),
        format!("{:.1} ({:})", avg_nodes, format_comma(max_nodes)),
        format_comma(reads),
        format!("{:.1} ({:})", avg_reads, format_comma(max_reads)),
        format_comma(writes),
        format!("{:.1} ({:})", avg_writes, format_comma(max_writes)),
        format_comma(visited),
        format!("{:.1} ({:})", avg_visited, format_comma(max_visited)),
        format_comma(skipped),
        format!("{:.1} ({:})", avg_skipped, format_comma(max_skipped)),
        format_comma(gc_invoked),
        format_comma(gc_pruned),
        format!("{:.1} ({:})", avg_gc_pruned, format_comma(max_gc_pruned)),
        format_comma(exposures),
    ])
}

// True for the trace files we process: `<project>.csv.gz` or `<project>.csv`.
// Our own `output_tree_size_dist_*.csv` side outputs are excluded so re-running
// on the same folder doesn't treat them as inputs.
fn is_trace_file(file_name: &str) -> bool {
    if file_name.starts_with("output_tree_size_dist_") {
        return false;
    }
    file_name.ends_with(".csv.gz") || file_name.ends_with(".csv")
}

// Strip the `.csv.gz` / `.csv` suffix to recover the project name; falls back to
// the plain file stem for anything not matching those extensions.
fn project_name(file_name: &str) -> String {
    file_name
        .strip_suffix(".csv.gz")
        .or_else(|| file_name.strip_suffix(".csv"))
        .map(|s| s.to_string())
        .unwrap_or_else(|| {
            Path::new(file_name)
                .file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| file_name.to_string())
        })
}

// ── Main ──────────────────────────────────────────────────────────────────────
//
// Usage: bsan_tracing <folder> [out.csv]
//
// Processes every `<project>.csv.gz` file in <folder> -- each file being one
// project's BorrowSanitizer event stream -- and writes a single combined CSV
// (a header plus one row per project) to <out.csv>, or to stdout if no output
// path is given. The project name is the file name with `.csv.gz` stripped.
//
// As a side output it also writes each project's tree-size distribution
// (output_tree_size_dist_<project>.csv) INTO <folder>, next to the inputs: one
// row per distinct tree size with the tree count plus the total and average of
// each per-tree event (reads, writes, visited, skipped, gc_pruned, exposures).
//
// Diagnostics and per-project progress go to stderr.

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let pat = Patterns::new();

    let mut args = std::env::args().skip(1);
    let dir_arg = args.next().unwrap_or_else(|| ".".to_string());
    let out_arg = args.next();
    let dir = Path::new(&dir_arg);
    if !dir.is_dir() {
        return Err(format!("folder not found: {}", dir.display()).into());
    }

    // Collect the trace files (`*.csv.gz` or `*.csv`), sorted for stable output.
    let mut files: Vec<_> = fs::read_dir(dir)?
        .filter_map(|e| e.ok())
        .filter(|e| is_trace_file(&e.file_name().to_string_lossy()))
        .collect();
    files.sort_by_key(|e| e.file_name());

    if files.is_empty() {
        return Err(format!("no <project>.csv[.gz] files in {}", dir.display()).into());
    }
    eprintln!("Found {} project file(s) in {}", files.len(), dir.display());

    // Buffer the combined CSV, then write it to the output path or stdout.
    let mut wtr = csv::WriterBuilder::new().from_writer(vec![]);
    wtr.write_record(&build_header_main())?;

    let mut ok = 0u64;
    let mut failed = 0u64;
    for entry in &files {
        let fname = entry.file_name();
        let name = project_name(&fname.to_string_lossy());
        eprintln!("Analyzing '{}'", name);
        match process_file(&pat, &name, &entry.path(), dir) {
            Ok(row) => {
                wtr.write_record(&row)?;
                ok += 1;
                eprintln!("✓ {}", name);
            }
            Err(e) => {
                failed += 1;
                eprintln!("✗ {}: {}", name, e);
            }
        }
    }
    wtr.flush()?;
    let csv_bytes = wtr.into_inner()?;

    match out_arg {
        Some(path) => {
            fs::write(&path, &csv_bytes)?;
            eprintln!("wrote {}", path);
        }
        None => {
            use std::io::Write;
            std::io::stdout().write_all(&csv_bytes)?;
        }
    }

    eprintln!("Done: {} row(s) written, {} failed.", ok, failed);
    if failed > 0 {
        std::process::exit(1);
    }
    Ok(())
}
