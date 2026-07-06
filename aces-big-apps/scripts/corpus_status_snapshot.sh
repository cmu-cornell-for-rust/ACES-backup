#!/usr/bin/env bash
# Emit JSON snapshot of BSAN corpus batch status.
# Invoked as a one-shot remote read via SSH from update_corpus_dashboard.sh (local).
set -euo pipefail

: "${ACES_ROOT:?ACES_ROOT required}"
# shellcheck source=/dev/null
source "${ACES_ROOT}/config.env"
export ACES_ROOT ACES_USER OUTPUT_DIR BSAN_DIR APPS_DIR GROUP_ROOT USER_SCRATCH BSAN_CPUS

load_corpus_apps() {
  local list_file="${ACES_ROOT}/datasets/big-apps/corpus-apps.txt"
  CORPUS_APPS=()
  local line trimmed
  while IFS= read -r line || [[ -n "${line}" ]]; do
    trimmed="${line%%#*}"
    trimmed="$(echo "${trimmed}" | xargs 2>/dev/null || true)"
    [[ -n "${trimmed}" ]] || continue
    CORPUS_APPS+=("${trimmed}")
  done <"${list_file}"
}

load_corpus_apps

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

def pick_sbatch_log(app, job_id):
    sbatch_dir = os.path.join(output_dir, "sbatch")
    if job_id:
        exact = os.path.join(sbatch_dir, "bsan-{}.{}.log".format(app, job_id))
        if os.path.isfile(exact):
            return exact
    pattern = os.path.join(sbatch_dir, "bsan-{}.*.log".format(app))
    logs = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    return logs[0] if logs else None

def pick_active_log(app, job_id, slurm_state):
    """Prefer in-flight sbatch log over stale corpus log during reruns."""
    sbatch = pick_sbatch_log(app, job_id) if job_id else pick_sbatch_log(app, "")
    corpus = pick_latest_log(app)
    active_states = ("RUNNING", "COMPLETING", "PENDING")
    if slurm_state in active_states and sbatch:
        return sbatch, "sbatch"
    if sbatch and corpus:
        if os.path.getmtime(sbatch) >= os.path.getmtime(corpus):
            return sbatch, "sbatch"
        lines = read_log_lines(corpus)
        if not log_status_from_lines(lines):
            return sbatch, "sbatch"
        return corpus, "corpus"
    if sbatch:
        return sbatch, "sbatch"
    return corpus, "corpus"

def parse_submit_log(path):
    info = {"stamp": "", "apps": [], "submissions": []}
    if not path or not os.path.isfile(path):
        return info
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith("stamp="):
                info["stamp"] = line.split("=", 1)[1]
            elif line.startswith("apps="):
                info["apps"] = line.split("=", 1)[1].split()
            elif line.startswith("submitted job_id="):
                parts = line.split()
                row = {}
                for p in parts[1:]:
                    if "=" in p:
                        k, v = p.split("=", 1)
                        row[k] = v
                if row:
                    info["submissions"].append(row)
    return info

def tail_lines(path, max_lines=20):
    if not path or not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.readlines()[-max_lines:]

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
        if app == "fd" and ("test_exec_nulls" in h or "null" in h):
            return "infra", "fd --print0/--exec ordering on 1-CPU nodes; fixed with BSAN_CPUS>1."
        if app == "polars-core" and "unreachable" in h:
            return "investigate", "proptest scalar cast hit unreachable! — isolate vs BSAN/proptest seed."
        if app in ("rusty-v8", "firecracker", "wgpu-hal") and status == "build_error":
            return "build_blocker", "Heavy FFI/native deps — may need image or host-cc tweaks."
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

submit_logs = sorted(
    glob.glob(os.path.join(output_dir, "corpus.submit.*.log")),
    key=os.path.getmtime,
    reverse=True,
)
rerun_batch = parse_submit_log(submit_logs[0]) if submit_logs else {"stamp": "", "apps": [], "submissions": []}
rerun_job_ids = {s.get("app"): s.get("job_id") for s in rerun_batch.get("submissions", []) if s.get("app")}
rerun_apps = set(rerun_batch.get("apps", []))

servo_submit_logs = sorted(
    glob.glob(os.path.join(output_dir, "servo-fonts.submit.*.log")),
    key=os.path.getmtime,
    reverse=True,
)
servo_batch = parse_submit_log(servo_submit_logs[0]) if servo_submit_logs else {"stamp": "", "submissions": []}

app_rows = []
counts = {
    "ok": 0, "test_error": 0, "build_error": 0, "fetch_error": 0,
    "in_progress": 0, "queued": 0, "other": 0,
}

