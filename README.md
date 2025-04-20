# Mini Platform



| Layer                     | Components                                                                 |
|---------------------------|----------------------------------------------------------------------------|
| **Use Case**              | Chat, OCR, Semantic Search, Agent, RAG ,Fine-tuning                        |
| **Discovery & Gateway**   | Authz/Authn, LB / Proxy / Route,  KV-cache                                 |
| **Engine & Model**        | Reasoning model, Base model, Embedding model, LLaMA, DeepSeek, Qwen, Mistral, Gemma|
| **Compute**               | K8S, CPU, GPU, RAM                                                         |
| **Storage**               | Blob, Disk, DB, Vector DB                                                  |
| **Platform Operations**   | Scalability, Observability, FinOps                                         |


- Base
```bash
helm install postgresql charts/postgresql -f mini-values/postgres-values.yaml
helm install redis charts/redis -f mini-values/redis-values.yaml

export POSTGRES_PASSWORD=$(kubectl get secret --namespace default postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)
kubectl run postgresql-client --rm --tty -i --restart='Never' --namespace default --image docker.io/bitnami/postgresql:17.4.0-debian-12-r15 --env="PGPASSWORD=$POSTGRES_PASSWORD" \
    --command -- psql --host postgresql -U postgres -d postgres -p 5432

init-dbs.sql

helm install litellm charts/litellm-helm -f charts/litellm-helm/values.yaml

export POD_NAME=$(kubectl get pods --namespace default -l "app.kubernetes.io/name=litellm,app.kubernetes.io/instance=litellm" -o jsonpath="{.items[0].metadata.name}")
export CONTAINER_PORT=$(kubectl get pod --namespace default $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
kubectl --namespace default port-forward $POD_NAME 4000:$CONTAINER_PORT


helm install qdrant charts/qdrant -f mini-values/qdrant-values.yaml




```
- Usecase : Text-2-SQL
```bash
export POSTGRES_PASSWORD=$(kubectl get secret --namespace default postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)
kubectl run postgresql-client --rm --tty -i --restart='Never' --namespace default --image docker.io/bitnami/postgresql:17.4.0-debian-12-r15 --env="PGPASSWORD=$POSTGRES_PASSWORD" \
    --command -- psql --host postgresql -U postgres -d postgres -p 5432

run mini-store.sql

helm install jupyterhub charts/jupyterhub

kubectl --namespace default port-forward svc/proxy-public 8080:80

upload text-2-sql/postgres-openai-standard-qdrant.ipynb
```
- Chat
```bash
helm install open-webui charts/open-webui -f mini-values/open-webui-values.yaml

export LOCAL_PORT=8010
export POD_NAME=$(kubectl get pods -n default -l "app.kubernetes.io/component=open-webui" -o jsonpath="{.items[0].metadata.name}")
export CONTAINER_PORT=$(kubectl get pod -n default $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
kubectl -n default port-forward $POD_NAME $LOCAL_PORT:$CONTAINER_PORT
```



## Data

### Jupyterhub
https://github.com/jupyterhub/helm-chart

```bash
# Let helm the command line tool know about a Helm chart repository
# that we decide to name jupyterhub.
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update

# Simplified example on how to install a Helm chart from a Helm chart repository
# named jupyterhub. See the Helm chart's documentation for additional details
# required.
helm install jupyterhub/jupyterhub --version <helm chart version>
```

## AI/LLM

### OpenWebUI
https://github.com/open-webui/helm-charts
```bash
helm repo add open-webui https://helm.openwebui.com/
helm upgrade --install open-webui open-webui/open-webui
```

### Vanna
https://github.com/vanna-ai/vanna
vanna on jupyter
https://github.com/vanna-ai/notebooks/blob/main/postgres-other-llm-qdrant.ipynb


### LiteLLM
https://github.com/BerriAI/litellm/tree/main/deploy/charts/litellm-helm

```bash
helm pull oci://ghcr.io/berriai/litellm-helm --untar
```

### VLLM production-stack
https://github.com/vllm-project/production-stack

```bash
git clone https://github.com/vllm-project/production-stack.git
cd production-stack/
helm repo add vllm https://vllm-project.github.io/production-stack
helm install vllm vllm/vllm-stack -f tutorials/assets/values-01-minimal-example.yaml
```

### Qdrant
https://github.com/qdrant/qdrant-helm

```bash
helm repo add qdrant https://qdrant.github.io/qdrant-helm
helm repo update
helm upgrade -i qdrant qdrant/qdrant
```

## Observability

### Grafana + Loki + Promtail + Mirmir + Tempo
https://github.com/grafana/helm-charts/tree/main

```bash
helm repo add grafana https://grafana.github.io/helm-charts
```
### Pormetheus
https://github.com/prometheus-community/helm-charts

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/prometheus
```

## Autha/Authz

### Keycloak
https://artifacthub.io/packages/helm/bitnami/keycloak

helm install my-release oci://registry-1.docker.io/bitnamicharts/keycloak

## Storage

### Postgresql
https://artifacthub.io/packages/helm/bitnami/postgresql
```bash
helm install my-release oci://registry-1.docker.io/bitnamicharts/postgresql
```

### Redis
https://artifacthub.io/packages/helm/bitnami/redis
```bash
helm install my-release oci://registry-1.docker.io/bitnamicharts/redis
```

### MINIO
https://github.com/minio/minio/tree/master/helm/minio
```bash
helm repo add minio https://charts.min.io/
helm install --namespace minio --set rootUser=rootuser,rootPassword=rootpass123 --generate-name minio/minio
```