#!/usr/bin/env bash
# 给节点打混合架构所需的标签：zone（local/cloud）、gpu（true/false）、runs-minio
# 仅在 master 节点跑（在 06-install-components.sh 之前）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/hosts.env"

export KUBECONFIG=/etc/kubernetes/admin.conf
log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

label_node() {
  local node=$1
  shift
  log "label $node: $*"
  kubectl label node "$node" "$@" --overwrite
}

# Master
label_node "${MASTER_HOST}" \
  "topology.kubernetes.io/zone=${MASTER_ZONE}" \
  "node-role.k8s.io/infra=true"

# Node01（本地）
label_node "${NODE01_HOST}" \
  "topology.kubernetes.io/zone=${NODE01_ZONE}" \
  "node-role.k8s.io/infra=true" \
  "has-gpu=${NODE01_HAS_GPU}"

# Node02（云端 + GPU + MinIO）
label_node "${NODE02_HOST}" \
  "topology.kubernetes.io/zone=${NODE02_ZONE}" \
  "has-gpu=${NODE02_HAS_GPU}" \
  "runs-minio=${NODE02_RUNS_MINIO:-false}"

# Node03（云端 + GPU）
label_node "${NODE03_HOST}" \
  "topology.kubernetes.io/zone=${NODE03_ZONE}" \
  "has-gpu=${NODE03_HAS_GPU}"

log "标签已打。当前节点视图："
kubectl get nodes --show-labels=false -L topology.kubernetes.io/zone -L has-gpu -L runs-minio
