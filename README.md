# KubeCon 2026

KubeCon 2026 North America gave me quite a few things to try for myself.

Apple Container's local Kubernetes clusters, `kagent`, `Coder`, and OpenTelemetry (OTLP/OTTL) all sounded worth investigating.

This repository is all that: a local Kubernetes environment on macOS that brings together kagent, Coder, and an LGTM stack—a place to try each of them while experimenting with OTTL transformations and traces in a realistic telemetry pipeline.

The cluster is currently ephemeral because Apple Container clusters are not reliably restartable after sleep, logout, reboot, or a Container service restart: their control-plane address can change and leave the kubeconfig stale.
The original control-plane IP-rotation failure is documented in [apple/container#2156](https://github.com/apple/container/issues/2156), and [apple/container#2440](https://github.com/apple/container/issues/2440) tracks the missing cluster stop/start lifecycle.
Nothing in this repository relies on resuming a stopped cluster; rerun the bootstrap script to delete the old cluster and build a fresh lab.

## Quick start

### Prerequisites

- Install Apple Container, helm, jq, kagent, kubectl and openssl:

```sh
brew install container helm jq kagent kubectl openssl
```

- **24 GB of host RAM** — the default cluster uses 6 CPUs and 20 GiB of memory.
- **An OpenAI API key** — required by `kagent`.

Create and update a local credential file from the example:

```sh
cp .env.example .env
# Edit .env and set OPENAI_API_KEY, RUSTFS_ACCESS_KEY, and RUSTFS_SECRET_KEY.
set -a; . ./.env; set +a
./bootstrap.sh
```

The credential file is intentionally not committed. `CODER_DB_PASSWORD` is
optional; a fresh value is generated for each bootstrap when it is unset.

To explicitly remove the lab:

```sh
./destroy.sh
```

If Apple Container is not running, start it before bootstrapping:

```sh
container system start
```

If bootstrap fails at any point, correct the reported problem and rerun it. It
stops the local forwards, deletes the named cluster, and starts the lab again
from a clean state.

The cluster is pinned to `docker.io/kindest/node:v1.37.0`.
Substrate uses Kubernetes PodCertificateRequest and ClusterTrustBundle APIs to
issue workload identities and distribute their trust roots. Kubernetes v1.37
makes both APIs stable and enabled by default; earlier versions require beta-API
and feature-gate setup. The digest pins the Kubernetes cluster node image. Use
`CLUSTER_NAME`,
`CLUSTER_CPUS`, `CLUSTER_MEMORY`, or `KUBERNETES_NODE_IMAGE` to override the
defaults for a run. For example: `CLUSTER_MEMORY=18g ./bootstrap.sh`.

## Deployment order

`bootstrap.sh` is the source of truth. Every run deletes and recreates the
named cluster, then installs applications in this order: **Coder → kagent →
the LGTM stack**.

The full sequence is:

1. **Kubernetes:** creates the single-node `kubecon-lab` Apple Container
   cluster at Kubernetes v1.37.0.
2. **Storage and namespaces:** applies
   [00-local-storage.yaml](manifests/00-local-storage.yaml)
   and creates `coder`, `ate-system`, `kagent`, and `monitoring`.
3. **Coder database:** creates its credentials, PVC, Service, and the
   PostgreSQL Deployment from
   [10-coder-postgres.yaml](manifests/10-coder-postgres.yaml).
4. **Coder:** installs the Coder Helm release using
   [values/coder.yaml](values/coder.yaml).
5. **kagent:** prepares RustFS storage permissions, then runs the pinned
   installer to create its development PostgreSQL and identity material,
   deploy the kagent/Substrate runtime (including Atelet and RustFS), and
   install kagent.
6. **LGTM prerequisite — Mimir object-store buckets:** creates the dedicated Mimir buckets in the
   RustFS instance via
   [20-mimir-rustfs-buckets.yaml](manifests/20-mimir-rustfs-buckets.yaml).
7. **LGTM — Mimir and Kafka:** installs the scaled-down `mimir-distributed` release;
   its chart-managed, single-broker KRaft Kafka deployment provides Mimir's
   ingest-storage transport.
8. **LGTM — Loki:** installs one non-persistent single-binary log-store replica.
9. **LGTM — Tempo:** installs one non-persistent trace-store replica.
10. **LGTM — Grafana:** installs the UI with Mimir, Loki, and Tempo datasources already
    configured.
11. **LGTM — OpenTelemetry Collector:** installs OTLP gRPC/HTTP ingestion, the OTTL
    transform processor, Mimir remote-write metrics export, and Tempo trace
    export.

## Components

| Component | Purpose in this lab | Deployment shape |
| --- | --- | --- |
| Apple Container Kubernetes | Disposable local Kubernetes runtime | One named single-node cluster, recreated on every bootstrap. |
| Coder | Browser-based development environments | Helm control plane with a one-replica PostgreSQL database and local PVC. |
| kagent + Substrate | Kubernetes AI agent platform and its runtime services | Pinned `1.0.1` supported installer, including its development PostgreSQL setup; requires `OPENAI_API_KEY`. |
| RustFS | S3-compatible object storage | Bundled with Substrate. It stores kagent snapshots and separate Mimir buckets. |
| Grafana Mimir | Long-term Prometheus-compatible metrics backend | `mimir-distributed`, but one replica per component, no HA/caches, and one Kafka partition. |
| Kafka | Mimir ingest-storage transport | One chart-managed KRaft broker, ephemeral disk, one `mimir-ingest` partition. |
| Loki | Log store | One non-persistent single-binary replica. |
| Tempo | Trace store | One non-persistent local-storage replica. |
| Grafana | Query and visualization UI | Preconfigured Mimir, Loki, and Tempo data sources; no persistent state. |
| OpenTelemetry Collector | OTLP ingestion and OTTL practice point | One deployment with OTLP gRPC/HTTP receivers, a `transform/lab` processor, debug output, Mimir metric export, and Tempo trace export. |

## Configuration layout

- [manifests/](manifests/) holds Kubernetes resources. Numeric prefixes indicate
  the bootstrap order; recovery helpers are deliberately unnumbered.
- [values/](values/) holds Helm values only.
- [kagent-install/](kagent-install/) is the version-pinned kagent
  install configuration, values, and credential-safe install wrapper.
- [bootstrap.sh](bootstrap.sh) orchestrates the full install; do not apply the
  manifests in arbitrary order.

## Access and first tests

Bootstrap starts localhost-only port forwards automatically. Check or stop them
with:

```sh
./access.sh status
./access.sh stop
./access.sh start
```

At the end of bootstrap, the generated Grafana admin password is printed for
immediate login. You can retrieve it again with the command below.

The exposed endpoints are:

| Component | Local address |
| --- | --- |
| Coder | <http://localhost:7080> |
| kagent UI | <http://localhost:8080> |
| RustFS console | <http://localhost:9001> |
| Mimir Prometheus API | <http://localhost:9009/prometheus> |
| Loki API | <http://localhost:3100> |
| Tempo API | <http://localhost:3200> |
| Grafana | <http://localhost:3000> |
| OTLP/gRPC | `localhost:4317` |
| OTLP/HTTP | `http://localhost:4318` |

The forwards bind only to `127.0.0.1`; they do not expose the lab on your local
network. They are recreated by each successful bootstrap. To obtain Grafana's
login password or watch Collector output:

```sh

# Print Grafana's generated admin password
kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 --decode; echo

# Watch OTel Collector output while sending test telemetry
kubectl -n monitoring logs deployment/otel-opentelemetry-collector -f
```

Grafana is available at `http://localhost:3000`. The Collector listens in the
cluster on `otel-opentelemetry-collector.monitoring.svc.cluster.local:4317` for
OTLP/gRPC and port `4318` for OTLP/HTTP. Metrics are written to Mimir under
tenant `lab`; the `X-Scope-OrgID: lab` header is already configured in Grafana.

To experiment with OTTL, edit `transform/lab` in
[values/otel-collector.yaml](values/otel-collector.yaml), then update only the
Collector with:

```sh
helm upgrade --install otel open-telemetry/opentelemetry-collector \
  --version 0.182.0 --namespace monitoring --wait --timeout 10m \
  -f values/otel-collector.yaml
```

Alternatively, run `./bootstrap.sh` to rebuild the entire lab.

### Send a first trace

With the local forwards running, the following sends one OTLP/HTTP trace through
the Collector. It adds the `lab.ottl=processed` attribute defined by the sample
transformation.

```sh
curl -sS http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  --data '{
    "resourceSpans": [{
      "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "readme-demo"}}]},
      "scopeSpans": [{"spans": [{
        "traceId": "5b8efff798038103d269b633813fc60c",
        "spanId": "eee19b7ec3c1b174",
        "name": "readme-demo",
        "kind": 1,
        "startTimeUnixNano": "1763654400000000000",
        "endTimeUnixNano": "1763654401000000000"
      }]}]
    }]
  }'
```

Open Grafana Explore with the Tempo data source and search for trace ID
`5b8efff798038103d269b633813fc60c`. The span should include
`lab.ottl=processed`; Collector debug output is also available from the log
command above.

## Data and resource expectations

All data is disposable. Coder/PostgreSQL and RustFS use node-local volumes, but
those volumes belong to the cluster node and disappear when the cluster is
recreated. Loki, Tempo, Kafka, and Grafana are configured without persistence.

RustFS runs as non-root, while the Apple Container `hostPath` backing its PVC is
initially root-owned. The installer runs the scoped `rustfs-volume-permissions`
Job before installing Substrate so the RustFS pod can write to the volume on
its first start. Its world-writable mode is appropriate only for this disposable
local lab.

The Mimir topology is intentionally not production-like for reliability:
replication, zone awareness, caches, durable Kafka storage, and autoscaling are
disabled or scaled to one. It retains the Kafka ingest-storage path and
S3-compatible object-store integration needed for meaningful learning.
