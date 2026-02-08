#!/usr/bin/env bash
set -euo pipefail

usage() {
cat <<'USAGE'
Usage:
  ./howto_hfl.sh

Environment variables:
  HFL_DIR=./hfl                           Path to HFL checkout
  AUTO_INSTALL_DEPS=0                     Install baseline deps via apt
  PLAN_ONLY=0                             Only print planned commands (no execution)
  CLEAN=0                                 Remove selected old build outputs first
  DOWNLOAD_KERNEL=1                       Run hfl/scripts/download_kernel.sh
  SOURCE_COMMON=1                         Source hfl/scripts/common.sh (validation step)
  BUILD_GCC=1                             Run hfl/scripts/build-gcc.sh
  BUILD_S2E=1                             Build S2E component
  BUILD_S2E_KERNEL=1                      Build S2E kernel package
  BUILD_S2E_IMAGE=1                       Build S2E guest image
  RUN_SNAPSHOTS=1                         Run s2e/snapshots.sh (requires S2E image)
  BUILD_SYZ=1                             Build Syzkaller component
  BUILD_SYZ_IMAGE=1                       Build Syzkaller disk image
  BUILD_SYZ_KERNEL=1                      Build Syzkaller kernel
  PATCH_S2E_CONFIG=1                      Update scripts/s2e-config.lua HostFiles baseDirs
  SYZ_KERNEL_CONFIG=.../scripts/syz/config
  S2E_KERNEL_CONFIG=.../scripts/s2e/config

Examples:
  PLAN_ONLY=1 ./howto_hfl.sh
  AUTO_INSTALL_DEPS=1 ./howto_hfl.sh
  BUILD_S2E=0 BUILD_S2E_KERNEL=0 BUILD_S2E_IMAGE=0 RUN_SNAPSHOTS=0 ./howto_hfl.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

log() {
	echo "[howto_hfl] $*"
}

die() {
	echo "[howto_hfl][error] $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

run_cmd() {
	log "$*"
	if [[ "$PLAN_ONLY" == "1" ]]; then
		return 0
	fi
	"$@"
}

run_in_dir() {
	local dir="$1"
	shift
	if [[ "$PLAN_ONLY" == "1" ]]; then
		log "(cd $dir && $*)"
		return 0
	fi
	(
		cd "$dir"
		"$@"
	)
}

source_common_if_needed() {
	if [[ "$SOURCE_COMMON" != "1" ]]; then
		return
	fi
	if [[ "$PLAN_ONLY" == "1" ]]; then
		log "(cd $SCRIPTS_DIR && source ./common.sh)"
		return
	fi
	# shellcheck disable=SC1090
	source "$SCRIPTS_DIR/common.sh"
	log "Loaded env from $SCRIPTS_DIR/common.sh (HFLHOME=${HFLHOME:-unset}, GOPATH=${GOPATH:-unset}, GOROOT=${GOROOT:-unset})"
}

install_deps_if_needed() {
	if [[ "$AUTO_INSTALL_DEPS" != "1" ]]; then
		return
	fi

	log "Installing baseline dependencies with apt..."
	run_cmd sudo apt-get update
	run_cmd sudo apt-get install -y \
		bc bison build-essential curl flex gcc g++ git make realpath tmux timeout wget
}

patch_s2e_config_if_needed() {
	if [[ "$PATCH_S2E_CONFIG" != "1" ]]; then
		return
	fi

	local s2e_cfg="$SCRIPTS_DIR/s2e-config.lua"
	[[ -f "$s2e_cfg" ]] || die "Missing file: $s2e_cfg"
	local target_tmp
	if command -v realpath >/dev/null 2>&1; then
		target_tmp="$(realpath "$SCRIPTS_DIR/tmp")"
	else
		target_tmp="$SCRIPTS_DIR/tmp"
	fi

	if grep -q "$target_tmp" "$s2e_cfg"; then
		log "s2e-config.lua already points to $target_tmp"
		return
	fi

	log "Patching HostFiles baseDirs in s2e-config.lua -> $target_tmp"
	if [[ "$PLAN_ONLY" == "1" ]]; then
		return
	fi

	sed -i -E "s|^[[:space:]]*\"/PATH/hfl/scripts/tmp/\"|        \"${target_tmp}/\"|g" "$s2e_cfg"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HFL_DIR="${HFL_DIR:-$SCRIPT_DIR/hfl}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$HFL_DIR/scripts}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-0}"
PLAN_ONLY="${PLAN_ONLY:-0}"
CLEAN="${CLEAN:-0}"
DOWNLOAD_KERNEL="${DOWNLOAD_KERNEL:-1}"
SOURCE_COMMON="${SOURCE_COMMON:-1}"
BUILD_GCC="${BUILD_GCC:-1}"
BUILD_SYZ="${BUILD_SYZ:-1}"
BUILD_SYZ_KERNEL="${BUILD_SYZ_KERNEL:-1}"
BUILD_SYZ_IMAGE="${BUILD_SYZ_IMAGE:-1}"
BUILD_S2E="${BUILD_S2E:-1}"
BUILD_S2E_KERNEL="${BUILD_S2E_KERNEL:-1}"
BUILD_S2E_IMAGE="${BUILD_S2E_IMAGE:-1}"
RUN_SNAPSHOTS="${RUN_SNAPSHOTS:-1}"
PATCH_S2E_CONFIG="${PATCH_S2E_CONFIG:-1}"
SYZ_KERNEL_CONFIG="${SYZ_KERNEL_CONFIG:-$SCRIPTS_DIR/syz/config}"
S2E_KERNEL_CONFIG="${S2E_KERNEL_CONFIG:-$SCRIPTS_DIR/s2e/config}"

[[ -d "$HFL_DIR" ]] || die "HFL_DIR not found: $HFL_DIR"
[[ -d "$SCRIPTS_DIR" ]] || die "scripts dir not found: $SCRIPTS_DIR"

install_deps_if_needed

if [[ "$PLAN_ONLY" != "1" ]]; then
	require_cmd bash
	require_cmd git
	require_cmd nproc
	if [[ "$DOWNLOAD_KERNEL" == "1" ]]; then
		require_cmd wget
	fi
	if [[ "$BUILD_GCC" == "1" || "$BUILD_SYZ" == "1" || "$BUILD_SYZ_KERNEL" == "1" || "$BUILD_S2E" == "1" || "$BUILD_S2E_KERNEL" == "1" ]]; then
		require_cmd make
		require_cmd gcc
	fi
	if [[ "$BUILD_SYZ" == "1" ]]; then
		require_cmd go
	fi
fi

if [[ "$CLEAN" == "1" ]]; then
	log "Cleaning selected HFL artifacts..."
	run_cmd rm -rf "$HFL_DIR/build/syz" "$HFL_DIR/build/s2e" "$SCRIPTS_DIR/workdir" "$SCRIPTS_DIR/tmp"
fi

patch_s2e_config_if_needed

if [[ "$DOWNLOAD_KERNEL" == "1" ]]; then
	run_in_dir "$SCRIPTS_DIR" ./download_kernel.sh
fi

source_common_if_needed

if [[ "$BUILD_GCC" == "1" ]]; then
	log "Building HFL GCC (can take a long time)..."
	run_in_dir "$SCRIPTS_DIR" ./build-gcc.sh
fi

if [[ "$BUILD_S2E" == "1" ]]; then
	log "Building S2E (heavy, can take hours)..."
	run_in_dir "$SCRIPTS_DIR/s2e" ./build-s2e.sh
fi

if [[ "$BUILD_S2E_KERNEL" == "1" ]]; then
	[[ -f "$S2E_KERNEL_CONFIG" ]] || die "S2E kernel config not found: $S2E_KERNEL_CONFIG"
	log "Building S2E kernel package..."
	run_in_dir "$SCRIPTS_DIR/s2e" ./build-kernel.sh -conf "$S2E_KERNEL_CONFIG"
fi

if [[ "$BUILD_S2E_IMAGE" == "1" ]]; then
	log "Building S2E guest image..."
	run_in_dir "$SCRIPTS_DIR/s2e" ./build-image.sh
fi

if [[ "$RUN_SNAPSHOTS" == "1" ]]; then
	log "Taking S2E snapshots..."
	run_in_dir "$SCRIPTS_DIR/s2e" ./snapshots.sh
fi

if [[ "$BUILD_SYZ" == "1" ]]; then
	log "Building HFL Syzkaller..."
	run_in_dir "$SCRIPTS_DIR/syz" ./build-syzkaller.sh
fi

if [[ "$BUILD_SYZ_IMAGE" == "1" ]]; then
	log "Building Syzkaller disk image..."
	run_in_dir "$SCRIPTS_DIR/syz" ./build-image.sh
fi

if [[ "$BUILD_SYZ_KERNEL" == "1" ]]; then
	[[ -f "$SYZ_KERNEL_CONFIG" ]] || die "Syz kernel config not found: $SYZ_KERNEL_CONFIG"
	log "Building Syzkaller kernel..."
	run_in_dir "$SCRIPTS_DIR/syz" ./build-kernel.sh -conf "$SYZ_KERNEL_CONFIG"
fi

cat <<EOF
[howto_hfl] Done.
[howto_hfl] Next recommended command:
  cd "$SCRIPT_DIR"
  ./run_12h_hfl.sh

[howto_hfl] Quick manual run (without 12h wrapper):
  cd "$SCRIPTS_DIR"
  ./run_syzkaller.sh
  ./run_s2e.sh
  ./run_agent.sh
EOF
