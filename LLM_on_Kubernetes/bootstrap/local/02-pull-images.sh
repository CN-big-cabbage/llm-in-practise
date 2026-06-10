#!/usr/bin/env bash
# 拉取所有需要的容器镜像，打包成单个 tar 便于离线导入
# 依赖：本机已装 docker（无需 K8s）
#
# 用法：
#   bash 02-pull-images.sh          默认：底座 + 推理基础（约 12GB）
#   bash 02-pull-images.sh --full   全套：底座 + 推理 + 监控 + LMCache + Router + WebUI（约 28GB）
#
# 参考 bootstrap/IMAGES.md 完整清单
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"

FULL_MODE=false
[[ "${1:-}" == "--full" ]] && FULL_MODE=true

OFFLINE_DIR="$ROOT_DIR/offline"
IMG_DIR="$OFFLINE_DIR/images"
mkdir -p "$IMG_DIR"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

if ! command -v docker >/dev/null; then
  echo "需要 docker，请先安装" >&2
  exit 1
fi

# ============ 底座 + 推理基础（默认） ============
IMAGES=(
  # ----- K8s 核心 -----
  "registry.k8s.io/kube-apiserver:${K8S_VERSION}"
  "registry.k8s.io/kube-controller-manager:${K8S_VERSION}"
  "registry.k8s.io/kube-scheduler:${K8S_VERSION}"
  "registry.k8s.io/kube-proxy:${K8S_VERSION}"
  "registry.k8s.io/coredns/coredns:v1.11.3"
  "${PAUSE_IMAGE}"
  "registry.k8s.io/etcd:3.5.15-0"

  # ----- Calico 完整 9 个 -----
  "quay.io/tigera/operator:v1.34.5"
  "docker.io/calico/cni:${CALICO_VERSION}"
  "docker.io/calico/node:${CALICO_VERSION}"
  "docker.io/calico/kube-controllers:${CALICO_VERSION}"
  "docker.io/calico/typha:${CALICO_VERSION}"
  "docker.io/calico/csi:${CALICO_VERSION}"
  "docker.io/calico/node-driver-registrar:${CALICO_VERSION}"
  "docker.io/calico/pod2daemon-flexvol:${CALICO_VERSION}"
  "docker.io/calico/apiserver:${CALICO_VERSION}"

  # ----- MetalLB -----
  "quay.io/metallb/controller:${METALLB_VERSION}"
  "quay.io/metallb/speaker:${METALLB_VERSION}"

  # ----- Ingress-Nginx -----
  "registry.k8s.io/ingress-nginx/controller:${INGRESS_NGINX_VERSION}"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4"

  # ----- OpenEBS LocalPV -----
  "docker.io/openebs/provisioner-localpv:${OPENEBS_VERSION}"
  "docker.io/openebs/linux-utils:${OPENEBS_VERSION}"

  # ----- GPU Operator -----
  "nvcr.io/nvidia/gpu-operator:${GPU_OPERATOR_VERSION}"
  "nvcr.io/nvidia/k8s-device-plugin:${NVIDIA_DEVICE_PLUGIN_VERSION}"
  "nvcr.io/nvidia/k8s/container-toolkit:${NVIDIA_TOOLKIT_VERSION}"
  "nvcr.io/nvidia/k8s/dcgm-exporter:${NVIDIA_DCGM_VERSION}"
  "nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04"
  "registry.k8s.io/nfd/node-feature-discovery:${NFD_VERSION}"
  # GFD 可能拉不到（NGC 不开放），最佳忽略，GPU Operator 25.x 内置
  # "nvcr.io/nvidia/gpu-feature-discovery:${NVIDIA_GFD_VERSION}"

  # ----- cuda-sample (07-verify-gpu 用) -----
  "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04"

  # ----- MinIO + mc（两个版本：离线包用 + YAML 引用）-----
  "quay.io/minio/minio:${MINIO_VERSION}"
  "quay.io/minio/mc:${MC_VERSION}"
  "docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z"

  # ----- 推理引擎 + 预热工具 -----
  "docker.io/vllm/vllm-openai:${VLLM_VERSION}"
  "docker.io/busybox:1.36"
)

