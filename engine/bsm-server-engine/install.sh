#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_DIR/lib/common.sh"

ORIGINAL_ARGS=("$@")
CONFIG_ARG=""
NON_INTERACTIVE="no"
VERIFY_ONLY="no"

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh
  sudo ./install.sh --config ./config.env --non-interactive
  sudo ./install.sh --verify
Options:
  --config PATH       Load settings from a trusted shell environment file
  --non-interactive   Do not show the package-selection menu
  --verify            Run verification only
  --help              Show this help
EOF
}

while (($#)); do
  case "$1" in
    --config) CONFIG_ARG="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE="yes"; shift ;;
    --verify) VERIFY_ONLY="yes"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root "${ORIGINAL_ARGS[@]}"
init_runtime
banner

if [[ "$VERIFY_ONLY" == "yes" ]]; then
  exec "$PROJECT_DIR/scripts/verify.sh" "${CONFIG_ARG:-/etc/bsm-engine/config.env}"
fi

DOMAIN="example.com"
SERVER_LABEL="server"
PUBLIC_IP=""
TIMEZONE="UTC"
APP_OWNER="ubuntu"
PUID="1000"
PGID="1000"
INSTALL_HESTIA="no"
HESTIA_HOSTNAME="cp.example.com"
HESTIA_USER="hadmin"
HESTIA_EMAIL=""
HESTIA_PASSWORD=""
APPS="portainer homepage filebrowser uptime-kuma dozzle beszel gitea vaultwarden it-tools stirling-pdf webtop rdesktop"

PORT_PORTAINER="9443"
PORT_HOMEPAGE="3000"
PORT_UPTIME="3001"
PORT_GITEA="3002"
PORT_FILEBROWSER="18081"
PORT_DOZZLE="8082"
PORT_BESZEL="8090"
PORT_VAULTWARDEN="18084"
PORT_ITTOOLS="8085"
PORT_STIRLING="8086"
PORT_WEBTOP="13003"

INSTALL_CLOUDFLARED="yes"
CF_TUNNEL_TOKEN=""
CF_ACCESS_EMAIL=""

RDP_EXPOSURE="cloudflare"
RDP_LOCAL_PORT="18888"
RDP_PUBLIC_PORT="8888"
RDP_ALLOWED_CIDR=""
RDP_INSTALL_CHROMIUM="yes"
RDESKTOP_IMAGE="lscr.io/linuxserver/rdesktop:ubuntu-xfce-version-80684ffb"
WEBTOP_IMAGE="lscr.io/linuxserver/webtop:ubuntu-xfce"
SKIP_ARCH_CHECK="no"

WEBTOP_USER="admin"
WEBTOP_PASSWORD=""
RDP_PASSWORD=""
VAULTWARDEN_SIGNUPS_ALLOWED="true"
GITEA_REGISTRATION="true"

BACKUP_ENABLE="no"
RCLONE_REMOTE="remote"
BACKUP_REMOTE_PATH="backups/server/full"
BACKUP_HOUR="04:15"
BACKUP_RETENTION_DAYS="14"

CONFIG_SOURCE=""
if [[ -n "$CONFIG_ARG" ]]; then
  CONFIG_SOURCE="$CONFIG_ARG"
elif [[ -f /etc/bsm-engine/config.env ]]; then
  CONFIG_SOURCE="/etc/bsm-engine/config.env"
elif [[ -f "$PROJECT_DIR/config.env" ]]; then
  CONFIG_SOURCE="$PROJECT_DIR/config.env"
fi

if [[ -n "$CONFIG_SOURCE" ]]; then
  info "Loading config: $CONFIG_SOURCE"
  source "$CONFIG_SOURCE"
fi

install_menu_tools() {
  if ! command -v whiptail >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq whiptail >/dev/null
  fi
}

