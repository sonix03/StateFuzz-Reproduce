#!/usr/bin/env bash
set -euo pipefail

usage() {
cat <<'USAGE'
Usage:
  ./run_12h_tmux.sh

Environment variables:
  SESSION=statefuzz12h                    tmux session name
  DURATION=12h                            run duration (timeout format)
  STATEFUZZ_DIR=./statefuzz               path to statefuzz checkout
  CFG=$STATEFUZZ_DIR/my-4.19.cfg          syz-manager config path
  LOG_DIR=$HOME/statefuzz-4.19/workdir/logs

Examples:
  ./run_12h_tmux.sh
  SESSION=sf-12h DURATION=12h ./run_12h_tmux.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

die() {
	echo "[run_12h_tmux][error] $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATEFUZZ_DIR="${STATEFUZZ_DIR:-$SCRIPT_DIR/statefuzz}"
CFG="${CFG:-$STATEFUZZ_DIR/my-4.19.cfg}"
SESSION="${SESSION:-statefuzz12h}"
DURATION="${DURATION:-12h}"
LOG_DIR="${LOG_DIR:-$HOME/statefuzz-4.19/workdir/logs}"

require_cmd tmux
require_cmd timeout
require_cmd stdbuf
require_cmd awk

[[ -d "$STATEFUZZ_DIR" ]] || die "STATEFUZZ_DIR not found: $STATEFUZZ_DIR"
[[ -f "$CFG" ]] || die "Config file not found: $CFG"
[[ -x "$STATEFUZZ_DIR/bin/syz-manager" ]] || die "syz-manager not found/executable: $STATEFUZZ_DIR/bin/syz-manager"

if tmux has-session -t "$SESSION" 2>/dev/null; then
	die "tmux session '$SESSION' already exists. Use: tmux attach -t $SESSION"
fi

mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="$LOG_DIR/statefuzz-run-${TS}.log"
COVERAGE_LOG="$LOG_DIR/statefuzz-coverage-${TS}.log"
HOURLY_DIR="$LOG_DIR/statefuzz-hourly-${TS}"
HOURLY_SUMMARY="$LOG_DIR/statefuzz-hourly-summary-${TS}.log"
META="$LOG_DIR/statefuzz-last-run.env"
RUNNER="$LOG_DIR/.statefuzz-runner-${TS}.sh"

cat >"$META" <<EOF
SESSION="$SESSION"
DURATION="$DURATION"
STATEFUZZ_DIR="$STATEFUZZ_DIR"
CFG="$CFG"
RUN_LOG="$RUN_LOG"
COVERAGE_LOG="$COVERAGE_LOG"
HOURLY_DIR="$HOURLY_DIR"
HOURLY_SUMMARY="$HOURLY_SUMMARY"
START_TIME="$(date -Is)"
EOF

cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$STATEFUZZ_DIR"
mkdir -p "$HOURLY_DIR"
start_epoch=\$(date +%s)
echo "[runner] started at \$(date -Is)"
echo "[runner] cfg: $CFG"
echo "[runner] duration: $DURATION"
echo "[runner] run log: $RUN_LOG"
echo "[runner] coverage log: $COVERAGE_LOG"
echo "[runner] hourly dir: $HOURLY_DIR"
echo "[runner] hourly summary: $HOURLY_SUMMARY"
set +e
stdbuf -oL -eL timeout -s INT -k 5m "$DURATION" ./bin/syz-manager -config "$CFG" 2>&1 \
  | tee "$RUN_LOG" \
  | stdbuf -oL awk -v cov="$COVERAGE_LOG" -v hourly_dir="$HOURLY_DIR" -v start="\$start_epoch" '
      /syzkaller-VMs/ {
        now = systime();
        elapsed = now - start;
        hour_idx = int(elapsed / 3600) + 1;
        ts = strftime("%F %T");
        line = ts " " \$0;
        print line >> cov;
        hour_file = sprintf("%s/hour-%02d.log", hourly_dir, hour_idx);
        print line >> hour_file;
        fflush(cov);
        fflush(hour_file);
      }
    '
rc=\${PIPESTATUS[0]}
set -e

{
  echo "# statefuzz hourly summary"
  echo "# generated_at=\$(date -Is)"
  echo "# source_coverage_log=$COVERAGE_LOG"
  if compgen -G "$HOURLY_DIR/hour-*.log" >/dev/null; then
    for f in "$HOURLY_DIR"/hour-*.log; do
      if [[ ! -s "\$f" ]]; then
        continue
      fi
      h=\$(basename "\$f" .log)
      last_line=\$(tail -n 1 "\$f")
      echo "\$h: \${last_line}"
    done
  else
    echo "no coverage lines captured"
  fi
} > "$HOURLY_SUMMARY"

if [[ "\$rc" -eq 124 ]]; then
  echo "[runner] finished by timeout (\$DURATION) at \$(date -Is)"
  exit 0
fi
echo "[runner] exited with code \$rc at \$(date -Is)"
exit "\$rc"
EOF
chmod +x "$RUNNER"

tmux new-session -d -s "$SESSION" "bash '$RUNNER'"

cat <<EOF
[run_12h_tmux] Started.
[run_12h_tmux] Session      : $SESSION
[run_12h_tmux] Run log      : $RUN_LOG
[run_12h_tmux] Coverage log : $COVERAGE_LOG
[run_12h_tmux] Hourly dir   : $HOURLY_DIR
[run_12h_tmux] Hourly sum   : $HOURLY_SUMMARY

Useful commands:
  tmux attach -t $SESSION
  tmux detach
  tmux kill-session -t $SESSION
  tail -f "$COVERAGE_LOG"
  ls -1 "$HOURLY_DIR"
  cat "$HOURLY_SUMMARY"
EOF
