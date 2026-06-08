# Chart Update Process

This repository is a passive library of vendored upstream Helm charts. Updates
should replace chart subtrees verbatim and keep platform-specific behavior in
the separate `mini-platform-deployment` repository.

## When to update a chart

- A platform component needs a security fix, bug fix, or feature from upstream.
- The deployment repository has a values overlay ready for the new chart shape.
- The update can be validated against the deployment repository before merge.

## Update workflow

1. Create a branch from the current charts branch.
2. Fetch the upstream chart archive for the target chart and version.
3. Replace the matching `charts/<name>` subtree with the upstream chart contents.
4. Preserve vendored files exactly. Avoid local patches to templates, schemas,
   defaults, or dependency metadata.
5. Update `charts-index.yaml` with the new `chartVersion`, `appVersion`, and any
   upstream provenance changes.
6. Run the local inventory check:

   ```sh
   scripts/check-chart-inventory.sh
   ```

7. In a checkout of `mini-platform-deployment`, run its GitOps validation with
   `CHARTS_DIR` pointing at this repository checkout.
8. Summarize deployment-repo validation results in the pull request.

## If a chart needs customization

Prefer values overrides in `mini-platform-deployment`. Patch vendored chart
templates here only when an upstream fix is unavailable and the deployment
cannot work around the issue. If a patch is unavoidable, document it in the pull
request and open or reference the upstream issue.

## Secret handling

Never add credentials, generated secrets, tokens, kubeconfigs, or sealed secret
material here. Vault and the deployment repository own runtime secret wiring.

## Inventory fields

`charts-index.yaml` tracks the component path, chart name, chart version, app
version, broad platform category, and upstream provenance. Keep it current so
reviewers can see what changed without opening every vendored chart.
