#!/usr/bin/env bash
set -euo pipefail

usage() {
cat <<'USAGE'
Usage:
  ./run_12h_hfl.sh

Environment variables:
  (Equivalent runtime of: ./run_syzkaller.sh, ./run_s2e.sh, ./run_agent.sh)
  SESSION=hfl12h                           tmux session name
  DURATION=12h                             Run duration (timeout format)
  HFL_DIR=./hfl                            HFL checkout path
  HFL_SCRIPTS=$HFL_DIR/scripts             HFL scripts path
  CONFIG_FILE=$HFL_SCRIPTS/sample.cfg      syz-manager config
  LOG_DIR=$HOME/hfl-run/logs               log output directory
  ENABLE_SYZ=1                             run syz-manager
  ENABLE_S2E=1                             run s2e.py
  ENABLE_AGENT=1                           run agent.py
  CLEAN_RUNTIME=1                          clean scripts/workdir,tmp/*.log before run

Examples:
  ./run_12h_hfl.sh
  SESSION=hfl-exp DURATION=24h ./run_12h_hfl.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

die() {
	echo "[run_12h_hfl][error] $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
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

	die "Python 2 runtime not found (required by hfl/scripts/s2e.py and hfl/scripts/agent.py)"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HFL_DIR="${HFL_DIR:-$SCRIPT_DIR/hfl}"
HFL_SCRIPTS="${HFL_SCRIPTS:-$HFL_DIR/scripts}"
CONFIG_FILE="${CONFIG_FILE:-$HFL_SCRIPTS/sample.cfg}"
SESSION="${SESSION:-hfl12h}"
DURATION="${DURATION:-12h}"
LOG_DIR="${LOG_DIR:-$HOME/hfl-run/logs}"
ENABLE_SYZ="${ENABLE_SYZ:-1}"
ENABLE_S2E="${ENABLE_S2E:-1}"
ENABLE_AGENT="${ENABLE_AGENT:-1}"
CLEAN_RUNTIME="${CLEAN_RUNTIME:-1}"

require_cmd tmux
require_cmd timeout
require_cmd stdbuf
require_cmd tee

[[ -d "$HFL_DIR" ]] || die "HFL_DIR not found: $HFL_DIR"
[[ -d "$HFL_SCRIPTS" ]] || die "HFL_SCRIPTS not found: $HFL_SCRIPTS"
[[ -f "$HFL_SCRIPTS/common.sh" ]] || die "common.sh not found: $HFL_SCRIPTS/common.sh"
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

PY2="$(detect_py2)"

if tmux has-session -t "$SESSION" 2>/dev/null; then
	die "tmux session '$SESSION' already exists"
fi

mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
ROOT_LOG="$LOG_DIR/hfl-run-${TS}.log"
SYZ_LOG="$LOG_DIR/hfl-syz-${TS}.log"
S2E_LOG="$LOG_DIR/hfl-s2e-${TS}.log"
AGENT_LOG="$LOG_DIR/hfl-agent-${TS}.log"
META="$LOG_DIR/hfl-last-run.env"
RUNNER="$LOG_DIR/.hfl-runner-${TS}.sh"

cat >"$META" <<EOF
SESSION="$SESSION"
DURATION="$DURATION"
HFL_DIR="$HFL_DIR"
HFL_SCRIPTS="$HFL_SCRIPTS"
CONFIG_FILE="$CONFIG_FILE"
ROOT_LOG="$ROOT_LOG"
SYZ_LOG="$SYZ_LOG"
S2E_LOG="$S2E_LOG"
AGENT_LOG="$AGENT_LOG"
START_TIME="$(date -Is)"
EOF

cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

cd "$HFL_SCRIPTS"
source ./common.sh

cleanup() {
  set +e
  for pid in \${pids:-}; do
    kill "\$pid" >/dev/null 2>&1 || true
  done
  wait >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if [[ "$CLEAN_RUNTIME" == "1" ]]; then
  rm -rf ./workdir/* ./tmp/* vm*.smt2.log >/dev/null 2>&1 || true
fi

mkdir -p ./tmp
cp -f ./sample/opcodes.h ./tmp/
cp -f ./sample/s2e.h ./tmp/

echo "[runner] started at \$(date -Is)" | tee -a "$ROOT_LOG"
echo "[runner] duration=$DURATION" | tee -a "$ROOT_LOG"
echo "[runner] config=$CONFIG_FILE" | tee -a "$ROOT_LOG"
echo "[runner] equivalent commands: ./run_syzkaller.sh ./run_s2e.sh ./run_agent.sh" | tee -a "$ROOT_LOG"
echo "[runner] logs: syz=$SYZ_LOG s2e=$S2E_LOG agent=$AGENT_LOG" | tee -a "$ROOT_LOG"

pids=""

if [[ "$ENABLE_SYZ" == "1" ]]; then
  [[ -x "\$SYZHOME/bin/syz-manager" ]] || { echo "[runner][error] missing \$SYZHOME/bin/syz-manager" | tee -a "$ROOT_LOG"; exit 1; }
  stdbuf -oL -eL timeout -s INT -k 5m "$DURATION" "\$SYZHOME/bin/syz-manager" -config "$CONFIG_FILE" -enable enable_syscalls \
    > >(tee "$SYZ_LOG") 2>&1 &
  pids="\$pids \$!"
fi

if [[ "$ENABLE_S2E" == "1" ]]; then
  stdbuf -oL -eL timeout -s INT -k 5m "$DURATION" "$PY2" ./s2e.py \
    > >(tee "$S2E_LOG") 2>&1 &
  pids="\$pids \$!"
fi

if [[ "$ENABLE_AGENT" == "1" ]]; then
  export S2EHOME="\$S2EHOME"
  Z3_PY_PATH="\$S2EHOME/build/z3-z3-4.6.0/build/python/"
  export PYTHONPATH="\$Z3_PY_PATH"
  export Z3_LIBRARY_PATH="\$Z3_PY_PATH"
  export LD_LIBRARY_PATH="\$Z3_PY_PATH"

  stdbuf -oL -eL timeout -s INT -k 5m "$DURATION" "$PY2" ./agent.py \
    > >(tee "$AGENT_LOG") 2>&1 &
  pids="\$pids \$!"
fi

if [[ -z "\${pids// /}" ]]; then
  echo "[runner][error] all components disabled (ENABLE_SYZ/ENABLE_S2E/ENABLE_AGENT)" | tee -a "$ROOT_LOG"
  exit 1
fi

rc=0
for pid in \$pids; do
  wait "\$pid" || this_rc=\$?
  if [[ "\${this_rc:-0}" -ne 0 && "\${this_rc:-0}" -ne 124 ]]; then
    rc="\${this_rc:-1}"
  fi
  unset this_rc
done

if [[ "\$rc" -eq 0 ]]; then
  echo "[runner] finished at \$(date -Is)" | tee -a "$ROOT_LOG"
else
  echo "[runner] failed with code \$rc at \$(date -Is)" | tee -a "$ROOT_LOG"
fi

exit "\$rc"
EOF

chmod +x "$RUNNER"
tmux new-session -d -s "$SESSION" "bash '$RUNNER'"

cat <<EOF
[run_12h_hfl] Started.
[run_12h_hfl] Session   : $SESSION
[run_12h_hfl] Root log  : $ROOT_LOG
[run_12h_hfl] Syz log   : $SYZ_LOG
[run_12h_hfl] S2E log   : $S2E_LOG
[run_12h_hfl] Agent log : $AGENT_LOG

Useful commands:
  tmux attach -t $SESSION
  tmux kill-session -t $SESSION
  tail -f "$ROOT_LOG"
  tail -f "$SYZ_LOG"
  tail -f "$S2E_LOG"
  tail -f "$AGENT_LOG"
EOF
