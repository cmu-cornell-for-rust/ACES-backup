# BSAN FFI/Unsafe Corpus Scout Report

See apps.tsv Tier A/B entries. Primary targets: uutils-coreutils, ripgrep, ring, rustls, nix, quiche, git2-rs, rusqlite, bat, fd.

uutils (eae191c): ~260 unsafe, rustix+libc, no custom allocator.

Launch: `PREFLIGHT_FORCE=1 ./scripts/run_corpus_parallel.sh 4:00 32`
