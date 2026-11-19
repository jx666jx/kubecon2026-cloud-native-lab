#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
: "${OPENAI_API_KEY:?Set OPENAI_API_KEY before running this script}"
: "${RUSTFS_ACCESS_KEY:?Set RUSTFS_ACCESS_KEY before running this script}"
: "${RUSTFS_SECRET_KEY:?Set RUSTFS_SECRET_KEY before running this script}"
command -v kagent >/dev/null || { echo "Missing required command: kagent" >&2; exit 1; }
command -v jq >/dev/null || { echo "Missing required command: jq" >&2; exit 1; }

# Apple Container creates this hostPath as root. RustFS runs unprivileged, so
# fix the backing directory before kagent's supported installer creates its PVC.
echo "Preparing permissions on the local RustFS volume..."
kubectl -n ate-system delete job rustfs-volume-permissions --ignore-not-found --wait=true
kubectl apply -f "$repo_root/manifests/rustfs-volume-permissions.yaml"
kubectl -n ate-system wait --for=condition=complete job/rustfs-volume-permissions --timeout=5m

# Unlike the dry-run Helm export, this creates the bundled development
# PostgreSQL, its certificate identities, schemas, and all four connection
# Secrets before installing Substrate and kagent. The CLI does not interpolate
# shell variables in values files, so add the RustFS credentials as a private
# runtime-only override instead of committing them to the repository.
umask 077
install_tmp=$(mktemp -d)
trap 'rm -rf "$install_tmp"' EXIT HUP INT TERM
access_key_file="$install_tmp/access-key"
secret_key_file="$install_tmp/secret-key"
runtime_values="$install_tmp/rustfs-values.json"
runtime_config="$install_tmp/kagent-install.json"
printf '%s' "$RUSTFS_ACCESS_KEY" > "$access_key_file"
printf '%s' "$RUSTFS_SECRET_KEY" > "$secret_key_file"
kubectl -n ate-system create secret generic kagent-rustfs-credentials \
  --from-file=AWS_ACCESS_KEY_ID="$access_key_file" \
  --from-file=AWS_SECRET_ACCESS_KEY="$secret_key_file" \
  --dry-run=client -o yaml | kubectl apply -f -
# The chart recreates this Job when credentials change, but Kubernetes does not
# permit patching a Job pod template after it has run.
kubectl -n ate-system delete job rustfs-bucket-init --ignore-not-found --wait=true
jq -n --arg access "$RUSTFS_ACCESS_KEY" --arg secret "$RUSTFS_SECRET_KEY" \
  '{rustfs: {accessKey: $access, secretKey: $secret}}' > "$runtime_values"
jq --arg base_values "$script_dir/values/substrate.yaml" --arg runtime_values "$runtime_values" \
  '.install.substrate.valuesFiles = [$base_values, $runtime_values]' \
  "$script_dir/config.yaml" > "$runtime_config"
kagent --config "$runtime_config" install --provider OpenAI --timeout 10m
