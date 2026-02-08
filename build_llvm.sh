#!/usr/bin/env bash
set -euo pipefail

usage() {
cat <<'USAGE'
Usage:
  ./build_llvm.sh

Environment variables:
  LLVM_SRC=./llvm-11.0.1                  LLVM source directory
  LLVM_BUILD_DIR=$LLVM_SRC/build          Build directory
  BUILD_TYPE=Release                      CMake build type
  JOBS=$(nproc)                           Parallel build jobs
  CLEAN=1                                 Remove existing build dir first
  AUTO_INSTALL_DEPS=0                     Install build deps via apt
  USE_NINJA=0                             Use Ninja generator instead of Make
  INSTALL=0                               Run install step after build
  INSTALL_PREFIX=$LLVM_BUILD_DIR/install  Install prefix (if INSTALL=1)
  DISABLE_BENCHMARKS=1                    Set LLVM_INCLUDE_BENCHMARKS/LLVM_BUILD_BENCHMARKS=OFF
  DISABLE_TESTS=1                         Set LLVM_INCLUDE_TESTS=OFF
  DISABLE_EXAMPLES=1                      Set LLVM_INCLUDE_EXAMPLES=OFF
  CMAKE_ARGS=""                           Extra args for cmake (quoted string)

Examples:
  ./build_llvm.sh
  CLEAN=1 USE_NINJA=1 ./build_llvm.sh
  BUILD_TYPE=Debug CMAKE_ARGS="-DLLVM_ENABLE_ASSERTIONS=ON" ./build_llvm.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

log() {
	echo "[build_llvm] $*"
}

die() {
	echo "[build_llvm][error] $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

run_cmd() {
	log "$*"
	"$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLVM_SRC="${LLVM_SRC:-$SCRIPT_DIR/llvm-11.0.1}"
LLVM_BUILD_DIR="${LLVM_BUILD_DIR:-$LLVM_SRC/build}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
if command -v nproc >/dev/null 2>&1; then
	DEFAULT_JOBS="$(nproc)"
else
	DEFAULT_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi
JOBS="${JOBS:-$DEFAULT_JOBS}"
CLEAN="${CLEAN:-1}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-0}"
USE_NINJA="${USE_NINJA:-0}"
INSTALL="${INSTALL:-0}"
INSTALL_PREFIX="${INSTALL_PREFIX:-$LLVM_BUILD_DIR/install}"
DISABLE_BENCHMARKS="${DISABLE_BENCHMARKS:-1}"
DISABLE_TESTS="${DISABLE_TESTS:-1}"
DISABLE_EXAMPLES="${DISABLE_EXAMPLES:-1}"
CMAKE_ARGS="${CMAKE_ARGS:-}"

[[ -d "$LLVM_SRC" ]] || die "LLVM_SRC not found: $LLVM_SRC"
[[ -f "$LLVM_SRC/CMakeLists.txt" ]] || die "Not an LLVM source tree: $LLVM_SRC"

if [[ "$AUTO_INSTALL_DEPS" == "1" ]]; then
	run_cmd sudo apt-get update
	run_cmd sudo apt-get install -y build-essential cmake python3 zlib1g-dev libxml2-dev ninja-build
fi

require_cmd cmake
require_cmd make

if [[ "$USE_NINJA" == "1" ]]; then
	require_cmd ninja
fi

if [[ "$CLEAN" == "1" ]]; then
	log "Cleaning previous build directory..."
	run_cmd rm -rf "$LLVM_BUILD_DIR"
fi

run_cmd mkdir -p "$LLVM_BUILD_DIR"
cd "$LLVM_BUILD_DIR"

cmake_cmd=(cmake .. -DCMAKE_BUILD_TYPE="$BUILD_TYPE")
if [[ "$USE_NINJA" == "1" ]]; then
	cmake_cmd+=( -G Ninja )
fi
if [[ "$INSTALL" == "1" ]]; then
	cmake_cmd+=( -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" )
fi
if [[ "$DISABLE_BENCHMARKS" == "1" ]]; then
	cmake_cmd+=(
		-DLLVM_INCLUDE_BENCHMARKS=OFF
		-DLLVM_BUILD_BENCHMARKS=OFF
	)
fi
if [[ "$DISABLE_TESTS" == "1" ]]; then
	cmake_cmd+=( -DLLVM_INCLUDE_TESTS=OFF )
fi
if [[ "$DISABLE_EXAMPLES" == "1" ]]; then
	cmake_cmd+=( -DLLVM_INCLUDE_EXAMPLES=OFF )
fi
if [[ -n "$CMAKE_ARGS" ]]; then
	# shellcheck disable=SC2206
	extra_args=( $CMAKE_ARGS )
	cmake_cmd+=( "${extra_args[@]}" )
fi

log "Configuring LLVM..."
run_cmd "${cmake_cmd[@]}"

BUILD_LOG="$LLVM_BUILD_DIR/build-llvm.log"
if [[ "$USE_NINJA" == "1" ]]; then
	log "Building LLVM with Ninja ($JOBS jobs)..."
	ninja -j "$JOBS" 2>&1 | tee "$BUILD_LOG"
else
	log "Building LLVM with Make ($JOBS jobs)..."
	make -j "$JOBS" 2>&1 | tee "$BUILD_LOG"
fi

if [[ "$INSTALL" == "1" ]]; then
	if [[ "$USE_NINJA" == "1" ]]; then
		run_cmd ninja install
	else
		run_cmd make install
	fi
fi

[[ -x "$LLVM_BUILD_DIR/bin/llvm-config" ]] || die "Build finished but missing: $LLVM_BUILD_DIR/bin/llvm-config"
[[ -x "$LLVM_BUILD_DIR/bin/opt" ]] || die "Build finished but missing: $LLVM_BUILD_DIR/bin/opt"
[[ -x "$LLVM_BUILD_DIR/bin/clang" ]] || die "Build finished but missing: $LLVM_BUILD_DIR/bin/clang"

log "Verification:"
"$LLVM_BUILD_DIR/bin/llvm-config" --version
"$LLVM_BUILD_DIR/bin/opt" --version | sed -n '1p'
"$LLVM_BUILD_DIR/bin/clang" --version | sed -n '1p'

cat <<EOF
[build_llvm] Done.
[build_llvm] Build dir : $LLVM_BUILD_DIR
[build_llvm] Build log : $BUILD_LOG
EOF
