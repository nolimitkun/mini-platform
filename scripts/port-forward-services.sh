#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-mini-platform}"
ARGO_NS="${ARGO_NS:-argocd}"
PID_DIR="${PID_DIR:-${TMPDIR:-/tmp}/mini-platform-port-forwards}"

services=(
  "Argo CD|$ARGO_NS|svc/argocd-server|8080|80"
  "Open WebUI|$NS|svc/open-webui|3000|80"
  "Langfuse|$NS|svc/langfuse-web|3001|3000"
  "Grafana|$NS|svc/grafana|3002|80"
  "LiteLLM|$NS|svc/litellm|4000|4000"
  "MLflow|$NS|svc/mlflow-tracking|5000|80"
  "JupyterHub|$NS|svc/proxy-public|8000|80"
  "Superset|$NS|svc/superset|8088|8088"
  "Keycloak|$NS|svc/keycloak|8090|80"
  "MinIO Console|$NS|svc/minio-console|9001|9001"
)

mkdir -p "$PID_DIR"

stop_forwards() {
  local pid_file pid
  shopt -s nullglob
  for pid_file in "$PID_DIR"/*.pid; do
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
    fi
    rm -f "$pid_file"
  done
  shopt -u nullglob
}

case "${1:-start}" in
  stop)
    stop_forwards
    printf 'Stopped Mini Platform port forwards.\n'
    exit 0
    ;;
  restart)
    stop_forwards
    ;;
  start)
    ;;
  *)
    printf 'Usage: %s [start|stop|restart]\n' "$0" >&2
    exit 1
    ;;
esac

for spec in "${services[@]}"; do
  IFS='|' read -r name namespace resource local_port remote_port <<<"$spec"
  key="${name// /-}"
  pid_file="$PID_DIR/$key.pid"
  log_file="$PID_DIR/$key.log"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    continue
  fi
  kubectl -n "$namespace" port-forward "$resource" "$local_port:$remote_port" \
    >"$log_file" 2>&1 &
  printf '%s\n' "$!" > "$pid_file"
  printf '%-14s http://127.0.0.1:%s\n' "$name" "$local_port"
done

printf '\nLogs and PIDs: %s\n' "$PID_DIR"
