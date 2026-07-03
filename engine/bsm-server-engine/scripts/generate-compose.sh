#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/lib/common.sh"

: "${DOMAIN:=example.com}"
: "${TIMEZONE:=UTC}"
: "${PUID:=1000}"
: "${PGID:=1000}"
: "${RDP_EXPOSURE:=cloudflare}"
: "${RDP_LOCAL_PORT:=18888}"
: "${RDP_PUBLIC_PORT:=8888}"
: "${RDESKTOP_IMAGE:=lscr.io/linuxserver/rdesktop:ubuntu-xfce-version-80684ffb}"
: "${WEBTOP_IMAGE:=lscr.io/linuxserver/webtop:ubuntu-xfce}"

STACK_DIR="${STACK_DIR:-/opt/stacks/apps}"
COMPOSE="$STACK_DIR/compose.yaml"
mkdir -p "$STACK_DIR"
backup_file "$COMPOSE"

cat >"$COMPOSE" <<EOF
name: bsm-managed-apps

services:
EOF

if selected homepage; then
cat >>"$COMPOSE" <<EOF
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_HOMEPAGE}:3000"
    environment:
      TZ: "${TIMEZONE}"
      PUID: "${PUID}"
      PGID: "${PGID}"
      HOMEPAGE_ALLOWED_HOSTS: "home.${DOMAIN}"
    volumes:
      - /opt/appdata/homepage:/app/config

EOF
fi

if selected filebrowser; then
cat >>"$COMPOSE" <<EOF
  filebrowser:
    image: filebrowser/filebrowser:s6
    container_name: filebrowser
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_FILEBROWSER}:80"
    environment:
      TZ: "${TIMEZONE}"
      PUID: "${PUID}"
      PGID: "${PGID}"
    volumes:
      - /srv/personal-files:/srv
      - /opt/appdata/filebrowser/database:/database
      - /opt/appdata/filebrowser/config:/config

EOF
fi

if selected uptime-kuma; then
cat >>"$COMPOSE" <<EOF
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_UPTIME}:3001"
    volumes:
      - /opt/appdata/uptime-kuma:/app/data

EOF
fi

if selected dozzle; then
cat >>"$COMPOSE" <<EOF
  dozzle:
    image: amir20/dozzle:latest
    container_name: dozzle
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_DOZZLE}:8080"
    environment:
      DOZZLE_ENABLE_ACTIONS: "false"
      DOZZLE_ENABLE_SHELL: "false"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/appdata/dozzle:/data

EOF
fi

if selected beszel; then
cat >>"$COMPOSE" <<EOF
  beszel:
    image: henrygd/beszel:latest
    container_name: beszel
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_BESZEL}:8090"
    environment:
      APP_URL: "https://monitor.${DOMAIN}"
    volumes:
      - /opt/appdata/beszel/data:/beszel_data
      - /opt/appdata/beszel/socket:/beszel_socket

EOF
fi

if selected gitea; then
cat >>"$COMPOSE" <<EOF
  gitea:
    image: docker.gitea.com/gitea:1
    container_name: gitea
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_GITEA}:3000"
    environment:
      USER_UID: "${PUID}"
      USER_GID: "${PGID}"
      GITEA__database__DB_TYPE: sqlite3
      GITEA__server__DOMAIN: "git.${DOMAIN}"
      GITEA__server__ROOT_URL: "https://git.${DOMAIN}/"
      GITEA__server__DISABLE_SSH: "true"
      GITEA__service__DISABLE_REGISTRATION: "\${GITEA_REGISTRATION}"
    volumes:
      - /opt/appdata/gitea:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro

EOF
fi

if selected vaultwarden; then
cat >>"$COMPOSE" <<EOF
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_VAULTWARDEN}:80"
    environment:
      DOMAIN: "https://vault.${DOMAIN}"
      SIGNUPS_ALLOWED: "\${VAULTWARDEN_SIGNUPS_ALLOWED}"
      INVITATIONS_ALLOWED: "false"
      SHOW_PASSWORD_HINT: "false"
      TZ: "${TIMEZONE}"
    volumes:
      - /opt/appdata/vaultwarden:/data

EOF
fi

if selected it-tools; then
cat >>"$COMPOSE" <<EOF
  it-tools:
    image: corentinth/it-tools:latest
    container_name: it-tools
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_ITTOOLS}:80"

EOF
fi

if selected stirling-pdf; then
cat >>"$COMPOSE" <<EOF
  stirling-pdf:
    image: stirlingtools/stirling-pdf:latest
    container_name: stirling-pdf
    restart: unless-stopped
    mem_limit: 2g
    cpus: "1.0"
    ports:
      - "127.0.0.1:${PORT_STIRLING}:8080"
    environment:
      SECURITY_ENABLELOGIN: "true"
      SYSTEM_DEFAULTLOCALE: "fa-IR"
      TZ: "${TIMEZONE}"
    volumes:
      - /opt/appdata/stirling/configs:/configs
      - /opt/appdata/stirling/logs:/logs
      - /opt/appdata/stirling/pipeline:/pipeline
      - /opt/appdata/stirling/tessdata:/usr/share/tessdata

EOF
fi

if selected webtop; then
cat >>"$COMPOSE" <<EOF
  webtop:
    image: ${WEBTOP_IMAGE}
    container_name: webtop
    restart: unless-stopped
    shm_size: "1gb"
    mem_limit: 2g
    cpus: "1.0"
    ports:
      - "127.0.0.1:${PORT_WEBTOP}:3001"
    environment:
      PUID: "${PUID}"
      PGID: "${PGID}"
      TZ: "${TIMEZONE}"
      CUSTOM_USER: "\${WEBTOP_USER}"
      FILE__PASSWORD: "/run/secrets/webtop_password"
      TITLE: "BSM Web Desktop"
      START_DOCKER: "false"
    volumes:
      - /opt/appdata/webtop:/config
      - /etc/bsm-engine/webtop-password:/run/secrets/webtop_password:ro

EOF
fi

if selected rdesktop && [[ "$RDP_EXPOSURE" != "disabled" ]]; then
  if [[ "$RDP_EXPOSURE" == "public" ]]; then
    RDP_BIND="0.0.0.0:${RDP_PUBLIC_PORT}:3389"
  else
    RDP_BIND="127.0.0.1:${RDP_LOCAL_PORT}:3389"
  fi
cat >>"$COMPOSE" <<EOF
  rdesktop:
    image: ${RDESKTOP_IMAGE}
    container_name: rdesktop
    restart: unless-stopped
    security_opt:
      - seccomp:unconfined
    shm_size: "1gb"
    mem_limit: 2g
    cpus: "1.0"
    ports:
      - "${RDP_BIND}"
    environment:
      PUID: "${PUID}"
      PGID: "${PGID}"
      TZ: "${TIMEZONE}"
    volumes:
      - /opt/appdata/rdesktop:/config
      - /opt/appdata/rdesktop/custom-cont-init.d:/custom-cont-init.d:ro
      - /etc/bsm-engine/rdp-password:/run/secrets/rdp_password:ro

EOF
fi

chmod 640 "$COMPOSE"
