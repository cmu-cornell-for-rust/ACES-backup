#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../config.env"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# Bound stack so ACES' unlimited default does not perturb Linux mmap layout enough
# to collide with BSAN/DFSan reserved regions. The exact KiB value is not magic;
# any reasonable finite limit works. Override with BSAN_STACK_KB or opt out via
# BSAN_STACK_UNLIMITED=1.
apply_bsan_stack_limit() {
  if [[ "${BSAN_STACK_UNLIMITED:-0}" == 1 ]]; then
    log "WARN: BSAN_STACK_UNLIMITED=1; stack soft limit left at $(ulimit -S -s) KB"
    return 0
  fi
  local limit_kb="${BSAN_STACK_KB:-8192}"
  ulimit -S -s "${limit_kb}" || die "ulimit -S -s ${limit_kb} failed"
}

# servo-fonts links yeslogic-fontconfig-sys + freetype-sys through pkg-config.
# Servo's Linux font_list.rs imports Fc* symbols at the fontconfig_sys crate
# root (linked mode). RUST_FONTCONFIG_DLOPEN switches fontconfig-sys to dlopen
# and hides those root exports — that mode does not match Servo's imports.
prepare_servo_fontconfig_build() {
  unset RUST_FONTCONFIG_DLOPEN
  export PKG_CONFIG_ALLOW_CROSS=1
  require_pkg_config_modules fontconfig freetype2
}

require_pkg_config_modules() {
  local m
  for m in "$@"; do
    if ! pkg-config --exists "$m" 2>/dev/null; then
      die "pkg-config missing ${m}. Rebuild group bsan.sif (see containers/build_scripts/bsan.def: libfontconfig-dev libfreetype-dev)."
    fi
    log "pkg-config ${m}=$(pkg-config --modversion "$m") libs=$(pkg-config --libs "$m")"
  done
}

# yeslogic-fontconfig-sys fingerprints the dlopen cfg in its build script. A prior
# build with RUST_FONTCONFIG_DLOPEN=1 poisons the cache and breaks servo-fonts.
clean_servo_fontconfig_cargo_cache() {
  local root="$1"
  log "Cleaning stale fontconfig-sys / freetype-sys / dlib artifacts (target/bsan)"
  (
    cd "${root}"
    export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-bsan}"
    export BSAN_RUST_ONLY="${BSAN_RUST_ONLY:-1}"
    export PATH="${CARGO_HOME}/bin:${PATH}"
    # cargo +bsan bsan uses target/bsan; plain cargo +bsan clean only hits target/debug.
    for pkg in dlib yeslogic-fontconfig-sys freetype-sys; do
      cargo +bsan bsan clean -p "${pkg}" 2>/dev/null || true
    done
    # Drop stale fingerprints from prior wrong-target cleans.
    find target/bsan -type d -path '*/.fingerprint/dlib-*' -prune -exec rm -rf {} + 2>/dev/null || true
    find target/bsan -type d -path '*/.fingerprint/yeslogic-fontconfig-sys-*' -prune -exec rm -rf {} + 2>/dev/null || true
    find target/bsan -type d -path '*/.fingerprint/freetype-sys-*' -prune -exec rm -rf {} + 2>/dev/null || true
  ) || true
}

bsan_singularity_host_ffi_binds() {
  local lib
  for lib in \
    /usr/lib64/libfontconfig.so.1 \
    /usr/lib64/libfreetype.so.6 \
    /usr/lib64/libexpat.so.1; do
    if [[ -e "${lib}" ]]; then
      printf '%s:%s:ro\n' "${lib}" "${lib}"
    fi
  done
}

ensure_network() {
  if command -v module >/dev/null 2>&1; then
    module load WebProxy 2>/dev/null || true
  fi
}

ensure_dirs() {
  mkdir -p "${CARGO_TEMP}" "${CARGO_HOME}" "${RUSTUP_HOME}" "${APPS_DIR}" "${OUTPUT_DIR}"
}

