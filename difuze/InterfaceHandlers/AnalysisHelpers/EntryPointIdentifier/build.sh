#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
LLVM_CONFIG_BIN="${LLVM_CONFIG_BIN:-$(command -v llvm-config)}"
if [[ -z "$LLVM_CONFIG_BIN" ]]; then
  echo "[!] llvm-config not found in PATH" >&2
  exit 1
fi

LLVM_CXXFLAGS="$("$LLVM_CONFIG_BIN" --cxxflags)"
LLVM_LDFLAGS="$("$LLVM_CONFIG_BIN" --ldflags)"
LLVM_SYS_LIBS="$("$LLVM_CONFIG_BIN" --system-libs)"
if LLVM_LIBS="$("$LLVM_CONFIG_BIN" --link-shared --libs 2>/dev/null)" && [[ -n "$LLVM_LIBS" ]]; then
  :
else
  LLVM_LIBS="$("$LLVM_CONFIG_BIN" --libs core irreader bitreader bitwriter support)"
fi

# shellcheck disable=SC2086
g++ "$BASEDIR/src/main.cpp" -fpermissive -o "$BASEDIR/entry_point_handler" \
  $LLVM_CXXFLAGS $LLVM_LDFLAGS $LLVM_LIBS $LLVM_SYS_LIBS
