#!/bin/bash
env JOBS=8 BD_STEP_CPUS=1 BD_STEP_MEM=8192M BUILD_RUSTFLAGS=--cap-lints=warn PRIMARY_RUSTFLAGS=--cfg=miri BUILD_TIMEOUT=3600 bash /scratch/group/p.cis260229.000/outputs/build-treeborrows/_logs/.build_dataset.sh --node --part 58 --image experimental-bsan --doc --no-bsan --doc-only --download /scratch/group/p.cis260229.000/outputs/build-treeborrows 
