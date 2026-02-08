#!/usr/bin/env bash
set -euo pipefail

usage() {
cat <<'USAGE'
Usage:
  ./build_difuze.sh

Environment variables:
  DIFUZE_DIR=./difuze                          Path to difuze checkout
  LLVM_BUILD_DIR=./llvm-11.0.1/build          LLVM build directory (contains bin/clang, bin/opt, bin/llvm-config)
  KERNEL_SRC=...                               Kernel source path
  KERNEL_OUT=...                               Kernel output path (the O= path used in build)
  MAKEOUT=...                                  makeout.txt path from kernel build
  OUT_BASE=./difuze-out                        Base output folder
  LLVM_BC_OUT=$OUT_BASE/lvout-linux            LLVM BC output directory (also contains entry_point_out.txt)
  IOCTL_OUT=$OUT_BASE/ioctlfinded-linux        Ioctl finder output directory
  CHIPSET_NUM=5                                1..5 (5=linux_x86)
  ARCH_NUM=3                                   1=arm32, 2=arm64, 3=x86_64 (repo-specific)
  IS_CLANG_BUILD=1                             Pass -isclang to run_all.py
  CLANG_BIN=$LLVM_BUILD_DIR/bin/clang          clang path used by difuze
  COMPILER_NAME=$CLANG_BIN                     Compiler marker in makeout.txt (for -g)
  SPARSE_DIR=$DIFUZE_DIR/difuze_deps/sparse    sparse dependency dir
  SPARSE_REPO=git://git.kernel.org/pub/scm/devel/sparse/sparse.git
  SPARSE_TAG=v0.6.4
  SPARSE_BUILD_MODE=auto                     auto|strict|minimal
                                             auto: try full sparse build, fallback to sparse+cgcc
                                             strict: fail if full sparse build fails
                                             minimal: build sparse+cgcc only (skip sparse-llvm)
  C2XML_MODE=auto                            require|auto|skip
                                             require: fail if c2xml missing
                                             auto: use c2xml if available, else skip related steps
                                             skip: always skip c2xml-related steps
  APPLY_MANUAL_MAP=1                           Run parse_interface_with_manual_interface.py
  MANUAL_CSV=.../interface_manual_linux.csv    Manual device mapping csv
  CLEAN=0                                      Remove OUT_BASE and rebuild artifacts first
  AUTO_INSTALL_DEPS=0                          Install basic deps with apt
  DRY_RUN=0                                    Print commands only

Examples:
  KERNEL_SRC=$HOME/kernel/linux \
  KERNEL_OUT=$HOME/kernel/linux-out \
  MAKEOUT=$HOME/kernel/linux/makeout.txt \
  ./build_difuze.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

log() {
	echo "[build_difuze] $*"
}

die() {
	echo "[build_difuze][error] $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

run_cmd() {
	log "$*"
	if [[ "$DRY_RUN" == "1" ]]; then
		return 0
	fi
	"$@"
}

run_in_dir() {
	local dir="$1"
	shift
	if [[ "$DRY_RUN" == "1" ]]; then
		log "(cd $dir && $*)"
		return 0
	fi
	(
		cd "$dir"
		"$@"
	)
}

run_in_dir_allow_fail() {
	local dir="$1"
	shift
	if [[ "$DRY_RUN" == "1" ]]; then
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
	die "Python 2 runtime not found (required by difuze helper scripts)."
}

install_deps_if_needed() {
	if [[ "$AUTO_INSTALL_DEPS" != "1" ]]; then
		return
	fi
	run_cmd sudo apt-get update
	run_cmd sudo apt-get install -y \
		build-essential cmake git python2 clang llvm c2xml libxml2-dev
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIFUZE_DIR="${DIFUZE_DIR:-$SCRIPT_DIR/difuze}"
LLVM_BUILD_DIR="${LLVM_BUILD_DIR:-$SCRIPT_DIR/llvm-11.0.1/build}"
LLVM_BIN_DIR="${LLVM_BIN_DIR:-$LLVM_BUILD_DIR/bin}"
CLANG_BIN="${CLANG_BIN:-$LLVM_BIN_DIR/clang}"
COMPILER_NAME="${COMPILER_NAME:-$CLANG_BIN}"

KERNEL_SRC="${KERNEL_SRC:-$SCRIPT_DIR/kernel/linux}"
KERNEL_OUT="${KERNEL_OUT:-$SCRIPT_DIR/kernel/linux-out}"
MAKEOUT="${MAKEOUT:-$KERNEL_SRC/makeout.txt}"

OUT_BASE="${OUT_BASE:-$SCRIPT_DIR/difuze-out}"
LLVM_BC_OUT="${LLVM_BC_OUT:-$OUT_BASE/lvout-linux}"
IOCTL_OUT="${IOCTL_OUT:-$OUT_BASE/ioctlfinded-linux}"

CHIPSET_NUM="${CHIPSET_NUM:-5}"
ARCH_NUM="${ARCH_NUM:-3}"
IS_CLANG_BUILD="${IS_CLANG_BUILD:-1}"

SPARSE_DIR="${SPARSE_DIR:-$DIFUZE_DIR/difuze_deps/sparse}"
SPARSE_REPO="${SPARSE_REPO:-git://git.kernel.org/pub/scm/devel/sparse/sparse.git}"
SPARSE_TAG="${SPARSE_TAG:-v0.6.4}"
SPARSE_BUILD_MODE="${SPARSE_BUILD_MODE:-auto}"
C2XML_MODE="${C2XML_MODE:-auto}"

APPLY_MANUAL_MAP="${APPLY_MANUAL_MAP:-1}"
MANUAL_CSV="${MANUAL_CSV:-$DIFUZE_DIR/helper_scripts/interface_manual_linux.csv}"

CLEAN="${CLEAN:-0}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-0}"
DRY_RUN="${DRY_RUN:-0}"

[[ -d "$DIFUZE_DIR" ]] || die "DIFUZE_DIR not found: $DIFUZE_DIR"
[[ -d "$LLVM_BUILD_DIR" ]] || die "LLVM_BUILD_DIR not found: $LLVM_BUILD_DIR"
[[ -x "$CLANG_BIN" ]] || die "CLANG_BIN not executable: $CLANG_BIN"
[[ -d "$KERNEL_SRC" ]] || die "KERNEL_SRC not found: $KERNEL_SRC"
[[ -f "$MAKEOUT" ]] || die "MAKEOUT not found: $MAKEOUT"

install_deps_if_needed
if [[ "$DRY_RUN" == "1" ]]; then
	PY2="${PY2_BIN:-python2}"
else
	PY2="$(detect_py2)"
fi

export PATH="$LLVM_BIN_DIR:$SPARSE_DIR:$PATH"
export LLVM_ROOT="$LLVM_BUILD_DIR"

if [[ "$DRY_RUN" != "1" ]]; then
	require_cmd git
	require_cmd make
	require_cmd cmake
	require_cmd g++
	require_cmd llvm-config
	require_cmd opt
fi

if [[ "$CLEAN" == "1" ]]; then
	log "Cleaning previous difuze artifacts..."
	run_cmd rm -rf "$OUT_BASE" "$DIFUZE_DIR/InterfaceHandlers/MainAnalysisPasses/build_dir"
fi
run_cmd mkdir -p "$OUT_BASE"

if [[ ! -d "$SPARSE_DIR/.git" ]]; then
	log "Cloning sparse dependency..."
	run_cmd mkdir -p "$(dirname "$SPARSE_DIR")"
	run_cmd git clone "$SPARSE_REPO" "$SPARSE_DIR"
fi

if [[ -f "$DIFUZE_DIR/deps/sparse/pre-process.c" ]]; then
	log "Applying sparse pre-process.c patch from difuze/deps..."
	run_cmd cp -f "$DIFUZE_DIR/deps/sparse/pre-process.c" "$SPARSE_DIR/pre-process.c"
fi

if [[ "$DRY_RUN" != "1" ]]; then
	if run_in_dir "$SPARSE_DIR" git rev-parse --verify -q "$SPARSE_TAG" >/dev/null 2>&1; then
		run_in_dir "$SPARSE_DIR" git checkout "$SPARSE_TAG"
	else
		run_in_dir "$SPARSE_DIR" git fetch --tags
		run_in_dir "$SPARSE_DIR" git checkout "$SPARSE_TAG"
	fi

	SPARSE_MAKEFILE="$SPARSE_DIR/Makefile"
	if [[ -f "$SPARSE_MAKEFILE" ]]; then
		# sparse v0.6.4 often links sparse-llvm with too few LLVM libs on modern toolchains.
		if grep -q 'llvm-config --libs bitwriter' "$SPARSE_MAKEFILE"; then
			log "Patching sparse Makefile for LLVM 11+ (bitwriter -> all --system-libs)"
			run_cmd sed -i 's/llvm-config --libs bitwriter/llvm-config --libs all --system-libs/g' "$SPARSE_MAKEFILE"
		elif grep -q 'llvm-config --libs' "$SPARSE_MAKEFILE" && ! grep -q 'llvm-config --libs all' "$SPARSE_MAKEFILE"; then
			log "Patching sparse Makefile for LLVM 11+ (--libs -> --libs all --system-libs)"
			run_cmd sed -i 's/llvm-config --libs/llvm-config --libs all --system-libs/g' "$SPARSE_MAKEFILE"
		fi
	fi

	SPARSE_JOBS="$(nproc)"
	SPARSE_LOG="$OUT_BASE/sparse-build.log"
	LLVM_CFG_BIN="$LLVM_BIN_DIR/llvm-config"
	[[ -x "$LLVM_CFG_BIN" ]] || die "llvm-config not found in LLVM_BIN_DIR: $LLVM_CFG_BIN"

	case "$SPARSE_BUILD_MODE" in
		strict)
			log "Building sparse (strict mode)..."
			run_in_dir "$SPARSE_DIR" env LLVM_CONFIG="$LLVM_CFG_BIN" make -j"$SPARSE_JOBS" \
				2>&1 | tee "$SPARSE_LOG"
			;;
		minimal)
			log "Building sparse minimal targets (sparse, cgcc)..."
			run_in_dir_allow_fail "$SPARSE_DIR" make clean >/dev/null 2>&1 || true
			run_in_dir "$SPARSE_DIR" env LLVM_CONFIG="$LLVM_CFG_BIN" make -j"$SPARSE_JOBS" sparse cgcc \
				2>&1 | tee "$SPARSE_LOG"
			;;
		auto)
			log "Building sparse (auto mode)..."
			if ! run_in_dir_allow_fail "$SPARSE_DIR" env LLVM_CONFIG="$LLVM_CFG_BIN" make -j"$SPARSE_JOBS" \
				2>&1 | tee "$SPARSE_LOG"; then
				log "Full sparse build failed. Retrying minimal targets (sparse, cgcc)..."
				run_in_dir_allow_fail "$SPARSE_DIR" make clean >/dev/null 2>&1 || true
				run_in_dir "$SPARSE_DIR" env LLVM_CONFIG="$LLVM_CFG_BIN" make -j"$SPARSE_JOBS" sparse cgcc \
					2>&1 | tee "$SPARSE_LOG"
				log "Continuing with sparse minimal build (sparse-llvm skipped)."
			fi
			;;
		*)
			die "Invalid SPARSE_BUILD_MODE=$SPARSE_BUILD_MODE (valid: auto|strict|minimal)"
			;;
	esac
