#!/usr/bin/env bash
# 仅在 master 节点跑：安装 Calico（tigera-operator 模式）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"
source "$ROOT_DIR/hosts.env"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

CHARTS_DIR="$ROOT_DIR/charts"
BINS_DIR="$ROOT_DIR/bins"
export KUBECONFIG=/etc/kubernetes/admin.conf

# Helm 安装
if ! command -v helm >/dev/null; then
  log "安装 helm"
  tar xzf "$BINS_DIR/helm-${HELM_VERSION}-linux-amd64.tar.gz" -C /tmp
  install -m 755 /tmp/linux-amd64/helm /usr/local/bin/helm
fi

# 找到 tigera-operator chart 包
CHART_FILE=$(ls "$CHARTS_DIR"/tigera-operator-*.tgz 2>/dev/null | head -1)
if [[ -z "$CHART_FILE" ]]; then
  echo "未找到 tigera-operator chart" >&2
  exit 1
fi

# values：指定 Pod CIDR
# 混合架构: Tailscale (1280) - VXLAN 头 (50) = 1230
# 同云内网: 1450（标准 VXLAN MTU）
CALICO_MTU="${CALICO_MTU:-1230}"
log "Calico MTU = ${CALICO_MTU}"
VALUES=/tmp/calico-values.yaml
cat > "$VALUES" <<EOF
installation:
  enabled: true
  calicoNetwork:
    mtu: ${CALICO_MTU}
    ipPools:
      - cidr: ${POD_CIDR}
        encapsulation: VXLAN
        natOutgoing: Enabled
        nodeSelector: all()
EOF

log "安装 Calico"
helm upgrade --install calico "$CHART_FILE" \
  -n tigera-operator --create-namespace \
  -f "$VALUES"

log "等待 calico-system 就绪（最长 5 分钟）"
for i in {1..30}; do
  if kubectl -n calico-system get pods 2>/dev/null | grep -q calico-node && \
     ! kubectl -n calico-system get pods 2>/dev/null | grep -E "Pending|Init|ContainerCreating|0/" >/dev/null; then
    break
  fi
  sleep 10
done

log "节点状态："
kubectl get nodes -o wide
log "Calico 状态："
kubectl get pods -n calico-system 2>/dev/null || kubectl get pods -A | grep calico
