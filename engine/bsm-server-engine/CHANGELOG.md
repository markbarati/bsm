# Changelog

## 2.0.0

- Reconciles a partially configured Ubuntu 24.04 ARM64/Hestia/Docker host.
- Avoids Hestia port conflicts by moving File Browser to 18081 and Vaultwarden to 18084.
- Replaces the failed rootless Gitea layout with the standard `/data` layout when no user data exists.
- Adds LinuxServer Webtop Ubuntu XFCE behind Cloudflare Tunnel.
- Adds optional pinned Ubuntu 24.04 XFCE/xrdp Rdesktop with persistent Chromium.
- Supports Cloudflare-only RDP with no inbound RDP port, or restricted public TCP 8888.
- Adds whiptail service selection, config-file mode, concise PASS/FAIL output, full logs, verification, status, backup, and restore testing.
