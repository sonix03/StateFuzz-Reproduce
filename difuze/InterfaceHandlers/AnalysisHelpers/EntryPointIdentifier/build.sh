#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
LLVM_CONFIG_BIN="${LLVM_CONFIG_BIN:-$(command -v llvm-config)}"
if [[ -z "$LLVM_CONFIG_BIN" ]]; then
  echo "[!] llvm-config not found in PATH" >&2
  exit 1
fi

g++ "$BASEDIR/src/main.cpp" -fpermissive -o "$BASEDIR/entry_point_handler" \
  $("$LLVM_CONFIG_BIN" --cxxflags --ldflags --libs all --system-libs)
