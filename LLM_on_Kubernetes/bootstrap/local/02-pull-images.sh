#!/usr/bin/env bash
# 拉取所有需要的容器镜像，打包成单个 tar 便于离线导入
# 依赖：本机已装 docker（无需 K8s）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"

OFFLINE_DIR="$ROOT_DIR/offline"
IMG_DIR="$OFFLINE_DIR/images"
mkdir -p "$IMG_DIR"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

if ! command -v docker >/dev/null; then
  echo "需要 docker，请先安装" >&2
  exit 1
fi

# 镜像清单
IMAGES=(
  # K8s 核心
  "registry.k8s.io/kube-apiserver:${K8S_VERSION}"
  "registry.k8s.io/kube-controller-manager:${K8S_VERSION}"
  "registry.k8s.io/kube-scheduler:${K8S_VERSION}"
  "registry.k8s.io/kube-proxy:${K8S_VERSION}"
  "registry.k8s.io/coredns/coredns:v1.11.3"
  "${PAUSE_IMAGE}"
  "registry.k8s.io/etcd:3.5.15-0"

  # Calico (tigera-operator)
  "quay.io/tigera/operator:v1.34.5"
  "docker.io/calico/cni:${CALICO_VERSION}"
  "docker.io/calico/node:${CALICO_VERSION}"
  "docker.io/calico/kube-controllers:${CALICO_VERSION}"
  "docker.io/calico/typha:${CALICO_VERSION}"
  "docker.io/calico/csi:${CALICO_VERSION}"
  "docker.io/calico/node-driver-registrar:${CALICO_VERSION}"
  "docker.io/calico/pod2daemon-flexvol:${CALICO_VERSION}"
  "docker.io/calico/apiserver:${CALICO_VERSION}"

  # MetalLB
  "quay.io/metallb/controller:${METALLB_VERSION}"
  "quay.io/metallb/speaker:${METALLB_VERSION}"

  # Ingress-Nginx
  "registry.k8s.io/ingress-nginx/controller:${INGRESS_NGINX_VERSION}"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4"

  # OpenEBS LocalPV-Hostpath 最小集
  "openebs/provisioner-localpv:${OPENEBS_VERSION}"
  "openebs/linux-utils:${OPENEBS_VERSION}"

  # GPU Operator（driver 不拉，由节点提供）
  "nvcr.io/nvidia/gpu-operator:${GPU_OPERATOR_VERSION}"
  "nvcr.io/nvidia/k8s-device-plugin:${NVIDIA_DEVICE_PLUGIN_VERSION}"
  "nvcr.io/nvidia/gpu-feature-discovery:${NVIDIA_GFD_VERSION}"
  "nvcr.io/nvidia/k8s/container-toolkit:${NVIDIA_TOOLKIT_VERSION}"
  "nvcr.io/nvidia/k8s/dcgm-exporter:${NVIDIA_DCGM_VERSION}"
  "nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04"
  "registry.k8s.io/nfd/node-feature-discovery:${NFD_VERSION}"

  # 推理引擎（先备一个常用版本）
  "vllm/vllm-openai:${VLLM_VERSION}"

  # MinIO（集群内单机部署）
  "quay.io/minio/minio:${MINIO_VERSION}"
  "quay.io/minio/mc:${MC_VERSION}"
)

# 单独 pull 每个镜像（便于失败时重试单个）
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    log "已存在，跳过：$img"
    continue
  fi
  log "拉取：$img"
  for i in 1 2 3; do
    if docker pull --platform=linux/amd64 "$img"; then
      break
    fi
    log "第 $i 次失败，等 5s 后重试"
    sleep 5
    if [[ $i -eq 3 ]]; then
      echo "拉取失败：$img" >&2
      exit 1
    fi
  done
done

OUT="$IMG_DIR/k8s-all-images.tar"
if [[ -f "$OUT" ]]; then
  log "$OUT 已存在，删除重新打包"
  rm -f "$OUT"
fi

log "打包所有镜像到 $OUT"
docker save -o "$OUT" "${IMAGES[@]}"
log "完成，大小："
du -sh "$OUT"