# Read corpus-apps.txt (one name per line; comments with #).
load_corpus_apps() {
  local list_file="${ACES_ROOT}/datasets/big-apps/corpus-apps.txt"
  [[ -f "${list_file}" ]] || die "Missing corpus app list: ${list_file}"
  CORPUS_APPS=()
  local line trimmed
  while IFS= read -r line || [[ -n "${line}" ]]; do
    trimmed="${line%%#*}"
    trimmed="$(echo "${trimmed}" | xargs 2>/dev/null || true)"
    [[ -n "${trimmed}" ]] || continue
    CORPUS_APPS+=("${trimmed}")
  done <"${list_file}"
}

# Bash `read` collapses consecutive tabs; use awk for apps.tsv columns.
app_field() {
  local app="$1" col="$2"
  local tsv="${ACES_ROOT}/datasets/big-apps/apps.tsv"
  awk -F '\t' -v app="${app}" -v col="${col}" '$1 == app {print $col; exit}' "${tsv}"
}

resolve_image() {
  local image="${1:-${BSAN_IMAGE}}"
  if [[ ! -f "${image}" ]]; then
    image="${GROUP_CONTAINERS}/rust.sif"
    log "WARN: ${BSAN_IMAGE} missing; falling back to ${image}"
  fi
  if [[ "${image}" != /* ]]; then
    image="${GROUP_CONTAINERS}/${image##*/}"
  fi
  [[ -f "${image}" ]] || die "Missing container image ${image}"
  printf '%s\n' "${image}"
}

# firecracker links -lseccomp at build-script time; use bsan-ext.sif when present.
resolve_image_for_app() {
  local app="${1:-}"
  local ext="${BSAN_EXT_IMAGE:-${USER_SCRATCH}/containers/bsan-ext.sif}"
  if [[ "${app}" == firecracker && -f "${ext}" ]]; then
    resolve_image "${ext}"
    return 0
  fi
  resolve_image "${BSAN_IMAGE}"
}

count_user_jobs() {
  local pattern="${1:-bsan}"
  squeue -h -u "${ACES_USER}" -o "%j" 2>/dev/null | grep -c "${pattern}" || true
}

guard_no_duplicate_jobs() {
  local pattern="${1:-bsan}"
  local force="${2:-0}"
  local n
  n="$(count_user_jobs "${pattern}")"
  if [[ "${n}" -gt 0 && "${force}" -eq 0 ]]; then
    die "Refusing to submit: ${n} job(s) matching '${pattern}' already queued/running. Check: squeue -u \$USER"
  fi
}


# Host strace for Singularity jobs (container image often lacks strace).
resolve_strace() {
  local candidate
  local staged="${USER_SCRATCH}/tools/strace-bundle/bin/strace"
  for candidate in "${staged}" /usr/bin/strace strace /bin/strace; do
    if command -v "${candidate}" &>/dev/null; then
      command -v "${candidate}"
      return 0
    fi
    if [[ -x "${candidate}" ]]; then
      printf '%s
' "${candidate}"
      return 0
    fi
  done
  return 1
}

export_rust_env() {
  export RUSTUP_HOME CARGO_HOME
  export PATH="${CARGO_HOME}/bin:/opt/cargo/bin:/opt/rust/cargo/bin:${PATH}"
}

prepare_bsan_native_cc_env() {
  # cargo-bsan sets global CC/CFLAGS with the BSAN plugin and lld driver flags.
  # cc-rs and autoconf inherit those and break -Werror C builds (ring) and
  # configure link probes (protobuf-src). Rust stays on BSAN via RUSTUP_TOOLCHAIN.
  unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LD
  local host_cc host_cxx clean_flags
  host_cc="$(command -v cc 2>/dev/null || echo /usr/bin/cc)"
  host_cxx="$(command -v c++ 2>/dev/null || echo /usr/bin/c++)"
  clean_flags="-O1 -ffunction-sections -fdata-sections -fPIC -g -gdwarf-4 -fno-omit-frame-pointer -m64"
  export CC="${host_cc}"
  export CXX="${host_cxx}"
  export CFLAGS="${clean_flags}"
  export CXXFLAGS="${clean_flags}"
  export CC_x86_64_unknown_linux_gnu="${host_cc}"
  export CXX_x86_64_unknown_linux_gnu="${host_cxx}"
  export CFLAGS_x86_64_unknown_linux_gnu="${clean_flags}"
  export CXXFLAGS_x86_64_unknown_linux_gnu="${clean_flags}"
  export CMAKE_C_COMPILER="${host_cc}"
  export CMAKE_CXX_COMPILER="${host_cxx}"
}

# cargo-bsan overwrites shell CC with BSAN clang; [env] force=true wins for build scripts.
write_host_cc_cargo_config() {
  local app_dir="$1"
  local wrap_dir="${CARGO_TEMP:-/tmp}/host-cc-wrap/bin"
  local host_cc host_cxx clean_flags
  host_cc="$(command -v cc 2>/dev/null || echo /usr/bin/cc)"
  host_cxx="$(command -v c++ 2>/dev/null || echo /usr/bin/c++)"
  clean_flags="-O1 -ffunction-sections -fdata-sections -fPIC -g -gdwarf-4 -fno-omit-frame-pointer -m64"
  mkdir -p "${wrap_dir}"
  cat > "${wrap_dir}/cc" <<'WRAP'
#!/usr/bin/env bash
real_cc="${HOST_CC_REAL:-/usr/bin/cc}"
args=()
for a in "$@"; do
  case "$a" in
    -fuse-ld=*| -fpass-plugin=*|-Wl,*|--target=* ) continue ;;
    *) args+=("$a") ;;
  esac
