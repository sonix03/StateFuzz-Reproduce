#!/usr/bin/env bash
set -euo pipefail

LLVM_DIR="$LLVM_ROOT/../cmake"
echo "[*] Trying to Run Cmake"
mkdir -p build_dir
cd build_dir
cmake ..
echo "[*] Trying to make"
make -j"$(nproc)"
