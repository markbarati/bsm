#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/lib/common.sh"
init_runtime

for compose in /opt/stacks/portainer/compose.yaml /opt/stacks/apps/compose.yaml; do
  [[ -f "$compose" ]] || continue
  backup_file "$compose"
  run_step "Validate $(dirname "$compose")" docker compose -f "$compose" config -q
  run_step "Pull images $(dirname "$compose")" docker compose -f "$compose" pull
  run_step "Recreate stack $(dirname "$compose")" docker compose -f "$compose" up -d
done
docker image prune -f >>"$LOG_FILE" 2>&1 || true
ok "Update complete. Log: $LOG_FILE"
warn "The LinuxServer rdesktop image is deprecated; review it manually before upgrades."
