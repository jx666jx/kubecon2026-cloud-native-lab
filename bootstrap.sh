#!/usr/bin/env bash
# Applies root-level manifests in this order: storage, Coder DB, kagent/RustFS,
# Mimir buckets, then Mimir/Kafka and the remaining LGTM components.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLUSTER_NAME=${CLUSTER_NAME:-kubecon-lab}
CLUSTER_CPUS=${CLUSTER_CPUS:-6}
CLUSTER_MEMORY=${CLUSTER_MEMORY:-20g}
KUBERNETES_NODE_IMAGE=${KUBERNETES_NODE_IMAGE:-docker.io/kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}

for command in container kubectl helm openssl kagent jq; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done
: "${OPENAI_API_KEY:?Set OPENAI_API_KEY (for kagent)}"
: "${RUSTFS_ACCESS_KEY:?Set RUSTFS_ACCESS_KEY}"
: "${RUSTFS_SECRET_KEY:?Set RUSTFS_SECRET_KEY}"

# 1. Recreate the single-node Kubernetes cluster. This intentionally removes
#    any prior ephemeral lab state.
echo '==>'
echo '==> 1/6: Creating the Kubernetes cluster'
echo '==>'
"$ROOT/access.sh" stop >/dev/null 2>&1 || true
container cluster delete --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
container cluster create --name "$CLUSTER_NAME" --cpus "$CLUSTER_CPUS" --memory "$CLUSTER_MEMORY" --node-image "$KUBERNETES_NODE_IMAGE"
kubectl config use-context "$CLUSTER_NAME" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=5m

# 2. Create the statically provisioned local volumes and all target namespaces.
echo '==>'
echo '==> 2/6: Creating local storage and namespaces'
echo '==>'
kubectl apply -f "$ROOT/manifests/00-local-storage.yaml"
for namespace in coder ate-system kagent monitoring; do
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
done

# 3. Install Coder and its small in-cluster PostgreSQL database.
echo '==>'
echo '==> 3/6: Installing Coder and PostgreSQL'
echo '==>'
CODER_DB_PASSWORD=${CODER_DB_PASSWORD:-$(openssl rand -base64 32 | tr -d '\n' | tr '/+' '_-')}
kubectl -n coder create secret generic coder-postgres-auth --from-literal=password="$CODER_DB_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n coder create secret generic coder-db-url --from-literal=url="postgres://coder:${CODER_DB_PASSWORD}@coder-postgres.coder.svc:5432/coder?sslmode=disable" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$ROOT/manifests/10-coder-postgres.yaml"
kubectl -n coder rollout status deployment/coder-postgres --timeout=5m
helm upgrade --install coder oci://ghcr.io/coder/chart/coder --version 2.38.6 --namespace coder --create-namespace --wait --timeout 10m -f "$ROOT/values/coder.yaml"

# 4. Install kagent/Substrate. It also installs RustFS, which is the shared
#    S3-compatible object store for kagent and the observability stack.
echo '==>'
echo '==> 4/6: Installing kagent, Substrate, and RustFS'
echo '==>'
export OPENAI_API_KEY RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY
(cd "$ROOT/kagent-install" && ./install.sh)
kubectl -n ate-system delete job mimir-rustfs-buckets --ignore-not-found
kubectl apply -f "$ROOT/manifests/20-mimir-rustfs-buckets.yaml"
kubectl -n ate-system wait --for=condition=complete job/mimir-rustfs-buckets --timeout=5m

# 5. Install Mimir (including its single Kafka broker) using RustFS storage.
#    Credentials are supplied from temporary files so they do not appear in
#    the process list or Helm command output.
echo '==>'
echo '==> 5/6: Installing Mimir and Kafka'
echo '==>'
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
mimir_secret_dir=$(mktemp -d)
trap 'rm -rf "$mimir_secret_dir"' EXIT
printf '%s' "$RUSTFS_ACCESS_KEY" > "$mimir_secret_dir/access-key"
printf '%s' "$RUSTFS_SECRET_KEY" > "$mimir_secret_dir/secret-key"
helm upgrade --install mimir grafana/mimir-distributed --version 6.2.2 --namespace monitoring --create-namespace --wait --timeout 15m -f "$ROOT/values/mimir.yaml" --set-file mimir.structuredConfig.blocks_storage.s3.access_key_id="$mimir_secret_dir/access-key" --set-file mimir.structuredConfig.blocks_storage.s3.secret_access_key="$mimir_secret_dir/secret-key" --set-file mimir.structuredConfig.ruler_storage.s3.access_key_id="$mimir_secret_dir/access-key" --set-file mimir.structuredConfig.ruler_storage.s3.secret_access_key="$mimir_secret_dir/secret-key" --set-file mimir.structuredConfig.alertmanager_storage.s3.access_key_id="$mimir_secret_dir/access-key" --set-file mimir.structuredConfig.alertmanager_storage.s3.secret_access_key="$mimir_secret_dir/secret-key"
rm -rf "$mimir_secret_dir"
trap - EXIT
# 6. Finish the LGTM stack and expose OTLP ingestion for OTel/OTTL testing.
echo '==>'
echo '==> 6/6: Installing Loki, Tempo, Grafana, and the OTel Collector'
echo '==>'
helm upgrade --install loki grafana/loki --version 7.6.0 --namespace monitoring --wait --timeout 10m -f "$ROOT/values/loki.yaml"
helm upgrade --install tempo grafana/tempo --version 1.24.4 --namespace monitoring --wait --timeout 10m -f "$ROOT/values/tempo.yaml"
helm upgrade --install grafana grafana/grafana --version 10.5.15 --namespace monitoring --wait --timeout 10m -f "$ROOT/values/grafana.yaml"
helm upgrade --install otel open-telemetry/opentelemetry-collector --version 0.179.1 --namespace monitoring --wait --timeout 10m -f "$ROOT/values/otel-collector.yaml"

echo "Lab is ready in context: $CLUSTER_NAME"
kubectl get pods -A
"$ROOT/access.sh" start
echo "Use ./access.sh status or ./access.sh stop to manage localhost access."
echo "Grafana: http://localhost:3000"
echo "Grafana admin user: admin"
printf 'Grafana admin password: '
kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 --decode
echo
