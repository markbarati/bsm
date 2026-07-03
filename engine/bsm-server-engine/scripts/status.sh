#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/lib/common.sh"

banner
printf '%sHost%s\n' "$C_BOLD" "$C_RESET"
printf '  %-20s %s\n' "Hostname:" "$(hostname -f 2>/dev/null || hostname)"
printf '  %-20s %s\n' "OS:" "$(. /etc/os-release; echo "$PRETTY_NAME")"
printf '  %-20s %s\n' "Architecture:" "$(dpkg --print-architecture)"
printf '  %-20s %s\n' "Uptime:" "$(uptime -p)"
printf '  %-20s %s\n' "Load:" "$(cut -d' ' -f1-3 /proc/loadavg)"
printf '  %-20s %s\n' "Memory:" "$(free -h | awk '/Mem:/{print $3 " / " $2}')"
printf '  %-20s %s\n' "Root disk:" "$(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"

printf '\n%sCore services%s\n' "$C_BOLD" "$C_RESET"
for svc in hestia nginx apache2 mariadb docker cloudflared fail2ban; do
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$svc"; then
      printf '  %s●%s %-18s active\n' "$C_GREEN" "$C_RESET" "$svc"
    else
      printf '  %s●%s %-18s inactive/failed\n' "$C_RED" "$C_RESET" "$svc"
    fi
  fi
done

printf '\n%sDocker containers%s\n' "$C_BOLD" "$C_RESET"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || warn "Docker is unavailable."

printf '\n%sRecent BSM logs%s\n' "$C_BOLD" "$C_RESET"
ls -1t "$BSM_ENGINE_LOG_DIR"/*.log 2>/dev/null | head -n 5 || echo "  No logs yet."

printf '\n%sUseful paths%s\n' "$C_BOLD" "$C_RESET"
printf '  Config:      %s\n' "$BSM_ENGINE_ETC/config.env"
printf '  Secrets:     %s\n' "$BSM_ENGINE_ETC/secrets.env"
printf '  CF routes:   %s\n' "$BSM_ENGINE_ETC/cloudflare-routes.md"
printf '  Compose:     %s\n' "/opt/stacks/apps/compose.yaml"
