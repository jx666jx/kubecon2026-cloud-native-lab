#!/usr/bin/env bash
# Maintains localhost-only kubectl port forwards for the disposable lab.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLUSTER_NAME=${CLUSTER_NAME:-kubecon-lab}
STATE_DIR="$ROOT/.run/access"

forwards=(
  "coder coder coder 7080 80 http://localhost:7080"
  "kagent-ui kagent kagent-ui 8080 8080 http://localhost:8080"
  "rustfs-console ate-system rustfs 9001 9001 http://localhost:9001"
  "mimir monitoring mimir-gateway 9009 80 http://localhost:9009/prometheus"
  "loki monitoring loki 3100 3100 http://localhost:3100"
  "tempo monitoring tempo 3200 3200 http://localhost:3200"
  "grafana monitoring grafana 3000 80 http://localhost:3000"
  "otel monitoring otel-opentelemetry-collector 4317 4317 otlp-grpc://localhost:4317"
  "otel-http monitoring otel-opentelemetry-collector 4318 4318 http://localhost:4318"
)

usage() {
  echo "Usage: $0 {start|stop|status}" >&2
}

stop_forward() {
  local name=$1 pid_file="$STATE_DIR/$1.pid" pid
  [[ -f "$pid_file" ]] || return 0
  pid=$(<"$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
}

start_forward() {
  local name=$1 namespace=$2 service=$3 local_port=$4 remote_port=$5 url=$6
  local pid_file="$STATE_DIR/$name.pid" log_file="$STATE_DIR/$name.log" pid
  if [[ -f "$pid_file" ]]; then
    pid=$(<"$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Already forwarding $name: $url"
      return 0
    fi
    rm -f "$pid_file"
  fi
  nohup kubectl --context "$CLUSTER_NAME" --namespace "$namespace" port-forward \
    "service/$service" "$local_port:$remote_port" --address 127.0.0.1 \
    >"$log_file" 2>&1 < /dev/null &
  echo $! >"$pid_file"
  echo "Forwarding $name: $url"
}

case ${1:-} in
  start)
    command -v kubectl >/dev/null || { echo "Missing required command: kubectl" >&2; exit 1; }
    mkdir -p "$STATE_DIR"
    for forward in "${forwards[@]}"; do
      read -r name namespace service local_port remote_port url <<<"$forward"
      start_forward "$name" "$namespace" "$service" "$local_port" "$remote_port" "$url"
    done
    ;;
  stop)
    for forward in "${forwards[@]}"; do
      read -r name _ <<<"$forward"
      stop_forward "$name"
    done
    ;;
  status)
    for forward in "${forwards[@]}"; do
      read -r name _ _ _ _ url <<<"$forward"
      pid_file="$STATE_DIR/$name.pid"
      if [[ -f "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
        echo "running $name: $url"
      else
        echo "stopped $name: $url"
      fi
    done
    ;;
  *) usage; exit 2 ;;
esac
