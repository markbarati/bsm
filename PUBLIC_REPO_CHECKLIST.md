# Public repository checklist

Before publishing:

- [ ] `./scripts/public-release-check.sh` passes.
- [ ] Git history never contained a real secret. If it did, revoke the secret before rewriting history.
- [ ] GitHub Secret Scanning and Push Protection are enabled.
- [ ] `.env`, private keys, runtime databases, logs, diagnostics, and backup files are not tracked.
- [ ] Examples use `example.com`, `203.0.113.0/24`, and placeholders.
- [ ] GitHub Actions permissions remain read-only unless a workflow explicitly needs more.
- [ ] Uploaded update/task packages are reviewed before execution.
