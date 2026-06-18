use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::Path;

use flate2::read::GzDecoder;
use regex::Regex;
use serde_json;

// ── File reading (transparently gunzips .gz files) ──────────────────────────────

fn read_content(path: &Path) -> std::io::Result<String> {
    if path.extension().and_then(|e| e.to_str()) == Some("gz") {
        let mut decoder = GzDecoder::new(fs::File::open(path)?);
        let mut s = String::new();
        decoder.read_to_string(&mut s)?;
        Ok(s)
    } else {
        fs::read_to_string(path)
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

// CSV-encode a single record (proper quoting for fields containing commas/quotes,
// e.g. the memory_kinds JSON) into a single trimmed line, no trailing newline.
fn encode_record(record: &[String]) -> Result<String, Box<dyn std::error::Error>> {
    let mut wtr = csv::WriterBuilder::new().from_writer(vec![]);
    wtr.write_record(record)?;
    wtr.flush()?;
    let data = wtr.into_inner()?;
    let s = String::from_utf8(data)?;
    Ok(s.trim_end_matches(['\r', '\n']).to_string())
}

// ── Regex bundle (compiled once) ──────────────────────────────────────────────

struct Patterns {
    e1:    Regex,
    e2:    Regex,
    e3:    Regex,
    e4:    Regex,
    e5:    Regex,
    e6:    Regex,
    e7:    Regex,
}

impl Patterns {
    fn new() -> Self {
        Self {
            e1:    Regex::new(r"E1[^(]*\(alloc(\d+), t(\d+)\)").unwrap(),
            e2:    Regex::new(r"E2[^(]*\(t(\d+), t(\d+), s(\d+)\)").unwrap(),
            e3:    Regex::new(r"E3[^(]*\(t(\d+)\)").unwrap(),
            e4:    Regex::new(r"E4[^(]*\(t(\d+)\)").unwrap(),
            e5:    Regex::new(r"E5[^(]*\(t(\d+), (\d+), (\d+)\)").unwrap(),
            e6:    Regex::new(r"E6.*GC").unwrap(),
            e7:    Regex::new(r"E7[^(]*\(t(\d+), (\d+)\)").unwrap(),
        }
    }
}

fn parse_e1a(e: &str) -> Option<(String, String)> {
    // E1a<anything>(alloc<id>, <kind>)
    let open = e.find('(')?;
    let inner = e[open + 1..].strip_suffix(')')?;
    let (alloc_part, kind) = inner.split_once(", ")?;
    let alloc_id = alloc_part.strip_prefix("alloc")?.to_string();
    Some((alloc_id, kind.trim().to_string()))
}

// ── CSV header ──────────────────────────────────────────────────────────────

fn build_header_main() -> Vec<String> {
    vec![
        "crate","trees","nodes","avg_nodes","read","avg_read (max)","write","avg_write (max)",
        "visited","avg_visited (max)","skipped","avg_skipped (max)",
        "gc_invoked","gc_pruned","avg_gc_pruned",
        "memory_kinds",
    ].into_iter().map(|s| s.to_string()).collect()
}

// ── Tree-size distribution bucket ────────────────────────────────────────────
//
// One bucket per distinct tree size (node count). `count` is how many trees have
// that size; the rest are sums of each per-tree event across those trees, from
// which the distribution CSV derives the averages (sum / count).

#[derive(Default)]
struct SizeAgg {
    count:     u64,
    reads:     u64,
    writes:    u64,
    visited:   u64,
    skipped:   u64,
    gc_pruned: u64,
}

// ── Per-crate analysis ──────────────────────────────────────────────────────────
//
// Walk one crate's tracing directory (the events-*/traces-* files) and reduce it
// to a single CSV row. This is the unit of parallelism: the orchestrator launches
// one process per crate, so all per-crate state is local to this function.

fn process_crate(
    pat: &Patterns,
    crate_name: &str,
    crate_path: &Path,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    // ── per-crate accumulators ────────────────────────────────────────
    let mut trees: u64 = 0;
    let mut nodes: u64 = 0;
    let mut reads: u64 = 0;
    let mut writes: u64 = 0;
    let mut visited: u64 = 0;
    let mut skipped: u64 = 0;
    let mut gc_invoked: u64 = 0;
    let mut gc_pruned: u64 = 0;

    let mut max_nodes: u64 = 0;
    let mut max_reads: u64 = 0;
    let mut max_writes: u64 = 0;
    let mut max_visited: u64 = 0;
    let mut max_skipped: u64 = 0;
    let mut max_gc_pruned: u64 = 0;

    let mut all_memory_kinds: HashMap<String, u64> = HashMap::new();

    // tree-size distribution: maps a tree's node count -> aggregate stats over
    // all trees of that size, accumulated across every events file (the per-file
    // tree_* maps are reset per file).
    let mut tree_size_dist: HashMap<u64, SizeAgg> = HashMap::new();

    // ── collect and sort directory entries ────────────────────────────
    let mut entries: Vec<_> = fs::read_dir(crate_path)?
        .filter_map(|e| e.ok())
        .collect();
    entries.sort_by_key(|e| e.file_name());

    for entry in &entries {
        let fname = entry.file_name();
        let fname_str = fname.to_string_lossy();

        if fname_str.starts_with("events-") {
            // ── per-file per-tree maps ────────────────────────────────
            let mut tag_root:     HashMap<u64, u64> = HashMap::new();
            let mut alloc_to_tag: HashMap<String, u64> = HashMap::new();
            let mut tree_nodes:     HashMap<u64, u64> = HashMap::new();
            let mut tree_reads:     HashMap<u64, u64> = HashMap::new();
            let mut tree_writes:    HashMap<u64, u64> = HashMap::new();
            let mut tree_visited:   HashMap<u64, u64> = HashMap::new();
            let mut tree_skipped:   HashMap<u64, u64> = HashMap::new();
            let mut tree_gc_pruned: HashMap<u64, u64> = HashMap::new();

            let content = read_content(&entry.path())?;
            let events: Vec<&str> = content
                .lines()
                .map(|l| l.trim())
                .filter(|l| !l.is_empty())
                .collect();

            for e in &events {
                if e.starts_with("E1a") {
                    if let Some((alloc_id, kind)) = parse_e1a(e) {
                        if alloc_to_tag.contains_key(&alloc_id) {
                            *all_memory_kinds.entry(kind).or_default() += 1;
                        }
                    }

                } else if e.starts_with("E1") {
                    if let Some(caps) = pat.e1.captures(e) {
                        let alloc_id = caps[1].to_string();
                        let tag: u64 = caps[2].parse()?;
                        alloc_to_tag.insert(alloc_id, tag);
                        tag_root.insert(tag, tag);
                        trees += 1;
                        nodes += 1;
                        *tree_nodes.entry(tag).or_default() += 1;
                    }

                } else if e.starts_with("E2") {
                    if let Some(caps) = pat.e2.captures(e) {
                        let child:  u64 = caps[1].parse()?;
                        let parent: u64 = caps[2].parse()?;
                        if let Some(&root) = tag_root.get(&parent) {
                            tag_root.insert(child, root);
                            nodes += 1;
                            *tree_nodes.entry(root).or_default() += 1;
                        }
                    }

                } else if e.starts_with("E3") {
                    if let Some(caps) = pat.e3.captures(e) {
                        let tag: u64 = caps[1].parse()?;
                        if let Some(&root) = tag_root.get(&tag) {
                            reads += 1;
                            *tree_reads.entry(root).or_default() += 1;
                        }
                    }

                } else if e.starts_with("E4") {
                    if let Some(caps) = pat.e4.captures(e) {
                        let tag: u64 = caps[1].parse()?;
                        if let Some(&root) = tag_root.get(&tag) {
                            writes += 1;
                            *tree_writes.entry(root).or_default() += 1;
                        }
                    }

                } else if e.starts_with("E5") {
                    if let Some(caps) = pat.e5.captures(e) {
                        let tag: u64 = caps[1].parse()?;
                        let v:   u64 = caps[2].parse()?;
                        let s:   u64 = caps[3].parse()?;
                        if let Some(&root) = tag_root.get(&tag) {
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
                    if let Some(caps) = pat.e7.captures(e) {
                        let tag: u64 = caps[1].parse()?;
                        let r:   u64 = caps[2].parse()?;
                        gc_pruned += r;
                        if let Some(&root) = tag_root.get(&tag) {
                            *tree_gc_pruned.entry(root).or_default() += r;
                        }
                    }
                }
            }

            let mx = |m: &HashMap<u64, u64>| m.values().copied().max().unwrap_or(0);
            max_nodes     = max_nodes.max(mx(&tree_nodes));
            max_reads     = max_reads.max(mx(&tree_reads));
            max_writes    = max_writes.max(mx(&tree_writes));
            max_visited   = max_visited.max(mx(&tree_visited));
            max_skipped   = max_skipped.max(mx(&tree_skipped));
            max_gc_pruned = max_gc_pruned.max(mx(&tree_gc_pruned));

            // tree_nodes keys are roots, values their node counts: bin each root
            // by size and fold in its per-tree event totals.
            let get = |m: &HashMap<u64, u64>, k: &u64| m.get(k).copied().unwrap_or(0);
            for (&root, &size) in &tree_nodes {
                let agg = tree_size_dist.entry(size).or_default();
                agg.count     += 1;
                agg.reads     += get(&tree_reads,     &root);
                agg.writes    += get(&tree_writes,    &root);
                agg.visited   += get(&tree_visited,   &root);
                agg.skipped   += get(&tree_skipped,   &root);
                agg.gc_pruned += get(&tree_gc_pruned, &root);
            }
        }
    }

    // ── tree-size distribution CSV, written next to the inputs ────────────
    // One file per crate in the crate's own tracing dir (output_tree_size_dist_
    // <crate>.csv, columns tree_size,count), sorted by size. Skipped when the
    // crate has no tree data, so we never leave an empty header-only file.
    if !tree_size_dist.is_empty() {
        let dist_path = crate_path.join(format!("output_tree_size_dist_{}.csv", crate_name));
        let mut dist_wtr = csv::Writer::from_path(&dist_path)?;
        dist_wtr.write_record([
            "tree_size", "count",
            "reads", "avg_reads", "writes", "avg_writes",
            "visited", "avg_visited", "skipped", "avg_skipped",
            "gc_pruned", "avg_gc_pruned",
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
            ])?;
        }
        dist_wtr.flush()?;
        eprintln!("wrote {}", dist_path.display());
    }

    // ── derived scalars ───────────────────────────────────────────────

    let avg = |n: u64, d: u64| if d > 0 { n as f64 / d as f64 } else { 0.0 };
    let avg_nodes     = avg(nodes,     trees);
    let avg_reads     = avg(reads,     trees);
    let avg_writes    = avg(writes,    trees);
    let avg_visited   = avg(visited,   trees);
    let avg_skipped   = avg(skipped,   trees);
    let avg_gc_pruned = avg(gc_pruned, trees);

    let mut mk_sorted: Vec<(&String, &u64)> = all_memory_kinds.iter().collect();
    mk_sorted.sort_by_key(|(k, _)| k.as_str());
    let mk_map: serde_json::Map<String, serde_json::Value> = mk_sorted
        .into_iter()
        .map(|(k, v)| (k.clone(), serde_json::Value::Number((*v).into())))
        .collect();
    let memory_kinds_json = serde_json::to_string(&mk_map)?;

    // ── build the row ─────────────────────────────────────────────────

    Ok(vec![
        crate_name.to_string(),
        format_comma(trees),
        format_comma(nodes),
        format!("{:.1} ({:})", avg_nodes,     format_comma(max_nodes)),
        format_comma(reads),
        format!("{:.1} ({:})", avg_reads,     format_comma(max_reads)),
        format_comma(writes),
        format!("{:.1} ({:})", avg_writes,    format_comma(max_writes)),
        format_comma(visited),
        format!("{:.1} ({:})", avg_visited,   format_comma(max_visited)),
        format_comma(skipped),
        format!("{:.1} ({:})", avg_skipped,   format_comma(max_skipped)),
        format_comma(gc_invoked),
        format_comma(gc_pruned),
        format!("{:.1} ({:})", avg_gc_pruned, format_comma(max_gc_pruned)),
        memory_kinds_json,
    ])
}

// ── Main ──────────────────────────────────────────────────────────────────────
//
// Usage: tree_tracing <crate_dir>
//
// Processes the tracing output for ONE crate (a directory of events-* files;
// traces-* files are ignored) and emits its single CSV row on stdout, prefixed
// so the orchestrator
// (run_tree_tracing.sh) can collect it from the job log:
//   CSVHEADER:<csv-encoded header>
//   CSVROW:<csv-encoded row>
// Diagnostics go to stderr. The crate name is the basename of <crate_dir>.
//
// As a side output it also writes the crate's tree-size distribution
// (output_tree_size_dist_<crate>.csv) INTO <crate_dir>, alongside the input
// files: one row per distinct tree size with the tree count plus the total and
// average of each per-tree event (reads, writes, visited, skipped, gc_pruned).

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let pat = Patterns::new();

    let crate_path_arg = std::env::args().nth(1).unwrap_or_else(|| ".".to_string());
    let crate_path = Path::new(&crate_path_arg);
    if !crate_path.is_dir() {
        return Err(format!("crate dir not found: {}", crate_path.display()).into());
    }
    let crate_name = crate_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| crate_path_arg.clone());

    eprintln!("Analyzing crate '{}' at {}", crate_name, crate_path.display());

    let row = process_crate(&pat, &crate_name, crate_path)?;

    // Header first (the orchestrator keeps the first one it sees), then the row.
    println!("CSVHEADER:{}", encode_record(&build_header_main())?);
    println!("CSVROW:{}", encode_record(&row)?);

    eprintln!("✓ {}", crate_name);
    Ok(())
}
