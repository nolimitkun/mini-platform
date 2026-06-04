# Mini Platform

Mini Platform is a self-contained Kubernetes reference stack for local LLM
inference, LLM observability, experiment tracking, and SQL analytics. It vendors
upstream Helm charts under [`charts/`](charts/), layers integration-focused
overlays on top of them in [`values/`](values/), and uses **Argo CD** to
reconcile the whole stack from Git.

Two principles shape the design:

- **GitOps.** Argo CD is the only thing that deploys workloads. After you change
  an overlay or GitOps chart, commit and push it — Argo CD does not read a local
  working tree.
- **No credentials in Git.** **Vault** is the source of truth for application
  credentials, and **Vault Secrets Operator (VSO)** materializes only the
  Kubernetes Secrets each release needs.

## Architecture

The default AI request path is:

```text
Open WebUI ──▶ LiteLLM ──▶ vLLM Router ──▶ vLLM
                  │
                  └──▶ Langfuse (request traces)
```

Open WebUI talks to LiteLLM as an OpenAI-compatible gateway; LiteLLM routes the
`local-opt125m` model to the vLLM router serving `facebook/opt-125m`, and emits
traces to Langfuse using project keys it shares with Langfuse through Vault.

Supporting subsystems:

```text
Vault ──▶ Vault Secrets Operator ──▶ Kubernetes Secrets ──▶ workloads

Ingress NGINX ──▶ Open WebUI, LiteLLM, Langfuse, MLflow, Grafana,
                  JupyterHub, Superset, MinIO Console, Keycloak, Argo CD

Prometheus     ──▶ Grafana            (metrics + dashboards)
MLflow                                (experiment + artifact tracking)
Qdrant                                (vector store for notebook/RAG examples)
Spark Operator ──▶ Spark batch jobs
Superset       ──▶ Trino ──▶ analytics sources
Keycloak                              (identity provider)
MinIO                                 (shared S3-compatible object store)
Argo CD        ──▶ reconciles every release + secret mapping from Git
```

Langfuse, MLflow, and Superset each deploy their own isolated stateful
dependencies so their upgrades stay independent of the LiteLLM gateway. Vault
runs as a single persistent standalone server in this starter configuration and
**must be initialized and unsealed before dependent applications turn healthy.**

## Repository Layout

| Path | Purpose |
| --- | --- |
| `charts/` | Vendored upstream Helm charts (Argo CD, Vault, VSO, and every platform component) |
| `values/` | Mini Platform integration overlays — no committed credentials |
| `gitops/mini-platform/` | Argo CD app-of-apps chart defining every managed release and its sync wave |
| `gitops/vault-resources/` | `VaultStaticSecret` mappings and the VSO auth service account |
| `gitops/ingress-resources/` | Browser-facing `.test` ingress routes |
| `gitops/root-application.yaml` | Root Argo CD Application that bootstraps the app-of-apps |
| `scripts/deploy-minikube.sh` | Creates/resets Minikube and automates the Argo CD + Vault bootstrap |
| `scripts/bootstrap-vault-secrets.sh` | Generates and writes initial credentials into Vault |
| `scripts/port-forward-services.sh` | Host-local or LAN port forwards for browser services |
| `scripts/set-repo.sh` | Repoints the GitOps config (repoURL/revision) at a fork in one command |
| `scripts/validate-gitops.sh` | Lints/renders the GitOps charts and shellchecks the scripts; run in CI too |
| `tools/` | Optional utility workloads (e.g. network diagnostics) |

## Deployment

All commands run from the repository root.

> **GitOps reminder.** The stack reconciles from a specific `repoURL` and
> `targetRevision`. When deploying a fork or a different branch, repoint every
> reference in one step, then commit and push before syncing:
>
> ```bash
> ./scripts/set-repo.sh --repo-url https://github.com/<owner>/mini-platform.git --revision main
> ```
>
> This rewrites [`gitops/root-application.yaml`](gitops/root-application.yaml),
> [`gitops/mini-platform/values.yaml`](gitops/mini-platform/values.yaml), and the
> `scripts/deploy-minikube.sh` defaults so they stay in sync.

