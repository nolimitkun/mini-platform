# Mini Platform — Charts

This repository is the **chart library** for Mini Platform, a self-contained
Kubernetes reference stack for local LLM inference, observability, experiment
tracking, and SQL analytics.

It contains only the **vendored upstream Helm charts** under [`charts/`](charts/)
— Argo CD, Vault, Vault Secrets Operator, and every platform component —
committed verbatim. There is no application code, no values overlays, and no
deployment wiring here.

## Where the rest lives

Deployment is driven from a separate repo:
**[`mini-platform-deployment`](https://github.com/nolimitkun/mini-platform-deployment)**.
It holds the integration overlays, the Argo CD app-of-apps wiring, the Vault
secret mappings, the ingress routes, and the bootstrap/deploy scripts. Start
there to deploy or operate the stack.

## How these charts are used

Argo CD reconciles the stack by combining the two repos. Each generated Argo CD
`Application` is **multi-source**: it pulls its chart from `charts/<name>` in
this repo (referenced as `chartsRepo` / `chartsRevision`) and its values file
from the deployment repo. Nothing in this repo deploys on its own.

For local validation, the deployment repo's `scripts/validate-gitops.sh` can
point its `CHARTS_DIR` at a checkout of this repo to confirm every referenced
`chartPath` resolves.

## Conventions

- Charts are **third-party and vendored** — not linted or modified here. The
  normal change is bumping an upstream chart to a new version by replacing its
  subtree. Prefer a values override in the deployment repo over patching a chart.
- **No credentials in Git.** Vault is the source of truth for all application
  secrets.
