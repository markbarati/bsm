#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
bad(){ printf 'ERROR: %s\n' "$*" >&2; fail=1; }

# Files that must never be committed.
while IFS= read -r file; do
  bad "Sensitive filename is tracked: $file"
done < <(find . -type f \( -name '*.pem' -o -name '*.p12' -o -name '*.pfx' -o -name '*.ppk' -o -name 'agent.token' -o -name 'secrets.json' -o -name 'cloudflared.env' \) -not -path './.git/*')

# Common credential patterns. Examples and documentation should use obvious placeholders.
patterns=(
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
  'sk-[A-Za-z0-9_-]{20,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'AIza[0-9A-Za-z_-]{30,}'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'eyJ[A-Za-z0-9_-]{80,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
)
for pattern in "${patterns[@]}"; do
  if grep -RInE --exclude-dir=.git --exclude='public-release-check.sh' -- "$pattern" . >/tmp/bsm-secret-scan.txt; then
    cat /tmp/bsm-secret-scan.txt >&2
    bad "Possible secret matched pattern: $pattern"
  fi
done

# Project-specific private strings can be supplied locally, one per line.
if [[ -n "${BSM_FORBIDDEN_STRINGS_FILE:-}" && -f "$BSM_FORBIDDEN_STRINGS_FILE" ]]; then
  while IFS= read -r value; do
    [[ -n "$value" ]] || continue
    if grep -RIlF "$value" . --exclude-dir=.git | grep -q .; then
      bad "A project-specific forbidden string is present."
    fi
  done < "$BSM_FORBIDDEN_STRINGS_FILE"
fi

(( fail == 0 )) || exit 1
printf 'Public-release checks passed.\n'
