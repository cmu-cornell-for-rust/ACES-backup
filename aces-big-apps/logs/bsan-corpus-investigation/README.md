# BSAN corpus logs (local copy)

Synced from ACES: `/scratch/group/p.cis260229.000/aces-big-apps/outputs/bsan-big-apps/`

## Current batch (latest)

| Item | Value |
|------|-------|
| **Batch** | `main-batch-20260706T160706Z` |
| **BSAN** | `main` @ `890b2b3` (CLANG_PATH/LIBCLANG_PATH #270) |
| **Submit log** | `meta/corpus.submit.20260706T160706Z.log` |
| **Jobs** | 1919565–1919578 (14 apps, `BSAN_CLEAN=1`) |

### Harness build fixes in this batch

| App | Fix |
|-----|-----|
| ring, tikv, quiche, … | `.cargo/config.toml` + host `cc` wrapper strips BSAN `-fuse-ld`/plugin flags |
| rusqlite | `--features bundled` (no `-lsqlite3` in image) |
| polars-core | `--features object` |
| vector-core | `ahash` pin to 0.7.8 via `prepare_app_build_fixes` |
| all apps | `LLVM_CONFIG`/`CLANG_PATH` exported from BSAN sysroot |

### Previous batches

| Directory | BSAN | Notes |
|-----------|------|-------|
| `main-batch-20260702T185646Z/` | `main` @ `1f571b0` | First GC batch; build errors on ring/tikv/rusqlite/vector/polars |
| `corpus/` | — | Full remote mirror (~200 files) |

## Layout

```
bsan-corpus-investigation/
├── main-batch-20260706T160706Z/   ← start here
│   ├── corpus/                    per-app logs
│   ├── sbatch/                    Slurm wrappers
│   ├── meta/                      submit log
│   └── investigate/               (synced when present)
├── corpus/                        full mirror
└── README.md
```

## Re-sync

```bash
./aces/scripts/sync_corpus_logs.sh              # latest batch
./aces/scripts/sync_corpus_logs.sh 20260706T160706Z
./aces/scripts/poll_and_sync_corpus.sh 5      # wait for jobs, then sync
```

## Remote monitor

```bash
ssh -F aces/ssh/config login.aces 'squeue -u $USER; source /scratch/group/p.cis260229.000/aces-big-apps/config.env; for a in ring tikv-codec rusqlite vector-core polars-core; do f=$(ls -t $OUTPUT_DIR/${a}.*.log|head -1); echo $a: $(grep ^status= $f|tail -1); done'
```
