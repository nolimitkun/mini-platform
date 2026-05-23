# Mini Platform

Mini Platform is a Kubernetes reference stack for local LLM inference, LLM
observability, experiment tracking, and SQL analytics. It vendors Helm charts
with integration-focused values and uses Argo CD to reconcile the stack from
Git.

The default AI request path is `Open WebUI -> LiteLLM -> vLLM Router -> vLLM`,
with LiteLLM emitting request traces to Langfuse. Vault is the source of
application credentials; Vault Secrets Operator materializes only the
Kubernetes Secrets required by each Helm release.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `charts/` | Vendored upstream Helm charts, including Argo CD, Vault, and Vault Secrets Operator |
| `values/` | Mini Platform integration overlays without committed credentials |
| `gitops/mini-platform/` | Argo CD app-of-apps chart for managed releases |
| `gitops/vault-resources/` | Vault secret synchronization mappings for platform workloads |
| `gitops/root-application.yaml` | Root Argo CD Application bootstrap manifest |
| `scripts/bootstrap-vault-secrets.sh` | Writes generated initial credentials to Vault |
| `text-2-sql/` | Notebook and sample SQL assets for the text-to-SQL use case |

## Architecture

```text
Open WebUI -> LiteLLM -> vLLM
                  |
                  +-> Langfuse traces

Vault -> Vault Secrets Operator -> Kubernetes Secrets -> platform workloads

Prometheus -> Grafana
MLflow     -> experiment and artifact tracking
Qdrant     -> vector storage for notebook/RAG examples

Spark Operator -> Spark batch workloads
Superset       -> Trino -> analytics data sources
Keycloak       -> identity provider
MinIO          -> shared object-store endpoint

Argo CD        -> reconciles Helm releases and secret mappings from Git
```

Langfuse, MLflow, and Superset deploy isolated stateful dependencies to keep
their upgrades independent from the LiteLLM gateway. Vault uses persistent
standalone storage in the starter configuration and must be initialized and
unsealed before dependent applications become healthy.

## Deployment

Argo CD reconciles the vendored Helm charts using the overlays under
[`values/`](values/). No application credential is committed to Git.

### Prerequisites

- Kubernetes `1.28` or newer. The current JupyterHub chart requires this.
- Helm 3, `kubectl`, the Vault CLI, and `openssl`.
- Network access from Argo CD to this repository, or update `repoURL` for a fork.
- A default StorageClass for platform PVCs, including Vault.
- An NVIDIA-capable node and device plugin for the default vLLM values. Change
  [`values/vllm-values.yaml`](values/vllm-values.yaml) for CPU testing.

All commands below run from the repository root.

### 1. Create The Namespace

```bash
export NS=mini-platform
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
```

Do not manually create workload credential Secrets. Vault Secrets Operator
creates them after Vault is configured and populated in step 4.

### 2. Bootstrap Argo CD

Argo CD is installed directly with Helm once. After the root application is
applied, Argo CD reconciles its own chart configuration and every platform
release.

```bash
export ARGO_NS=argocd
kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd charts/argo-cd \
  -n "$ARGO_NS" -f values/argo-cd-values.yaml --wait

kubectl -n "$ARGO_NS" port-forward svc/argocd-server 8080:80
kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

The bootstrap values expose Argo CD only through a local port-forward.
Configure ingress, TLS, and identity integration before exposing it.

### 3. Apply The Root Application

[`gitops/root-application.yaml`](gitops/root-application.yaml) points to this
repository's `main` branch. Update its `repoURL` and `targetRevision` fields
first when deploying from a fork or release branch.

```bash
kubectl apply -f gitops/root-application.yaml
kubectl -n argocd get applications
```

Vault and Vault Secrets Operator are created before the dependent chart
applications. The first reconciliation can show missing-secret failures until
Vault is initialized and the `VaultStaticSecret` resources synchronize.

### 4. Initialize Vault And Seed Secrets

The starter overlay installs one persistent Vault server with HTTP limited to
cluster networking and port-forward access. Initialize it once and store the
unseal key and root token outside this repository.

```bash
umask 077
kubectl -n "$NS" exec vault-0 -- vault operator init \
  -key-shares=1 -key-threshold=1 -format=json > "$HOME/.vault-mini-platform-init.json"

export VAULT_UNSEAL_KEY='<unseal-key-from-secure-init-output>'
export VAULT_TOKEN='<initial-root-token-from-secure-init-output>'
kubectl -n "$NS" exec vault-0 -- vault operator unseal "$VAULT_UNSEAL_KEY"

kubectl -n "$NS" port-forward svc/vault 8200:8200
```

In a second terminal, export `VAULT_ADDR` and `VAULT_TOKEN` again, then
configure the KV store and Kubernetes authentication used by Vault Secrets
Operator:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN='<initial-root-token-from-secure-init-output>'

vault secrets enable -path=mini-platform kv-v2
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc.cluster.local:443

vault policy write mini-platform-read - <<'EOF'
path "mini-platform/data/*" {
  capabilities = ["read"]
}
path "mini-platform/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

vault write auth/kubernetes/role/mini-platform \
  bound_service_account_names=vault-auth \
  bound_service_account_namespaces=mini-platform \
  audience=vault \
  policies=mini-platform-read \
  ttl=1h

vault audit enable file file_path=/vault/audit/audit.log
./scripts/bootstrap-vault-secrets.sh
```

