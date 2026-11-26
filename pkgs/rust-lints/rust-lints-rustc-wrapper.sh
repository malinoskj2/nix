#!/bin/sh
case "${1##*/}" in
  clippy-driver | dylint-driver) exec "$@" ;;
esac
if [ -n "${RUST_LINTS_RUSTC_WRAPPER-}" ]; then
  exec "$RUST_LINTS_RUSTC_WRAPPER" "$@"
fi
exec "$@"