interactive_menu() {
  install_menu_tools
  DOMAIN="$(whiptail --title "BSM Server Engine" --inputbox \
    "Base domain" 10 70 "$DOMAIN" 3>&1 1>&2 2>&3)" || exit 1
  TIMEZONE="$(whiptail --title "BSM Server Engine" --inputbox \
    "Timezone" 10 70 "$TIMEZONE" 3>&1 1>&2 2>&3)" || exit 1

  local choices
  choices="$(whiptail --title "Select services" --checklist \
    "Space selects. Enter confirms." 28 86 18 \
    portainer "Docker management" "$(selected portainer && echo ON || echo OFF)" \
    homepage "Service dashboard" "$(selected homepage && echo ON || echo OFF)" \
    filebrowser "Web file manager" "$(selected filebrowser && echo ON || echo OFF)" \
    uptime-kuma "Uptime monitoring" "$(selected uptime-kuma && echo ON || echo OFF)" \
    dozzle "Docker logs" "$(selected dozzle && echo ON || echo OFF)" \
    beszel "Lightweight monitoring" "$(selected beszel && echo ON || echo OFF)" \
    gitea "Private Git server" "$(selected gitea && echo ON || echo OFF)" \
    vaultwarden "Password manager" "$(selected vaultwarden && echo ON || echo OFF)" \
    it-tools "IT utility tools" "$(selected it-tools && echo ON || echo OFF)" \
    stirling-pdf "PDF tools" "$(selected stirling-pdf && echo ON || echo OFF)" \
    webtop "Browser Ubuntu XFCE desktop" "$(selected webtop && echo ON || echo OFF)" \
    rdesktop "EOL pinned Ubuntu 24.04 XFCE/xrdp (optional)" "$(selected rdesktop && echo ON || echo OFF)" \
    3>&1 1>&2 2>&3)" || exit 1
  APPS="$(tr -d '"' <<<"$choices")"

  if selected rdesktop; then
    RDP_EXPOSURE="$(whiptail --title "RDP exposure" --radiolist \
      "Cloudflare is recommended. Public mode requires port 8888." 16 82 3 \
      cloudflare "No inbound port; client-side cloudflared" "$([[ "$RDP_EXPOSURE" == cloudflare ]] && echo ON || echo OFF)" \
      public "Public 8888; restrict source CIDR" "$([[ "$RDP_EXPOSURE" == public ]] && echo ON || echo OFF)" \
      disabled "Do not run RDP container" "$([[ "$RDP_EXPOSURE" == disabled ]] && echo ON || echo OFF)" \
      3>&1 1>&2 2>&3)" || exit 1
    if [[ "$RDP_EXPOSURE" == "public" ]]; then
      RDP_ALLOWED_CIDR="$(whiptail --title "RDP allowed source" --inputbox \
        "Allowed source CIDR, example 203.0.113.5/32" 10 76 "$RDP_ALLOWED_CIDR" \
        3>&1 1>&2 2>&3)" || exit 1
    fi
  fi
}

if [[ "$NON_INTERACTIVE" != "yes" && -t 0 ]]; then
  interactive_menu
fi

safe_owner_ids
APP_GROUP="$(id -gn "$APP_OWNER" 2>/dev/null || echo "$APP_OWNER")"

. /etc/os-release
[[ "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 required; found ${VERSION_ID:-unknown}."
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "arm64" || "$ARCH" == "amd64" ]] || die "Supported architectures are arm64 and amd64; found $ARCH."

if [[ -x /usr/local/hestia/bin/v-list-sys-services ]]; then
  ok "Existing Hestia detected; it will not be reinstalled."
elif is_yes "$INSTALL_HESTIA"; then
  export HESTIA_HOSTNAME HESTIA_USER HESTIA_EMAIL HESTIA_PASSWORD
  "$PROJECT_DIR/scripts/install-hestia.sh"
  warn "Reboot and rerun this installer."
  exit 0
else
  warn "Hestia is not detected and INSTALL_HESTIA=no."
fi

run_step "Install base utilities" bash -c \
  'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg jq openssl rsync zstd age rclone whiptail'

