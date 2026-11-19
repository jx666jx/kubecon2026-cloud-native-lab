# kagent Helm installation export

This directory contains the Helm commands, Atelet rollout check, and values that `kagent install` would apply. Each values file contains only the values that the CLI sets for that release. Chart defaults are not included.

Review every values file before you commit or share this directory. User-provided values are copied as supplied, and secrets in them are not detected or removed. Only the credentials in the Environment references section are replaced.

## Before you run the script

The exported installer creates the Substrate certificate and JWT identity pools
and starts the PodCertificate controller. The `substrate-atelet` release runs
before the main `substrate` release and needs its object-store credentials in
advance.

On this disposable Apple Container lab, the bundled RustFS PVC uses a node-local
`hostPath` directory that starts as root-owned. `install.sh` creates the
Substrate resources without waiting, runs
`../manifests/rustfs-volume-permissions.yaml`
as root to make the PVC writable, and then waits for the release. The `0777`
permission is acceptable only because this local volume is disposable.

When RustFS is enabled, set `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` to the effective `rustfs.accessKey` and `rustfs.secretKey` for the Substrate release: use the selected chart's defaults with the overrides in `values/substrate.yaml` and any environment references below. Create the namespace if needed, then create the Secret if it does not already exist:

```sh
kubectl create namespace ate-system
kubectl create secret generic kagent-rustfs-credentials -n ate-system \
  --from-literal=AWS_ACCESS_KEY_ID="${RUSTFS_ACCESS_KEY:?Set the configured RustFS access key}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${RUSTFS_SECRET_KEY:?Set the configured RustFS secret key}"
```

Preserve an existing Secret and verify that its keys match the Substrate values before continuing. `kagent install` checks this match; this exported script does not. When `rustfs.enabled=false`, skip the RustFS Secret. For another object store, configure both releases and prepare the Secret referenced by `objectStore.credentialsSecret` in `values/substrate-atelet.yaml`, if one is configured.

The values configure certificate authentication for the bundled database. This export does not provision the database.

## Environment references

Set these environment variables before you run `install.sh`:

- `OPENAI_API_KEY`: `providers.openAI.apiKey` in the `kagent` release
- `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY`: credentials for the bundled RustFS
  instance. They are also used by the disposable Mimir lab to access its own
  buckets in that instance.

`kagent install --provider OpenAI` reads `OPENAI_API_KEY` directly from its
environment and supplies it to the generated kagent release. The checked-in
`values/kagent.yaml` retains `${OPENAI_API_KEY}` only as an export placeholder;
Helm does not expand environment variables in YAML. Always use `install.sh`
rather than applying that values file directly, or Helm would install the
literal placeholder text.

## Run the script

```sh
sh ./install.sh
```

The script installs the releases in order in the current kubeconfig context. Running it again upgrades the same releases. The export did not check the cluster or compute a diff.