done
exec "${real_cc}" "${args[@]}"
WRAP
  cat > "${wrap_dir}/c++" <<'WRAP'
#!/usr/bin/env bash
real_cxx="${HOST_CXX_REAL:-/usr/bin/c++}"
args=()
for a in "$@"; do
  case "$a" in
    -fuse-ld=*| -fpass-plugin=*|-Wl,*|--target=* ) continue ;;
    *) args+=("$a") ;;
  esac
done
exec "${real_cxx}" "${args[@]}"
WRAP
  chmod +x "${wrap_dir}/cc" "${wrap_dir}/c++"
  export HOST_CC_REAL="${host_cc}"
  export HOST_CXX_REAL="${host_cxx}"
  mkdir -p "${app_dir}/.cargo"
  cat > "${app_dir}/.cargo/config.toml" <<EOF
# BSAN corpus: host C toolchain for build scripts (ring, tikv protobuf-src, quiche cmake).
[env]
HOST_CC_REAL = { value = "${host_cc}", force = true }
HOST_CXX_REAL = { value = "${host_cxx}", force = true }
CC = { value = "${wrap_dir}/cc", force = true }
CXX = { value = "${wrap_dir}/c++", force = true }
CFLAGS = { value = "${clean_flags}", force = true }
CXXFLAGS = { value = "${clean_flags}", force = true }
CMAKE_C_COMPILER = { value = "${wrap_dir}/cc", force = true }
CMAKE_CXX_COMPILER = { value = "${wrap_dir}/c++", force = true }
CMAKE_C_FLAGS = { value = "${clean_flags}", force = true }
CMAKE_CXX_FLAGS = { value = "${clean_flags}", force = true }
EOF
}