INSTALL_ROOT="/usr/local/lib/bsm-engine"
install_project_copy() {
  mkdir -p "$INSTALL_ROOT"
  if [[ "$(readlink -f "$PROJECT_DIR")" != "$(readlink -f "$INSTALL_ROOT")" ]]; then
    rsync -a --delete --exclude 'config.env' "$PROJECT_DIR/" "$INSTALL_ROOT/"
  fi
  chmod 755 "$INSTALL_ROOT/install.sh" "$INSTALL_ROOT"/scripts/*.sh "$INSTALL_ROOT/lib/common.sh"
  cat >/usr/local/sbin/bsm-engine <<'EOF'
#!/usr/bin/env bash
exec /usr/local/lib/bsm-engine/install.sh "$@"
EOF
  chmod 755 /usr/local/sbin/bsm-engine
}
run_step "Install BSM Engine management files" install_project_copy

install_docker() {
  if docker compose version >/dev/null 2>&1; then return 0; fi
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}
run_step "Install or verify Docker" install_docker

check_port_owner() {
  local port="$1" expected="$2" line
  line="$(ss -lntp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print; exit}')"
  [[ -z "$line" ]] && return 0
  if docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null       | awk -F'|' -v n="$expected" -v p=":$port->" '$1==n && index($2,p){found=1} END{exit !found}'; then
    return 0
  fi
  die "Host port $port is already used by another process: $line"
}

if [[ ! -f /etc/docker/daemon.json ]]; then
  mkdir -p /etc/docker
  cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  },
  "live-restore": true
}
EOF
  run_step "Restart Docker with log rotation" systemctl restart docker
fi

mkdir -p /opt/stacks/apps /opt/stacks/portainer /opt/appdata /srv/personal-files
chown -R "$APP_OWNER:$APP_GROUP" /opt/stacks
chown root:"$APP_GROUP" /opt/appdata
chmod 750 /opt/stacks /opt/appdata /srv/personal-files

for d in \
  homepage filebrowser/database filebrowser/config uptime-kuma dozzle \
  beszel/data beszel/socket gitea vaultwarden \
  stirling/configs stirling/logs stirling/pipeline stirling/tessdata \
  webtop rdesktop portainer; do
  mkdir -p "/opt/appdata/$d"
done

chown -R "$PUID:$PGID" \
  /opt/appdata/homepage /opt/appdata/filebrowser /opt/appdata/uptime-kuma \
  /opt/appdata/gitea /opt/appdata/stirling /opt/appdata/webtop \
  /opt/appdata/rdesktop /srv/personal-files || true

mkdir -p "$BSM_ENGINE_ETC"
SECRETS="$BSM_ENGINE_ETC/secrets.env"
REQUESTED_WEBTOP_USER="$WEBTOP_USER"
REQUESTED_WEBTOP_PASSWORD="$WEBTOP_PASSWORD"
REQUESTED_RDP_PASSWORD="$RDP_PASSWORD"
if [[ -f "$SECRETS" ]]; then source "$SECRETS"; fi
[[ -n "$REQUESTED_WEBTOP_USER" ]] && WEBTOP_USER="$REQUESTED_WEBTOP_USER"
[[ -n "$REQUESTED_WEBTOP_PASSWORD" ]] && WEBTOP_PASSWORD="$REQUESTED_WEBTOP_PASSWORD"
[[ -n "$REQUESTED_RDP_PASSWORD" ]] && RDP_PASSWORD="$REQUESTED_RDP_PASSWORD"
WEBTOP_PASSWORD="${WEBTOP_PASSWORD:-$(random_hex 16)}"
RDP_PASSWORD="${RDP_PASSWORD:-$(random_hex 16)}"

: >"$SECRETS"
write_shell_kv "$SECRETS" WEBTOP_USER "$WEBTOP_USER"
write_shell_kv "$SECRETS" WEBTOP_PASSWORD "$WEBTOP_PASSWORD"
write_shell_kv "$SECRETS" RDP_PASSWORD "$RDP_PASSWORD"
chmod 600 "$SECRETS"

if [[ "$RDP_PASSWORD" == *$'\n'* || "$RDP_PASSWORD" == *:* ]]; then
  die "RDP_PASSWORD must not contain a newline or colon."
fi

printf '%s' "$WEBTOP_PASSWORD" >"$BSM_ENGINE_ETC/webtop-password"
printf '%s' "$RDP_PASSWORD" >"$BSM_ENGINE_ETC/rdp-password"
chmod 600 "$BSM_ENGINE_ETC/webtop-password" "$BSM_ENGINE_ETC/rdp-password"

mkdir -p /opt/appdata/rdesktop/custom-cont-init.d
cat >/opt/appdata/rdesktop/custom-cont-init.d/10-set-rdp-password <<'EOF'
#!/bin/bash
set -Eeuo pipefail
if [[ -s /run/secrets/rdp_password ]]; then
  password="$(cat /run/secrets/rdp_password)"
  [[ "$password" != *$'\n'* && "$password" != *:* ]] || exit 1
  printf 'abc:%s\n' "$password" | chpasswd
fi
EOF
chown root:root /opt/appdata/rdesktop/custom-cont-init.d/10-set-rdp-password
chmod 755 /opt/appdata/rdesktop/custom-cont-init.d/10-set-rdp-password

FINAL_CONFIG="$BSM_ENGINE_ETC/config.env"
: >"$FINAL_CONFIG"
for key in \
  DOMAIN SERVER_LABEL PUBLIC_IP TIMEZONE APP_OWNER PUID PGID \
  INSTALL_HESTIA HESTIA_HOSTNAME HESTIA_USER HESTIA_EMAIL \
  APPS PORT_PORTAINER PORT_HOMEPAGE PORT_UPTIME PORT_GITEA \
  PORT_FILEBROWSER PORT_DOZZLE PORT_BESZEL PORT_VAULTWARDEN \
  PORT_ITTOOLS PORT_STIRLING PORT_WEBTOP INSTALL_CLOUDFLARED \
  CF_TUNNEL_TOKEN CF_ACCESS_EMAIL RDP_EXPOSURE RDP_LOCAL_PORT \
  RDP_PUBLIC_PORT RDP_ALLOWED_CIDR RDP_INSTALL_CHROMIUM RDESKTOP_IMAGE WEBTOP_IMAGE SKIP_ARCH_CHECK \
  VAULTWARDEN_SIGNUPS_ALLOWED GITEA_REGISTRATION BACKUP_ENABLE \
  RCLONE_REMOTE BACKUP_REMOTE_PATH BACKUP_HOUR BACKUP_RETENTION_DAYS; do
  write_shell_kv "$FINAL_CONFIG" "$key" "${!key}"
done
chmod 600 "$FINAL_CONFIG"

cat >/opt/stacks/apps/.env <<EOF
WEBTOP_USER=$WEBTOP_USER
GITEA_REGISTRATION=$GITEA_REGISTRATION
VAULTWARDEN_SIGNUPS_ALLOWED=$VAULTWARDEN_SIGNUPS_ALLOWED
EOF
chmod 600 /opt/stacks/apps/.env
chown "$APP_OWNER:$APP_GROUP" /opt/stacks/apps/.env

if selected portainer; then
  check_port_owner "$PORT_PORTAINER" portainer
  backup_file /opt/stacks/portainer/compose.yaml
  cat >/opt/stacks/portainer/compose.yaml <<EOF
name: portainer
services:
  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_PORTAINER}:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/appdata/portainer:/data
EOF
  chown "$APP_OWNER:$APP_GROUP" /opt/stacks/portainer/compose.yaml
  run_step "Validate Portainer compose" docker compose -f /opt/stacks/portainer/compose.yaml config -q
  run_step "Deploy Portainer" docker compose -f /opt/stacks/portainer/compose.yaml up -d
fi

selected homepage && check_port_owner "$PORT_HOMEPAGE" homepage
selected filebrowser && check_port_owner "$PORT_FILEBROWSER" filebrowser
selected uptime-kuma && check_port_owner "$PORT_UPTIME" uptime-kuma
selected dozzle && check_port_owner "$PORT_DOZZLE" dozzle
selected beszel && check_port_owner "$PORT_BESZEL" beszel
selected gitea && check_port_owner "$PORT_GITEA" gitea
selected vaultwarden && check_port_owner "$PORT_VAULTWARDEN" vaultwarden
selected it-tools && check_port_owner "$PORT_ITTOOLS" it-tools
selected stirling-pdf && check_port_owner "$PORT_STIRLING" stirling-pdf
selected webtop && check_port_owner "$PORT_WEBTOP" webtop
if selected rdesktop && [[ "$RDP_EXPOSURE" == "public" ]]; then
  check_port_owner "$RDP_PUBLIC_PORT" rdesktop
elif selected rdesktop && [[ "$RDP_EXPOSURE" == "cloudflare" ]]; then
  check_port_owner "$RDP_LOCAL_PORT" rdesktop
fi

# Migrate only the empty failed rootless Gitea attempt. Rootless/rootful data are not compatible.
if selected gitea && [[ -d /opt/appdata/gitea/data || -d /opt/appdata/gitea/config ]]; then
  if find /opt/appdata/gitea/data /opt/appdata/gitea/config -type f -print -quit 2>/dev/null | grep -q .; then
    die "Rootless-style Gitea files exist. Automatic rootless→rootful conversion is unsafe."
  fi
  docker rm -f gitea >/dev/null 2>&1 || true
  rmdir /opt/appdata/gitea/data /opt/appdata/gitea/config 2>/dev/null || true
fi

export DOMAIN TIMEZONE PUID PGID APPS RDP_EXPOSURE RDP_LOCAL_PORT RDP_PUBLIC_PORT RDESKTOP_IMAGE WEBTOP_IMAGE
export PORT_HOMEPAGE PORT_UPTIME PORT_GITEA PORT_FILEBROWSER PORT_DOZZLE
export PORT_BESZEL PORT_VAULTWARDEN PORT_ITTOOLS PORT_STIRLING PORT_WEBTOP
"$PROJECT_DIR/scripts/generate-compose.sh"
chown "$APP_OWNER:$APP_GROUP" /opt/stacks/apps/compose.yaml

check_platform_images() {
  local platform="linux/$(dpkg --print-architecture)"
  local image failed=0
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    if ! docker buildx imagetools inspect "$image" 2>/dev/null | grep -Eq "Platform:[[:space:]]+$platform|$platform"; then
      echo "No $platform manifest found: $image" >&2
      failed=1
    fi
  done < <(
    {
      selected portainer && docker compose -f /opt/stacks/portainer/compose.yaml config --images
      docker compose -f /opt/stacks/apps/compose.yaml config --images
    } | sort -u
  )
  return "$failed"
}

run_step "Validate applications compose" docker compose -f /opt/stacks/apps/compose.yaml config -q
if ! is_yes "$SKIP_ARCH_CHECK"; then
  if ! run_step "Verify selected images support the host architecture" check_platform_images; then
    warn "Manifest inspection was inconclusive. Docker pull will perform the final architecture check."
  fi
fi
run_step "Pull selected application images" docker compose -f /opt/stacks/apps/compose.yaml pull
run_step "Deploy selected applications" docker compose -f /opt/stacks/apps/compose.yaml up -d

if selected rdesktop && [[ "$RDP_EXPOSURE" != "disabled" ]]; then
  warn "Rdesktop is pinned to its final LinuxServer Ubuntu 24.04 image because the project is EOL."
  warn "It will not receive future base-image security updates. Prefer Webtop for regular use."
  ready="no"
  for _ in {1..12}; do
    if docker exec -u root rdesktop true >/dev/null 2>&1; then ready="yes"; break; fi
    sleep 2
  done
  if [[ "$ready" != "yes" ]]; then
    warn "RDP container was not ready. Password initialization and Chromium setup could not be verified."
  fi
  if [[ "$ready" == "yes" ]] && is_yes "$RDP_INSTALL_CHROMIUM"; then
    if docker exec -u abc rdesktop bash -lc \
      'command -v proot-apps >/dev/null && proot-apps install chromium' \
      >>"$LOG_FILE" 2>&1; then
      ok "Chromium installed persistently in the RDP profile."
    else
      warn "Chromium install did not complete. See $LOG_FILE."
    fi
  fi
fi

install_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg
    cat >/etc/apt/sources.list.d/cloudflared.list <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared noble main
EOF
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflared
  fi
  if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
    if systemctl list-unit-files cloudflared.service 2>/dev/null | grep -q '^cloudflared.service'; then
      systemctl enable --now cloudflared
    else
      cloudflared service install "$CF_TUNNEL_TOKEN"
      systemctl enable --now cloudflared
    fi
  fi
}
if is_yes "$INSTALL_CLOUDFLARED"; then
  run_step "Install or verify cloudflared" install_cloudflared
fi

ROUTES="$BSM_ENGINE_ETC/cloudflare-routes.md"
cat >"$ROUTES" <<EOF
# Cloudflare Tunnel routes

| Hostname | Origin service | TLS check |
|---|---|---|
| cp.${DOMAIN} | https://localhost:8083 | No TLS Verify: ON |
EOF
selected portainer && echo "| portainer.${DOMAIN} | https://localhost:${PORT_PORTAINER} | No TLS Verify: ON |" >>"$ROUTES"
selected homepage && echo "| home.${DOMAIN} | http://localhost:${PORT_HOMEPAGE} | normal |" >>"$ROUTES"
selected filebrowser && echo "| files.${DOMAIN} | http://localhost:${PORT_FILEBROWSER} | normal |" >>"$ROUTES"
selected uptime-kuma && echo "| uptime.${DOMAIN} | http://localhost:${PORT_UPTIME} | normal |" >>"$ROUTES"
selected dozzle && echo "| logs.${DOMAIN} | http://localhost:${PORT_DOZZLE} | normal |" >>"$ROUTES"
selected beszel && echo "| monitor.${DOMAIN} | http://localhost:${PORT_BESZEL} | normal |" >>"$ROUTES"
selected gitea && echo "| git.${DOMAIN} | http://localhost:${PORT_GITEA} | normal |" >>"$ROUTES"
selected vaultwarden && echo "| vault.${DOMAIN} | http://localhost:${PORT_VAULTWARDEN} | normal |" >>"$ROUTES"
selected it-tools && echo "| tools.${DOMAIN} | http://localhost:${PORT_ITTOOLS} | normal |" >>"$ROUTES"
selected stirling-pdf && echo "| pdf.${DOMAIN} | http://localhost:${PORT_STIRLING} | normal |" >>"$ROUTES"
selected webtop && echo "| desktop.${DOMAIN} | https://localhost:${PORT_WEBTOP} | No TLS Verify: ON |" >>"$ROUTES"
if selected rdesktop && [[ "$RDP_EXPOSURE" == "cloudflare" ]]; then
  echo "| rdp.${DOMAIN} | RDP localhost:${RDP_LOCAL_PORT} | Access policy required |" >>"$ROUTES"
fi
chmod 600 "$ROUTES"

if selected rdesktop && [[ "$RDP_EXPOSURE" == "public" ]]; then
  [[ -n "$RDP_ALLOWED_CIDR" ]] || die "Public RDP requires RDP_ALLOWED_CIDR."
  if [[ -x /usr/local/hestia/bin/v-add-firewall-rule ]]; then
    if ! grep -q "${RDP_PUBLIC_PORT}" /usr/local/hestia/data/firewall/rules.conf 2>/dev/null; then
      run_step "Add restricted Hestia RDP firewall rule" \
        /usr/local/hestia/bin/v-add-firewall-rule \
        ACCEPT "$RDP_ALLOWED_CIDR" "$RDP_PUBLIC_PORT" TCP "BSM-RDP"
    fi
  fi
  warn "Oracle NSG must allow TCP $RDP_PUBLIC_PORT only from $RDP_ALLOWED_CIDR."
  warn "Cloudflare DNS for rdp.${DOMAIN} must be DNS-only in public mode."
fi

if is_yes "$BACKUP_ENABLE"; then
  cat >/etc/systemd/system/bsm-engine-backup.service <<EOF
[Unit]
Description=BSM Server Engine encrypted backup
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/lib/bsm-engine/scripts/backup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
  cat >/etc/systemd/system/bsm-engine-backup.timer <<EOF
[Unit]
Description=BSM Server Engine nightly backup
[Timer]
OnCalendar=*-*-* ${BACKUP_HOUR}:00
Persistent=true
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now bsm-engine-backup.timer
fi

ok "Installation/reconciliation completed."
info "Detailed log: $LOG_FILE"
info "Saved config: $FINAL_CONFIG"
info "Saved secrets: $SECRETS"
info "Cloudflare routes: $ROUTES"
printf '\n%sWebtop login%s: %s / %s\n' "$C_BOLD" "$C_RESET" "$WEBTOP_USER" "$WEBTOP_PASSWORD"
if selected rdesktop && [[ "$RDP_EXPOSURE" != "disabled" ]]; then
  printf '%sRDP login%s: abc / %s\n' "$C_BOLD" "$C_RESET" "$RDP_PASSWORD"
fi
printf '\n'
"$PROJECT_DIR/scripts/verify.sh" "$FINAL_CONFIG" || warn "Verification reported one or more failures."
