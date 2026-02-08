#!/usr/bin/env bash
set -euo pipefail

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
echo "[*] Trying to Build AnalysisHelpers"
(
  cd "$BASEDIR/AnalysisHelpers"
  bash ./build.sh
)
echo "[*] Trying to Build MainAnalysisPasses"
(
  cd "$BASEDIR/MainAnalysisPasses"
  bash ./build.sh
)
