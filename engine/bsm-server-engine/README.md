# BSM Server Engine

Idempotent/reconciling installer for Ubuntu server, Ubuntu 24.04, an existing or fresh HestiaCP host, Docker applications, Cloudflare Tunnel, Webtop, optional native RDP, and optional encrypted rclone remote backups.

## What this version fixes

- Detects an existing Hestia installation and does not reinstall it.
- Backs up existing Compose files before replacement.
- Does not delete `/opt/appdata`.
- Uses `18081` for File Browser and `18084` for Vaultwarden, avoiding Hestia's current `8081` and `8084`.
- Uses standard/rootful Gitea with the correct `/data` volume.
- Keeps every browser UI bound to `127.0.0.1`.
- Publishes browser tools through Cloudflare Tunnel, so no Oracle inbound ports are needed for them.
- Offers an interactive package checklist and a config-file/non-interactive mode.
- Writes concise PASS/FAIL output and detailed logs under `/var/log/bsm-engine/`.

## Run on your partially configured server

```bash
tar -xzf bsm-server-engine.tar.gz
cd bsm-server-engine
sudo ./install.sh
```

The installer can be rerun. It reconciles the selected services and preserves application data.

Config-driven mode:

```bash
cp config.env.example config.env
nano config.env
sudo ./install.sh --config ./config.env --non-interactive
```

Verify:

```bash
sudo ./install.sh --verify
```

## Cloudflare routes

After installation:

```bash
sudo cat /etc/bsm-engine/cloudflare-routes.md
```

Create the listed Published Applications in the Cloudflare Tunnel dashboard. Put browser admin tools behind Cloudflare Access.

Recommended Access-protected hostnames:

- `cp.example.com`
- `portainer.example.com`
- `home.example.com`
- `files.example.com`
- `uptime.example.com`
- `logs.example.com`
- `monitor.example.com`
- `tools.example.com`
- `pdf.example.com`
- `desktop.example.com`

Gitea and Vaultwarden normally use their own authentication because native clients can be disrupted by an interactive Cloudflare Access login page.

## Webtop

`desktop.example.com` maps to:

```text
https://localhost:13003
```

Enable **No TLS Verify** on the Tunnel origin and protect it with Cloudflare Access.

## RDP modes

### Recommended: Cloudflare mode

No inbound RDP port is opened.

Server route:

```text
rdp.example.com → RDP localhost:18888
```

On Windows:

```powershell
cloudflared access rdp --hostname rdp.example.com --url rdp://localhost:13389
```

Then connect Microsoft Remote Desktop to:

```text
localhost:13389
```

A helper exists at:

```text
scripts/rdp-client-windows.ps1
```

### Optional: public port 8888

Set:

```bash
RDP_EXPOSURE="public"
RDP_ALLOWED_CIDR="YOUR.PUBLIC.IP/32"
```

Open TCP 8888 in the cloud firewall or security group from the same CIDR only. The `rdp.example.com` record must be DNS-only.

## RDP image warning

LinuxServer's `rdesktop:ubuntu-xfce` image supports Ubuntu Noble, ARM64, XFCE and xrdp, but the project has deprecated the image. This installer therefore treats it as optional, does not mount the Docker socket into it, and defaults to Cloudflare tunneling. Chromium is installed persistently through `proot-apps`.

## Logs and secrets

```text
/var/log/bsm-engine/
/etc/bsm-engine/config.env
/etc/bsm-engine/secrets.env
```

## Update

```bash
sudo ./scripts/update.sh
```

## rclone remote backup

Configure and test an rclone remote named `remote`, set `BACKUP_ENABLE=yes`, and rerun the installer. The backup script encrypts with `age`, uploads with low concurrency, and verifies remote size. Copy this private key off the server:

```text
/etc/bsm-engine/age/backup.key
```

## Installer validation performed before release

- All Bash files pass `bash -n` syntax validation.
- Generated Compose YAML for the complete service set passes YAML parsing.
- Runtime image manifests are checked for `linux/arm64` unless `SKIP_ARCH_CHECK=yes`.
- Actual deployment still depends on registry/network availability and the current state of the target server; take an OCI boot-volume backup before the first run.
