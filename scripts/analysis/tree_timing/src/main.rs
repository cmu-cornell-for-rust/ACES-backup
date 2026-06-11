use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::Path;

use csv::Writer;
use flate2::read::GzDecoder;
use regex::Regex;
use serde_json;

// Directory holding the per-crate tracing output, relative to where the binary runs.
const BASE_DIR: &str = "../../outputs/tracing";

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

// ── Crate list ────────────────────────────────────────────────────────────────

fn collect_crates() -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let mut names: Vec<String> = fs::read_dir(BASE_DIR)?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|name| !name.starts_with('.'))
        .collect();
    names.sort();
    Ok(names)
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

struct Patterns {
    trace: Regex,
    empty: Regex,
    noop:  Regex,
    root:  Regex,
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
            trace: Regex::new(r"\[([A-Z, ]+)\]\s+(\d+)").unwrap(),
            empty: Regex::new(r"empty_fsm=(\d+)").unwrap(),
            noop:  Regex::new(r"noop_transitions=(\d+)").unwrap(),
            root:  Regex::new(r"^t(\d+)@").unwrap(),
            e1:    Regex::new(r"E1[^(]*\(alloc(\d+), t(\d+)\)").unwrap(),
            e2:    Regex::new(r"E2[^(]*\(t(\d+), t(\d+), s(\d+)\)").unwrap(),
            e3:    Regex::new(r"E3[^(]*\(t(\d+)\)").unwrap(),
            e4:    Regex::new(r"E4[^(]*\(t(\d+)\)").unwrap(),
            e5:    Regex::new(r"E5[^(]*\(t(\d+), (\d+), (\d+)\)").unwrap(),
            e6:    Regex::new(r"E6[^(]*\(\)").unwrap(),
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
        "loc_state","red_loc_state","transitions","red_transitions","red_trees",
        "memory_kinds",
    ].into_iter().map(|s| s.to_string()).collect()
}

// ── Main ──────────────────────────────────────────────────────────────────────

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let pat = Patterns::new();

    let mut wtr_main = Writer::from_path("output.csv")?;
    wtr_main.write_record(&build_header_main())?;

    for crate_name in collect_crates()? {
        let crate_path = Path::new(BASE_DIR).join(&crate_name);
        if !crate_path.exists() {
            eprintln!("Warning: directory {} not found, skipping", crate_name);
            continue;
        }

        // ── per-crate accumulators ────────────────────────────────────────
        let mut trees: u64 = 0;
        let mut nodes: u64 = 0;
        let mut reads: u64 = 0;
        let mut writes: u64 = 0;
        let mut visited: u64 = 0;
        let mut skipped: u64 = 0;
        let mut gc_invoked: u64 = 0;
        let mut gc_pruned: u64 = 0;
        let mut loc_states: u64 = 0;
        let mut red_loc_states: u64 = 0;
        let mut transitions: u64 = 0;
        let mut red_transitions: u64 = 0;

        let mut max_nodes: u64 = 0;
        let mut max_reads: u64 = 0;
        let mut max_writes: u64 = 0;
        let mut max_visited: u64 = 0;
        let mut max_skipped: u64 = 0;
        let mut max_gc_pruned: u64 = 0;

        let mut all_memory_kinds: HashMap<String, u64> = HashMap::new();
        let mut nonred_roots: HashSet<u64> = HashSet::new();

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
                        if pat.e6.is_match(e) {
                            gc_invoked += 1;
                        }
                        // "E6 (start)" sentinel — skip

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

            } else if fname_str.starts_with("traces-") {
                let content = read_content(&entry.path())?;
                for line in content.lines() {
                    if line.starts_with("__STATS__") {
                        let em: u64 = pat.empty.captures(line)
                            .and_then(|c| c[1].parse().ok()).unwrap_or(0);
                        let no: u64 = pat.noop.captures(line)
                            .and_then(|c| c[1].parse().ok()).unwrap_or(0);
                        red_loc_states  += em;
                        red_transitions += no;
                        loc_states      += em;
                        transitions     += no;
                    } else {
                        if let Some(caps) = pat.root.captures(line) {
                            let root: u64 = caps[1].parse()?;
                            nonred_roots.insert(root);
                        }
                        for caps in pat.trace.captures_iter(line) {
                            let c: u64 = caps[2].parse()?;
                            let n: u64 = caps[1].split(',').count() as u64;
                            loc_states  += c;
                            transitions += n * c;
                        }
                    }
                }
            }
        }

        // ── derived scalars ───────────────────────────────────────────────

        let avg = |n: u64, d: u64| if d > 0 { n as f64 / d as f64 } else { 0.0 };
        let avg_nodes     = avg(nodes,     trees);
        let avg_reads     = avg(reads,     trees);
        let avg_writes    = avg(writes,    trees);
        let avg_visited   = avg(visited,   trees);
        let avg_skipped   = avg(skipped,   trees);
        let avg_gc_pruned = avg(gc_pruned, trees);
        let red_trees     = trees - nonred_roots.len() as u64;

        let mut mk_sorted: Vec<(&String, &u64)> = all_memory_kinds.iter().collect();
        mk_sorted.sort_by_key(|(k, _)| k.as_str());
        let mk_map: serde_json::Map<String, serde_json::Value> = mk_sorted
            .into_iter()
            .map(|(k, v)| (k.clone(), serde_json::Value::Number((*v).into())))
            .collect();
        let memory_kinds_json = serde_json::to_string(&mk_map)?;

        // ── write main row ────────────────────────────────────────────────

        let main_row: Vec<String> = vec![
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
            format_comma(loc_states),
            format_comma(red_loc_states),
            format_comma(transitions),
            format_comma(red_transitions),
            format_comma(red_trees),
            memory_kinds_json,
        ];
        wtr_main.write_record(&main_row)?;
        wtr_main.flush()?;

        println!("✓ {}", crate_name);
    }

    println!("Done. output.csv written.");
    Ok(())
}
