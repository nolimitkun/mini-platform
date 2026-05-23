# Integrated Mini Platform Deployment

This guide deploys the vendored Helm charts with the overlays under
[`values/`](values/). The resulting request path is:

```text
Open WebUI -> LiteLLM -> vLLM
                  |
                  +-> Langfuse traces

Prometheus -> Grafana
MLflow     -> experiment and artifact tracking
Qdrant     -> vector storage for notebook/RAG examples

Spark Operator -> Spark batch workloads
Superset       -> Trino -> analytics data sources
Keycloak       -> identity provider
MinIO          -> shared object-store endpoint

Argo CD        -> reconciles all Helm releases from Git
```

Langfuse and MLflow each deploy their own stateful dependencies. This avoids
sharing application databases with the LiteLLM gateway and keeps chart
upgrades isolated. Superset follows the same pattern for its metadata store
and cache; Trino is the query endpoint exposed to dashboards.

## Prerequisites

- Kubernetes `1.28` or newer. The current JupyterHub chart requires this.
- Helm 3 and `kubectl` configured for the target cluster.
- A Git repository URL reachable by Argo CD. Push this workspace before
  applying the root application; no Git remote is configured in this checkout.
- A default StorageClass for PostgreSQL, Qdrant, Grafana, Langfuse, MLflow,
  and Superset dependency PVCs.
- An NVIDIA-capable node and device plugin for the default vLLM values. Change
  [`values/vllm-values.yaml`](values/vllm-values.yaml) for CPU testing or a different model.

All commands below run from the repository root.

## 1. Namespace And Secrets

The values files contain no committed credentials. Generate secrets locally in
your shell and create Kubernetes Secrets:

```bash
export NS=mini-platform
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

POSTGRES_ADMIN_PASSWORD="$(openssl rand -base64 32)"
LITELLM_DB_PASSWORD="$(openssl rand -base64 32)"
REDIS_PASSWORD="$(openssl rand -base64 32)"
LITELLM_MASTER_KEY="sk-$(openssl rand -hex 32)"

kubectl -n "$NS" create secret generic postgresql-credentials \
  --from-literal=postgres-password="$POSTGRES_ADMIN_PASSWORD" \
  --from-literal=password="$LITELLM_DB_PASSWORD" \
  --from-literal=metrics-password="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic litellm-dbcredentials \
  --from-literal=username=litellm \
  --from-literal=password="$LITELLM_DB_PASSWORD"
kubectl -n "$NS" create secret generic redis-credentials \
  --from-literal=redis-password="$REDIS_PASSWORD"
kubectl -n "$NS" create secret generic litellm-redis \
  --from-literal=REDIS_HOST=redis-master.mini-platform.svc.cluster.local \
  --from-literal=REDIS_PORT=6379 \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD"
kubectl -n "$NS" create secret generic litellm-master-key \
  --from-literal=PROXY_MASTER_KEY="$LITELLM_MASTER_KEY"

kubectl -n "$NS" create secret generic langfuse-app-secrets \
  --from-literal=salt="$(openssl rand -base64 32)" \
  --from-literal=encryption-key="$(openssl rand -hex 32)" \
  --from-literal=nextauth-secret="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic langfuse-postgresql \
  --from-literal=password="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic langfuse-redis \
  --from-literal=password="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic langfuse-clickhouse \
  --from-literal=password="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic langfuse-s3 \
  --from-literal=root-user=langfuse \
  --from-literal=root-password="$(openssl rand -base64 32)"

kubectl -n "$NS" create secret generic mlflow-auth \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 32)" \
  --from-literal=flask-server-secret-key="$(openssl rand -hex 32)"
kubectl -n "$NS" create secret generic mlflow-postgresql \
  --from-literal=postgres-password="$(openssl rand -base64 32)" \
  --from-literal=password="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic mlflow-minio \
  --from-literal=root-user=mlflow \
  --from-literal=root-password="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 32)"

SUPERSET_DB_PASSWORD="$(openssl rand -base64 32)"
SUPERSET_REDIS_PASSWORD="$(openssl rand -base64 32)"
SUPERSET_ADMIN_PASSWORD="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic superset-postgresql \
  --from-literal=postgres-password="$(openssl rand -base64 32)" \
  --from-literal=password="$SUPERSET_DB_PASSWORD"
kubectl -n "$NS" create secret generic superset-redis \
  --from-literal=redis-password="$SUPERSET_REDIS_PASSWORD"
kubectl -n "$NS" create secret generic superset-env \
  --from-literal=DB_HOST=superset-postgresql \
  --from-literal=DB_PORT=5432 \
  --from-literal=DB_USER=superset \
  --from-literal=DB_PASS="$SUPERSET_DB_PASSWORD" \
  --from-literal=DB_NAME=superset \
  --from-literal=REDIS_HOST=superset-redis-headless \
  --from-literal=REDIS_PORT=6379 \
  --from-literal=REDIS_PROTO=redis \
  --from-literal=REDIS_PASSWORD="$SUPERSET_REDIS_PASSWORD" \
  --from-literal=REDIS_DB=1 \
  --from-literal=REDIS_CELERY_DB=0 \
  --from-literal=SUPERSET_SECRET_KEY="$(openssl rand -base64 42)" \
  --from-literal=SUPERSET_ADMIN_PASSWORD="$SUPERSET_ADMIN_PASSWORD"

kubectl -n "$NS" create secret generic keycloak-admin \
  --from-literal=admin-password="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic keycloak-postgresql \
  --from-literal=postgres-password="$(openssl rand -base64 32)" \
  --from-literal=password="$(openssl rand -base64 32)"
kubectl -n "$NS" create secret generic minio-root-credentials \
  --from-literal=rootUser=mini-platform \
  --from-literal=rootPassword="$(openssl rand -base64 32)"
```

