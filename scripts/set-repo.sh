#!/usr/bin/env bash
# Point the GitOps configuration at a different Git repository and/or revision.
#
# The repoURL and targetRevision are referenced in several places that must stay
# in sync for Argo CD to reconcile correctly:
#   - gitops/root-application.yaml      (source + the helm parameters it passes)
#   - gitops/mini-platform/values.yaml  (app-of-apps defaults)
#   - scripts/deploy-minikube.sh        (REPO_URL / TARGET_REVISION defaults)
#
# Run this after forking so a fork is a one-command change instead of four edits.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: scripts/set-repo.sh --repo-url URL [--revision REV]

Options:
  --repo-url URL   Git repository URL Argo CD reconciles from (required).
  --revision REV   Git revision (branch/tag/commit). Default: leave unchanged.
  --help           Show this help.

Example:
  scripts/set-repo.sh --repo-url https://github.com/me/mini-platform.git --revision main
EOF
}

REPO_URL=""
REVISION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url) REPO_URL="${2:?--repo-url needs a value}"; shift 2 ;;
    --revision) REVISION="${2:?--revision needs a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$REPO_URL" ]] || { printf 'ERROR: --repo-url is required.\n\n' >&2; usage; exit 1; }

# Rewrite repoURL/targetRevision YAML keys and the matching Argo CD helm
# parameter (- name: / value:) pairs, in place, without touching other keys.
rewrite_yaml() {
  local file="$1" tmp
  tmp="$(mktemp)"
  awk -v url="$REPO_URL" -v rev="$REVISION" '
    function indent_of(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }
    {
      line = $0
      if (line ~ /^[[:space:]]*repoURL:[[:space:]]/) {
        print indent_of(line) "repoURL: " url; next
      }
      if (rev != "" && line ~ /^[[:space:]]*targetRevision:[[:space:]]/) {
        print indent_of(line) "targetRevision: " rev; next
      }
      if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*repoURL[[:space:]]*$/) {
        pending = "url"; print; next
      }
      if (line ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*targetRevision[[:space:]]*$/) {
        pending = "rev"; print; next
      }
      if (pending != "" && line ~ /^[[:space:]]*value:[[:space:]]/) {
        if (pending == "url")              print indent_of(line) "value: " url
        else if (rev != "")                print indent_of(line) "value: " rev
        else                               print
        pending = ""; next
      }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  printf '  updated %s\n' "${file#"$ROOT"/}"
}

# Rewrite the bash default-assignment lines in the deploy script.
rewrite_deploy_defaults() {
  local file="$ROOT/scripts/deploy-minikube.sh"
  sed -i -E "s|^REPO_URL=\"\\\$\{REPO_URL:-[^}]*\}\"|REPO_URL=\"\${REPO_URL:-${REPO_URL//|/\\|}}\"|" "$file"
  if [[ -n "$REVISION" ]]; then
    sed -i -E "s|^TARGET_REVISION=\"\\\$\{TARGET_REVISION:-[^}]*\}\"|TARGET_REVISION=\"\${TARGET_REVISION:-${REVISION//|/\\|}}\"|" "$file"
  fi
  printf '  updated %s\n' "scripts/deploy-minikube.sh"
}

printf 'Setting repoURL=%s%s\n' "$REPO_URL" "${REVISION:+ revision=$REVISION}"
rewrite_yaml "$ROOT/gitops/root-application.yaml"
rewrite_yaml "$ROOT/gitops/mini-platform/values.yaml"
rewrite_deploy_defaults

cat <<EOF

Done. Review and commit the changes, then push so Argo CD can reconcile them:

  git diff
  git add gitops/ scripts/deploy-minikube.sh
  git commit -m "point GitOps at ${REPO_URL}"
  git push
EOF
