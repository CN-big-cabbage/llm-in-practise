#!/usr/bin/env bash
# 给节点打混合架构所需的标签：zone（local/cloud）、has-gpu（true/false）、runs-minio
# 仅在 master 节点跑（在 06-install-components.sh 之前）
# 自动支持 2 节点 / 4 节点模式：NODE0X_IP 为空则跳过该节点
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

# ---------- Master ----------
MASTER_LABELS=(
  "topology.kubernetes.io/zone=${MASTER_ZONE:-cloud}"
  "has-gpu=${MASTER_HAS_GPU:-false}"
)
[[ "${MASTER_RUNS_MINIO:-false}" == "true" ]] && MASTER_LABELS+=("runs-minio=true")
# 4 节点模式下 master 是 infra 角色（不直接跑业务）
if [[ -z "${NODE02_IP:-}" ]]; then
  log "检测到 2 节点模式"
else
  MASTER_LABELS+=("node-role.k8s.io/infra=true")
fi
label_node "${MASTER_HOST}" "${MASTER_LABELS[@]}"

# 2 节点模式：去掉 master 的 NoSchedule taint，让业务能调度上去
if [[ -z "${NODE02_IP:-}" ]]; then
  log "去掉 master 的 control-plane taint"
  kubectl taint nodes "${MASTER_HOST}" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || \
    log "taint 不存在或已去掉"
fi

# ---------- Node01 ----------
NODE01_LABELS=(
  "topology.kubernetes.io/zone=${NODE01_ZONE:-cloud}"
  "has-gpu=${NODE01_HAS_GPU:-false}"
)
[[ "${NODE01_ZONE:-}" == "local" ]] && NODE01_LABELS+=("node-role.k8s.io/infra=true")
label_node "${NODE01_HOST}" "${NODE01_LABELS[@]}"

# ---------- Node02（可选）----------
if [[ -n "${NODE02_IP:-}" ]]; then
  NODE02_LABELS=(
    "topology.kubernetes.io/zone=${NODE02_ZONE:-cloud}"
    "has-gpu=${NODE02_HAS_GPU:-false}"
  )
  [[ "${NODE02_RUNS_MINIO:-false}" == "true" ]] && NODE02_LABELS+=("runs-minio=true")
  label_node "${NODE02_HOST}" "${NODE02_LABELS[@]}"
fi

# ---------- Node03（可选）----------
if [[ -n "${NODE03_IP:-}" ]]; then
  NODE03_LABELS=(
    "topology.kubernetes.io/zone=${NODE03_ZONE:-cloud}"
    "has-gpu=${NODE03_HAS_GPU:-false}"
  )
  label_node "${NODE03_HOST}" "${NODE03_LABELS[@]}"
fi

log "标签已打。当前节点视图："
kubectl get nodes -L topology.kubernetes.io/zone -L has-gpu -L runs-minio
