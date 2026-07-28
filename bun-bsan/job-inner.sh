#!/bin/bash
# Runs INSIDE the charliecloud container (Ubuntu 25.04 + bsan toolchain +
# LLVM 21 + bun). The container FS is read-only; all writes go to group
# scratch via a fake $HOME.
set -uxo pipefail

G=/scratch/group/p.cis260229.000/bun-bsan
export HOME=$G/fakehome
mkdir -p "$HOME" "$G/logs"

# ── Writable rustup/cargo homes backed by the read-only container toolchain ──
export RUSTUP_HOME=$HOME/.rustup CARGO_HOME=$HOME/.cargo
mkdir -p "$RUSTUP_HOME/toolchains" "$CARGO_HOME"
for t in /root/.rustup/toolchains/*; do
  ln -sfn "$t" "$RUSTUP_HOME/toolchains/$(basename "$t")"
done
cp /root/.rustup/settings.toml "$RUSTUP_HOME/" 2>/dev/null || true
[ -d "$CARGO_HOME/bin" ] || cp -a /root/.cargo/bin "$CARGO_HOME/bin"
export PATH=$CARGO_HOME/bin:/root/.bun/bin:/usr/lib/llvm-21/bin:$PATH

rustc --version || true
clang-21 --version | head -1 || true
bun --version || true

# ── Phase 1: x86_64 BSAN sysroot + cc-wrapper (once, cached in fakehome) ──
if [ ! -x "$HOME/.bsan-wrap/clang" ]; then
  tmp=$(mktemp -d)
  cd "$tmp"
  cargo new hello >/dev/null 2>&1
  cd hello
  cargo bsan run > "$G/logs/sysroot-prep.log" 2>&1
  echo "sysroot prep exit: $?" | tee -a "$G/logs/sysroot-prep.log"
  mkdir -p "$HOME/.bsan-wrap"
  cp target/bsan/clang "$HOME/.bsan-wrap/clang"
  chmod +x "$HOME/.bsan-wrap/clang"
fi

# ── Phase 2: instrumented Bun build ──
cd "$G/bun"
bun install > "$G/logs/bun-install.log" 2>&1
echo "bun install exit: $?"

# poisoned probe cache from any earlier failed run (see local experiment)
rm -f build/debug/rust-target/.rustc_info.json

export CARGO_BUILD_JOBS=${SLURM_CPUS_PER_TASK:-64}
BUN_BSAN=1 bun scripts/build.ts --profile=debug-no-asan -j"${SLURM_CPUS_PER_TASK:-64}" \
  > "$G/logs/build.log" 2>&1
build_exit=$?
echo "BUILD EXIT: $build_exit" | tee -a "$G/logs/build.log"

# ── Phase 3: run Bun under BSAN, capture diagnostics ──
BIN=./build/debug/bun-debug
if [ -x "$BIN" ]; then
  export BSAN_OPTIONS=stacktrace_max_len=32
  {
    echo "=== bun-debug --version ==="
    timeout 300 "$BIN" --version; echo "exit=$?"
    echo "=== bun-debug --revision ==="
    timeout 300 "$BIN" --revision; echo "exit=$?"
    echo "=== eval: arithmetic + JSON ==="
    timeout 300 "$BIN" -e 'console.log(JSON.stringify({ok: 1 + 1}))'; echo "exit=$?"
    echo "=== eval: heap-heavy workload ==="
    timeout 600 "$BIN" -e '
      const a = [];
      for (let i = 0; i < 1e4; i++) a.push({ i, s: "x".repeat(100) });
      const buf = Buffer.alloc(1 << 20, 7);
      console.log("heap ok", a.length, buf[12345]);
      const t = await Bun.file("/etc/os-release").text().catch(() => "nofile");
      console.log("io ok", t.length);
    '; echo "exit=$?"
  } > "$G/logs/run-bsan.log" 2>&1
else
  echo "no bun-debug binary produced" > "$G/logs/run-bsan.log"
fi

echo "INNER DONE build_exit=$build_exit"
exit "$build_exit"
