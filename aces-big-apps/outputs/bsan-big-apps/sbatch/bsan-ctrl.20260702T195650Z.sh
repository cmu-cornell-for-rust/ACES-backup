#!/bin/bash
#SBATCH -A 158460239852
#SBATCH --job-name=bsan-ctrl
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --time=00:15:00
#SBATCH --output=/scratch/group/p.cis260229.000/aces-big-apps/outputs/bsan-big-apps/sbatch/bsan-ctrl.%j.log
export CPUS=1
exec /scratch/group/p.cis260229.000/aces-big-apps/scripts/bsan_singularity_run.sh /scratch/group/p.cis260229.000/containers/bsan.sif /scratch/group/p.cis260229.000/aces-big-apps bash -lc $'\nset -euo pipefail\nexport ACES_ROOT=/scratch/group/p.cis260229.000/aces-big-apps; source $ACES_ROOT/config.env\nexport RUSTUP_TOOLCHAIN=nightly\nunset BSAN_PLUGIN BSAN_RT_RUST BSAN_RT_LLVM BSAN_RUST_ONLY\necho kernel=$(uname -r)\necho --- quiche nightly ---\ncd $APPS_DIR/quiche\nexport CARGO_TARGET_DIR=$APPS_DIR/quiche/target/nightly-ctrl\ncargo test -p quiche h3::tests::additional_headers_before_data_client -- --exact --nocapture --test-threads=1 2>&1 | tail -5 && echo quiche_nightly=PASS || echo quiche_nightly=FAIL\necho --- nix mremap nightly ---\ncd $APPS_DIR/nix\nexport CARGO_TARGET_DIR=$APPS_DIR/nix/target/nightly-ctrl\nNB=$(find target/nightly-ctrl/debug/deps -maxdepth 1 -type f -executable -name test-* 2>/dev/null | head -1)\nif [[ -z "$NB" ]]; then cargo test -p nix --test test --no-run 2>&1 | tail -3; NB=$(find target/nightly-ctrl/debug/deps -maxdepth 1 -type f -executable -name test-* | head -1); fi\n"$NB" --exact --nocapture --test-threads=1 sys::test_mman::test_mremap_dontunmap 2>&1 | tail -8 || echo mremap_nightly=FAIL\necho --- nix cpu nightly ---\n"$NB" --exact --nocapture --test-threads=1 sys::test_resource::test_self_cpu_time 2>&1 | tail -5 && echo cpu_nightly=PASS || echo cpu_nightly=FAIL\n'
