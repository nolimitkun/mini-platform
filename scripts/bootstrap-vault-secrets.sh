#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_ADDR:?Set VAULT_ADDR to the initialized Vault server address.}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN to a token allowed to write mini-platform/ secrets.}"
: "${HF_TOKEN:?Set HF_TOKEN to a Hugging Face token for pulling the vLLM model weights and tokenizer.}"

vault_cli() {
  if [[ -n "${VAULT_POD:-}" ]]; then
    : "${VAULT_NAMESPACE:?Set VAULT_NAMESPACE when VAULT_POD is configured.}"
    kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- env \
      VAULT_ADDR="$VAULT_ADDR" \
      VAULT_TOKEN="$VAULT_TOKEN" \
      vault "$@"
  else
    command vault "$@"
  fi
}

rand_b64() {
  openssl rand -base64 32 | tr -d '\n'
}

rand_hex() {
  openssl rand -hex 32
}

POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-$(rand_b64)}"
LITELLM_DB_PASSWORD="${LITELLM_DB_PASSWORD:-$(rand_hex)}"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(rand_b64)}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-$(rand_hex)}"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-lf_pk_$(rand_hex)}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-lf_sk_$(rand_hex)}"
SUPERSET_DB_PASSWORD="${SUPERSET_DB_PASSWORD:-$(rand_hex)}"
SUPERSET_REDIS_PASSWORD="${SUPERSET_REDIS_PASSWORD:-$(rand_hex)}"
SUPERSET_ADMIN_PASSWORD="${SUPERSET_ADMIN_PASSWORD:-$(rand_b64)}"

vault_cli kv put mini-platform/postgresql-credentials \
  postgres-password="$POSTGRES_ADMIN_PASSWORD" \
  password="$LITELLM_DB_PASSWORD" \
  metrics-password="$(rand_b64)"
vault_cli kv put mini-platform/litellm-dbcredentials \
  username=litellm \
  password="$LITELLM_DB_PASSWORD"
vault_cli kv put mini-platform/redis-credentials redis-password="$REDIS_PASSWORD"
vault_cli kv put mini-platform/litellm-redis \
  REDIS_HOST=redis-master.mini-platform.svc.cluster.local \
  REDIS_PORT=6379 \
  REDIS_PASSWORD="$REDIS_PASSWORD"
vault_cli kv put mini-platform/litellm-master-key PROXY_MASTER_KEY="$LITELLM_MASTER_KEY"

# Hugging Face token for pulling the vLLM model weights and tokenizer.
vault_cli kv put mini-platform/vllm-hf-token HF_TOKEN="$HF_TOKEN"

vault_cli kv put mini-platform/langfuse-app-secrets \
  salt="$(rand_b64)" \
  encryption-key="$(rand_hex)" \
  nextauth-secret="$(rand_b64)"
vault_cli kv put mini-platform/langfuse-postgresql password="$(rand_hex)"
vault_cli kv put mini-platform/langfuse-redis password="$(rand_hex)"
vault_cli kv put mini-platform/langfuse-clickhouse password="$(rand_hex)"
vault_cli kv put mini-platform/langfuse-s3 \
  root-user=langfuse \
  root-password="$(rand_b64)"
vault_cli kv put mini-platform/litellm-langfuse \
  LANGFUSE_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
  LANGFUSE_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
  LANGFUSE_HOST=http://langfuse-web.mini-platform.svc.cluster.local:3000
# Langfuse headless init user: makes the auto-provisioned org/project visible in
# the UI (org/project alone are API-only; a fresh signup joins no org).
vault_cli kv put mini-platform/langfuse-init-user \
  LANGFUSE_INIT_USER_EMAIL=admin@mini-platform.test \
  LANGFUSE_INIT_USER_NAME=Admin \
  LANGFUSE_INIT_USER_PASSWORD="$(rand_b64)"

vault_cli kv put mini-platform/mlflow-auth \
  admin-user=admin \
  admin-password="$(rand_b64)" \
  flask-server-secret-key="$(rand_hex)"
vault_cli kv put mini-platform/mlflow-postgresql \
  postgres-password="$(rand_b64)" \
  password="$(rand_b64)"
vault_cli kv put mini-platform/mlflow-minio \
  root-user=mlflow \
  root-password="$(rand_b64)"
vault_cli kv put mini-platform/grafana-admin \
  admin-user=admin \
  admin-password="$(rand_b64)"

vault_cli kv put mini-platform/superset-postgresql \
  postgres-password="$(rand_b64)" \
  password="$SUPERSET_DB_PASSWORD"
vault_cli kv put mini-platform/superset-redis redis-password="$SUPERSET_REDIS_PASSWORD"
vault_cli kv put mini-platform/superset-env \
  DB_HOST=superset-postgresql \
  DB_PORT=5432 \
  DB_USER=superset \
  DB_PASS="$SUPERSET_DB_PASSWORD" \
  DB_NAME=superset \
  REDIS_HOST=superset-redis-headless \
  REDIS_PORT=6379 \
  REDIS_PROTO=redis \
  REDIS_PASSWORD="$SUPERSET_REDIS_PASSWORD" \
  REDIS_DB=1 \
  REDIS_CELERY_DB=0 \
  SUPERSET_SECRET_KEY="$(openssl rand -base64 42 | tr -d '\n')" \
  SUPERSET_ADMIN_PASSWORD="$SUPERSET_ADMIN_PASSWORD"

vault_cli kv put mini-platform/keycloak-admin admin-password="$(rand_b64)"
vault_cli kv put mini-platform/keycloak-postgresql \
  postgres-password="$(rand_b64)" \
  password="$(rand_b64)"
vault_cli kv put mini-platform/minio-root-credentials \
  rootUser=mini-platform \
  rootPassword="$(rand_b64)"

printf '%s\n' \
  "Base Mini Platform secrets, including Langfuse project bootstrap keys, have been written to Vault."
