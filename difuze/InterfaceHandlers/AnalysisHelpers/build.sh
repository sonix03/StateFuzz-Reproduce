#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
echo "[*] Trying to Build Dr_linker"
(
  cd "$BASEDIR/Dr_linker"
  bash ./build.sh
)
echo "[*] Trying to Build EntryPointIdentifier"
(
  cd "$BASEDIR/EntryPointIdentifier"
  bash ./build.sh
)
