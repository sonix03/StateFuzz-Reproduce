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
  USE_DIFUZE=1                            Enable HFL-D flow (Difuze -> Syzkaller)
  DIFUZE_HELPER_DIR=.../difuze/helper_scripts
                                           Path to difuze helper scripts
  DIFUZE_IOCTL_DIR=...                    Raw ioctl finder output directory (.txt)
  DIFUZE_ENTRY_OUT=.../entry_point_out.txt
                                           Entry point mapping file from difuze
  DIFUZE_JSON_DIR=...                     Parsed JSON output for difuze interface files
  DIFUZE_SYZ_DESC_DIR=...                 Generated syzkaller syscall description files
  DIFUZE_APPLY_MANUAL_MAP=1               Run parse_interface_with_manual_interface.py
  DIFUZE_MANUAL_CSV=.../interface_manual_linux.csv
                                           Manual interface map csv
  DIFUZE_ENABLE_FILE=.../hfl/scripts/enable_syscalls
                                           syscall list for -enable filter
  HFL_CONFIG_FILE=.../hfl/scripts/sample.cfg
                                           manager config that gets enable_syscalls updated
  DIFUZE_GENERATE=1                       Run syzkaller make generate after copy
  DIFUZE_GENERATE_RETRIES=5               Retry count with parse_error handler
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
  USE_DIFUZE=1 DIFUZE_IOCTL_DIR=/work/ioctlfinded-linux \
    DIFUZE_ENTRY_OUT=/work/lvout-linux/entry_point_out.txt ./howto_hfl.sh
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

detect_py2() {
	if [[ -n "${PY2_BIN:-}" ]]; then
		command -v "$PY2_BIN" >/dev/null 2>&1 || die "PY2_BIN not found: $PY2_BIN"
		echo "$PY2_BIN"
		return
	fi

	if command -v python2 >/dev/null 2>&1; then
		echo python2
		return
	fi

	if command -v python >/dev/null 2>&1; then
		if python - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info[0] == 2 else 1)
PY
		then
			echo python
			return
		fi
	fi

	die "Python 2 runtime not found (required for difuze helper scripts)."
}

detect_py3() {
	if command -v python3 >/dev/null 2>&1; then
		echo python3
		return
	fi
	if command -v python >/dev/null 2>&1; then
		if python - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info[0] == 3 else 1)
PY
		then
			echo python
			return
		fi
	fi
	die "Python 3 runtime not found (required to update JSON config files safely)."
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

