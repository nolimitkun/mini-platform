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
| `gitops/ingress-resources/` | Local browser-facing `.test` ingress routes |
| `gitops/root-application.yaml` | Root Argo CD Application bootstrap manifest |
| `scripts/deploy-minikube.sh` | Creates or resets Minikube and automates Argo/Vault bootstrap |
| `scripts/bootstrap-vault-secrets.sh` | Writes generated initial credentials to Vault |
| `scripts/port-forward-services.sh` | Starts host-local browser service port forwards |
| `tools/` | Optional Kubernetes utility workloads, such as network diagnostics |

## Architecture

```text
Open WebUI -> LiteLLM -> vLLM
                  |
                  +-> Langfuse traces

Vault -> Vault Secrets Operator -> Kubernetes Secrets -> platform workloads

Ingress NGINX -> Open WebUI, LiteLLM, Langfuse, MLflow, Grafana, JupyterHub,
                 Superset, MinIO Console, Keycloak, and Argo CD

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

This is a GitOps deployment: after changing an overlay or a GitOps chart,
commit and push it to the revision configured in
[`gitops/root-application.yaml`](gitops/root-application.yaml). Argo CD does
not read changes that exist only in a local working tree.

### Prerequisites

- Kubernetes `1.28` or newer. The current JupyterHub chart requires this.
- Helm 3, `kubectl`, `git`, `jq`, and `openssl` for the automated Minikube
  workflow. The manual Vault steps additionally require the Vault CLI.
- Network access from Argo CD to this repository, or a pushed fork containing
  any local configuration changes.
- A default StorageClass for platform PVCs, including Vault.
- An NVIDIA-capable node and device plugin for the default vLLM values. Change
  [`values/vllm-values.yaml`](values/vllm-values.yaml) for CPU testing.

All commands below run from the repository root.

### Recommended: Automated Minikube Deployment

For a GPU-enabled Minikube host with a pushed Git repository available to
Argo CD, run:

```bash
./scripts/deploy-minikube.sh \
  --repo-url https://github.com/<owner>/mini-platform.git \
  --revision main
```

To clean an existing `mini-platform` profile and rebuild it from the
beginning, add `--reset`. The script backs up any existing Vault
initialization JSON before deleting the profile.

```bash
./scripts/deploy-minikube.sh --reset \
  --repo-url https://github.com/<owner>/mini-platform.git \
  --revision main
```

When the checkout exists only on the Minikube host, or the remote repository
is private and no Argo CD credential has been configured, deploy through a
private cluster-internal Git source:

```bash
git status --short
# Commit the configuration intended for deployment before continuing.
./scripts/deploy-minikube.sh --reset --local-source
```

`--local-source` rejects staged, modified, or untracked files because Argo CD
reconciles Git commits. It creates a persistent `gitops-source/git-source`
service reachable only within the cluster and pins Argo CD to the current
commit. Re-run the command after committing a later configuration update to
refresh that source.

The deployment script:

- creates or starts the `mini-platform` Minikube profile with NVIDIA GPU
  passthrough by default;
- enables dynamic storage and ingress;
- installs Argo CD and configures the root Application source;
- initializes and unseals Vault, retaining recovery material at
  `~/.vault-mini-platform-init.json`;
- configures Kubernetes authentication and seeds initial credentials; and
- waits for Vault Secrets Operator synchronization.

On a Linux host using rootless Docker, the script warns when user lingering is
disabled; it does not change that system setting automatically.

Use `--no-gpu` only with a corresponding CPU-capable vLLM overlay. Re-running
an initialized deployment keeps existing service credentials; pass
`--rotate-secrets` only when credential replacement is intended.

To expose the browser services directly on the Minikube host:

```bash
./scripts/port-forward-services.sh
```

For a remote host, forward the printed host ports over SSH, for example:

```bash
ssh -N \
  -L 3000:127.0.0.1:3000 \
  -L 3001:127.0.0.1:3001 \
  -L 4000:127.0.0.1:4000 \
  user@minikube-host
```

If Minikube uses rootless Docker on a remote Linux host, ensure the user's
Docker service is configured to remain running without an active login
session. Otherwise the cluster may stop when the SSH session exits.

### Manual Deployment Steps

### Optional: Prepare A Minikube Cluster

Minikube's minimum resources are not sufficient for this multi-service stack.
For a local evaluation cluster without GPU access, allocate additional CPU,
memory, and storage:

```bash
minikube start -p mini-platform \
  --driver=docker \
  --kubernetes-version=v1.28.0 \
  --cpus=8 \
  --memory=16384 \
  --disk-size=100g
```

The default [`values/vllm-values.yaml`](values/vllm-values.yaml) requests an
NVIDIA GPU. On a host with NVIDIA container runtime support and a compatible
Minikube driver, use this startup command instead:

```bash
minikube start -p mini-platform \
  --driver=docker \
  --container-runtime=docker \
  --gpus=nvidia \
  --kubernetes-version=v1.28.0 \
  --cpus=8 \
  --memory=16384 \
  --disk-size=100g
