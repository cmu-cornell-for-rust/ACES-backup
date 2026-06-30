# BSAN Big Apps on ACES

Run [BorrowSanitizer](https://github.com/BorrowSanitizer/bsan) (`icmccorm/thread-docs`, experimental GC) against large Rust applications on TAMU ACES.

**Target apps**

| App | Repo | BSAN entry point |
|-----|------|------------------|
| React Compiler | `facebook/react` → `compiler/` | `cargo bsan test --lib --tests` |
| Bun (React Compiler crate) | `oven-sh/bun` | `cargo bsan test -p bun_react_compiler --lib --tests` |
| Servo (starter) | `servo/servo` | `cargo bsan test -p servo-xpath --lib --tests` |

Edit `datasets/big-apps/apps.tsv` to add crates or broader test targets.

## Getting on ACES (follow group guide)

1. **Portal** or **SSH** to `login.aces.hprc.tamu.edu` (not `aces-jump` directly).
2. SSH keys expire ~49h; regenerate via portal **Utilities → sshca**.
3. `This account is currently not available` on the jump host means you need `ProxyJump` — see `ssh/config`.
4. Before long jobs: `tmux new -s bsan`.
5. Network on compute nodes: `module load WebProxy`.

Account: `u.ra353315` · Group: `p.cis260229.000`

## Deploy

From your laptop:

```bash
chmod +x aces/scripts/*.sh aces/containers/build_scripts/*.sh
./aces/scripts/deploy.sh
```

On ACES:

```bash
export ACES_ROOT=/scratch/group/p.cis260229.000/aces-big-apps
cd "$ACES_ROOT"
```

Uses existing group scripts when present: `scripts/run_job.sh`, `containers/run.sh`.

## Resource-safe workflow

Scripts **refuse to submit** if BSAN is not ready or another `bsan*` job is already queued.

```bash
cd "$ACES_ROOT"

# Free login-node checks (no compute tokens)
./scripts/check_bsan.sh

# One-time BSAN install (single srun, 16G, 2h) — uses group bsan.sif
tmux new -s bsan
./scripts/setup_bsan_job.sh

# Clone apps (login node only)
./scripts/fetch_apps.sh react-compiler

# After check_bsan.sh passes, smoke test one app
./scripts/smoke_test.sh react-compiler

# Full batch (one job per app, only after BSAN is ready)
./scripts/run_big_apps.sh
```

Rustup/cargo live under `/scratch/user/u.ra353315/cargo-temp-u.ra353315`. Group `containers/bsan.sif` already exists.

Monitor jobs in tmux (login node, no extra tokens):

```bash
tmux new -s bsan-monitor
export ACES_ROOT=/scratch/group/p.cis260229.000/aces-big-apps
cd "$ACES_ROOT"
./scripts/monitor_bsan.sh        # refresh every 30s
./scripts/monitor_bsan.sh --once # single snapshot
```

Or manually: `squeue -u $USER`, `scancel <jobid>`, `scancel -u $USER`

Results land in `$ACES_ROOT/outputs/bsan-big-apps/` (`results.csv` + per-run logs).

## Servo note

Full Servo needs `./mach bootstrap` and system deps. The default target (`servo-xpath`) is a small workspace member for smoke testing. After bootstrap, add more rows to `apps.tsv` (e.g. other `tests/unit/*` crates).

### servo-fonts (unsafe / FFI)

`servo-fonts` links `yeslogic-fontconfig-sys` and `freetype-sys` via **pkg-config** (linked mode). Do **not** set `RUST_FONTCONFIG_DLOPEN` for Servo — dlopen hides the `Fc*` symbols that `components/fonts/platform/freetype/font_list.rs` imports.

Build the layered servo image once (extends group `bsan.sif` with `libfontconfig-dev` / `libfreetype-dev`):

```bash
./scripts/rebuild_bsan_servo_image_job.sh   # writes $BSAN_SERVO_IMAGE (user scratch)
```

```bash
cd "$ACES_ROOT"
./scripts/fetch_apps.sh servo-xpath
./scripts/run_servo_fonts_job.sh          # 2h, 32G — servo-fonts BSAN test
# or on an allocated node / existing srun shell:
./scripts/run_servo_bsan_package.sh fonts
```

If a prior run set `RUST_FONTCONFIG_DLOPEN=1`, the script cleans `yeslogic-fontconfig-sys` artifacts by default (`SERVO_FONTCONFIG_CLEAN=1`).

## Policies

- Respect ACES job and storage limits; clean up `cargo-temp-*` after `scancel`.
- Do not run excessive parallel jobs; default script submits one job per app.
- Use group `showquota` before large clones.
- Never submit benchmarks until `./scripts/check_bsan.sh` passes.
