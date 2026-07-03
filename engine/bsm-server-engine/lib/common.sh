#!/usr/bin/env bash
set -Eeuo pipefail

BSM_ENGINE_VERSION="2.0.0"
BSM_ENGINE_ETC="/etc/bsm-engine"
BSM_ENGINE_STATE="/var/lib/bsm-engine"
BSM_ENGINE_LOG_DIR="/var/log/bsm-engine"
BSM_ENGINE_BACKUP_DIR="/var/backups/bsm-engine"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
else
  C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_CYAN=""
fi

LOG_FILE=""

init_runtime() {
  mkdir -p "$BSM_ENGINE_ETC" "$BSM_ENGINE_STATE" "$BSM_ENGINE_LOG_DIR" "$BSM_ENGINE_BACKUP_DIR"
  chmod 700 "$BSM_ENGINE_ETC"
  local stamp="$(date +%Y%m%d-%H%M%S)"
  LOG_FILE="$BSM_ENGINE_LOG_DIR/install-$stamp.log"
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
}

banner() {
  printf '\n%s%s╔══════════════════════════════════════════════════════╗%s\n' "$C_BLUE" "$C_BOLD" "$C_RESET"
  printf '%s%s║          BSM Server Engine — ARM64 Installer          ║%s\n' "$C_BLUE" "$C_BOLD" "$C_RESET"
  printf '%s%s╚══════════════════════════════════════════════════════╝%s\n\n' "$C_BLUE" "$C_BOLD" "$C_RESET"
}
info(){ printf '%sℹ%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok(){ printf '%s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn(){ printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die(){ printf '%s✘%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
log(){ [[ -n "$LOG_FILE" ]] && printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" || true; }


bsm_ledger_step() {
  local label="$1" command="$2" exit_code="$3" duration_ms="$4"
  local ledger_dir="/var/log/bsm"
  [[ -d "$ledger_dir" ]] || return 0
  # Conservative redaction: never record obvious secret-bearing assignments/flags.
  command="$(printf '%s' "$command" | sed -E 's/((password|passwd|token|secret|api[_-]?key)(=|[[:space:]]+))[^[:space:]]+/\1[REDACTED]/Ig')"
  BSM_LABEL="$label" BSM_COMMAND="$command" BSM_EXIT="$exit_code" BSM_DURATION="$duration_ms" \
  BSM_ACTOR="${BSM_ACTOR:-bsm-engine}" BSM_JOB="${BSM_JOB_ID:-}" python3 - <<'PYLEDGER' >>"$ledger_dir/command-ledger.jsonl" 2>/dev/null || true
import json, os, datetime
print(json.dumps({
  "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "actor": os.environ.get("BSM_ACTOR","bsm-engine"),
  "source": "bsm-engine-run-step",
  "job_id": os.environ.get("BSM_JOB",""),
  "argv": ["RUN_STEP", os.environ.get("BSM_LABEL","") , os.environ.get("BSM_COMMAND","")],
  "cwd": os.getcwd(),
  "exit_code": int(os.environ.get("BSM_EXIT","0")),
  "duration_ms": int(os.environ.get("BSM_DURATION","0")),
}, ensure_ascii=False))
PYLEDGER
  {
    printf '\n# %s actor=%s job=%s label=%s\n' "$(date -Is)" "${BSM_ACTOR:-bsm-engine}" "${BSM_JOB_ID:-}" "$label"
    printf '%s\n' "$command"
    printf '# exit=%s duration_ms=%s\n' "$exit_code" "$duration_ms"
  } >>"$ledger_dir/command-ledger.sh" 2>/dev/null || true
}

run_step() {
  local label="$1"; shift
  local tmp="$(mktemp)" rc start_ms end_ms duration_ms command_text
  command_text="$(printf '%q ' "$@")"
  start_ms="$(date +%s%3N)"
  printf '%-50s' "$label"; log "STEP: $label"; log "CMD: $*"
  set +e; "$@" >"$tmp" 2>&1; rc=$?; set -e
  end_ms="$(date +%s%3N)"; duration_ms=$((end_ms-start_ms))
  bsm_ledger_step "$label" "$command_text" "$rc" "$duration_ms"
  cat "$tmp" >>"$LOG_FILE"
  if ((rc==0)); then printf ' %sPASS%s\n' "$C_GREEN" "$C_RESET"; rm -f "$tmp"; return 0; fi
  printf ' %sFAIL%s\n' "$C_RED" "$C_RESET"
  printf '\n%sآخرین خطوط خطا:%s\n' "$C_RED" "$C_RESET" >&2
  tail -n 18 "$tmp" >&2 || true
  printf '\nLog: %s\n' "$LOG_FILE" >&2
  rm -f "$tmp"; return "$rc"
}

backup_file() {
  local src="$1"; [[ -e "$src" ]] || return 0
  local stamp dst
  stamp="$(date +%Y%m%d-%H%M%S)"
  dst="$BSM_ENGINE_BACKUP_DIR/$stamp$src"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  log "Backed up $src to $dst"
}
is_yes(){ case "${1:-}" in yes|YES|true|TRUE|1|on|ON) return 0;; *) return 1;; esac; }
selected(){ [[ " ${APPS:-} " == *" $1 "* ]]; }
random_hex(){ openssl rand -hex "${1:-16}"; }
require_root(){ if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then exec sudo -E bash "$PROJECT_DIR/install.sh" "$@"; fi; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
safe_owner_ids(){ if id "$APP_OWNER" >/dev/null 2>&1; then PUID="$(id -u "$APP_OWNER")"; PGID="$(id -g "$APP_OWNER")"; fi; }
write_shell_kv(){ printf '%s=%q\n' "$2" "$3" >>"$1"; }