# ============ --full 模式：再加上面之外的所有阶段镜像 ============
if [[ "$FULL_MODE" == "true" ]]; then
  log "启用 --full 模式：加入监控/LMCache/Router/WebUI/Argo 镜像"
  IMAGES+=(
    # ----- 阶段 5：监控 + KEDA -----
    "quay.io/prometheus/prometheus:v3.0.0"
    "docker.io/grafana/grafana:11.4.0"
    "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0"
    "quay.io/prometheus/node-exporter:v1.8.2"
    "quay.io/prometheus/alertmanager:v0.27.0"
    "quay.io/prometheus-operator/prometheus-operator:v0.78.2"
    "quay.io/prometheus-operator/prometheus-config-reloader:v0.78.2"
    "ghcr.io/kedacore/keda:2.16.0"
    "ghcr.io/kedacore/keda-metrics-apiserver:2.16.0"
    "ghcr.io/kedacore/keda-admission-webhooks:2.16.0"

    # ----- 阶段 7：LMCache -----
    "docker.io/lmcache/vllm-openai:v0.3.15"

    # ----- 阶段 8：智能路由 -----
    "docker.io/lmcache/lmstack-router:latest"
    "ghcr.io/llm-d/llm-d-cuda:v0.6.0"

    # ----- 阶段 9：Argo Rollouts -----
    "quay.io/argoproj/argo-rollouts:v1.7.2"
    "quay.io/argoproj/kubectl-argo-rollouts:v1.7.2"

    # ----- 阶段 10：Open-WebUI -----
    "ghcr.io/open-webui/open-webui:main"
  )
fi

log "镜像清单：${#IMAGES[@]} 个 ($([[ $FULL_MODE == true ]] && echo "--full" || echo "默认"))"

# 单独 pull 每个镜像（best-effort：失败的镜像跳过，末尾汇总，不中断脚本）
FAILED_IMAGES=()
SUCCEEDED_IMAGES=()
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    log "已存在，跳过：$img"
    SUCCEEDED_IMAGES+=("$img")
    continue
  fi
  log "拉取：$img"
  PULLED=false
  for i in 1 2 3; do
    # 关键：直接判断 docker pull 退出码，不要管道任何过滤命令
    if docker pull --platform=linux/amd64 "$img"; then
      PULLED=true
      break
    fi
    log "第 $i 次失败，等 5s 后重试"
    sleep 5
  done
  if [[ "$PULLED" == "true" ]]; then
    SUCCEEDED_IMAGES+=("$img")
  else
    log "⚠️  ${img} 三次重试均失败，标记为失败、继续往下拉"
    FAILED_IMAGES+=("$img")
  fi
done

log "拉取统计：成功 ${#SUCCEEDED_IMAGES[@]} / 失败 ${#FAILED_IMAGES[@]}"
if [[ ${#FAILED_IMAGES[@]} -gt 0 ]]; then
  log "失败列表（请在云上用 cloud/pull-missing-images.sh 补拉，或换镜像源）："
  for img in "${FAILED_IMAGES[@]}"; do
    echo "    - $img"
  done
fi

OUT="$IMG_DIR/k8s-all-images.tar"
if [[ -f "$OUT" ]]; then
  log "$OUT 已存在，删除重新打包"
  rm -f "$OUT"
fi

log "打包所有镜像到 $OUT（${#SUCCEEDED_IMAGES[@]} 个）"
docker save -o "$OUT" "${SUCCEEDED_IMAGES[@]}"
log "完成，大小："
du -sh "$OUT"

if [[ ${#FAILED_IMAGES[@]} -gt 0 ]]; then
  log "⚠️  注意：${#FAILED_IMAGES[@]} 个镜像未拉到，部署到 K8s 时这些组件会失败。"
  log "   补救方法：在云节点上跑 cloud/pull-missing-images.sh"
  exit 2   # 非零退出码标记部分失败
fi
