#!/usr/bin/env bash
# Emit JSON snapshot of BSAN corpus batch status.
# Invoked as a one-shot remote read via SSH from update_corpus_dashboard.sh (local).
set -euo pipefail

: "${ACES_ROOT:?ACES_ROOT required}"
# shellcheck source=/dev/null
source "${ACES_ROOT}/config.env"
export ACES_ROOT ACES_USER OUTPUT_DIR BSAN_DIR APPS_DIR GROUP_ROOT USER_SCRATCH

CORPUS_APPS=(
  uutils-coreutils ripgrep ring rustls nix quiche git2-rs rusqlite bat fd
  tikv-codec polars-core vector-core react-compiler
)

python3 - "${CORPUS_APPS[@]}" <<'PY'
import json, os, subprocess, sys, glob
from datetime import datetime, timezone

apps = sys.argv[1:]
bsan_dir = os.environ.get("BSAN_DIR", "")
output_dir = os.environ.get("OUTPUT_DIR", "")
user = os.environ.get("ACES_USER", "")

def run(cmd):
    try:
        return subprocess.check_output(
            cmd, shell=True, universal_newlines=True, stderr=subprocess.DEVNULL
        ).strip()
    except subprocess.CalledProcessError:
        return ""

def git_field(args):
    if not bsan_dir or not os.path.isdir(os.path.join(bsan_dir, ".git")):
        return ""
    return run('git -C "{}" {}'.format(bsan_dir, args))

def strip_job_prefix(name):
    return name[5:] if name.startswith("bsan-") else name

def pick_latest_log(app):
    pattern = os.path.join(output_dir, "{}.*.log".format(app))
    logs = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    return logs[0] if logs else None

def read_log_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.readlines()

def log_status_from_lines(lines):
    status = ""
    for line in lines:
        if line.startswith("status="):
            status = line.strip().split("=", 1)[1]
    return status

def log_headline(lines):
    keys = (
        "error:", "error[E", "Undefined Behavior", "test failed",
        "SIGSEGV", "SIGKILL", "panic", "could not compile",
        "failed to run custom build", "unable to find library",
        "foreign to the protected tag", "unprotected",
    )
    for line in reversed(lines):
        s = line.strip()
        if not s or s.startswith("running ") or s == "ok":
            continue
        low = s.lower()
        if any(k.lower() in low for k in keys):
            return s[:240]
    for line in reversed(lines):
        s = line.strip()
        if s.startswith("test result:") or s.startswith("run_seconds="):
            return s[:240]
    return ""

def log_excerpt(lines, max_lines=16):
    if not lines:
        return ""
    keys = (
        "error", "failed", "undefined behavior", "panic", "sigsegv", "sigkill",
        "status=", "could not compile", "configure: error", "verdict",
        "foreign to the protected", "unprotected",
    )
    hit = -1
    for i, line in enumerate(lines):
        low = line.lower()
        if any(k in low for k in keys):
            hit = i
    if hit >= 0:
        start = max(0, hit - 6)
        chunk = lines[start : start + max_lines]
    else:
        chunk = lines[-max_lines:]
    text = "".join(chunk).strip()
    if len(text) > 2200:
        text = text[-2200:]
    return text

def classify_app(app, status, headline, excerpt, slurm_state):
    h = (headline + " " + excerpt).lower()
    if status == "ok":
        return "pass", "All tests passed under BSAN main."
    if slurm_state in ("RUNNING", "COMPLETING", "PENDING"):
        return "running", "Job still in flight; log is partial."
    if status == "build_error":
        if "lsqlite3" in h:
            return "container_deps", "Missing libsqlite3 in bsan.sif — skip or rebuild image."
        if "fuse-ld" in h and "unused" in h:
            return "harness_cc", "BSAN linker flags leak into ring cc-rs C build (-fuse-ld unused)."
        if "protobuf-src" in h or "c compiler cannot create executables" in h:
            return "harness_cc", "BSAN clang used as CC breaks protobuf-src autoconf link probe."
        if "stdsimd" in h or "unknown feature" in h:
            return "toolchain_compat", "ahash stdsimd feature unsupported on BSAN rustc 1.98."
        if "e0432" in h or "unresolved import" in h:
            return "workspace_pin", "polars-core compile failure — workspace/pin mismatch, not BSAN-specific."
        return "build_blocker", "Build failed before/during test phase."
    if status == "test_error":
        if app == "git2-rs" and ("foreign" in h or "unprotected" in h or "libgit2" in h):
            return "likely_fp", "GC tag violation at libgit2 C alloc — classic BSAN_RUST_ONLY mixed-heap FP."
        if app == "uutils-coreutils" and ("foreign" in h or "unprotected" in h):
            return "investigate", "GC deferred-ref violation on System dealloc in uu_dd — may be teardown or real."
        if "sigkill" in h:
            return "infra", "SIGKILL after long run — likely OOM or node kill, not a BSAN report."
        if "sigsegv" in h or "signal: 11" in h:
            return "investigate", "SIGSEGV during tests — needs isolated repro."
        if "stack_overflow" in h:
            return "investigate", "Fault in std PAL stack_overflow handler — may be signal-path noise."
        return "investigate", "Test failure under BSAN — isolate named test."
    if status == "fetch_error":
        return "harness", "cargo fetch failed — network or lock issue."
    return "unknown", "No terminal status yet."

