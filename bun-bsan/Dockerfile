# Bun + BorrowSanitizer build environment
#
# Base: BorrowSanitizer's official image, which ships:
#   - the `bsan` rustup toolchain (BorrowSanitizer's rustc fork, LLVM 22.1.6,
#     with the -Zcodegen-emit-retag flag and an instrumented-std sysroot)
#   - /root/.rustup/toolchains/bsan/lib/libbsan_plugin.so   (LLVM pass)
#   - /root/.rustup/toolchains/bsan/lib/libbsan_rt.a        (Rust runtime)
#   - /root/.rustup/toolchains/bsan/lib/libclang_rt.bsan-aarch64.a
#   - cargo-bsan (used here as RUSTC_WRAPPER inside Bun's ninja build)
#
# On top we add Bun's Linux build dependencies (docs/project/contributing):
#   - LLVM/clang/lld 21.1.x — Bun's build pins this range (tools.ts
#     LLVM_VERSION = "21.1.8") for the C++ side. NOTE: the C++ side is NOT
#     BSAN-instrumented; libbsan_plugin.so is built against LLVM 22 (plugin
#     ABI v2) and cannot load into clang 21 or the image's system clang 20.
#   - a release Bun binary (codegen / transpile bootstrap)
#   - cmake/ninja/go/ruby/etc. for vendored deps and codegen
FROM ghcr.io/borrowsanitizer/bsan:latest

ENV DEBIAN_FRONTEND=noninteractive
# apt's privilege-drop sandbox cannot setgroups inside an unprivileged
# user-namespace build (charliecloud ch-image); run apt methods as root.
RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/01-no-sandbox
RUN apt-get update && apt-get install -y \
    curl wget lsb-release software-properties-common cmake git golang \
    libtool ninja-build pkg-config ruby-full xz-utils python3 ccache unzip \
    && rm -rf /var/lib/apt/lists/*

# LLVM 21 (apt.llvm.org) — Bun's pinned C/C++ toolchain range
RUN curl -fsSL https://apt.llvm.org/llvm.sh -o /tmp/llvm.sh \
    && chmod +x /tmp/llvm.sh && /tmp/llvm.sh 21 \
    && apt-get install -y lld-21 && rm -rf /var/lib/apt/lists/*

# Release Bun — bootstrap binary for Bun's own codegen scripts.
# HOME is explicit: ch-image build's RUN environment doesn't define it.
ENV HOME=/root
RUN curl -fsSL https://bun.com/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# The pinned nightly for host artifacts is auto-installed by rustup on
# demand; the *target* crates are compiled by the `bsan` toolchain instead
# (see the BUN_BSAN patch to scripts/build/rust.ts).
#
# Build (inside a checkout patched with bsan-rust.patch):
#   BUN_BSAN=1 bun scripts/build.ts --profile=debug-no-asan
