#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/lib/common.sh"
init_runtime

CONFIG="/etc/bsm-engine/config.env"
[[ -f "$CONFIG" ]] || die "Missing $CONFIG"
source "$CONFIG"
is_yes "${BACKUP_ENABLE:-no}" || die "BACKUP_ENABLE is not yes."
require_cmd rclone; require_cmd age; require_cmd zstd; require_cmd jq

REMOTE="${RCLONE_REMOTE}:${BACKUP_REMOTE_PATH}"
WORK="$BSM_ENGINE_BACKUP_DIR/work"
STAMP="$(date +%F_%H-%M-%S)"
PLAIN="$WORK/bsm-$STAMP.tar.zst"
ENC="$PLAIN.age"
KEY_DIR="$BSM_ENGINE_ETC/age"
mkdir -p "$WORK" "$KEY_DIR"; chmod 700 "$KEY_DIR"

if [[ ! -f "$KEY_DIR/backup.key" ]]; then
  age-keygen -o "$KEY_DIR/backup.key" >>"$LOG_FILE" 2>&1
  age-keygen -y "$KEY_DIR/backup.key" >"$KEY_DIR/backup.pub"
  chmod 600 "$KEY_DIR/backup.key"; chmod 644 "$KEY_DIR/backup.pub"
  warn "New backup private key: $KEY_DIR/backup.key"
  warn "Copy it off this server before relying on backups."
fi

rclone lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1 || die "rclone remote is not reachable."
if [[ -x /usr/local/hestia/bin/v-backup-users ]]; then
  run_step "Create Hestia user backups" /usr/local/hestia/bin/v-backup-users
fi

stateful=(gitea vaultwarden uptime-kuma beszel filebrowser)
running=()
for c in "${stateful[@]}"; do
  [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" == "true" ]] && running+=("$c")
done
resume(){ ((${#running[@]})) && docker start "${running[@]}" >/dev/null 2>&1 || true; }
trap resume EXIT
((${#running[@]})) && docker stop "${running[@]}" >>"$LOG_FILE" 2>&1 || true
sync

paths=()
for p in backup opt/stacks opt/appdata srv/personal-files etc/bsm-engine etc/docker/daemon.json; do
  [[ -e "/$p" ]] && paths+=("$p")
done

tar --acls --xattrs --numeric-owner --exclude='etc/bsm-engine/age/backup.key' -C / -cf - "${paths[@]}" \
  | zstd -T1 -6 -o "$PLAIN" >>"$LOG_FILE" 2>&1
RECIPIENT="$(tr -d '\r\n' <"$KEY_DIR/backup.pub")"
age -r "$RECIPIENT" -o "$ENC" "$PLAIN" >>"$LOG_FILE" 2>&1
rm -f "$PLAIN"
resume; trap - EXIT

rclone copyto "$ENC" "$REMOTE/$(basename "$ENC")" \
  --transfers 1 --checkers 1 --retries 8 --low-level-retries 20 >>"$LOG_FILE" 2>&1

local_size="$(stat -c '%s' "$ENC")"
remote_size="$(rclone size "$REMOTE" --include "$(basename "$ENC")" --json \
  --checkers 1 | jq -r '.bytes')"
[[ "$local_size" == "$remote_size" ]] || die "Remote size verification failed."
rm -f "$ENC"

rclone delete "$REMOTE" --min-age "${BACKUP_RETENTION_DAYS}d" \
  --include 'bsm-*.tar.zst.age' --transfers 1 --checkers 1 >>"$LOG_FILE" 2>&1 || true
ok "Encrypted backup uploaded and size-verified."
