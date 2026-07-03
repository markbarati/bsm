#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/lib/common.sh"

CONFIG="${1:-/etc/bsm-engine/config.env}"
[[ -f "$CONFIG" ]] || die "Config not found: $CONFIG"
source "$CONFIG"
[[ -f /etc/bsm-engine/secrets.env ]] && source /etc/bsm-engine/secrets.env

banner
printf '%s\n' "Verification report — $(date)"
printf '%s\n\n' "Config: $CONFIG"

failures=0
checks=0
check() {
  local label="$1"; shift
  checks=$((checks+1))
  printf '%-52s' "$label"
  if "$@" >/dev/null 2>&1; then
    printf ' %sPASS%s\n' "$C_GREEN" "$C_RESET"
  else
    printf ' %sFAIL%s\n' "$C_RED" "$C_RESET"
    failures=$((failures+1))
  fi
}

check "Ubuntu 24.04" bash -c '. /etc/os-release; [[ "$VERSION_ID" == "24.04" ]]'
check "Supported architecture" bash -c 'a="$(dpkg --print-architecture)"; [[ "$a" == "arm64" || "$a" == "amd64" ]]'
check "Docker service" systemctl is-active --quiet docker
check "Docker Compose plugin" docker compose version

if [[ -x /usr/local/hestia/bin/v-list-sys-services ]]; then
  check "Hestia service" systemctl is-active --quiet hestia
  check "Nginx service" systemctl is-active --quiet nginx
  check "MariaDB service" systemctl is-active --quiet mariadb
fi

if is_yes "${INSTALL_CLOUDFLARED:-no}" && systemctl list-unit-files cloudflared.service >/dev/null 2>&1; then
  check "Cloudflared service" systemctl is-active --quiet cloudflared
fi

[[ ! -f /opt/stacks/portainer/compose.yaml ]] || \
  check "Portainer compose syntax" docker compose -f /opt/stacks/portainer/compose.yaml config -q
[[ ! -f /opt/stacks/apps/compose.yaml ]] || \
  check "Apps compose syntax" docker compose -f /opt/stacks/apps/compose.yaml config -q

printf '\n%sContainer status%s\n' "$C_BOLD" "$C_RESET"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

printf '\n%sExposure audit%s\n' "$C_BOLD" "$C_RESET"
bad=0
while IFS='|' read -r name ports; do
  [[ -n "$name" ]] || continue
  if [[ "$name" == "rdesktop" && "${RDP_EXPOSURE:-cloudflare}" == "public" ]]; then
    continue
  fi
  if grep -Eq '(^|, )0\.0\.0\.0:|\[::\]:' <<<"$ports"; then
    printf '%sWARN%s %-20s %s\n' "$C_YELLOW" "$C_RESET" "$name" "$ports"
    bad=$((bad+1))
  else
    printf '%sOK%s   %-20s %s\n' "$C_GREEN" "$C_RESET" "$name" "$ports"
  fi
done < <(docker ps --format '{{.Names}}|{{.Ports}}')

((bad==0)) || warn "$bad container(s) expose a public host port."
printf '\nChecked: %d | Failures: %d\n' "$checks" "$failures"
((failures==0)) || exit 1
