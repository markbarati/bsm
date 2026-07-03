#!/usr/bin/env bash
set -Eeuo pipefail

ORIGINAL_ARGS=("$@")

VERSION="$(cat "$(dirname "$0")/VERSION")"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="/opt/bsm-community"
RELEASE="$BASE/releases/$VERSION"
CURRENT="$BASE/current"
ETC="/etc/bsm"
STATE="/var/lib/bsm"
LOGDIR="/var/log/bsm"
RUNDIR="/run/bsm"
LOGFILE="$LOGDIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"

DOMAIN=""
MANAGER_HOSTNAME=""
TIMEZONE=""
APP_OWNER=""
ACCESS_MODE="quick"
TUNNEL_TOKEN=""
ADMIN_USER="admin"
ADMIN_PASSWORD=""
NON_INTERACTIVE="no"
RECONFIGURE="no"
NEW_ADMIN_PASSWORD=""

if [[ -t 1 ]]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'; N=$'\033[0m'
else G="";R="";Y="";B="";N=""; fi
info(){ printf '%sℹ%s %s\n' "$B" "$N" "$*"; }
ok(){ printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s⚠%s %s\n' "$Y" "$N" "$*" >&2; }
die(){ printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage(){ cat <<'USAGE'
BSM Community installer

Usage:
  sudo ./install-manager.sh
  sudo ./install-manager.sh --domain example.com --access-mode quick

Options:
  --domain NAME              Base domain used by managed services
  --manager-hostname NAME    Manager hostname, default manager.<domain>
  --timezone NAME            IANA timezone, auto-detected by default
  --app-owner USER           Non-root owner for application files
  --access-mode MODE         quick | named | local
  --tunnel-token TOKEN       Existing remotely-managed Cloudflare Tunnel token
  --admin-user USER          Initial local BSM username
  --admin-password PASSWORD  Initial local BSM password (prefer interactive entry)
  --non-interactive          Fail instead of prompting for missing required values
  --reconfigure              Prompt again even when an existing configuration exists
  -h, --help                 Show help

Access modes:
  quick  Temporary trycloudflare.com URL for setup. Testing only.
  named  Run an existing Cloudflare Tunnel token. The hostname route must exist.
  local  Bind only to localhost; use SSH port forwarding.
USAGE
}

while (($#)); do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2;;
    --manager-hostname) MANAGER_HOSTNAME="${2:-}"; shift 2;;
    --timezone) TIMEZONE="${2:-}"; shift 2;;
    --app-owner) APP_OWNER="${2:-}"; shift 2;;
    --access-mode) ACCESS_MODE="${2:-}"; shift 2;;
    --tunnel-token) TUNNEL_TOKEN="${2:-}"; shift 2;;
    --admin-user) ADMIN_USER="${2:-}"; shift 2;;
    --admin-password) ADMIN_PASSWORD="${2:-}"; shift 2;;
    --non-interactive) NON_INTERACTIVE="yes"; shift;;
    --reconfigure) RECONFIGURE="yes"; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then exec sudo -E bash "$0" "${ORIGINAL_ARGS[@]}"; fi
mkdir -p "$LOGDIR"; chmod 700 "$LOGDIR"; exec > >(tee -a "$LOGFILE") 2>&1
trap 'rc=$?; printf "\nBootstrap failed at line %s (exit %s). Log: %s\n" "$LINENO" "$rc" "$LOGFILE" >&2; exit "$rc"' ERR

printf '\n%sBSM Community %s%s\n' "$B" "$VERSION" "$N"

. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 is required."
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "arm64" || "$ARCH" == "amd64" ]] || die "Supported architectures: arm64, amd64. Found: $ARCH"

TIMEZONE="${TIMEZONE:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}"
APP_OWNER="${APP_OWNER:-${SUDO_USER:-ubuntu}}"
id "$APP_OWNER" >/dev/null 2>&1 || APP_OWNER="ubuntu"

# Preserve current configuration during upgrades unless explicitly reconfiguring.
if [[ -f "$ETC/server.json" && "$RECONFIGURE" != "yes" ]]; then
  eval "$(python3 - "$ETC/server.json" <<'PY'
import json,shlex,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
vals={
'DOMAIN':d.get('domain',''),
'MANAGER_HOSTNAME':(d.get('cloudflare') or {}).get('manager_hostname',''),
'TIMEZONE':d.get('timezone',''),
'APP_OWNER':d.get('app_owner',''),
}
for k,v in vals.items():
    if v: print(f'{k}={shlex.quote(str(v))}')
PY
)"
  info "Existing configuration detected; personal settings will be preserved."
fi

prompt_value(){
  local var="$1" label="$2" default="$3" secret="${4:-no}" value="${!var:-}"
  [[ -n "$value" ]] && return 0
  if [[ "$NON_INTERACTIVE" == "yes" || ! -t 0 ]]; then
    [[ -n "$default" ]] && printf -v "$var" '%s' "$default" && return 0
    die "$label is required in non-interactive mode."
  fi
  if [[ "$secret" == "yes" ]]; then
    read -rsp "$label${default:+ [$default]}: " value; echo
  else
    read -rp "$label${default:+ [$default]}: " value
  fi
  printf -v "$var" '%s' "${value:-$default}"
}

