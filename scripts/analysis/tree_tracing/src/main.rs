//! Post-hoc analysis of Tree Borrows event logs, for BOTH Miri (the `tracing`
//! branch) and BorrowSanitizer (the `e-logging` branch).
//!
//! The two runtimes emit the same event grammar, so one parser serves both; only
//! the file layout and the output shape differ, which is what `Format` selects.
//! Keeping them in one binary is deliberate: when they lived in two crates the
//! grammars silently drifted (E5/E7 were keyed by allocation on one side and by
//! tag on the other, and each side dropped wildcard subtrees differently), which
//! is exactly the class of bug a shared parser makes impossible.
//!
//! ── The event grammar ────────────────────────────────────────────────────────
//!
//!     E1:  Root Tag(alloc3, t3)       new allocation, root tag created
//!     E1a: Id(alloc3, Machine(Global)) allocation's memory kind      [Miri only]
//!     E2:  Reborrow(t4, t3, s4)       reborrow -> child tag (parent may be `tw`)
//!     E3:  Read(t10) | Read(tw)       read access via a tag (`tw` = wildcard)
//!     E4:  Write(t3) | Write(tw)      write access via a tag
//!     E5:  Access(t10, 2, 0)          per-tree access: nodes visited, skipped
//!     E5:  WC Access(t3, 2, 0)        wildcard-access variant, keyed by root
//!     E6:  GC                         one garbage-collection cycle
//!     E7:  Pruned(t3, 5)              nodes removed from a tree during a prune
//!     E8:  Exposed (t483, alloc83)    tag exposed (ptr->int)
//!
//! E1a is the only asymmetry: `MemoryKind` is an interpreter notion with no bsan
//! equivalent, so `memory_kinds` is empty for bsan runs. Everything else matches
//! byte for byte, `tw` forms included.
//!
//! `tw` is the wildcard: it owns no tree, so E3/E4 through it are counted by
//! neither runtime. A `tw` *parent* in E2 is different -- see the E2 arm.
//!
//! ── Sessions ────────────────────────────────────────────────────────────────
//!
//! Tags and allocation ids are only unique within ONE traced process, and both
//! runtimes' logs concatenate several processes:
//!
//!   * Miri writes one `events-*` file per run, so a file boundary is a process
//!     boundary.
//!   * bsan runs each test in its own process under a fresh `BSAN_NODE_LOG`,
//!     then `profile_bsan_dataset.sh` folds every test's log into one
//!     `<crate>.csv` under a leading test-name column:
//!         filter_ok,E5: Access(t4, 6, 0)
//!     so a change in that column is a process boundary.
//!
//! Both are handled by the same rule: a session ends at a new file or a new
//! prefix column, and the tag->tree maps reset. Carrying them across a boundary
//! would merge unrelated trees that happen to share a tag id -- inflating tree
//! sizes and misattributing every event hanging off them.
//!
//! Crate-level totals and the tree-size distribution accumulate across sessions;
//! the `max` columns are the largest per-tree value seen in any session.

use std::collections::HashMap;
use std::fs;
use std::io::BufRead;
use std::path::{Path, PathBuf};

use flate2::read::GzDecoder;
use regex::Regex;

// ── File reading (streams line-by-line, transparently gunzipping .gz) ─────────
//
// Returns a buffered reader rather than the whole file: a large trace (or a
// small gzip that explodes when decompressed) is processed one line at a time,
// so peak memory is bounded by the event maps, not by the file size.

