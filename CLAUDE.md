# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is the **charts repo** for Mini Platform — a passive library of **vendored
upstream Helm charts**, committed verbatim under `charts/` (Argo CD, Vault, VSO,
and every platform component). There is no application source code and no
first-party configuration here.

These charts are **third-party**: they are intentionally not linted, templated,
or modified in this repo. Customization happens entirely through values overlays
in the separate **deployment repo**,
[`mini-platform-deployment`](https://github.com/nolimitkun/mini-platform-deployment),
which is what **Argo CD** actually reconciles.

## How it is consumed

Argo CD does not deploy anything from this repo on its own. The deployment repo
emits one **multi-source** Argo CD `Application` per release: source 0 pulls a
chart from `charts/<name>` here, source 1 pulls that release's values file from
the deployment repo. So this repo is referenced as `chartsRepo` (with a
`chartsRevision`) by the deployment repo's app-of-apps; it has no app-of-apps,
scripts, or Vault wiring of its own.

## Working in this repo

- **Treat `charts/` as vendored.** The normal change here is bumping an upstream
  chart to a new version (replacing the subtree verbatim), not editing chart
  internals. If a behavioral change is needed, prefer a values override in the
  deployment repo over patching the chart.
- **No CI gate / no validator lives here.** Rendering and schema checks run in
  the deployment repo (`scripts/validate-gitops.sh`), which can point its
  `CHARTS_DIR` at a local checkout of this repo to verify chart paths resolve.
- **No credentials, ever.** Same invariant as the deployment repo: Vault is the
  source of truth for secrets.
- `.github/workflows/claude.yml` and `claude-code-review.yml` wire up the Claude
  GitHub app.

When adding a *new* component to the platform, the chart subtree is dropped here
under `charts/`, but the overlay, app-of-apps entry, secrets, and ingress route
all go in the deployment repo. See that repo's `CLAUDE.md` for the full recipe.