### Prerequisites

- Kubernetes `1.28` or newer (required by the current JupyterHub chart).
- `helm` 3, `kubectl`, `git`, `jq`, and `openssl` for the automated workflow.
  The manual Vault steps additionally need the Vault CLI.
- Network access from Argo CD to this repository (or to a pushed fork carrying
  your changes).
- A default `StorageClass` for platform PVCs, including Vault.
- An NVIDIA-capable node and device plugin for the default vLLM values. Edit
  [`values/vllm-values.yaml`](values/vllm-values.yaml) for CPU-only testing.

### Recommended: Automated Minikube Deployment

On a GPU-enabled Minikube host, with the repository pushed somewhere Argo CD can
reach:

```bash
./scripts/deploy-minikube.sh \
  --repo-url https://github.com/<owner>/mini-platform.git \
  --revision main
```

The script:

- creates/starts the `mini-platform` Minikube profile with NVIDIA GPU
  passthrough by default, and enables the storage and ingress addons;
- installs Argo CD and configures the root Application source;
- initializes and unseals Vault, retaining recovery material at
  `~/.vault-mini-platform-init.json`;
- configures Kubernetes auth and seeds initial credentials; and
- waits for VSO secret synchronization and platform pods to become ready.

Useful flags:

| Flag | Effect |
| --- | --- |
| `--reset` | Delete and recreate the profile first (backs up any existing Vault init JSON) |
| `--local-source` | Serve this committed checkout through a cluster-only Git service instead of a remote |
| `--no-gpu` | Start without GPU passthrough (use only with a CPU-capable vLLM overlay) |
| `--rotate-secrets` | Rewrite Vault credentials on an already-initialized Vault |
| `--skip-image-preload` | Skip loading host-cached images into Minikube |
| `--skip-workload-wait` | Return after secret sync instead of waiting for pods |

Re-running an initialized deployment keeps existing credentials; pass
`--rotate-secrets` only when you intend to replace them.

**Deploying from a local checkout.** When the repository lives only on the
Minikube host, or it is private and Argo CD has no credential, use
`--local-source`:

```bash
git status --short   # must be clean — Argo CD reconciles commits, not the working tree
./scripts/deploy-minikube.sh --reset --local-source
```

This creates a persistent, cluster-internal `gitops-source/git-source` service
and pins Argo CD to the current commit. Re-run it after committing later
changes to refresh the source.

**Rootless Docker on Linux.** If Minikube uses rootless Docker on a remote host,
ensure the user's Docker service keeps running without an active login (user
lingering). Otherwise the cluster stops when the SSH session exits — the script
warns about this but does not change the setting for you.

### Manual Deployment Steps

#### Optional: Prepare a Minikube cluster

Minikube's defaults are too small for this stack. For a CPU-only evaluation
cluster:

```bash
minikube start -p mini-platform \
  --driver=docker \
  --kubernetes-version=v1.28.0 \
  --cpus=8 --memory=16384 --disk-size=100g
```

The default [`values/vllm-values.yaml`](values/vllm-values.yaml) requests an
NVIDIA GPU. On a host with NVIDIA container runtime support, start with GPU
passthrough instead:

```bash
minikube start -p mini-platform \
  --driver=docker --container-runtime=docker --gpus=nvidia \
  --kubernetes-version=v1.28.0 \
  --cpus=8 --memory=16384 --disk-size=100g
```

Without GPU access, adjust the vLLM overlay before deploying or its pod stays
unschedulable. Then confirm a default StorageClass exists:

```bash
kubectl config use-context mini-platform
kubectl get nodes
kubectl get storageclass
# If no default is shown:
minikube addons enable storage-provisioner -p mini-platform
minikube addons enable default-storageclass -p mini-platform
```

Enable the ingress controller (the checked-in routes use `.test` hostnames):

