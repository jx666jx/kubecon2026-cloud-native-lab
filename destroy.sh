#!/usr/bin/env bash
set -euo pipefail
container cluster delete --name "${CLUSTER_NAME:-kubecon-lab}"
