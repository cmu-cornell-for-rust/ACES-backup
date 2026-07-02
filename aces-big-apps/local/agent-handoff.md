# ACES BSAN Big-Apps — Agent Handoff

**Last updated:** 2026-07-02 (UTC)  
**Purpose:** Continue BSAN corpus runs on TAMU ACES, Servo-fonts investigation, and harness fixes.

---

## Goals

1. Build a **corpus of large real-world Rust programs** with heavy **FFI / unsafe**, **no custom global allocator** (avoid Servo/jemalloc class).
2. Run them under **BorrowSanitizer (BSAN)** via `cargo +bsan bsan test` inside Singularity on ACES compute nodes.
3. **Do not modify BSAN**; fix harness / Servo-side issues only.
4. Servo-fonts is a **separate track** (jemalloc + FreeType); patched but still hits teardown UB.

---

## Paths

| What | Path |
|------|------|
| **Local repo** | `/Users/rafo/projects/big-programs/aces/` |
| **ACES deploy root** | `/scratch/group/p.cis260229.000/aces-big-apps` |
| **User scratch** | `/scratch/user/u.ra353315` |
| **App checkouts** | `/scratch/user/u.ra353315/big-apps/<app>/` |
| **BSAN toolchain** | `/scratch/user/u.ra353315/bsan` |
| **Cargo/rustup** | `/scratch/user/u.ra353315/cargo-temp-u.ra353315/{cargo,rustup}` |
| **Logs** | `$ACES_ROOT/outputs/bsan-big-apps/` |
| **Container (corpus)** | `$GROUP_ROOT/containers/bsan.sif` |
| **Container (Servo)** | `/scratch/user/u.ra353315/containers/bsan-servo.sif` |
| **SSH** | `ssh -F aces/ssh/config login.aces` |

```bash
export ACES_ROOT=/scratch/group/p.cis260229.000/aces-big-apps
cd "$ACES_ROOT/outputs/bsan-big-apps"
```

**Deploy local → ACES:** `./aces/scripts/deploy.sh`

---

## BSAN configuration

- **`config.env`:** `BSAN_BRANCH=main` (was `icmccorm/thread-docs`; GC merge on main — **current corpus jobs used old toolchain** until rerun).
- **`BSAN_RUST_ONLY=1`** in `prepare_bsan_cargo_env()` — Rust instrumented; C uses plain clang. **Mixed-heap false positives** (git2-rs, etc.).
- **Stack limit:** `BSAN_STACK_KB=8192` — avoids mmap/BSAN shadow clash on ACES.
- **Per-app target:** `CARGO_TARGET_DIR=${app_dir}/target/bsan-${APP}` in `run_bsan_app.sh`.

---

## Corpus workflow

| Script | Role |
|--------|------|
| `fetch_apps.sh` | Clone/update from `datasets/big-apps/apps.tsv` |
| `run_corpus_parallel.sh` | Serial prefetch → parallel `sbatch` (14 apps) |
| `run_corpus_prefetch.sh` | One `srun`, serial `cargo fetch` (`BSAN_FETCH_ONLY=1`) |
| `run_corpus_submit.sh` | Phase 2 only — `sbatch` all apps |
| `run_bsan_app.sh` | Per-app fetch/compile/test + logs |
| `run_bsan_job.sh` | Singularity; `--batch` for `sbatch` |

```bash
cd $ACES_ROOT
PREFLIGHT_FORCE=1 ./scripts/run_corpus_parallel.sh 4:00 32   # full
PREFLIGHT_FORCE=1 ./scripts/run_corpus_submit.sh 4:00 32      # after prefetch
```

---

## apps.tsv (17 apps)

**Tier A:** uutils-coreutils, ripgrep, ring, rustls, nix, quiche, git2-rs, rusqlite, bat, fd  
**Tier B:** tikv-codec, polars-core, vector-core  
**Other:** react-compiler; bun (skip batch); servo-xpath (Servo scripts only)

**Fixed for next run:** ripgrep/fd — `--tests` only (no `--lib`).  
**Build blockers:** rusqlite (`-lsqlite3`), tikv (protobuf-src), polars/vector (compile).

---

## Harness bugs fixed

| Bug | Fix |
|-----|-----|
| Missing `cd "${app_dir}"` in `run_bsan_app.sh` | `fetch_error` everywhere |
| No `prepare_bsan_cargo_env()` | `libbsan_plugin.so` not found |
| Broken `printf` in `run_bsan_job.sh` sbatch wrapper | `bsan.sif/config.env: Not a directory` |
| Blocking `srun` loop | Prefetch + parallel `sbatch` |
| Duplicate Servo fonts jobs | Cargo lock — one job only |
| No strace in container | `/scratch/user/u.ra353315/tools/strace-bundle/bin/strace` |

---

## Corpus batch ~20260702T1614xx

**Prefetch:** all 14 `fetch_ok`. **At handoff:** 0 `ok`; ring/rustls/nix RUNNING; bat done `test_error`.

| App | Status | Notes |
|-----|--------|-------|
| git2-rs | test_error | libgit2 realloc — likely mixed-heap FP |
| quiche | test_error | libtest Vec::push after many passes |
| uutils | test_error | uu_cp 3/3 ok; TLS dtor UB |
| bat | test_error | test #2; stack_overflow.rs |
| react-compiler | test_error | AST test `unknown_statement_round_trips...` |
| ripgrep, fd | build_error | fixed in apps.tsv |
| rusqlite, tikv, polars, vector | build_error | deps/compile |

**Jobs:** ring 1912463, rustls 1912464, nix 1912465 (RUNNING ~41m at last check).

---

## Servo-fonts (separate)

- `test_font_can_do_fast_shaping` passes; **teardown UB** after.
- **Patch v2:** `patches/servo_library_handle.bsan.rs` (`FREETYPE_ALLOC_SIZES`, no `usable_size`) — **did not fix** teardown.
- **One job:** `run_servo_fonts_one_job.sh`, `bsan-servo.sif`, `target/bsan-fonts`.
- Last job **1912214** — same UB. Strace: jemalloc arena mmap at init; usable_size is userspace.

---

## git2-rs verdict

Probable **BSAN_RUST_ONLY false positive**: uninstrumented libgit2 C + intercepted realloc in BSAN Rust binary.

---

## uutils / bat / react-compiler

| App | Confidence |
|-----|------------|
| uutils | Low — teardown |
| bat | Low — PAL path |
| react-compiler | Medium — isolate named AST test |

---

## Open work

1. Finish ring/rustls/nix; collect statuses.
2. Rerun: BSAN `main` on ACES, `run_corpus_submit.sh`, fixed apps.tsv.
3. Skip/fix rusqlite, tikv, polars, vector.
4. Servo sysalloc probe; never batch with corpus.
5. See also: `local/ffi-corpus-scout-report.md`, `local/teardown-ub-*.md`.

---

## Constraints

- **Do not modify BSAN.**
- One Servo fonts job at a time.
- `PREFLIGHT_FORCE=1` to bypass duplicate-job guard.
- Servo: integration tests only (`font`, `font_context`, `font_template`).

---

## Monitor

```bash
squeue -u $USER
for a in uutils-coreutils ripgrep ring rustls nix quiche git2-rs rusqlite bat fd tikv-codec polars-core vector-core react-compiler; do
  f=$(ls -t $ACES_ROOT/outputs/bsan-big-apps/${a}.*.log 2>/dev/null | head -1)
  [[ -n "$f" ]] && printf "%-20s %s\n" "$a" "$(grep '^status=' "$f" | tail -1)"
done
```
