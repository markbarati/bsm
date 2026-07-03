# Security model

BSM Community can trigger a small allowlist of privileged host operations. Treat access to the panel as privileged server administration.

## Required deployment controls

1. Keep the web container bound to `127.0.0.1:8788`.
2. Use a remotely-managed Cloudflare Tunnel or SSH port forwarding for permanent access.
3. Protect a permanent hostname with Cloudflare Access and strong identity authentication.
4. Use a unique BSM password of at least 12 characters.
5. Do not publish the Docker socket or agent Unix socket to the network.
6. Do not commit `/etc/bsm`, logs, diagnostics, backups, or AI keys.

## AI data handling

- AI integration is disabled until a provider, model, and API key are configured.
- The key is stored only in root-readable host configuration.
- Context is redacted, network-anonymized by default, and truncated before transmission.
- The UI can preview the exact sanitized snapshot; a reviewed preview is reused for the next request.
- Only explicitly selected container and allowlisted systemd logs are included.
- AI responses are advisory and are never executed automatically.
- Do not send information you are not authorized to share with the selected provider.

## Quick Tunnel warning

The automatic `trycloudflare.com` setup URL is temporary and intended for setup/testing. It is protected by BSM login but is not a replacement for a permanent Cloudflare Tunnel plus Access policy.

## Updates and taskpacks

Checksum validation detects corruption but does not prove publisher identity. Review uploaded packages and use signed releases for production distribution. Unsigned arbitrary scripts must not be executed automatically.

## Reporting vulnerabilities

Use a private security advisory or private contact channel. Do not include live credentials, private keys, or unredacted production logs in a public issue.
