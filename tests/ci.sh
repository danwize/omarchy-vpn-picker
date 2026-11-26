#!/usr/bin/env bash
#
# Runs the same checks as .github/workflows/ci.yml, so they can be run
# locally when GitHub Actions is unavailable. The workflow calls this script,
# so local and CI results cannot drift apart.
#
#   tests/ci.sh
#
# Uses `shellcheck` from PATH, or falls back to `uvx --from shellcheck-py`.
# Requires `jq`, so the manifest and JSON checks in tests/run.sh always run.

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

# tests/run.sh skips its manifest and JSON checks without jq; CI must not.
if ! command -v jq >/dev/null 2>&1; then
  echo "ci: jq not found (tests/run.sh would skip the manifest and JSON checks)" >&2
  exit 1
fi

# Only Omarchy machines ship the plugin validator; say so rather than skip silently.
if ! command -v omarchy-plugin-validate >/dev/null 2>&1; then
  echo "ci: omarchy-plugin-validate not found; skipping that one check (run 'omarchy plugin validate .' on an Omarchy machine)"
fi

echo "== ShellCheck"
"${shellcheck[@]}" -x bin/omarchy-vpn-picker install.sh tests/run.sh tests/ci.sh

echo "== Tests"
tests/run.sh

echo "== No VPN configs or keys committed"
# Match in bash so a missing or failing grep cannot turn this check into a pass.
tracked=$(git ls-files)
secret_files=()
shopt -s nocasematch
while IFS= read -r f; do
  [[ $f =~ \.(ovpn|key|crt|pem|p12|pfx)$ ]] && secret_files+=("$f")
done <<<"$tracked"
shopt -u nocasematch
if ((${#secret_files[@]} > 0)); then
  printf '%s\n' "${secret_files[@]}"
  echo "VPN configs, keys, or certificates must not be committed" >&2
  exit 1
fi

echo "ci: all checks passed"
