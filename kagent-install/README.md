# kagent installer

`install.sh` installs the version-pinned kagent and Substrate releases used by
this lab. It uses `config.yaml` for the kagent CLI configuration and
`values/substrate.yaml` for the checked-in Substrate overrides.

The script creates the bundled development PostgreSQL resources, certificate
identities, schemas, and connection Secrets through the supported `kagent`
installer. It also prepares the local RustFS volume and creates or updates the
`kagent-rustfs-credentials` Secret without exposing its values in the process
list.

## Prerequisites

- A current kubeconfig context with the `ate-system` and `kagent` namespaces.
  `bootstrap.sh` creates both.
- `kagent`, `jq`, and `kubectl` on `PATH`.
- `OPENAI_API_KEY`, `RUSTFS_ACCESS_KEY`, and `RUSTFS_SECRET_KEY` set in the
  environment.

`RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` must match the effective RustFS
credentials for this Substrate release. The same Secret is used by the lab's
Mimir bucket-initialization Job.

On this disposable Apple Container lab, the RustFS PVC is backed by a
root-owned node-local `hostPath`. Before installation, the script runs
`manifests/rustfs-volume-permissions.yaml` to make it writable. Its `0777`
mode is appropriate only for this local disposable environment.

## Run

```sh
./install.sh
```

The installer targets the current kubeconfig context. Re-running it upgrades
the same releases. It does not compute a cluster diff before applying changes.