```bash
minikube addons enable ingress -p mini-platform
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=120s
kubectl -n ingress-nginx patch service ingress-nginx-controller \
  --type merge -p '{"spec":{"type":"LoadBalancer"}}'
```

With the Docker driver on macOS or Windows, keep one tunnel running for the
ingress controller rather than a port-forward per service:

```bash
minikube tunnel -p mini-platform
```

Once the tunnel assigns an external IP, map the local hostnames:

```bash
export INGRESS_IP="$(kubectl -n ingress-nginx get service ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
printf '%s %s\n' "$INGRESS_IP" \
  'argocd.test open-webui.test litellm.test langfuse.test mlflow.test grafana.test jupyterhub.test superset.test minio.test keycloak.test' \
  | sudo tee -a /etc/hosts
```

On hosts that can reach `minikube ip` directly, the `ingress-dns` addon is an
alternative to editing `/etc/hosts`.

#### 1. Create the namespace

```bash
export NS=mini-platform
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
```

Do **not** create workload credential Secrets by hand — VSO creates them after
Vault is configured in step 4.

#### 2. Bootstrap Argo CD

Argo CD is installed once with Helm; afterward it reconciles its own chart and
every platform release.

```bash
export ARGO_NS=argocd
kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd charts/argo-cd \
  -n "$ARGO_NS" -f values/argo-cd-values.yaml --wait

kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

With ingress prepared, the Argo CD UI is at `http://argocd.test`. The local
route is plain HTTP; configure TLS and identity integration before exposing it
beyond a development cluster.

#### 3. Apply the root Application

[`gitops/root-application.yaml`](gitops/root-application.yaml) renders the
app-of-apps chart, which in turn creates one Argo CD Application per release.
When deploying a fork or other revision, run `scripts/set-repo.sh` (above) so
both `spec.source.repoURL` / `spec.source.targetRevision` **and** the matching
`spec.source.helm.parameters` are updated together — the first pair tells Argo CD
where to find the app-of-apps chart; the parameters tell that chart where every
managed app reads its chart and values.

```bash
kubectl apply -f gitops/root-application.yaml
kubectl -n argocd get applications
```

Sync waves order the rollout: Argo CD and Vault/VSO come first, then secret
mappings and stateful dependencies, then the application tier, and finally
LiteLLM, Open WebUI, and ingress. Early reconciliations may show
missing-secret failures until Vault is initialized in step 4 and the
`VaultStaticSecret` resources synchronize.

#### 4. Initialize Vault and seed secrets

The starter overlay installs one persistent Vault server reachable only over
cluster networking and port-forward. Initialize it once and store the unseal key
and root token **outside this repository**.

```bash
umask 077
kubectl -n "$NS" exec vault-0 -- vault operator init \
  -key-shares=1 -key-threshold=1 -format=json > "$HOME/.vault-mini-platform-init.json"

export VAULT_UNSEAL_KEY='<unseal-key-from-init-output>'
kubectl -n "$NS" exec vault-0 -- vault operator unseal "$VAULT_UNSEAL_KEY"

kubectl -n "$NS" port-forward svc/vault-ui 8200:8200
```

In a second terminal, configure the KV store and Kubernetes auth that VSO uses,
then seed credentials:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN='<initial-root-token-from-init-output>'

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

`bootstrap-vault-secrets.sh` generates random credentials for every component
and writes them under `mini-platform/`. Notably, it writes shared Langfuse
project keys to `mini-platform/litellm-langfuse`: Langfuse's headless init
provisions the starter organization and project from those keys, and LiteLLM
consumes the same Vault-managed secret for tracing — no browser setup is needed
before LiteLLM is ready.

VSO then creates the destination Kubernetes Secrets. Check synchronization:

```bash
kubectl -n "$NS" get vaultstaticsecrets
kubectl -n "$NS" get secrets
```

> This starter configuration uses manual unseal and disables in-cluster TLS. For
> production, configure TLS, auto-unseal, tightly scoped tokens, backups, and an
> HA storage backend before storing real credentials.