Use an external secret manager or sealed secrets instead of shell-generated
secrets for a persistent production environment.

## 2. Bootstrap Argo CD

Argo CD is installed directly with Helm once to bootstrap its controllers.
After the root application is applied, Argo CD also reconciles its own chart
configuration from Git along with every platform application release.

```bash
export ARGO_NS=argocd
kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd charts/argo-cd \
  -n "$ARGO_NS" -f values/argo-cd-values.yaml --wait

kubectl -n "$ARGO_NS" port-forward svc/argocd-server 8080:80
kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

The UI is available locally at `http://localhost:8080`. The bootstrap values
use an internal `ClusterIP` service and HTTP behind the port-forward; configure
ingress, TLS, and identity integration before exposing Argo CD.

## 3. Commit And Configure The Root Application

Commit and push `charts/`, `values/`, and `gitops/` to a repository accessible
from the cluster. This checkout has no configured Git remote, so the repository
URL cannot be prefilled.

Edit [`gitops/root-application.yaml`](gitops/root-application.yaml):

1. Replace both `REPLACE_WITH_GIT_REPOSITORY_URL` values with the Git URL.
2. Set both `targetRevision` values to the branch or revision to reconcile.

Apply the root application:

```bash
kubectl apply -f gitops/root-application.yaml
kubectl -n argocd get applications
```

The root application renders [`gitops/mini-platform/`](gitops/mini-platform/)
and creates an `AppProject` and child applications with automated pruning and
self-healing enabled.

## 4. Managed Releases

Argo CD manages every top-level chart in `charts/`. The Argo CD release starts
as the bootstrap install and is adopted by its child application after the
root application is synchronized:

| Argo CD application | Chart | Values |
| --- | --- | --- |
| `mini-platform-argocd` | `charts/argo-cd` | `values/argo-cd-values.yaml` |
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

The application annotations express intended creation waves for platform
dependencies. Because each child is independently reconciled, applications
must also tolerate dependency startup delays.

## 5. Complete Langfuse Integration

The first reconciliation deploys Langfuse, but LiteLLM cannot emit traces
until a Langfuse project key exists. Port-forward Langfuse, create its initial
project, then provide the required Secret:

```bash
kubectl -n "$NS" port-forward svc/langfuse-web 3000:3000

export LANGFUSE_PUBLIC_KEY='<project-public-key>'
export LANGFUSE_SECRET_KEY='<project-secret-key>'
kubectl -n "$NS" create secret generic litellm-langfuse \
  --from-literal=LANGFUSE_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
  --from-literal=LANGFUSE_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
  --from-literal=LANGFUSE_HOST=http://langfuse-web.mini-platform.svc.cluster.local:3000
```

Argo CD automatically reconciles LiteLLM after its referenced secret is
available.

## 6. Access And Verify Services

```bash
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
`trino://superset@trino.mini-platform.svc.cluster.local:8080/tpch`. The
starter Superset overlay installs its Trino driver at startup; publish an
image with that driver preinstalled for production.

This starter configuration leaves Trino unauthenticated on an internal
`ClusterIP` service. Configure TLS and authentication before exposing it.

Test the LLM gateway:

```bash
export LITELLM_MASTER_KEY="$(kubectl -n "$NS" get secret litellm-master-key -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)"
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"local-opt125m","messages":[{"role":"user","content":"Say hello in one sentence."}]}'
```

Submit `SparkApplication` resources into `mini-platform` using
`serviceAccount: spark-operator-spark`.

## Operational Checks

```bash
kubectl -n argocd get applications
kubectl -n "$NS" get pods
kubectl -n "$NS" get svc
```