Vault Secrets Operator now creates the destination Kubernetes Secrets requested
by the values overlays. Check synchronization with:

```bash
kubectl -n "$NS" get vaultstaticsecrets
kubectl -n "$NS" get secrets
```

This starter configuration uses manual unseal and disables TLS inside the
cluster. For a production installation, configure TLS, an auto-unseal
mechanism, tightly scoped administrative tokens, backups, and an HA storage
design before storing credentials.

### 5. Managed Releases

Argo CD manages these chart applications and the Vault secret mappings:

| Argo CD application | Chart | Values |
| --- | --- | --- |
| `mini-platform-argocd` | `charts/argo-cd` | `values/argo-cd-values.yaml` |
| `mini-platform-vault` | `charts/vault` | `values/vault-values.yaml` |
| `mini-platform-vault-secrets-operator` | `charts/vault-secrets-operator` | `values/vault-secrets-operator-values.yaml` |
| `mini-platform-vault-resources` | `gitops/vault-resources` | `gitops/vault-resources/values.yaml` |
| `mini-platform-postgresql` | `charts/postgresql` | `values/postgresql-values.yaml` |
| `mini-platform-redis` | `charts/redis` | `values/redis-values.yaml` |
| `mini-platform-qdrant` | `charts/qdrant` | `values/qdrant-values.yaml` |
| `mini-platform-minio` | `charts/minio` | `values/minio-values.yaml` |
| `mini-platform-spark-operator` | `charts/spark-operator` | `values/spark-operator-values.yaml` |
| `mini-platform-keycloak` | `charts/keycloak` | `values/keycloak-values.yaml` |
| `mini-platform-langfuse` | `charts/langfuse` | `values/langfuse-values.yaml` |
| `mini-platform-mlflow` | `charts/mlflow` | `values/mlflow-values.yaml` |
| `mini-platform-trino` | `charts/trino` | `values/trino-values.yaml` |
| `mini-platform-vllm` | `charts/vllm-stack` | `values/vllm-values.yaml` |
| `mini-platform-prometheus` | `charts/prometheus` | `values/prometheus-values.yaml` |
| `mini-platform-grafana` | `charts/grafana` | `values/grafana-values.yaml` |
| `mini-platform-jupyterhub` | `charts/jupyterhub` | `values/jupyterhub-values.yaml` |
| `mini-platform-superset` | `charts/superset` | `values/superset-values.yaml` |
| `mini-platform-litellm` | `charts/litellm-helm` | `values/litellm-values.yaml` |
| `mini-platform-open-webui` | `charts/open-webui` | `values/open-webui-values.yaml` |

### 6. Complete Langfuse Integration

Once Langfuse is running, create its initial project and store the project
keys in Vault for LiteLLM:

```bash
kubectl -n "$NS" port-forward svc/langfuse-web 3000:3000

export LANGFUSE_PUBLIC_KEY='<project-public-key>'
export LANGFUSE_SECRET_KEY='<project-secret-key>'
vault kv put mini-platform/litellm-langfuse \
  LANGFUSE_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
  LANGFUSE_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
  LANGFUSE_HOST=http://langfuse-web.mini-platform.svc.cluster.local:3000
```

Vault Secrets Operator updates `litellm-langfuse`; Argo CD and Kubernetes then
converge LiteLLM with Langfuse tracing enabled.

### 7. Access And Verify Services

```bash
kubectl -n "$NS" port-forward svc/vault-ui 8200:8200
kubectl -n "$NS" port-forward svc/litellm 4000:4000
kubectl -n "$NS" port-forward svc/open-webui 8080:80
kubectl -n "$NS" port-forward svc/mlflow-tracking 5000:80
kubectl -n "$NS" port-forward svc/prometheus-server 9090:80
kubectl -n "$NS" port-forward svc/grafana 3001:80
kubectl -n "$NS" port-forward svc/proxy-public 8888:80
kubectl -n "$NS" port-forward svc/trino 8081:8080
kubectl -n "$NS" port-forward svc/superset 8088:8088
kubectl -n "$NS" port-forward svc/minio-console 9001:9001
kubectl -n "$NS" port-forward svc/keycloak 8082:80
```

LiteLLM uses
`http://vllm-router-service.mini-platform.svc.cluster.local/v1`. Superset
imports the starter Trino `tpch` catalog connection
`trino://superset@trino.mini-platform.svc.cluster.local:8080/tpch`.

This starter configuration leaves Trino unauthenticated on an internal
`ClusterIP` service. Configure TLS and authentication before exposing it.

Test the LLM gateway after retrieving its Vault-managed Kubernetes Secret:

```bash
export LITELLM_MASTER_KEY="$(kubectl -n "$NS" get secret litellm-master-key -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)"
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"local-opt125m","messages":[{"role":"user","content":"Say hello in one sentence."}]}'
```

Submit `SparkApplication` resources into `mini-platform` using
`serviceAccount: spark-operator-spark`.

### Operational Checks

```bash
kubectl -n argocd get applications
kubectl -n "$NS" get vaultstaticsecrets
kubectl -n "$NS" get pods
kubectl -n "$NS" get svc
```