integrate_difuze_if_needed() {
	if [[ "$USE_DIFUZE" != "1" ]]; then
		return
	fi

	if [[ "$PLAN_ONLY" == "1" ]]; then
		log "(difuze) expected helper dir: $DIFUZE_HELPER_DIR"
		log "(difuze) expected ioctl output: $DIFUZE_IOCTL_DIR"
		log "(difuze) expected entry map: $DIFUZE_ENTRY_OUT"
		if [[ "$DIFUZE_APPLY_MANUAL_MAP" == "1" ]]; then
			log "(cd $DIFUZE_HELPER_DIR && <python2> parse_interface_with_manual_interface.py $DIFUZE_IOCTL_DIR $DIFUZE_MANUAL_CSV)"
		fi
		log "(cd $DIFUZE_HELPER_DIR && <python2> parse_interface_output.py $DIFUZE_IOCTL_DIR $DIFUZE_JSON_DIR)"
		log "(cd $DIFUZE_HELPER_DIR && <python2> parse_interface_to_syzkaller.py $DIFUZE_JSON_DIR $DIFUZE_SYZ_DESC_DIR $DIFUZE_ENTRY_OUT | tee $DIFUZE_PARSE_LOG)"
		log "(copy $DIFUZE_SYZ_DESC_DIR/*.txt -> $SYZ_SYS_LINUX_DIR)"
		log "(write enable syscalls -> $DIFUZE_ENABLE_FILE)"
		if [[ "$DIFUZE_GENERATE" == "1" ]]; then
			log "(cd $SYZ_HOME && make generate) with retries=$DIFUZE_GENERATE_RETRIES + parse_interface_to_syzkaller_errorhandle.py"
		fi
		if [[ "$DIFUZE_UPDATE_CFG" == "1" ]]; then
			log "(update enable_syscalls in $HFL_CONFIG_FILE from $DIFUZE_ENABLE_FILE)"
		fi
		return
	fi

	[[ -d "$DIFUZE_HELPER_DIR" ]] || die "DIFUZE_HELPER_DIR not found: $DIFUZE_HELPER_DIR"
	[[ -d "$DIFUZE_IOCTL_DIR" ]] || die "DIFUZE_IOCTL_DIR not found: $DIFUZE_IOCTL_DIR"
	[[ -f "$DIFUZE_ENTRY_OUT" ]] || die "DIFUZE_ENTRY_OUT not found: $DIFUZE_ENTRY_OUT"
	[[ -d "$SYZ_HOME" ]] || die "SYZ_HOME not found: $SYZ_HOME"
	[[ -d "$SYZ_SYS_LINUX_DIR" ]] || die "SYZ_SYS_LINUX_DIR not found: $SYZ_SYS_LINUX_DIR"

	if [[ "$DIFUZE_APPLY_MANUAL_MAP" == "1" ]]; then
		[[ -f "$DIFUZE_MANUAL_CSV" ]] || die "DIFUZE_MANUAL_CSV not found: $DIFUZE_MANUAL_CSV"
	fi

	local py2 py3
	py2="$(detect_py2)"
	py3="$(detect_py3)"

	log "Preparing HFL-D (Difuze -> Syzkaller)..."
	mkdir -p "$DIFUZE_JSON_DIR" "$DIFUZE_SYZ_DESC_DIR"

	if [[ "$DIFUZE_APPLY_MANUAL_MAP" == "1" ]]; then
		log "Applying manual interface mapping from CSV..."
		run_in_dir "$DIFUZE_HELPER_DIR" "$py2" parse_interface_with_manual_interface.py "$DIFUZE_IOCTL_DIR" "$DIFUZE_MANUAL_CSV"
	fi

	log "Parsing difuze output into JSON format..."
	run_in_dir "$DIFUZE_HELPER_DIR" "$py2" parse_interface_output.py "$DIFUZE_IOCTL_DIR" "$DIFUZE_JSON_DIR"

	log "Converting difuze JSON into syzkaller descriptions..."
	(
		cd "$DIFUZE_HELPER_DIR"
		"$py2" parse_interface_to_syzkaller.py "$DIFUZE_JSON_DIR" "$DIFUZE_SYZ_DESC_DIR" "$DIFUZE_ENTRY_OUT" | tee "$DIFUZE_PARSE_LOG"
	)

	local enable_line
	enable_line="$(awk '/^\[.*\]$/{line=$0} END{print line}' "$DIFUZE_PARSE_LOG")"
	[[ -n "$enable_line" ]] || die "Failed to parse enable_syscalls from: $DIFUZE_PARSE_LOG"
	local enable_raw_file="$DIFUZE_JSON_DIR/enable_syscalls.raw"
	printf '%s\n' "$enable_line" >"$enable_raw_file"

	log "Writing enable syscall filter to $DIFUZE_ENABLE_FILE"
	"$py3" - "$DIFUZE_ENABLE_FILE" "$enable_raw_file" <<'PY'
import ast
import sys

out_path = sys.argv[1]
raw_path = sys.argv[2]
with open(raw_path) as f:
    line = f.read().strip()
try:
    values = ast.literal_eval(line)
except Exception as exc:
    raise SystemExit("cannot parse enable_syscalls list: %s" % exc)

seen = set()
final = []
for value in values:
    s = str(value).strip()
    if not s or s in seen:
        continue
    seen.add(s)
    final.append(s)

with open(out_path, "w") as f:
    for item in final:
        f.write(item + "\n")
print("wrote_enable_syscalls=%d" % len(final))
PY

	shopt -s nullglob
	local desc_files=("$DIFUZE_SYZ_DESC_DIR"/*.txt)
	if (( ${#desc_files[@]} == 0 )); then
		shopt -u nullglob
		die "No generated syzkaller description files found in: $DIFUZE_SYZ_DESC_DIR"
	fi
	log "Copying ${#desc_files[@]} difuze syscall description files into syzkaller..."
	cp -f "${desc_files[@]}" "$SYZ_SYS_LINUX_DIR/"
	shopt -u nullglob

	if [[ "$DIFUZE_GENERATE" == "1" ]]; then
		local attempt generate_ok generate_log
		generate_ok=0
		for ((attempt = 1; attempt <= DIFUZE_GENERATE_RETRIES; attempt++)); do
			generate_log="$DIFUZE_JSON_DIR/syzkaller-generate-attempt-${attempt}.log"
			log "Running syzkaller make generate (attempt $attempt/$DIFUZE_GENERATE_RETRIES)..."
			if (cd "$SYZ_HOME" && make generate >"$generate_log" 2>&1); then
				generate_ok=1
				break
			fi

			log "make generate failed, applying difuze error handler..."
			(
				cd "$DIFUZE_HELPER_DIR"
				"$py2" parse_interface_to_syzkaller_errorhandle.py "$generate_log" "$SYZ_SYS_LINUX_DIR" "$DIFUZE_SYZ_DESC_DIR" || true
			)
		done
		[[ "$generate_ok" == "1" ]] || die "syzkaller make generate failed after $DIFUZE_GENERATE_RETRIES attempts. Logs: $DIFUZE_JSON_DIR"
	fi

	if [[ "$DIFUZE_UPDATE_CFG" == "1" ]]; then
		[[ -f "$HFL_CONFIG_FILE" ]] || die "HFL_CONFIG_FILE not found: $HFL_CONFIG_FILE"
		log "Updating enable_syscalls in $HFL_CONFIG_FILE"
		"$py3" - "$HFL_CONFIG_FILE" "$DIFUZE_ENABLE_FILE" <<'PY'
import json
import sys

cfg_path = sys.argv[1]
enable_path = sys.argv[2]

with open(cfg_path) as f:
    cfg = json.load(f)

seen = set()
values = []
with open(enable_path) as f:
    for line in f:
        s = line.strip()
        if not s or s in seen:
            continue
        seen.add(s)
        values.append(s)

cfg["enable_syscalls"] = values
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("updated_config_enable_syscalls=%d" % len(values))
PY
	fi

	log "HFL-D integration step finished."
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HFL_DIR="${HFL_DIR:-$SCRIPT_DIR/hfl}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$HFL_DIR/scripts}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-0}"
PLAN_ONLY="${PLAN_ONLY:-0}"
CLEAN="${CLEAN:-0}"
DOWNLOAD_KERNEL="${DOWNLOAD_KERNEL:-1}"
SOURCE_COMMON="${SOURCE_COMMON:-1}"
USE_DIFUZE="${USE_DIFUZE:-1}"
SYZ_HOME="${SYZ_HOME:-$HFL_DIR/src/github.com/google/syzkaller}"
SYZ_SYS_LINUX_DIR="${SYZ_SYS_LINUX_DIR:-$SYZ_HOME/sys/linux}"
DIFUZE_HELPER_DIR="${DIFUZE_HELPER_DIR:-$SCRIPT_DIR/difuze/helper_scripts}"
DIFUZE_IOCTL_DIR="${DIFUZE_IOCTL_DIR:-$SCRIPT_DIR/difuze-out/ioctlfinded-linux}"
DIFUZE_ENTRY_OUT="${DIFUZE_ENTRY_OUT:-$SCRIPT_DIR/difuze-out/entry_point_out.txt}"
DIFUZE_JSON_DIR="${DIFUZE_JSON_DIR:-$SCRIPT_DIR/difuze-out/ioctlfinded-linux-json}"
DIFUZE_SYZ_DESC_DIR="${DIFUZE_SYZ_DESC_DIR:-$SCRIPT_DIR/difuze-out/ioctlfinded-linux-syzkaller}"
DIFUZE_APPLY_MANUAL_MAP="${DIFUZE_APPLY_MANUAL_MAP:-1}"
DIFUZE_MANUAL_CSV="${DIFUZE_MANUAL_CSV:-$DIFUZE_HELPER_DIR/interface_manual_linux.csv}"
DIFUZE_ENABLE_FILE="${DIFUZE_ENABLE_FILE:-$SCRIPTS_DIR/enable_syscalls}"
DIFUZE_UPDATE_CFG="${DIFUZE_UPDATE_CFG:-1}"
HFL_CONFIG_FILE="${HFL_CONFIG_FILE:-$SCRIPTS_DIR/sample.cfg}"
DIFUZE_GENERATE="${DIFUZE_GENERATE:-1}"
DIFUZE_GENERATE_RETRIES="${DIFUZE_GENERATE_RETRIES:-5}"
DIFUZE_PARSE_LOG="${DIFUZE_PARSE_LOG:-$DIFUZE_JSON_DIR/parse_interface_to_syzkaller.log}"
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

integrate_difuze_if_needed

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
