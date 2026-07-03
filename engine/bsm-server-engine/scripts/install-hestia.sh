#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/lib/common.sh"
init_runtime

: "${HESTIA_HOSTNAME:=cp.example.com}"
: "${HESTIA_USER:=hadmin}"
: "${HESTIA_EMAIL:=}"
: "${HESTIA_PASSWORD:=}"

if [[ -x /usr/local/hestia/bin/v-list-sys-services ]]; then
  ok "Hestia is already installed; no changes made."; exit 0
fi
[[ -n "$HESTIA_EMAIL" ]] || die "HESTIA_EMAIL is required."
[[ -n "$HESTIA_PASSWORD" ]] || HESTIA_PASSWORD="$(random_hex 16)"
if getent passwd "$HESTIA_USER" >/dev/null || getent group "$HESTIA_USER" >/dev/null; then
  die "Hestia username/group '$HESTIA_USER' already exists. Choose another."
fi
. /etc/os-release
[[ "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 required."
[[ "$(dpkg --print-architecture)" == "arm64" ]] || die "arm64 required."

cd /root
curl -fsSLo hst-install.sh https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh
chmod 700 hst-install.sh
bash ./hst-install.sh \
  --interactive no --hostname "$HESTIA_HOSTNAME" --email "$HESTIA_EMAIL" \
  --username "$HESTIA_USER" --password "$HESTIA_PASSWORD" --port 8083 --lang en \
  --apache yes --phpfpm yes --multiphp '8.2,8.3,8.4' \
  --vsftpd no --proftpd no --named no --mysql yes --mysql8 no --postgresql no \
  --exim no --dovecot no --sieve no --clamav no --spamassassin no \
  --iptables yes --fail2ban yes --quota no --webterminal no --api no
ok "Hestia installation command completed."
warn "Reboot, then rerun the main installer."