append_cargo_config_env() {
  local app_dir="$1"
  shift
  [[ $# -gt 0 ]] || return 0
  mkdir -p "${app_dir}/.cargo"
  {
    echo ""
    echo "# BSAN corpus app-specific build env"
    echo "[env]"
    while [[ $# -gt 0 ]]; do
      echo "$1"
      shift
    done
  } >>"${app_dir}/.cargo/config.toml"
}

# ahash stdsimd needs removed nightly feature; unify on 0.8.x without stdsimd.
patch_vector_core_ahash() {
  local app_dir="$1"
  local cargo="${app_dir}/Cargo.toml"
  [[ -f "${cargo}" ]] || return 0
  if grep -q 'bsan-patch-ahash' "${cargo}" 2>/dev/null; then
    return 0
  fi
  log "vector-core: patching ahash (disable stdsimd via [patch.crates-io])"
  cat >>"${cargo}" <<'PATCH'

# bsan-patch-ahash: stdsimd feature requires removed nightly feature
[patch.crates-io]
ahash = { version = "0.8.11", default-features = false, features = ["std", "runtime-rng"] }
PATCH
  (
    cd "${app_dir}"
    export_rust_env
    prepare_bsan_cargo_env
    cargo +bsan update -p ahash 2>/dev/null || true
  )
}

# rusty_v8 expects gen/src_binding_*.rs; download prebuilts and prime build-script.
prepare_rusty_v8_prebuild() {
  local app_dir="$1"
  local mirror="https://github.com/denoland/rusty_v8/releases/download"
  local v8_ver name binding
  v8_ver="$(grep -m1 '^version' "${app_dir}/Cargo.toml" | sed 's/.*"\([^"]*\)".*/\1/')"
  name="src_binding_release_x86_64-unknown-linux-gnu.rs"
  binding="${app_dir}/gen/${name}"
  mkdir -p "${app_dir}/gen"
  if [[ ! -s "${binding}" ]]; then
    log "rusty-v8: downloading prebuilt ${name} (v${v8_ver})"
    curl -fsSL -o "${binding}" "${mirror}/v${v8_ver}/${name}"
  fi
  append_cargo_config_env "${app_dir}" \
    "RUSTY_V8_MIRROR = { value = \"${mirror}\", force = true }" \
    "RUSTY_V8_SRC_BINDING_PATH = { value = \"${binding}\", force = true }"
  (
    cd "${app_dir}"
    export_rust_env
    prepare_bsan_cargo_env
    export RUSTY_V8_MIRROR
    export RUSTY_V8_SRC_BINDING_PATH="${binding}"
    log "rusty-v8: priming v8 build-script (cargo +bsan bsan build -p v8)"
    cargo +bsan bsan build -p v8 2>&1 | tail -30 || true
  )
}

# Per-app build fixes (lockfile pins, etc.) before compile.
prepare_app_build_fixes() {
  local app="$1"
  local app_dir="$2"
  write_host_cc_cargo_config "${app_dir}"
  case "${app}" in
    vector-core)
      patch_vector_core_ahash "${app_dir}"
      ;;
    rusty-v8)
      prepare_rusty_v8_prebuild "${app_dir}"
      ;;
    firecracker)
      if ! pkg-config --exists libseccomp 2>/dev/null; then
        log "WARN: firecracker needs libseccomp-dev in bsan.sif (rebuild containers/build_scripts/bsan.def)"
      fi
      ;;
    tikv-codec)
      # grpcio-sys cmake must not inherit BSAN --target= from cargo-bsan.
      append_cargo_config_env "${app_dir}" \
        'CMAKE_CXX_FLAGS = { value = "-O1 -ffunction-sections -fdata-sections -fPIC -g -gdwarf-4 -fno-omit-frame-pointer -m64", force = true }' \
        'CMAKE_C_FLAGS = { value = "-O1 -ffunction-sections -fdata-sections -fPIC -g -gdwarf-4 -fno-omit-frame-pointer -m64", force = true }'
      ;;
  esac
}

prepare_bsan_cargo_env() {
  export_rust_env
  ensure_bsan_toolchain_linked || true
  # bsan-servo.sif sets BSAN_SYSROOT=/opt/bsan-sysroot, which makes cargo-bsan skip its sysroot build.
  unset BSAN_SYSROOT
  export RUSTUP_TOOLCHAIN=bsan
  export BSAN_RUST_ONLY=1
  export_bsan_dep_env
}

export_bsan_dep_env() {
  export_rust_env
  local sysroot plugin rt_rust rt_llvm
  sysroot="$(rustc +bsan --print sysroot)"
  plugin="${sysroot}/lib/libbsan_plugin.so"
  rt_rust="${sysroot}/lib/libbsan_rt.a"
  rt_llvm="$(find "${sysroot}/lib" -maxdepth 1 -name 'libclang_rt.bsan-*.a' 2>/dev/null | head -1 || true)"
  if [[ ! -f "${plugin}" ]]; then
    plugin="${BSAN_DIR}/target/release/bsan-pass/build/libbsan_plugin.so"
  fi
  if [[ ! -f "${rt_rust}" ]]; then
    rt_rust="${BSAN_DIR}/target/release/libbsan_rt.a"
  fi
  if [[ -z "${rt_llvm}" || ! -f "${rt_llvm}" ]]; then
    rt_llvm="${BSAN_DIR}/target/release/compiler-rt/build/lib/linux/libclang_rt.bsan-x86_64.a"
  fi
  [[ -f "${plugin}" ]] || die "Missing libbsan_plugin.so — run setup_bsan.sh (xb install)"
  [[ -f "${rt_rust}" ]] || die "Missing libbsan_rt.a — run setup_bsan.sh (xb install)"
  [[ -f "${rt_llvm}" ]] || die "Missing libclang_rt.bsan runtime — run setup_bsan.sh (xb install)"
  export BSAN_PLUGIN="${plugin}"
  export BSAN_RT_RUST="${rt_rust}"
  export BSAN_RT_LLVM="${rt_llvm}"
  if [[ -x "${sysroot}/bin/llvm-config" ]]; then
    export LLVM_CONFIG="${sysroot}/bin/llvm-config"
  fi
  if [[ -x "${sysroot}/bin/clang-22" ]]; then
    export CLANG_PATH="${sysroot}/bin/clang-22"
    export LIBCLANG_PATH="${sysroot}/lib"
  fi
}

bsan_toolchain_installed() {
  [[ -x "${RUSTUP_HOME}/toolchains/bsan/bin/rustc" ]]
}

bsan_toolchain_registered() {
  export_rust_env
  if command -v rustup >/dev/null 2>&1 && rustup toolchain list 2>/dev/null | grep -qE '^bsan( |$)'; then
    return 0
  fi
  # xb setup can leave a full toolchain tree without a rustup list entry.
  bsan_toolchain_installed
}

ensure_bsan_toolchain_linked() {
  export_rust_env
  bsan_toolchain_installed || return 1
  if bsan_toolchain_registered && rustc_bsan_works && cargo +bsan -V >/dev/null 2>&1; then
    return 0
  fi
  command -v rustup >/dev/null 2>&1 || return 1
  # xb setup installs directly into ${RUSTUP_HOME}/toolchains/bsan. rustup
  # uninstall of a link pointing at that tree can delete the real toolchain.
  if rustup toolchain list 2>/dev/null | grep -qE '^bsan( |$)'; then
    return 0
  fi
  log "Linking bsan toolchain into rustup (${RUSTUP_HOME}/toolchains/bsan)"
  rustup toolchain link bsan "${RUSTUP_HOME}/toolchains/bsan"
  rustup default bsan 2>/dev/null || true
}

bsan_toolchain_ready() {
  export_rust_env
  ensure_bsan_toolchain_linked || true
  bsan_toolchain_installed && bsan_toolchain_registered && rustc_bsan_works && cargo +bsan -V >/dev/null 2>&1
}

rustc_bsan_works() {
  export_rust_env
  rustc +bsan -vV >/dev/null 2>&1
}

rustup_healthy() {
  export_rust_env
  command -v rustup >/dev/null 2>&1 || return 1
  if bsan_toolchain_ready; then
    rustc_bsan_works
  else
    rustc +nightly -vV >/dev/null 2>&1 || rustc -vV >/dev/null 2>&1
  fi
}

cargo_bsan_ready() {
  [[ -x "${CARGO_HOME}/bin/cargo-bsan" ]] || command -v cargo-bsan >/dev/null 2>&1
}

# Login-node safe: artifacts exist; rustc may not run on host glibc.
bsan_artifacts_ready() {
  bsan_toolchain_installed && cargo_bsan_ready
}

# Inside container/compute node: toolchain actually executes.
bsan_runtime_ready() {
  bsan_toolchain_ready && cargo_bsan_ready
}

bsan_ready() {
  bsan_artifacts_ready
}

require_bsan_ready() {
  if bsan_artifacts_ready; then
    return 0
  fi
  die "BSAN is not ready. Run once on a login node: ${ACES_ROOT}/scripts/setup_bsan_job.sh"
}

# One-line BSAN revision for corpus logs (branch + short sha + subject).
bsan_revision_line() {
  local dir="${BSAN_DIR:-}"
  [[ -n "${dir}" && -d "${dir}/.git" ]] || return 0
  local branch sha subject
  branch="$(git -C "${dir}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  sha="$(git -C "${dir}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  subject="$(git -C "${dir}" log -1 --format=%s 2>/dev/null || true)"
  printf 'bsan_repo=%s@%s %s\n' "${branch}" "${sha}" "${subject}"
}

run_job() {
  local runner="${GROUP_SCRIPTS}/run_job.sh"
  if [[ -x "${runner}" ]]; then
    "${runner}" "$@"
  else
    die "Missing ${runner}. Deploy aces/ under ${GROUP_ROOT} and use the portal terminal."
  fi
}