prompt_value DOMAIN "Base domain" ""
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || die "Invalid domain: $DOMAIN"
MANAGER_HOSTNAME="${MANAGER_HOSTNAME:-manager.$DOMAIN}"

if [[ "$RECONFIGURE" == "yes" || ! -f "$ETC/server.json" ]]; then
  prompt_value MANAGER_HOSTNAME "Manager hostname" "manager.$DOMAIN"
  prompt_value TIMEZONE "Timezone" "$TIMEZONE"
  prompt_value APP_OWNER "Application owner" "$APP_OWNER"
  if [[ "$NON_INTERACTIVE" != "yes" && -t 0 ]]; then
    printf '\nAccess method:\n  1) Quick temporary URL (easiest first setup)\n  2) Existing named Cloudflare Tunnel token\n  3) Localhost only / SSH tunnel\n'
    read -rp "Select [1]: " choice
    case "${choice:-1}" in 1) ACCESS_MODE=quick;; 2) ACCESS_MODE=named;; 3) ACCESS_MODE=local;; *) die "Invalid access selection";; esac
  fi
fi
[[ "$ACCESS_MODE" =~ ^(quick|named|local)$ ]] || die "Invalid access mode: $ACCESS_MODE"
if [[ "$ACCESS_MODE" == "named" ]]; then
  prompt_value TUNNEL_TOKEN "Cloudflare Tunnel token" "" yes
fi

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl rsync openssl python3 tar gzip coreutils jq

install_docker(){
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then return; fi
  info "Installing Docker Engine from Docker's official Ubuntu repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}
install_docker
ok "Docker and Compose are available."

getent group bsm >/dev/null 2>&1 || groupadd --system bsm
BSM_GID="$(getent group bsm | cut -d: -f3)"
mkdir -p "$BASE/releases" "$ETC" "$STATE/web/uploads" "$STATE/jobs" "$STATE/diagnostics" "$STATE/updates" "$LOGDIR" "$RUNDIR"
chmod 700 "$ETC" "$LOGDIR"
chown -R 10001:10001 "$STATE/web"
chmod 750 "$STATE" "$STATE/web" "$STATE/web/uploads"
chown root:bsm "$RUNDIR"; chmod 770 "$RUNDIR"

if [[ -d "$RELEASE" ]]; then
  BACKUP="$BASE/releases/${VERSION}.previous.$(date +%s)"
  mv "$RELEASE" "$BACKUP"
  warn "Existing release moved to $BACKUP"
fi
mkdir -p "$RELEASE"
rsync -a --delete --exclude '.git' --exclude 'config.local.*' --exclude '*.secret*' "$SOURCE_DIR/" "$RELEASE/"
ln -sfn "$RELEASE" "$CURRENT.new"
mv -Tf "$CURRENT.new" "$CURRENT"
chmod 755 "$RELEASE/install-manager.sh" "$RELEASE/agent/bsm_agent.py"
ok "Release installed at $RELEASE"

if [[ ! -s "$ETC/agent.token" ]]; then openssl rand -hex 32 >"$ETC/agent.token"; fi
chown root:bsm "$ETC/agent.token"; chmod 640 "$ETC/agent.token"

# Initial account; existing account/database is never overwritten on upgrades.
if [[ ! -f "$ETC/bootstrap-admin.json" ]]; then
  if [[ -z "$ADMIN_PASSWORD" && "$NON_INTERACTIVE" != "yes" && -t 0 ]]; then
    read -rsp "Initial BSM password (blank = generate): " ADMIN_PASSWORD; echo
  fi
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$(openssl rand -base64 30 | tr -d '=+/\n' | head -c 24)"
    NEW_ADMIN_PASSWORD="$ADMIN_PASSWORD"
  fi
  [[ ${#ADMIN_PASSWORD} -ge 12 ]] || die "Initial password must contain at least 12 characters."
  python3 - "$ADMIN_USER" "$ADMIN_PASSWORD" >"$ETC/bootstrap-admin.json" <<'PY'
import base64,hashlib,json,secrets,sys
username,password=sys.argv[1:3]
salt=secrets.token_bytes(16)
d=hashlib.scrypt(password.encode(),salt=salt,n=2**14,r=8,p=1,dklen=32)
encoded='scrypt$'+base64.urlsafe_b64encode(salt).decode()+'$'+base64.urlsafe_b64encode(d).decode()
print(json.dumps({'username':username,'password_hash':encoded}))
PY
fi
chown root:bsm "$ETC/bootstrap-admin.json"; chmod 640 "$ETC/bootstrap-admin.json"

# Write only public/non-secret settings to server.json. Preserve other existing fields.
python3 - "$ETC/server.json" "$DOMAIN" "$MANAGER_HOSTNAME" "$TIMEZONE" "$APP_OWNER" <<'PY'
import json,sys,os,tempfile
path,domain,host,tz,owner=sys.argv[1:]
try: d=json.load(open(path))
except Exception: d={}
d.update({'domain':domain,'public_ip':'','timezone':tz,'app_owner':owner})
cf=d.setdefault('cloudflare',{})
cf.update({'install':True,'manager_hostname':host})
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path),prefix='.server.')
with os.fdopen(fd,'w') as f: json.dump(d,f,indent=2); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,path)
PY

# Preserve all existing secrets and add the optional tunnel token.
python3 - "$ETC/secrets.json" "$TUNNEL_TOKEN" <<'PY'
import json,sys,os,tempfile
path,token=sys.argv[1:]
try: d=json.load(open(path))
except Exception: d={}
if token: d['cloudflare_tunnel_token']=token
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path),prefix='.secrets.')
with os.fdopen(fd,'w') as f: json.dump(d,f,indent=2); f.write('\n')
os.chmod(tmp,0o600); os.replace(tmp,path)
PY

