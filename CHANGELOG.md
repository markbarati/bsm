# Changelog

## 0.2.0

- Added a public-safe interactive bootstrap with Quick, named, and local access modes.
- Added optional OpenAI, Anthropic, Gemini, and OpenAI-compatible troubleshooting.
- Added selectable context preview, stronger secret redaction, and default network anonymization.
- Added a one-file self-extracting bootstrap and automated GitHub Release workflow.
- Added public-repository scans, CI, documentation, and MIT licensing.


- Removed all server-specific domains, public IPs, usernames, and backup paths from the public source tree.
- Added interactive public-repository bootstrap with quick, named-tunnel, and localhost access modes.
- Added temporary Quick Tunnel setup URL for a no-SSH first login.
- Added OpenAI, Anthropic, Gemini, and custom OpenAI-compatible AI troubleshooting.
- Added explicit context selection, exact preview, copying, redaction, truncation, and read-only AI behavior.
- Added SSE-to-polling fallback for live jobs so temporary Quick Tunnels remain usable.
- Added public-repository `.gitignore`, CI, credential-pattern scan, MIT license, and publication checklist.
- Generalized the bundled engine to Ubuntu 24.04 on arm64 and amd64.

## 0.1.0

- Initial local web control plane with allowlisted host agent, Docker monitoring, jobs, command ledger, diagnostics, update packages, and rollback.