```

For a Minikube host without GPU access, adjust the vLLM chart overlay before
deploying; the checked-in default vLLM release will otherwise remain
unschedulable.

After starting the selected cluster profile, verify dynamic storage:

```bash
kubectl config use-context mini-platform
kubectl get nodes
kubectl get storageclass
```

Minikube normally enables a default dynamic storage provisioner. If
`kubectl get storageclass` does not show a default StorageClass, enable its
storage addons:

```bash
minikube addons enable storage-provisioner -p mini-platform
minikube addons enable default-storageclass -p mini-platform
kubectl get storageclass
```

Enable the Minikube ingress controller. The checked-in ingress resources route
browser-facing services through `.test` hostnames:

```bash
minikube addons enable ingress -p mini-platform
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=120s
kubectl -n ingress-nginx patch service ingress-nginx-controller \
  --type merge -p '{"spec":{"type":"LoadBalancer"}}'
```

With the Docker driver on macOS or Windows, keep one tunnel running for the
ingress controller instead of one port-forward for every platform service:

```bash
minikube tunnel -p mini-platform
```

In another terminal, after the tunnel assigns an external IP, map the local
development hostnames:

```bash
export INGRESS_IP="$(kubectl -n ingress-nginx get service ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
printf '%s %s\n' "$INGRESS_IP" \
  'argocd.test open-webui.test litellm.test langfuse.test mlflow.test grafana.test jupyterhub.test superset.test minio.test keycloak.test' \
  | sudo tee -a /etc/hosts
```

On hosts that can reach `minikube ip` directly, Minikube's `ingress-dns` addon
can be used instead of adding host entries.

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

kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

After preparing Minikube ingress, the Argo CD UI is available at
`http://argocd.test`. The local route uses HTTP; configure TLS and identity
integration before exposing it outside a development cluster.

### 3. Apply The Root Application

[`gitops/root-application.yaml`](gitops/root-application.yaml) points to this
repository's `main` branch. When deploying a fork or another revision, update
both `spec.source.repoURL` / `spec.source.targetRevision` and the matching
`spec.source.helm.parameters` values. The first pair tells Argo CD where to
render the app-of-apps chart; the parameter pair tells that chart where every
managed application reads its Helm chart and values.

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

kubectl -n "$NS" port-forward svc/vault-ui 8200:8200
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

The bootstrap script writes project API keys to
`mini-platform/litellm-langfuse`. Langfuse uses its headless initialization
environment variables to create the starter organization and project with
those keys, while LiteLLM consumes the same Vault-managed secret. No browser
setup is required before LiteLLM becomes ready.

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
| `mini-platform-ingress-resources` | `gitops/ingress-resources` | `gitops/ingress-resources/values.yaml` |

### 6. Verify Langfuse Integration

Langfuse automatically creates the `mini-platform` organization and `litellm`
project from the Vault-managed project keys written in step 4. Vault Secrets
Operator exposes those same keys to LiteLLM for tracing.

Verify that the secret synchronized and both applications are healthy:

```bash
kubectl -n "$NS" get vaultstaticsecret litellm-langfuse
kubectl -n "$NS" get pods -l app.kubernetes.io/instance=langfuse
kubectl -n "$NS" get pods -l app.kubernetes.io/name=litellm
```

### 7. Access And Verify Services

With the Minikube ingress tunnel running, use these local entry points:

| Service | Local endpoint |
| --- | --- |
| Argo CD | `http://argocd.test` |
| Open WebUI | `http://open-webui.test` |
| LiteLLM API | `http://litellm.test` |
| Langfuse | `http://langfuse.test` |
| MLflow | `http://mlflow.test` |
| Grafana | `http://grafana.test` |
| JupyterHub | `http://jupyterhub.test` |
| Superset | `http://superset.test` |
| MinIO Console | `http://minio.test` |
| Keycloak | `http://keycloak.test` |

Vault, Prometheus, Trino, databases, and vLLM remain internal by default.
Use a targeted port-forward for Vault administration during initialization:

```bash
kubectl -n "$NS" port-forward svc/vault-ui 8200:8200
```

The bootstrap script generates browser-service credentials in Vault rather
than printing them. With `VAULT_ADDR` and an authorized `VAULT_TOKEN` set,
retrieve initial logins as needed:

```bash
vault kv get -field=admin-password mini-platform/grafana-admin
vault kv get -field=admin-password mini-platform/mlflow-auth
vault kv get -field=SUPERSET_ADMIN_PASSWORD mini-platform/superset-env
vault kv get -field=admin-password mini-platform/keycloak-admin
vault kv get -field=rootPassword mini-platform/minio-root-credentials
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
curl http://litellm.test/v1/chat/completions \
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
