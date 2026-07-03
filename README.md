# BSM Community 0.2.0

A public-safe web control plane for Ubuntu 24.04 servers. It installs a local management panel, preserves existing application data, and provides Docker monitoring, configuration, jobs, sanitized command history, backup tools, update packages, and optional read-only AI troubleshooting.

## Privacy model

The repository contains **no real domain, IP address, email, password, token, API key, or SSH key**. The bootstrap asks for the settings needed by a particular server and stores them locally under `/etc/bsm/` with root-only permissions.

Do not commit runtime files from `/etc/bsm`, `/var/lib/bsm`, `/var/log/bsm`, `/opt/appdata`, or `/opt/stacks`.

## Install from a public Git repository

After publishing this directory to GitHub:

```bash
git clone https://github.com/YOUR-USER/YOUR-REPOSITORY.git
cd YOUR-REPOSITORY
sudo ./bootstrap.sh
```

The interactive bootstrap asks for:

- base domain;
- manager hostname;
- timezone;
- non-root application owner;
- initial local admin password;
- initial access method.

It detects existing BSM/Hestia/Docker state and does not delete `/opt/appdata`.

## Easiest first access

The default **Quick Setup URL** starts a temporary Cloudflare Quick Tunnel and prints a random `trycloudflare.com` URL. This is intended only for initial setup and testing. Log in, configure a permanent remotely-managed tunnel, then disable the quick tunnel.

Other modes:

- `named`: run an existing remotely-managed Cloudflare Tunnel token;
- `local`: bind only to `127.0.0.1:8788` and use SSH port forwarding.

All modes retain BSM's own username/password authentication. A permanent manager hostname should additionally be protected by Cloudflare Access.

## AI troubleshooting

The AI page supports:

- OpenAI Responses API;
- Anthropic Messages API;
- Google Gemini API;
- a custom OpenAI-compatible chat-completions endpoint.

The API key is stored in `/etc/bsm/secrets.json` with root-only permissions and is never returned to the browser. The user explicitly selects which sanitized context is sent:

- system snapshot;
- Docker container status;
- redacted configuration;
- command-ledger tail;
- selected container logs;
- selected allowlisted systemd logs.

A preview can display the exact sanitized snapshot; when a preview exists, that reviewed snapshot is sent. Network anonymization is enabled by default. BSM also allows copying this sanitized context for manual use without configuring any AI key.

AI is advisory and read-only: model responses are not executed and cannot call the privileged agent.

For OpenAI, use an OpenAI Platform API key. A ChatGPT subscription and API billing are separate.

## Change ledger

Privileged changes are recorded in sanitized formats:

```text
/var/log/bsm/command-ledger.jsonl
/var/log/bsm/command-ledger.sh
```

The ledger records actor, time, command, working directory, exit code, duration, output tail, and file hashes where applicable. Known secrets are redacted.

## Runtime paths

```text
/etc/bsm/                              root-only settings and secrets
/var/lib/bsm/                          jobs, UI data, diagnostics and staged updates
/var/log/bsm/                          logs and command ledger
/opt/bsm-community/releases/  immutable panel releases
/opt/bsm-community/current    active release symlink
```

The legacy internal path name is retained for upgrade compatibility; it does not contain user information.

## Public repository safety

Run before publishing:

```bash
./scripts/public-release-check.sh
```

The included GitHub Actions workflow checks Bash, Python, JavaScript, Compose YAML, and common credential patterns. Enable GitHub Secret Scanning and Push Protection after creating the public repository.

## Supported platform

- Ubuntu 24.04
- `arm64` and `amd64`
- Docker Engine with Compose plugin

The bundled server engine is optimized for HestiaCP plus Docker but detects an existing Hestia installation instead of reinstalling it.

## Security

Read [SECURITY.md](SECURITY.md) before exposing the panel. Treat authenticated BSM access as privileged server administration even though the browser container does not directly mount the Docker socket.

## One-file release bootstrap

Tagged GitHub releases also contain a self-extracting installer:

```text
bsm-community-bootstrap-VERSION.sh
```

Download it together with the matching checksum file, verify it locally, and run:

```bash
chmod +x bsm-community-bootstrap-VERSION.sh
sudo ./bsm-community-bootstrap-VERSION.sh
```

The file verifies its embedded archive before executing the normal interactive bootstrap.

## Publishing

See [docs/PUBLISH_GITHUB.md](docs/PUBLISH_GITHUB.md) for the public-repository and automated-release workflow.
