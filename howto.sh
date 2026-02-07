#!/usr/bin/env bash
set -euo pipefail

# howto.sh
# Prepare StateFuzz to run against Linux kernel v4.19 on QEMU (x86_64).
# By default this script prepares everything and prints the run command.
# Set RUN_MANAGER=1 to start syz-manager at the end.

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
cat <<'USAGE'
Usage:
  ./howto.sh

Important environment variables:
  AUTO_INSTALL_DEPS=1   Auto-install host deps with apt (requires sudo)
  RUN_MANAGER=1         Start syz-manager after setup
  WORK_BASE=...         Workspace base (default: $HOME/statefuzz-4.19)
  KERNEL_TAG=...        Linux tag (default: v4.19)
  VM_COUNT=...          Number of QEMU VMs (default: 2)
  PROCS=...             Fuzzer procs per VM (default: 2)
  HTTP_ADDR=...         Manager HTTP bind (default: 127.0.0.1:56741)

Example:
  AUTO_INSTALL_DEPS=1 RUN_MANAGER=1 ./howto.sh
USAGE
	exit 0
fi

log() {
	echo "[howto] $*"
}

die() {
	echo "[howto][error] $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

ensure_go_on_path() {
	if command -v go >/dev/null 2>&1; then
		return
	fi
	if [[ -x /usr/local/go/bin/go ]]; then
		export PATH="/usr/local/go/bin:$PATH"
	fi
}

go_version_supported() {
	ensure_go_on_path
	if ! command -v go >/dev/null 2>&1; then
		return 1
	fi
	local raw version major minor rest
	raw="$(go version | awk '{print $3}')"
	version="${raw#go}"
	major="${version%%.*}"
	rest="${version#*.}"
	minor="${rest%%.*}"
	if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	(( major > 1 || (major == 1 && minor >= 19) ))
}

install_go_toolchain() {
	local go_arch tar_name go_url tmp_dir
	case "$(uname -m)" in
		x86_64|amd64) go_arch="amd64" ;;
		aarch64|arm64) go_arch="arm64" ;;
		*) die "Unsupported host arch for auto Go install: $(uname -m)" ;;
	esac

	tar_name="go${GO_BOOTSTRAP_VERSION}.linux-${go_arch}.tar.gz"
	go_url="${GO_BOOTSTRAP_URL:-https://go.dev/dl/${tar_name}}"
	tmp_dir="$(mktemp -d)"
	log "Installing Go ${GO_BOOTSTRAP_VERSION} from ${go_url}"
	wget -O "${tmp_dir}/${tar_name}" "${go_url}"
	sudo rm -rf /usr/local/go
	sudo tar -C /usr/local -xzf "${tmp_dir}/${tar_name}"
	rm -rf "${tmp_dir}"
	export PATH="/usr/local/go/bin:$PATH"
}

check_go_version() {
	ensure_go_on_path
	if ! command -v go >/dev/null 2>&1; then
		if [[ "$AUTO_INSTALL_DEPS" == "1" ]]; then
			install_go_toolchain
		else
			die "Missing command: go. Install Go >= 1.19 and ensure it is in PATH."
		fi
	fi
	if ! go_version_supported; then
		local current_go
		current_go="$(go version | awk '{print $3}')"
		if [[ "$AUTO_INSTALL_DEPS" == "1" ]]; then
			log "Go version too old (${current_go}), upgrading..."
			install_go_toolchain
		else
			die "Go >= 1.19 is required, found ${current_go}. Re-run with AUTO_INSTALL_DEPS=1 or install newer Go manually."
		fi
	fi
	local raw version major minor rest
	raw="$(go version | awk '{print $3}')"
	version="${raw#go}"
	major="${version%%.*}"
	rest="${version#*.}"
	minor="${rest%%.*}"
	if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
		log "Cannot parse Go version from: $raw (continuing)"
		return
	fi
	if (( major < 1 || (major == 1 && minor < 19) )); then
		die "Go >= 1.19 is required, found $raw"
	fi
}