fi

log "Building difuze InterfaceHandlers..."
run_cmd rm -rf "$DIFUZE_DIR/InterfaceHandlers/MainAnalysisPasses/build_dir"
run_in_dir "$DIFUZE_DIR/InterfaceHandlers" bash ./build.sh

DR_LINK_BIN="$DIFUZE_DIR/InterfaceHandlers/AnalysisHelpers/Dr_linker/dr_linker"
ENTRY_POINT_BIN="$DIFUZE_DIR/InterfaceHandlers/AnalysisHelpers/EntryPointIdentifier/entry_point_handler"
[[ "$DRY_RUN" == "1" || -x "$DR_LINK_BIN" ]] || die "AnalysisHelpers build incomplete, missing: $DR_LINK_BIN"
[[ "$DRY_RUN" == "1" || -x "$ENTRY_POINT_BIN" ]] || die "AnalysisHelpers build incomplete, missing: $ENTRY_POINT_BIN"

run_cmd mkdir -p "$OUT_BASE" "$LLVM_BC_OUT" "$IOCTL_OUT"

log "Running difuze helper_scripts/run_all.py ..."
RUN_ALL_LOG="$OUT_BASE/difuze-run_all.log"
NEED_C2XML_SHIM=0
C2XML_SHIM_DIR="$OUT_BASE/.shim-bin"
run_all_args=(
	run_all.py
	-l "$LLVM_BC_OUT"
	-a "$CHIPSET_NUM"
	-m "$MAKEOUT"
	-g "$COMPILER_NAME"
	-n "$ARCH_NUM"
	-o "$KERNEL_OUT"
	-k "$KERNEL_SRC"
	-f "$IOCTL_OUT"
	-clangp "$CLANG_BIN"
)
if [[ "$IS_CLANG_BUILD" == "1" ]]; then
	run_all_args+=( -isclang )
