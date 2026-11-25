#!/usr/bin/env bash
#
# Runs the same checks as .github/workflows/ci.yml, so they can be run
# locally when GitHub Actions is unavailable. The workflow calls this script,
# so local and CI results cannot drift apart.
#
#   tests/ci.sh
#
# Uses `shellcheck` from PATH, or falls back to `uvx --from shellcheck-py`.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck=(shellcheck)
elif command -v uvx >/dev/null 2>&1; then
  shellcheck=(uvx --from shellcheck-py shellcheck)
else
  echo "ci: shellcheck not found (install it, or install uv for uvx)" >&2
  exit 1
fi

echo "== ShellCheck"
"${shellcheck[@]}" -x bin/omarchy-vpn-picker install.sh tests/run.sh tests/ci.sh

echo "== Tests"
tests/run.sh

echo "== No VPN configs or keys committed"
if git ls-files | grep -Ei '\.(ovpn|key|crt|pem|p12|pfx)$'; then
  echo "VPN configs, keys, or certificates must not be committed" >&2
  exit 1
fi

echo "ci: all checks passed"
