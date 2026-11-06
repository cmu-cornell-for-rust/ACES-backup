#!/bin/bash
if [ "${CARGO_PRIMARY_PACKAGE:-}" = 1 ] && [[ "${CARGO_MANIFEST_DIR:-}" == /work* ]]; then
    exec "$EV_REAL_RUSTC" "$@" --cfg=miri
fi
exec "$EV_REAL_RUSTC" "$@"