fi

case "$C2XML_MODE" in
	require)
		if [[ "$DRY_RUN" != "1" ]]; then
			require_cmd c2xml
		fi
		;;
	auto)
		if [[ "$DRY_RUN" != "1" ]]; then
			if ! command -v c2xml >/dev/null 2>&1; then
				log "c2xml not found, auto-skipping GenerateIncludes/ParseHeaders/V4L2 steps"
				run_all_args+=( -skI -skp -skv )
				NEED_C2XML_SHIM=1
			fi
		fi
		;;
	skip)
		log "Skipping c2xml-related steps by request (C2XML_MODE=skip)"
		run_all_args+=( -skI -skp -skv )
		NEED_C2XML_SHIM=1
		;;
	*)
		die "Invalid C2XML_MODE=$C2XML_MODE (valid: require|auto|skip)"
		;;
esac

if [[ "$NEED_C2XML_SHIM" == "1" ]]; then
	if [[ "$DRY_RUN" == "1" ]]; then
		log "mkdir -p $C2XML_SHIM_DIR && create c2xml shim"
	else
		run_cmd mkdir -p "$C2XML_SHIM_DIR"
		printf '#!/usr/bin/env bash\nexit 0\n' > "$C2XML_SHIM_DIR/c2xml"
		run_cmd chmod +x "$C2XML_SHIM_DIR/c2xml"
	fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
	log "(cd $DIFUZE_DIR/helper_scripts && $PY2 ${run_all_args[*]} | tee $RUN_ALL_LOG)"
