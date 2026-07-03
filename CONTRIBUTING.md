# Contributing

1. Never include real domains, public IP addresses, email addresses, tokens, API keys, passwords, SSH keys, or production logs.
2. Use reserved documentation values such as `example.com` and `203.0.113.5`.
3. Run `./scripts/public-release-check.sh` before every push.
4. Run the syntax checks from `.github/workflows/ci.yml`.
5. New privileged agent actions must be explicit, allowlisted, validated, logged, and documented.
6. AI features must remain read-only. A model response must never execute commands automatically.