VERDICT_LABELS = {
    "pass": "Passed",
    "running": "In progress",
    "likely_fp": "Likely FP",
    "investigate": "Investigate",
    "harness_cc": "Harness CC",
    "container_deps": "Container deps",
    "toolchain_compat": "Toolchain",
    "workspace_pin": "Workspace",
    "build_blocker": "Build blocker",
    "infra": "Infra",
    "harness": "Harness",
    "unknown": "Unknown",
}

fetched_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

bsan = {
    "branch": git_field("rev-parse --abbrev-ref HEAD"),
    "commit": git_field("rev-parse --short HEAD"),
    "subject": git_field("log -1 --format=%s"),
}

jobs = []
for line in run('squeue -h -u {} -o "%i|%j|%T|%M"'.format(user)).splitlines():
    parts = line.split("|")
    if len(parts) < 4:
        continue
    jid, name, state, elapsed = parts[0], parts[1], parts[2], parts[3]
    if not name.startswith("bsan-"):
        continue
    jobs.append({
        "id": jid,
        "name": name,
        "app": strip_job_prefix(name),
        "state": state,
        "elapsed": elapsed,
    })

job_by_app = {}
for app in apps:
    target = "bsan-{}".format(app)
    match = None
    for j in jobs:
        n = j["name"]
        if n == target or target.startswith(n) or n.startswith(target[:20]):
            match = j
            break
    if match:
        job_by_app[app] = match

app_rows = []
counts = {
    "ok": 0, "test_error": 0, "build_error": 0, "fetch_error": 0,
    "in_progress": 0, "queued": 0, "other": 0,
}

for app in apps:
    latest = pick_latest_log(app)
    log_status = ""
    log_stamp = ""
    log_file = None
    headline = ""
    excerpt = ""
    lines = []
    if latest:
        log_file = os.path.basename(latest)
        log_stamp = log_file.replace("{}.".format(app), "").replace(".log", "")
        lines = read_log_lines(latest)
        log_status = log_status_from_lines(lines)
        headline = log_headline(lines)
        excerpt = log_excerpt(lines)

    slurm = job_by_app.get(app, {})
    slurm_state = slurm.get("state", "")
    slurm_id = slurm.get("id", "")
    slurm_elapsed = slurm.get("elapsed", "")

    verdict, analysis = classify_app(app, log_status, headline, excerpt, slurm_state)

    if log_status == "ok":
        counts["ok"] += 1
    elif log_status == "test_error":
        counts["test_error"] += 1
    elif log_status == "build_error":
        counts["build_error"] += 1
    elif log_status == "fetch_error":
        counts["fetch_error"] += 1
    elif slurm_state in ("RUNNING", "COMPLETING"):
        counts["in_progress"] += 1
    elif slurm_state == "PENDING":
        counts["queued"] += 1
    elif log_status:
        counts["other"] += 1
    elif slurm_state:
        counts["in_progress"] += 1
    else:
        counts["other"] += 1

    app_rows.append({
        "app": app,
        "logStatus": log_status or None,
        "logStamp": log_stamp or None,
        "logFile": log_file,
        "headline": headline or None,
        "logExcerpt": excerpt or None,
        "verdict": verdict,
        "analysis": analysis,
        "slurmId": slurm_id or None,
        "slurmState": slurm_state or None,
        "slurmElapsed": slurm_elapsed or None,
    })

submit_log = ""
submit_logs = sorted(
    glob.glob(os.path.join(output_dir, "corpus.submit.*.log")),
    key=os.path.getmtime,
    reverse=True,
)
if submit_logs:
    submit_log = os.path.basename(submit_logs[0])

verdict_counts = {}
for row in app_rows:
    v = row["verdict"]
    verdict_counts[v] = verdict_counts.get(v, 0) + 1

snapshot = {
    "fetchedAt": fetched_at,
    "bsan": bsan,
    "submitLog": submit_log,
    "verdictLabels": VERDICT_LABELS,
    "analysisSummary": (
        "BSAN main (@ deferred GC #252). Build errors cluster into harness CC flags "
        "(ring, tikv), container deps (rusqlite), and toolchain/workspace pins "
        "(vector, polars). Test errors: git2-rs matches mixed-heap FP pattern; "
        "uutils hits new GC tag violation on System dealloc; nix SIGKILL is infra."
    ),
    "summary": {
        "total": len(apps),
        "queued": sum(1 for j in jobs if j["state"] == "PENDING"),
        "running": sum(1 for j in jobs if j["state"] in ("RUNNING", "COMPLETING")),
        "verdicts": verdict_counts,
    },
    "jobs": jobs,
    "apps": app_rows,
}
snapshot["summary"].update(counts)

print(json.dumps(snapshot, indent=2))
PY