else
	(
		cd "$DIFUZE_DIR/helper_scripts"
		if [[ "$NEED_C2XML_SHIM" == "1" ]]; then
			PATH="$C2XML_SHIM_DIR:$PATH" "$PY2" "${run_all_args[@]}" 2>&1 | tee "$RUN_ALL_LOG"
		else
			"$PY2" "${run_all_args[@]}" 2>&1 | tee "$RUN_ALL_LOG"
		fi
	)
fi

ENTRY_POINT_OUT="$LLVM_BC_OUT/entry_point_out.txt"
[[ "$DRY_RUN" == "1" || -f "$ENTRY_POINT_OUT" ]] || die "entry_point_out.txt not found: $ENTRY_POINT_OUT"

if [[ "$APPLY_MANUAL_MAP" == "1" ]]; then
	[[ -f "$MANUAL_CSV" ]] || die "MANUAL_CSV not found: $MANUAL_CSV"
	log "Applying manual interface map..."
	run_in_dir "$DIFUZE_DIR/helper_scripts" "$PY2" parse_interface_with_manual_interface.py "$IOCTL_OUT" "$MANUAL_CSV"
fi

cat <<EOF
[build_difuze] Done.
[build_difuze] Outputs:
  IOCTL finder out : $IOCTL_OUT
  Entry points     : $ENTRY_POINT_OUT
  run_all log      : $RUN_ALL_LOG

[build_difuze] Next:
  USE_DIFUZE=1 DIFUZE_IOCTL_DIR="$IOCTL_OUT" DIFUZE_ENTRY_OUT="$ENTRY_POINT_OUT" PY2_BIN="$PY2" ./howto_hfl.sh
EOF