install_deps_if_needed() {
	if [[ "$AUTO_INSTALL_DEPS" != "1" ]]; then
		return
	fi
	log "Installing host dependencies via apt..."
	sudo apt-get update
	sudo apt-get install -y \
		bc bison debootstrap flex gcc git libelf-dev libncurses-dev \
		libssl-dev make qemu-system-x86 wget golang-go
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
STATEFUZZ_DIR="${STATEFUZZ_DIR:-$REPO_ROOT/statefuzz}"

WORK_BASE="${WORK_BASE:-$HOME/statefuzz-4.19}"
KERNEL_TAG="${KERNEL_TAG:-v4.19}"
KERNEL_SRC="${KERNEL_SRC:-$WORK_BASE/kernel/linux-4.19}"
KERNEL_OBJ="${KERNEL_OBJ:-$WORK_BASE/kernel/linux-out-4.19}"
IMAGE_DIR="${IMAGE_DIR:-$WORK_BASE/image}"
IMAGE_DISTRO="${IMAGE_DISTRO:-stretch}"
IMAGE_FILE="${IMAGE_FILE:-$IMAGE_DIR/${IMAGE_DISTRO}.img}"
SSH_KEY="${SSH_KEY:-$IMAGE_DIR/${IMAGE_DISTRO}.id_rsa}"
STATE_MODEL_DIR="${STATE_MODEL_DIR:-$WORK_BASE/statemodel}"
SV_RANGE_JSON="${SV_RANGE_JSON:-$STATE_MODEL_DIR/sv_range.json}"
SV_PAIRS_JSON="${SV_PAIRS_JSON:-$STATE_MODEL_DIR/sv_pairs.json}"
WORKDIR="${WORKDIR:-$WORK_BASE/workdir}"
MANAGER_CFG="${MANAGER_CFG:-$STATEFUZZ_DIR/my-4.19.cfg}"
KERNEL_BUILD_LOG="${KERNEL_BUILD_LOG:-$WORK_BASE/kernel/build-kernel-4.19.log}"

VM_COUNT="${VM_COUNT:-2}"
VM_CPU="${VM_CPU:-2}"
VM_MEM="${VM_MEM:-2048}"
PROCS="${PROCS:-2}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:56741}"
JOBS="${JOBS:-$(nproc)}"
CC_BIN="${CC_BIN:-gcc}"
GO_BOOTSTRAP_VERSION="${GO_BOOTSTRAP_VERSION:-1.20.14}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-0}"
RUN_MANAGER="${RUN_MANAGER:-0}"
# Building old kernels (e.g. 4.19) on modern distros can fail in
# scripts/selinux/genheaders with:
#   "New address family defined, please update secclass_map."
# Keep SELinux off by default to avoid that host-header mismatch.
DISABLE_SELINUX="${DISABLE_SELINUX:-1}"

install_deps_if_needed

require_cmd git
require_cmd make
require_cmd "$CC_BIN"
require_cmd qemu-system-x86_64
require_cmd debootstrap
require_cmd ssh-keygen
require_cmd sudo
require_cmd wget
check_go_version

[[ -d "$STATEFUZZ_DIR" ]] || die "StateFuzz source not found: $STATEFUZZ_DIR"

mkdir -p "$WORK_BASE" "$WORKDIR" "$STATE_MODEL_DIR" "$IMAGE_DIR" "$KERNEL_OBJ"

log "Preparing Linux source ($KERNEL_TAG)..."
if [[ ! -d "$KERNEL_SRC/.git" ]]; then
	git clone --depth=1 --branch "$KERNEL_TAG" https://github.com/torvalds/linux.git "$KERNEL_SRC"
else
	log "Reusing existing kernel tree: $KERNEL_SRC"
fi

log "Building StateFuzz binaries..."
(
	cd "$STATEFUZZ_DIR"
	make HOSTOS=linux HOSTARCH=amd64 TARGETOS=linux TARGETARCH=amd64 SOURCEDIR="$KERNEL_SRC"
)

log "Configuring kernel for fuzzing..."
make -C "$KERNEL_SRC" O="$KERNEL_OBJ" CC="$CC_BIN" defconfig
if ! make -C "$KERNEL_SRC" O="$KERNEL_OBJ" CC="$CC_BIN" kvmconfig; then
	log "kvmconfig not available, continuing with defconfig"
fi

if [[ -x "$KERNEL_SRC/scripts/config" || -f "$KERNEL_SRC/scripts/config" ]]; then
	chmod +x "$KERNEL_SRC/scripts/config"
	config_args=(
		--file "$KERNEL_OBJ/.config"
		-e KCOV \
		-e KCOV_INSTRUMENT_ALL \
		-e KCOV_ENABLE_COMPARISONS \
		-e DEBUG_FS \
		-e DEBUG_INFO \
		-e KALLSYMS \
		-e KALLSYMS_ALL \
		-e CONFIGFS_FS \
		-e SECURITYFS \
		-e NAMESPACES \
		-e UTS_NS \
		-e IPC_NS \
		-e PID_NS \
		-e NET_NS \
		-e USER_NS \
		-e CGROUP_PIDS \
		-e MEMCG \
		-e KASAN \
		-e KASAN_INLINE \
		-d RANDOMIZE_BASE
	)
	if [[ "$DISABLE_SELINUX" == "1" ]]; then
		config_args+=( -d SECURITY_SELINUX )
	fi
	"$KERNEL_SRC/scripts/config" "${config_args[@]}"
fi

make -C "$KERNEL_SRC" O="$KERNEL_OBJ" CC="$CC_BIN" olddefconfig

log "Building Linux kernel $KERNEL_TAG (this can take a while)..."
if ! make -C "$KERNEL_SRC" O="$KERNEL_OBJ" CC="$CC_BIN" -j"$JOBS" bzImage vmlinux 2>&1 | tee "$KERNEL_BUILD_LOG"; then
	log "Kernel build failed. Inspecting first compiler error..."
	err_line="$(grep -n "error:" "$KERNEL_BUILD_LOG" | head -n1 | cut -d: -f1 || true)"
	if [[ -n "${err_line}" ]]; then
		start_line=1
		if (( err_line > 35 )); then
			start_line=$((err_line - 35))
		fi
		end_line=$((err_line + 35))
		echo "----- kernel build error context -----" >&2
		sed -n "${start_line},${end_line}p" "$KERNEL_BUILD_LOG" >&2
		echo "--------------------------------------" >&2
	else
		log "No 'error:' token found; showing last 120 log lines."
		tail -n 120 "$KERNEL_BUILD_LOG" >&2
	fi
	die "Kernel build failed. Full log: $KERNEL_BUILD_LOG"
fi

if [[ ! -f "$IMAGE_FILE" || ! -f "$SSH_KEY" ]]; then
	log "Creating VM image ($IMAGE_DISTRO)..."
	(
		cd "$IMAGE_DIR"
		bash "$STATEFUZZ_DIR/tools/create-image.sh" -d "$IMAGE_DISTRO"
	)
else
	log "Reusing VM image: $IMAGE_FILE"
fi

chmod 600 "$SSH_KEY"

if [[ ! -f "$SV_RANGE_JSON" ]]; then
	printf '[]\n' >"$SV_RANGE_JSON"
fi
if [[ ! -f "$SV_PAIRS_JSON" ]]; then
	printf '[]\n' >"$SV_PAIRS_JSON"
fi

log "Writing manager config: $MANAGER_CFG"
cat >"$MANAGER_CFG" <<EOF
{
  "name": "statefuzz-kernel4.19",
  "target": "linux/amd64",
  "http": "$HTTP_ADDR",
  "workdir": "$WORKDIR",
  "kernel_src": "$KERNEL_SRC",
  "kernel_obj": "$KERNEL_OBJ",
  "image": "$IMAGE_FILE",
  "sshkey": "$SSH_KEY",
  "syzkaller": "$STATEFUZZ_DIR",
  "sv_range.json": "$SV_RANGE_JSON",
  "sv_pairs.json": "$SV_PAIRS_JSON",
  "procs": $PROCS,
  "reproduce": false,
  "type": "qemu",
  "vm": {
    "count": $VM_COUNT,
    "kernel": "$KERNEL_OBJ/arch/x86/boot/bzImage",
    "cpu": $VM_CPU,
    "mem": $VM_MEM
  }
}
EOF

if [[ ! -r /dev/kvm ]]; then
	log "Warning: /dev/kvm is not accessible. QEMU can be very slow or fail."
fi

if [[ "$RUN_MANAGER" == "1" ]]; then
	log "Starting syz-manager..."
	cd "$STATEFUZZ_DIR"
	exec ./bin/syz-manager -config "$MANAGER_CFG"
fi

cat <<EOF
[howto] Done.
[howto] To start fuzzing:
  cd "$STATEFUZZ_DIR"
  ./bin/syz-manager -config "$MANAGER_CFG"
EOF