for app in apps:
    slurm = job_by_app.get(app, {})
    slurm_state = slurm.get("state", "")
    slurm_id = slurm.get("id", "") or rerun_job_ids.get(app, "")
    slurm_elapsed = slurm.get("elapsed", "")

    latest, log_source = pick_active_log(app, slurm_id, slurm_state)
    log_status = ""
    log_stamp = ""
    log_file = None
    headline = ""
    excerpt = ""
    lines = []
    if latest:
        log_file = os.path.basename(latest)
        if log_source == "sbatch":
            log_stamp = "sbatch:{}".format(slurm_id or "?")
        else:
            log_stamp = log_file.replace("{}.".format(app), "").replace(".log", "")
        lines = read_log_lines(latest)
        log_status = log_status_from_lines(lines)
        headline = log_headline(lines)
        excerpt = log_excerpt(lines)
        if slurm_state in ("RUNNING", "COMPLETING") and not excerpt:
            excerpt = "".join(tail_lines(latest, 18)).strip()

    verdict, analysis = classify_app(app, log_status, headline, excerpt, slurm_state)
    if app in rerun_apps and slurm_state in ("RUNNING", "COMPLETING", "PENDING"):
        verdict, analysis = "running", "Rerun in progress (live sbatch log)."
    elif app in rerun_apps and not log_status and slurm_state:
        verdict, analysis = "running", "Rerun queued or starting."

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
        "logSource": log_source if latest else None,
        "headline": headline or None,
        "logExcerpt": excerpt or None,
        "verdict": verdict,
        "analysis": analysis,
        "slurmId": slurm_id or None,
        "slurmState": slurm_state or None,
        "slurmElapsed": slurm_elapsed or None,
        "isRerun": app in rerun_apps,
    })

submit_log = os.path.basename(submit_logs[0]) if submit_logs else ""

rerun_rows = []
for sub in rerun_batch.get("submissions", []):
    app_name = sub.get("app", "")
    jid = sub.get("job_id", "")
    jstate = ""
    jelapsed = ""
    for j in jobs:
        if j["id"] == jid:
            jstate = j["state"]
            jelapsed = j["elapsed"]
            break
    row = next((r for r in app_rows if r["app"] == app_name), None)
    rerun_rows.append({
        "app": app_name,
        "jobId": jid,
        "state": jstate or (row or {}).get("slurmState") or "—",
        "elapsed": jelapsed or (row or {}).get("slurmElapsed") or "",
        "logStatus": (row or {}).get("logStatus"),
        "headline": (row or {}).get("headline"),
    })

corpus_app_names = set(apps)
infra_jobs = []
for j in jobs:
    if j["app"] in corpus_app_names:
        continue
    sbatch_path = os.path.join(output_dir, "sbatch", "{}.{}.log".format(j["name"], j["id"]))
    infra_jobs.append({
        "id": j["id"],
        "name": j["name"],
        "state": j["state"],
        "elapsed": j["elapsed"],
        "logExcerpt": "".join(tail_lines(sbatch_path, 14)).strip() or None,
    })

servo_job = next((j for j in jobs if j["name"] == "bsan-servo-fonts"), None)
servo_row = None
if servo_job or servo_batch.get("submissions"):
    sj = servo_job or {}
    sid = sj.get("id", "")
    if not sid and servo_batch.get("submissions"):
        sid = servo_batch["submissions"][0].get("job_id", "")
    sbatch = os.path.join(output_dir, "sbatch", "bsan-servo-fonts.{}.log".format(sid)) if sid else ""
    if not os.path.isfile(sbatch):
        matches = sorted(glob.glob(os.path.join(output_dir, "sbatch", "bsan-servo-fonts.*.log")), key=os.path.getmtime, reverse=True)
        sbatch = matches[0] if matches else ""
    lines = read_log_lines(sbatch) if sbatch else []
    servo_row = {
        "jobId": sid or None,
        "state": sj.get("state"),
        "elapsed": sj.get("elapsed"),
        "submitStamp": servo_batch.get("stamp"),
        "logStatus": log_status_from_lines(lines) or None,
        "headline": log_headline(lines) or None,
        "logExcerpt": log_excerpt(lines) or "".join(tail_lines(sbatch, 16)).strip() or None,
    }

verdict_counts = {}
for row in app_rows:
    v = row["verdict"]
    verdict_counts[v] = verdict_counts.get(v, 0) + 1

rerun_active = any(
    r.get("state") in ("RUNNING", "COMPLETING", "PENDING") for r in rerun_rows
) or any(j["state"] in ("RUNNING", "COMPLETING", "PENDING") for j in infra_jobs)

if rerun_active:
    analysis = (
        "Live rerun batch {} — tracking sbatch logs for in-flight jobs. "
        "Apps: {}. Infra/setup jobs shown separately. BSAN_CPUS={}."
    ).format(
        rerun_batch.get("stamp") or "latest",
        ", ".join(rerun_batch.get("apps", [])) or "—",
        os.environ.get("BSAN_CPUS", "4"),
    )
else:
    analysis = (
        "BSAN corpus (17 apps + servo-fonts). Tier-A passes show no confirmed UB. "
        "Build reruns target tikv-codec, vector-core, rusty-v8, firecracker (bsan-ext.sif). "
        "BSAN_CPUS={}.".format(os.environ.get("BSAN_CPUS", "4"))
    )

snapshot = {
    "fetchedAt": fetched_at,
    "bsan": bsan,
    "submitLog": submit_log,
    "rerunBatch": {
        "stamp": rerun_batch.get("stamp"),
        "submitLog": submit_log,
        "apps": rerun_batch.get("apps", []),
        "rows": rerun_rows,
        "active": rerun_active,
    },
    "servoFonts": servo_row,
    "infraJobs": infra_jobs,
    "verdictLabels": VERDICT_LABELS,
    "analysisSummary": analysis,
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
