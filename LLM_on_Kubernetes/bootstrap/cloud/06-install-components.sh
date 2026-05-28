#!/usr/bin/env bash
# 仅在 master 节点跑：装 MetalLB / Ingress-Nginx / OpenEBS / GPU Operator / MinIO
# 混合架构版本：
#   - MetalLB 分两个池（cloud / local），按节点 zone 标签 advertise
#   - Ingress-Nginx 跑在本地节点（用户从本地访问）
#   - GPU Operator 只在带 GPU 的云端节点 schedule
#   - MinIO 钉到 node02（云端 GPU 旁边）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"
source "$ROOT_DIR/hosts.env"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }
CHARTS_DIR="$ROOT_DIR/charts"
export KUBECONFIG=/etc/kubernetes/admin.conf

# 前置检查：节点标签必须打过
if ! kubectl get nodes -L topology.kubernetes.io/zone | grep -qE 'cloud|local'; then
  echo "未检测到 zone 标签，请先跑 06a-label-nodes.sh" >&2
  exit 1
fi

# ================= MetalLB =================
log "安装 MetalLB"
CHART=$(ls "$CHARTS_DIR"/metallb-*.tgz | head -1)
helm upgrade --install metallb "$CHART" -n metallb-system --create-namespace --wait
sleep 5

log "配置 MetalLB 双 IP 池"
log "  cloud 池: ${METALLB_CLOUD_RANGE}（给推理 / MinIO Service）"
log "  local 池: ${METALLB_LOCAL_RANGE}（给 Ingress / Open-WebUI）"
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: cloud-pool
  namespace: metallb-system
spec:
  addresses: [ "${METALLB_CLOUD_RANGE}" ]
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses: [ "${METALLB_LOCAL_RANGE}" ]
---
# 只让云节点 ARP 通告 cloud-pool
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: cloud-l2
  namespace: metallb-system
spec:
  ipAddressPools: [ "cloud-pool" ]
  nodeSelectors:
    - matchLabels:
        topology.kubernetes.io/zone: cloud
---
# 只让本地节点 ARP 通告 local-pool
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-l2
  namespace: metallb-system
spec:
  ipAddressPools: [ "local-pool" ]
  nodeSelectors:
    - matchLabels:
        topology.kubernetes.io/zone: local
EOF

# ================= Ingress-Nginx =================
log "安装 Ingress-Nginx（钉到本地节点，从 local-pool 拿 IP）"
CHART=$(ls "$CHARTS_DIR"/ingress-nginx-*.tgz | head -1)
helm upgrade --install ingress-nginx "$CHART" \
  -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."metallb\.universe\.tf/address-pool"=local-pool \
  --set controller.ingressClassResource.default=true \
  --set controller.nodeSelector."topology\.kubernetes\.io/zone"=local \
  --wait

# ================= OpenEBS =================
log "安装 OpenEBS LocalPV"
CHART=$(ls "$CHARTS_DIR"/openebs-*.tgz | head -1)
helm upgrade --install openebs "$CHART" \
  -n openebs --create-namespace \
  --set engines.replicated.mayastor.enabled=false \
  --set engines.local.zfs.enabled=false \
  --set engines.local.lvm.enabled=false \
  --wait

kubectl patch storageclass openebs-hostpath \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true

# ================= GPU Operator =================
log "安装 GPU Operator（只在 has-gpu=true 的节点上调度）"
CHART=$(ls "$CHARTS_DIR"/gpu-operator-*.tgz | head -1)

# 给所有 GPU 组件加节点亲和（避免空跑到本地无卡机器上）
GPU_VALUES=/tmp/gpu-operator-values.yaml
cat > "$GPU_VALUES" <<EOF
driver:
  enabled: false
toolkit:
  enabled: true
devicePlugin:
  enabled: true
gfd:
  enabled: true
dcgmExporter:
  enabled: true
nfd:
  enabled: true
# 全局节点亲和：只在 has-gpu=true 的节点上跑
daemonsets:
  tolerations:
    - operator: Exists
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: has-gpu
              operator: In
              values: ["true"]
EOF
helm upgrade --install gpu-operator "$CHART" \
  -n gpu-operator --create-namespace \
  -f "$GPU_VALUES" \
  --wait --timeout=10m

# ================= MinIO =================
log "安装 MinIO（钉到 node02：runs-minio=true，从 cloud-pool 拿 IP）"
CHART=$(ls "$CHARTS_DIR"/minio-*.tgz | head -1)
helm upgrade --install minio "$CHART" \
  -n minio --create-namespace \
  --set mode=standalone \
  --set persistence.size=200Gi \
  --set rootUser="${MINIO_ROOT_USER}" \
  --set rootPassword="${MINIO_ROOT_PASSWORD}" \
  --set service.type=LoadBalancer \
  --set service.annotations."metallb\.universe\.tf/address-pool"=cloud-pool \
  --set consoleService.type=LoadBalancer \
  --set consoleService.annotations."metallb\.universe\.tf/address-pool"=cloud-pool \
  --set nodeSelector."runs-minio"=true \
  --wait --timeout=10m || log "MinIO 安装可能仍在进行，请检查 kubectl get pods -n minio"

# ================= 总结 =================
log "========================================"
log "组件安装完毕。"
echo
kubectl get nodes -o wide -L topology.kubernetes.io/zone -L has-gpu
echo
log "LoadBalancer 服务（MetalLB 分配 IP）："
kubectl get svc -A | grep LoadBalancer
echo
log "MinIO LoadBalancer IP（在云端，浏览器从本地通过 Tailscale 即可访问 IP:9001）："
kubectl -n minio get svc minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
echo
log "默认账号：${MINIO_ROOT_USER} / ${MINIO_ROOT_PASSWORD}"
log "========================================"
log "下一步：07-verify-gpu.sh 验证 GPU，然后 08-setup-minio.sh 上传模型"
