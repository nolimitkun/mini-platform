#!/usr/bin/env bash
# Validate the repo's own GitOps charts and scripts without a cluster.
#
# Runs the same checks as CI so failures can be reproduced locally:
#   - every chartPath / valuesFile referenced by the app-of-apps exists
#   - the three gitops/ charts lint and render
#   - rendered manifests pass kubeconform (CRDs are allowed to be unknown)
#   - shellcheck on scripts/
#
# Tools used if present: helm (required), kubeconform (optional), shellcheck
# (optional). Missing optional tools are reported and skipped, not failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
have() { command -v "$1" >/dev/null 2>&1; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; }

have helm || { echo "ERROR: helm is required." >&2; exit 1; }

GITOPS_CHARTS=(gitops/mini-platform gitops/vault-resources gitops/ingress-resources)
APP_OF_APPS=gitops/mini-platform
DUMMY_REPO=https://example.com/mini-platform.git

echo "==> Referenced chartPath / valuesFile exist"
# Extract "chartPath: X" and "valuesFile: Y" values from the app-of-apps values.
while read -r path; do
  [[ -n "$path" ]] || continue
  if [[ -e "$path" ]]; then ok "$path"; else bad "missing: $path"; fi
done < <(awk '/^[[:space:]]*(chartPath|valuesFile):[[:space:]]/ {print $2}' \
            "$APP_OF_APPS/values.yaml")

echo "==> helm lint"
for c in "${GITOPS_CHARTS[@]}"; do
  if helm lint "$c" --set repoURL="$DUMMY_REPO" >/dev/null 2>&1; then ok "$c"; else
    bad "$c"; helm lint "$c" --set repoURL="$DUMMY_REPO" || true
  fi
done

echo "==> helm template + kubeconform"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
for c in "${GITOPS_CHARTS[@]}"; do
  out="$RENDER_DIR/$(basename "$c").yaml"
  if helm template "$(basename "$c")" "$c" --set repoURL="$DUMMY_REPO" > "$out" 2>"$out.err"; then
    ok "render $c"
  else
    bad "render $c"; cat "$out.err"; continue
  fi
  if have kubeconform; then
    if kubeconform -strict -ignore-missing-schemas -summary "$out" >/dev/null 2>&1; then
      ok "kubeconform $c"
    else
      bad "kubeconform $c"; kubeconform -strict -ignore-missing-schemas "$out" || true
    fi
  fi
done
have kubeconform || skip "kubeconform not installed (manifest schema check skipped)"

echo "==> shellcheck"
if have shellcheck; then
  if shellcheck scripts/*.sh; then ok "scripts/*.sh"; else bad "scripts/*.sh"; fi
else
  skip "shellcheck not installed"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then echo "All checks passed."; else echo "Some checks FAILED." >&2; fi
exit "$FAIL"