fn open_reader(path: &Path) -> std::io::Result<Box<dyn BufRead>> {
    let file = fs::File::open(path)?;
    if path.extension().and_then(|e| e.to_str()) == Some("gz") {
        Ok(Box::new(std::io::BufReader::new(GzDecoder::new(file))))
    } else {
        Ok(Box::new(std::io::BufReader::new(file)))
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

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

// CSV-encode a single record (proper quoting for fields containing commas or
// quotes, e.g. the memory_kinds JSON) into one trimmed line, no trailing newline.
fn encode_record(record: &[String]) -> Result<String, Box<dyn std::error::Error>> {
    let mut wtr = csv::WriterBuilder::new().from_writer(vec![]);
    wtr.write_record(record)?;
    wtr.flush()?;
    let data = wtr.into_inner()?;
    let s = String::from_utf8(data)?;
    Ok(s.trim_end_matches(['\r', '\n']).to_string())
}

// Parse the tag out of a `t<digits>` / `tw` capture. `tw` (the wildcard) yields
// None so callers handle the no-owning-tree case explicitly.
fn parse_tag(s: &str) -> Option<u64> {
    if s == "tw" {
        None
    } else {
        s.strip_prefix('t').and_then(|d| d.parse().ok())
    }
}

// E1a<anything>(alloc<id>, <kind>). Hand-parsed rather than matched: `<kind>` is
// a Debug-printed `MemoryKind` that itself contains parens, e.g.
// `Machine(Global)`, which a regex would have to work to get right.
fn parse_e1a(e: &str) -> Option<(String, String)> {
    let open = e.find('(')?;
    let inner = e[open + 1..].strip_suffix(')')?;
    let (alloc_part, kind) = inner.split_once(", ")?;
    let alloc_id = alloc_part.strip_prefix("alloc")?.to_string();
    Some((alloc_id, kind.trim().to_string()))
}

// ── Regex bundle (compiled once) ─────────────────────────────────────────────

struct Patterns {
    /// Locates the event token within a line, tolerating the leading CSV column
    /// that bsan logs carry. Group 1 is the token; whatever precedes it is the
    /// session id. Anchoring to start-or-comma stops the `, ` separators inside
    /// a payload like `Access(t4, 6, 0)` from matching.
    event: Regex,
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
            event: Regex::new(r"(?:^|,)\s*(E\d+[a-z]?:)").unwrap(),
            e1: Regex::new(r"E1[^(]*\(alloc(\d+), t(\d+)\)").unwrap(),
            e2: Regex::new(r"E2[^(]*\(t(\d+), (t\d+|tw), s(\d+)\)").unwrap(),
            e3: Regex::new(r"E3[^(]*\((t\d+|tw)\)").unwrap(),
            e4: Regex::new(r"E4[^(]*\((t\d+|tw)\)").unwrap(),
            e5: Regex::new(r"E5[^(]*\(t(\d+), (\d+), (\d+)\)").unwrap(),
            e6: Regex::new(r"E6.*GC").unwrap(),
            e7: Regex::new(r"E7[^(]*\(t(\d+), (\d+)\)").unwrap(),
            e8: Regex::new(r"E8[^(]*\(t(\d+), alloc(\d+)\)").unwrap(),
        }
    }
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

// ── Per-session state ────────────────────────────────────────────────────────
//
// Everything keyed by a tag or allocation id, i.e. everything that is only
// meaningful within one traced process. Cleared at every session boundary.

#[derive(Default)]
struct Session {
    /// Any tag -> the root of the tree it belongs to.
    tag_root: HashMap<u64, u64>,
    /// Allocation ids we have seen an E1 for; gates E1a so a memory kind is only
    /// counted for an allocation that actually produced a tree.
    alloc_seen: HashMap<String, u64>,
    /// Per-tree counters, keyed by root tag. `tree_nodes` doubles as the set of
    /// known trees and their sizes.
    tree_nodes: HashMap<u64, u64>,
    tree_reads: HashMap<u64, u64>,
    tree_writes: HashMap<u64, u64>,
    tree_visited: HashMap<u64, u64>,
    tree_skipped: HashMap<u64, u64>,
    tree_gc_pruned: HashMap<u64, u64>,
    tree_exposures: HashMap<u64, u64>,
}

// ── Analysis ─────────────────────────────────────────────────────────────────
//
// Accumulates one unit of output (one Miri crate, or one bsan project) across
// however many sessions its logs contain.

#[derive(Default)]
struct Analysis {
    trees: u64,
    nodes: u64,
    reads: u64,
    writes: u64,
    visited: u64,
    skipped: u64,
    gc_invoked: u64,
    gc_pruned: u64,
    exposures: u64,

    max_nodes: u64,
    max_reads: u64,
    max_writes: u64,
    max_visited: u64,
    max_skipped: u64,
    max_gc_pruned: u64,

    memory_kinds: HashMap<String, u64>,
    size_dist: HashMap<u64, SizeAgg>,

    session: Session,
    /// The prefix column of the session in progress; a change ends the session.
    session_id: String,
}

impl Analysis {
    /// Feed one raw log line. Lines carrying no event token (headers, the node
    /// profile's own CSV rows) are ignored without ending the session.
    fn feed(&mut self, line: &str) -> Result<(), Box<dyn std::error::Error>> {
        let line = line.trim();
        if line.is_empty() {
            return Ok(());
        }
        let Some(caps) = self.pattern_event(line) else { return Ok(()) };
        let (session_id, e) = caps;
        if session_id != self.session_id {
            self.end_session();
            self.session_id = session_id;
        }
        self.dispatch(e)
    }

    /// Split a line into its session id and the event text. Kept separate so
    /// `feed` can borrow `self` mutably afterwards.
    fn pattern_event<'a>(&self, line: &'a str) -> Option<(String, &'a str)> {
        let m = PATTERNS.with(|p| p.event.captures(line).map(|c| c.get(1).unwrap().start()))?;
        let session_id = line[..m].trim_end_matches([',', ' ', '\t']).to_string();
        Some((session_id, &line[m..]))
    }

    fn dispatch(&mut self, e: &str) -> Result<(), Box<dyn std::error::Error>> {
        PATTERNS.with(|pat| -> Result<(), Box<dyn std::error::Error>> {
            let s = &mut self.session;
            // E1a must be tested before E1: both start with "E1".
            if e.starts_with("E1a") {
                if let Some((alloc_id, kind)) = parse_e1a(e) {
                    if s.alloc_seen.contains_key(&alloc_id) {
                        *self.memory_kinds.entry(kind).or_default() += 1;
                    }
                }
            } else if e.starts_with("E1") {
                if let Some(caps) = pat.e1.captures(e) {
                    let alloc_id = caps[1].to_string();
                    let tag: u64 = caps[2].parse()?;
                    s.alloc_seen.insert(alloc_id, tag);
                    s.tag_root.insert(tag, tag);
                    self.trees += 1;
                    self.nodes += 1;
                    *s.tree_nodes.entry(tag).or_default() += 1;
                }
            } else if e.starts_with("E2") {
                if let Some(caps) = pat.e2.captures(e) {
                    let child: u64 = caps[1].parse()?;
                    match parse_tag(&caps[2]) {
                        Some(parent) => {
                            if let Some(&root) = s.tag_root.get(&parent) {
                                s.tag_root.insert(child, root);
                                self.nodes += 1;
                                *s.tree_nodes.entry(root).or_default() += 1;
                            }
                        }
                        // A `tw` parent means the reborrow had wildcard
                        // provenance, so the runtime could not place it in an
                        // existing tree and rooted a *wildcard subtree* at
                        // `child` instead. That subtree is a tree of its own and
                        // accrues its own E5/E7 counts, so it has to be
                        // registered as a root -- otherwise those counts have no
                        // tree to land on. Its allocation stays unknown, which
                        // costs nothing: nothing here is keyed by allocation.
                        None => {
                            s.tag_root.insert(child, child);
                            self.trees += 1;
                            self.nodes += 1;
                            *s.tree_nodes.entry(child).or_default() += 1;
                        }
                    }
                }
            } else if e.starts_with("E3") {
                if let Some(caps) = pat.e3.captures(e) {
                    if let Some(tag) = parse_tag(&caps[1]) {
                        if let Some(&root) = s.tag_root.get(&tag) {
                            self.reads += 1;
                            *s.tree_reads.entry(root).or_default() += 1;
                        }
                    }
                }
            } else if e.starts_with("E4") {
                if let Some(caps) = pat.e4.captures(e) {
                    if let Some(tag) = parse_tag(&caps[1]) {
                        if let Some(&root) = s.tag_root.get(&tag) {
                            self.writes += 1;
                            *s.tree_writes.entry(root).or_default() += 1;
                        }
                    }
                }
            } else if e.starts_with("E5") {
                // Covers both `Access` (keyed by the accessed tag) and
                // `WC Access` (keyed by the walked tree's root); `tag_root`
                // resolves either.
                if let Some(caps) = pat.e5.captures(e) {
                    let tag: u64 = caps[1].parse()?;
                    let v: u64 = caps[2].parse()?;
                    let sk: u64 = caps[3].parse()?;
                    if let Some(&root) = s.tag_root.get(&tag) {
                        self.visited += v;
                        self.skipped += sk;
                        *s.tree_visited.entry(root).or_default() += v;
                        *s.tree_skipped.entry(root).or_default() += sk;
                    }
                }
            } else if e.starts_with("E6") {
                // Count "E6: GC" cycles; the "E6 ... start" sentinel has no "GC".
                if pat.e6.is_match(e) {
                    self.gc_invoked += 1;
                }
            } else if e.starts_with("E7") {
                // Keyed by the root tag of the tree that pruned, so the count
                // needs no allocation->root guess.
                if let Some(caps) = pat.e7.captures(e) {
                    let tag: u64 = caps[1].parse()?;
                    let r: u64 = caps[2].parse()?;
                    self.gc_pruned += r;
                    if let Some(&root) = s.tag_root.get(&tag) {
                        *s.tree_gc_pruned.entry(root).or_default() += r;
                    }
                }
            } else if e.starts_with("E8") {
                // Exposed(tag, alloc): attribute to the tag's tree if known.
                if let Some(caps) = pat.e8.captures(e) {
                    let tag: u64 = caps[1].parse()?;
                    self.exposures += 1;
                    if let Some(&root) = s.tag_root.get(&tag) {
                        *s.tree_exposures.entry(root).or_default() += 1;
                    }
                }
            }
            Ok(())
        })
    }

    /// Fold the finished session's per-tree data into the crate-level maxima and
    /// the tree-size distribution, then clear it. Idempotent on an empty session.
    fn end_session(&mut self) {
        let s = &self.session;
        let mx = |m: &HashMap<u64, u64>| m.values().copied().max().unwrap_or(0);
        self.max_nodes = self.max_nodes.max(mx(&s.tree_nodes));
        self.max_reads = self.max_reads.max(mx(&s.tree_reads));
        self.max_writes = self.max_writes.max(mx(&s.tree_writes));
        self.max_visited = self.max_visited.max(mx(&s.tree_visited));
        self.max_skipped = self.max_skipped.max(mx(&s.tree_skipped));
        self.max_gc_pruned = self.max_gc_pruned.max(mx(&s.tree_gc_pruned));

        // tree_nodes keys are roots, values their node counts: bin each root by
        // size and fold in its per-tree event totals.
        let get = |m: &HashMap<u64, u64>, k: &u64| m.get(k).copied().unwrap_or(0);
        for (&root, &size) in &s.tree_nodes {
            let agg = self.size_dist.entry(size).or_default();
            agg.count += 1;
            agg.reads += get(&s.tree_reads, &root);
            agg.writes += get(&s.tree_writes, &root);
            agg.visited += get(&s.tree_visited, &root);
            agg.skipped += get(&s.tree_skipped, &root);
            agg.gc_pruned += get(&s.tree_gc_pruned, &root);
            agg.exposures += get(&s.tree_exposures, &root);
        }
        self.session = Session::default();
    }

    /// Write this unit's tree-size distribution CSV. Skipped when there is no
    /// tree data, so we never leave an empty header-only file behind.
    fn write_dist(&self, name: &str, dir: &Path) -> Result<(), Box<dyn std::error::Error>> {
        if self.size_dist.is_empty() {
            return Ok(());
        }
        let path = dir.join(format!("output_tree_size_dist_{}.csv", name));
        let mut wtr = csv::Writer::from_path(&path)?;
        wtr.write_record([
            "tree_size", "count",
            "reads", "avg_reads", "writes", "avg_writes",
            "visited", "avg_visited", "skipped", "avg_skipped",
            "gc_pruned", "avg_gc_pruned", "exposures", "avg_exposures",
        ])?;
        let mut sizes: Vec<(&u64, &SizeAgg)> = self.size_dist.iter().collect();
        sizes.sort_by_key(|(size, _)| **size);
        for (size, agg) in sizes {
            // Averages are per tree of this size (sum / count); count > 0 here.
            let avg = |n: u64| n as f64 / agg.count as f64;
            wtr.write_record([
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
        wtr.flush()?;
        eprintln!("wrote {}", path.display());
        Ok(())
    }

    /// Reduce to the single summary row for this unit.
    fn row(&self, name: &str) -> Result<Vec<String>, Box<dyn std::error::Error>> {
        let avg = |n: u64, d: u64| if d > 0 { n as f64 / d as f64 } else { 0.0 };
        let mut mk: Vec<(&String, &u64)> = self.memory_kinds.iter().collect();
        mk.sort_by_key(|(k, _)| k.as_str());
        let mk_map: serde_json::Map<String, serde_json::Value> = mk
            .into_iter()
            .map(|(k, v)| (k.clone(), serde_json::Value::Number((*v).into())))
            .collect();

        Ok(vec![
            name.to_string(),
            format_comma(self.trees),
            format_comma(self.nodes),
            format!("{:.1} ({:})", avg(self.nodes, self.trees), format_comma(self.max_nodes)),
            format_comma(self.reads),
            format!("{:.1} ({:})", avg(self.reads, self.trees), format_comma(self.max_reads)),
            format_comma(self.writes),
            format!("{:.1} ({:})", avg(self.writes, self.trees), format_comma(self.max_writes)),
            format_comma(self.visited),
            format!("{:.1} ({:})", avg(self.visited, self.trees), format_comma(self.max_visited)),
            format_comma(self.skipped),
            format!("{:.1} ({:})", avg(self.skipped, self.trees), format_comma(self.max_skipped)),
            format_comma(self.gc_invoked),
            format_comma(self.gc_pruned),
            format!("{:.1} ({:})", avg(self.gc_pruned, self.trees), format_comma(self.max_gc_pruned)),
            format_comma(self.exposures),
            serde_json::to_string(&mk_map)?,
        ])
    }
}

fn build_header() -> Vec<String> {
    [
        "crate", "trees", "nodes", "avg_nodes", "read", "avg_read (max)", "write",
        "avg_write (max)", "visited", "avg_visited (max)", "skipped", "avg_skipped (max)",
        "gc_invoked", "gc_pruned", "avg_gc_pruned", "exposures", "memory_kinds",
    ]
    .into_iter()
    .map(|s| s.to_string())
    .collect()
}

thread_local! {
    static PATTERNS: Patterns = Patterns::new();
}

// ── Input layouts ────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
enum Format {
    /// Miri: <path> is ONE crate dir of `events-*` files (one file per process).
    Miri,
    /// bsan: <path> is a folder of `<project>.csv[.gz]` logs (one file per
    /// project, many test processes concatenated inside).
    Bsan,
}

// True for the bsan trace files we process. Our own `output_tree_size_dist_*.csv`
// side outputs are excluded so re-running on a folder never eats its own output.
fn is_trace_file(file_name: &str) -> bool {
    !file_name.starts_with("output_tree_size_dist_")
        && (file_name.ends_with(".csv.gz") || file_name.ends_with(".csv"))
}

// Strip `.csv.gz` / `.csv` to recover the project name.
fn project_name(file_name: &str) -> String {
    file_name
        .strip_suffix(".csv.gz")
        .or_else(|| file_name.strip_suffix(".csv"))
        .map(|s| s.to_string())
        .unwrap_or_else(|| file_name.to_string())
}

fn detect_format(dir: &Path) -> Result<Format, Box<dyn std::error::Error>> {
    let mut has_events = false;
    let mut has_trace = false;
    for entry in fs::read_dir(dir)?.filter_map(|e| e.ok()) {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with("events-") {
            has_events = true;
        } else if is_trace_file(&name) {
            has_trace = true;
        }
    }
    match (has_events, has_trace) {
        (true, _) => Ok(Format::Miri),
        (false, true) => Ok(Format::Bsan),
        (false, false) => Err(format!(
            "cannot tell format of {}: no events-* files (miri) and no \
             <project>.csv[.gz] files (bsan). Pass --format to force one.",
            dir.display()
        )
        .into()),
    }
}

/// Analyze one unit: a Miri crate dir (many `events-*` files, one session each)
/// or a single bsan project file (many sessions, split on the prefix column).
fn analyze(paths: &[PathBuf]) -> Result<Analysis, Box<dyn std::error::Error>> {
    let mut an = Analysis::default();
    for path in paths {
        // A new file is always a new process, so never let a session span files.
        an.end_session();
        an.session_id = String::new();
        for line in open_reader(path)?.lines() {
            an.feed(&line?)?;
        }
    }
    an.end_session();
    Ok(an)
}

// ── Main ─────────────────────────────────────────────────────────────────────

const USAGE: &str = "Usage: tree_tracing [--format miri|bsan] [--dist-only] <path> [out]\n\
    \n\
    \x20 <path>          miri: ONE crate dir of events-* files\n\
    \x20                 bsan: a folder of <project>.csv[.gz] trace files\n\
    \x20 <out>           bsan: combined CSV path (default: stdout)\n\
    \x20                 with --dist-only: the directory for the dist files\n\
    \x20 --format F      force miri or bsan (default: detected from <path>)\n\
    \x20 --dist-only     write only output_tree_size_dist_<name>.csv\n\
    \n\
    In miri mode the single crate row is printed as CSVHEADER:/CSVROW: lines for\n\
    run_tree_tracing.sh to collect. In bsan mode every project in the folder\n\
    becomes a row of one combined CSV.\n";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut dist_only = false;
    let mut forced: Option<Format> = None;
    let mut positional: Vec<String> = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--dist-only" => dist_only = true,
            "--format" => {
                forced = match args.next().as_deref() {
                    Some("miri") => Some(Format::Miri),
                    Some("bsan") => Some(Format::Bsan),
                    other => {
                        eprintln!("--format needs miri or bsan, got {:?}\n{}", other, USAGE);
                        std::process::exit(2);
                    }
                }
            }
            "-h" | "--help" => {
                print!("{}", USAGE);
                return Ok(());
            }
            // Usage goes to stderr as plain text: returning it as an Err would
            // print it Debug-escaped, with literal \n.
            _ if arg.starts_with('-') => {
                eprintln!("unknown flag: {}\n{}", arg, USAGE);
                std::process::exit(2);
            }
            _ => positional.push(arg),
        }
    }
    if positional.len() > 2 {
        eprintln!("too many arguments\n{}", USAGE);
        std::process::exit(2);
    }
    let mut positional = positional.into_iter();
    let dir_arg = positional.next().unwrap_or_else(|| ".".to_string());
    let out_arg = positional.next();
    let dir = Path::new(&dir_arg);
    if !dir.is_dir() {
        return Err(format!("not a directory: {}", dir.display()).into());
    }

    let format = match forced {
        Some(f) => f,
        None => {
            let f = detect_format(dir)?;
            eprintln!(
                "detected {} format in {}",
                if f == Format::Miri { "miri" } else { "bsan" },
                dir.display()
            );
            f
        }
    };

    // Under --dist-only the optional positional names the directory the
    // distribution files go into; otherwise they land next to the inputs.
    let dist_dir = match (dist_only, out_arg.as_deref()) {
        (true, Some(out)) => {
            let p = PathBuf::from(out);
            fs::create_dir_all(&p)?;
            p
        }
        _ => dir.to_path_buf(),
    };

    // Build the work list: (unit name, input files). Miri contributes exactly
    // one unit (the crate) whose sessions are its events-* files; bsan
    // contributes one unit per project file.
    let mut entries: Vec<_> = fs::read_dir(dir)?.filter_map(|e| e.ok()).collect();
    entries.sort_by_key(|e| e.file_name());
    let units: Vec<(String, Vec<PathBuf>)> = match format {
        Format::Miri => {
            let files: Vec<PathBuf> = entries
                .iter()
                .filter(|e| e.file_name().to_string_lossy().starts_with("events-"))
                .map(|e| e.path())
                .collect();
            let name = dir
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| dir_arg.clone());
            vec![(name, files)]
        }
        Format::Bsan => entries
            .iter()
            .filter(|e| is_trace_file(&e.file_name().to_string_lossy()))
            .map(|e| (project_name(&e.file_name().to_string_lossy()), vec![e.path()]))
            .collect(),
    };
    if units.is_empty() || units.iter().all(|(_, f)| f.is_empty()) {
        return Err(format!("no input files in {}", dir.display()).into());
    }
    eprintln!("Analyzing {} unit(s) in {}", units.len(), dir.display());

    let mut wtr = csv::WriterBuilder::new().from_writer(vec![]);
    wtr.write_record(&build_header())?;
    let mut ok = 0u64;
    let mut failed = 0u64;
    let mut rows: Vec<Vec<String>> = Vec::new();

    for (name, files) in &units {
        eprintln!("Analyzing '{}'", name);
        let result = analyze(files).and_then(|an| {
            an.write_dist(name, &dist_dir)?;
            an.row(name)
        });
        match result {
            Ok(row) => {
                wtr.write_record(&row)?;
                rows.push(row);
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

    if !dist_only {
        match format {
            // The orchestrator keeps the first header it sees, then the row.
            Format::Miri =>
                for row in &rows {
                    println!("CSVHEADER:{}", encode_record(&build_header())?);
                    println!("CSVROW:{}", encode_record(row)?);
                },
            Format::Bsan => match out_arg {
                Some(path) => {
                    fs::write(&path, &csv_bytes)?;
                    eprintln!("wrote {}", path);
                }
                None => {
                    use std::io::Write;
                    std::io::stdout().write_all(&csv_bytes)?;
                }
            },
        }
    }

    let unit = if dist_only { "distribution(s)" } else { "row(s)" };
    eprintln!("Done: {} {} written, {} failed.", ok, unit, failed);
    if failed > 0 {
        std::process::exit(1);
    }
    Ok(())
}