install -m 0644 "$RELEASE/agent/bsm-agent.service" /etc/systemd/system/bsm-agent.service
systemctl daemon-reload
systemctl enable --now bsm-agent
sleep 1
systemctl is-active --quiet bsm-agent || { journalctl -u bsm-agent -n 50 --no-pager; die "BSM agent failed."; }
ok "Privileged allowlisted agent is running."

cat >"$RELEASE/.env" <<ENV
BSM_GID=$BSM_GID
ENV
chmod 600 "$RELEASE/.env"
docker compose --env-file "$RELEASE/.env" -f "$RELEASE/docker-compose.yml" up -d --build
sleep 3
docker ps --filter name=bsm-web --format '{{.Names}} {{.Status}}'
ok "Web panel is running on 127.0.0.1:8788."

install_cloudflared(){
  if command -v cloudflared >/dev/null 2>&1; then return; fi
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  cat >/etc/apt/sources.list.d/cloudflared.list <<'CFREPO'
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared noble main
CFREPO
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflared
}

PUBLIC_URL=""
if [[ "$ACCESS_MODE" == "quick" || "$ACCESS_MODE" == "named" ]]; then install_cloudflared; fi

if [[ "$ACCESS_MODE" == "quick" ]]; then
  systemctl disable --now bsm-cloudflared.service >/dev/null 2>&1 || true
  cat >/etc/systemd/system/bsm-quick-tunnel.service <<'UNIT'
[Unit]
Description=BSM temporary Cloudflare Quick Tunnel
After=network-online.target bsm-agent.service docker.service
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/var/lib/bsm/quick-home
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --logfile /var/log/bsm/quick-tunnel.log --url http://127.0.0.1:8788
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  mkdir -p /var/lib/bsm/quick-home
  : >/var/log/bsm/quick-tunnel.log
  systemctl daemon-reload
  systemctl enable --now bsm-quick-tunnel.service
  info "Waiting for the temporary setup URL..."
  for _ in $(seq 1 30); do
    PUBLIC_URL="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/bsm/quick-tunnel.log | tail -1 || true)"
    [[ -n "$PUBLIC_URL" ]] && break
    sleep 1
  done
  [[ -n "$PUBLIC_URL" ]] || warn "Quick Tunnel started, but its URL was not detected yet. Run: journalctl -u bsm-quick-tunnel -f"
elif [[ "$ACCESS_MODE" == "named" ]]; then
  systemctl disable --now bsm-quick-tunnel.service >/dev/null 2>&1 || true
  cat >"$ETC/cloudflared.env" <<ENV
TUNNEL_TOKEN=$TUNNEL_TOKEN
ENV
  chmod 600 "$ETC/cloudflared.env"
  cat >/etc/systemd/system/bsm-cloudflared.service <<'UNIT'
[Unit]
Description=BSM Cloudflare Tunnel connector
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/bsm/cloudflared.env
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now bsm-cloudflared.service
  PUBLIC_URL="https://$MANAGER_HOSTNAME"
fi

cat >"$ETC/access-info.txt" <<INFO
BSM local origin: http://127.0.0.1:8788
Configured manager hostname: $MANAGER_HOSTNAME
Access mode: $ACCESS_MODE
${PUBLIC_URL:+Current URL: $PUBLIC_URL}
For a production named tunnel, route $MANAGER_HOSTNAME to http://localhost:8788 and protect it with Cloudflare Access.
INFO
chmod 600 "$ETC/access-info.txt"

printf '\n%sInstallation complete%s\n' "$G" "$N"
printf '  Local origin: http://127.0.0.1:8788\n'
if [[ -n "$PUBLIC_URL" ]]; then printf '  Open now:     %s\n' "$PUBLIC_URL"; fi
printf '  Username:     %s\n' "$ADMIN_USER"
if [[ -n "$NEW_ADMIN_PASSWORD" ]]; then
  printf '  Password:     %s\n' "$NEW_ADMIN_PASSWORD"
  printf '%sSave this password now. It is not stored in plaintext.%s\n' "$Y" "$N"
else
  printf '  Password:     your existing or entered password\n'
fi
if [[ "$ACCESS_MODE" == "quick" ]]; then
  warn "The trycloudflare.com URL is temporary and intended only for setup/testing. Configure a named tunnel from the panel for permanent use."
fi
printf '  Full log:     %s\n' "$LOGFILE"
