# Official sources used

- Cloudflare Tunnel overview: https://developers.cloudflare.com/tunnel/
- Cloudflare client-side RDP: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/rdp/rdp-cloudflared-authentication/
- LinuxServer Webtop: https://docs.linuxserver.io/images/docker-webtop/
- LinuxServer Rdesktop end-of-life notice: https://info.linuxserver.io/issues/2026-04-18-rdesktop/
- Final pinned Rdesktop tag: https://hub.docker.com/r/linuxserver/rdesktop/tags
- LinuxServer PRoot Apps: https://github.com/linuxserver/proot-apps
- Gitea standard Docker installation: https://docs.gitea.com/1.24/installation/install-with-docker
- Hestia firewall: https://hestiacp.com/docs/server-administration/firewall
- Hestia CLI reference: https://hestiacp.com/docs/reference/cli
- Docker Engine on Ubuntu: https://docs.docker.com/engine/install/ubuntu/

## Notes

- Webtop is a browser desktop and is exposed only through localhost plus Cloudflare Tunnel.
- The Rdesktop image is pinned because moving tags stopped after the project reached EOL.
- Public RDP mode is optional; Cloudflare client-side RDP is the default.