#### 5. Managed releases

The app-of-apps reconciles these applications (and the `vault-resources` and
`ingress-resources` GitOps charts):

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

## Accessing Services

### Via ingress

With ingress (and the Minikube tunnel, where applicable) running:

| Service | Endpoint |
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

Vault, Prometheus, Trino, the databases, and vLLM stay cluster-internal by
default. For Vault administration, use a targeted port-forward:

```bash
kubectl -n "$NS" port-forward svc/vault-ui 8200:8200
```

### Via port-forward

Run the port-forward script on the host running Minikube. For host-local access
on `127.0.0.1`:

```bash
./scripts/port-forward-services.sh
```

For LAN access from other machines on a trusted network (listens on all
interfaces and prints the detected LAN IP):

```bash
./scripts/port-forward-services.sh --mode lan
```

If LAN IP autodetection picks the wrong interface, pass it explicitly:

```bash
./scripts/port-forward-services.sh restart --mode lan --address 192.168.1.54
```

Services are then reachable at endpoints like `http://192.168.1.54:8080`. Stop
the forwards with `./scripts/port-forward-services.sh stop`.

### Retrieving credentials

The bootstrap script stores browser-service logins in Vault rather than printing
them. With `VAULT_ADDR` and an authorized `VAULT_TOKEN` set:

```bash
vault kv get -field=admin-password mini-platform/grafana-admin
vault kv get -field=admin-password mini-platform/mlflow-auth
vault kv get -field=SUPERSET_ADMIN_PASSWORD mini-platform/superset-env
vault kv get -field=admin-password mini-platform/keycloak-admin
vault kv get -field=rootPassword mini-platform/minio-root-credentials
```

## Verifying the Stack

**Langfuse + LiteLLM tracing.** Langfuse creates the `mini-platform` org and
`litellm` project from the Vault-managed keys written in step 4; VSO exposes the
same keys to LiteLLM. Confirm the secret synced and both apps are healthy:

```bash
kubectl -n "$NS" get vaultstaticsecret litellm-langfuse
kubectl -n "$NS" get pods -l app.kubernetes.io/instance=langfuse
kubectl -n "$NS" get pods -l app.kubernetes.io/name=litellm
```

**LLM gateway smoke test.** LiteLLM serves the `local-opt125m` model backed by
`http://vllm-router-service.mini-platform.svc.cluster.local/v1`:

```bash
export LITELLM_MASTER_KEY="$(kubectl -n "$NS" get secret litellm-master-key \
  -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)"
curl http://litellm.test/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"local-opt125m","messages":[{"role":"user","content":"Say hello in one sentence."}]}'
```

**Analytics.** Superset imports the starter Trino `tpch` catalog at
`trino://superset@trino.mini-platform.svc.cluster.local:8080/tpch`. Trino is
unauthenticated on an internal `ClusterIP` service in this starter config —
configure TLS and authentication before exposing it.

**Spark.** Submit `SparkApplication` resources into `mini-platform` with
`serviceAccount: spark-operator-spark`.

**General health:**

```bash
kubectl -n argocd get applications
kubectl -n "$NS" get vaultstaticsecrets
kubectl -n "$NS" get pods
kubectl -n "$NS" get svc
```

## Validating Changes

Before committing a change to the GitOps wiring, run the same checks CI runs
(`.github/workflows/validate.yaml`):

```bash
./scripts/validate-gitops.sh
```

It confirms every `chartPath`/`valuesFile` referenced by the app-of-apps exists,
lints and renders the three `gitops/` charts, runs `kubeconform` over the
rendered manifests, and `shellcheck`s the scripts. `kubeconform` and
`shellcheck` are used if installed and skipped otherwise; CI installs both.

## Production Hardening

This repository is a local reference stack. Before any non-development use, at
minimum: enable in-cluster TLS, replace Vault manual unseal with an auto-unseal
mechanism and HA storage, scope administrative tokens tightly, add backups, and
put authentication in front of Argo CD, Trino, and the other exposed services.
