#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/lib/common.sh"
init_runtime

CONFIG="/etc/bsm-engine/config.env"
[[ -f "$CONFIG" ]] || die "Missing $CONFIG"
source "$CONFIG"
require_cmd rclone; require_cmd age; require_cmd zstd

KEY="$BSM_ENGINE_ETC/age/backup.key"
[[ -f "$KEY" ]] || die "Missing age private key: $KEY"

REMOTE="${RCLONE_REMOTE}:${BACKUP_REMOTE_PATH}"
LATEST="$(rclone lsf "$REMOTE" --files-only --include 'bsm-*.tar.zst.age' | sort | tail -n1)"
[[ -n "$LATEST" ]] || die "No matching backup found."

TEST_ROOT="/var/tmp/bsm-engine-restore-test"
rm -rf "$TEST_ROOT"; mkdir -p "$TEST_ROOT"
ENC="$TEST_ROOT/$LATEST"
PLAIN="$TEST_ROOT/restore.tar.zst"

run_step "Download latest backup" rclone copyto "$REMOTE/$LATEST" "$ENC" --transfers 1 --checkers 1
run_step "Decrypt backup" age -d -i "$KEY" -o "$PLAIN" "$ENC"
run_step "List archive" bash -c "zstd -dc '$PLAIN' | tar -tf - | head -n 80"
ok "Restore test succeeded. Temporary files: $TEST_ROOT"
warn "This script does not overwrite the live server."
