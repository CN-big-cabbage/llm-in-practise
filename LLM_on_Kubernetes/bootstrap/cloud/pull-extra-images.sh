#!/usr/bin/env bash
# 批量补拉 Inference_Platfrom 各阶段需要的"非离线包"镜像
# 用国内镜像加速代理：daocloud
#
# 用法：sudo bash pull-extra-images.sh [stage]
#   stage = all | base | preloader | router | lmcache | webui | nfd | calico
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2; exit 1
fi

if ! command -v ctr >/dev/null; then
  echo "需要 containerd ctr 命令，先跑 01-install-containerd.sh" >&2; exit 1
fi

STAGE="${1:-all}"
log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# 加速映射：原始域名 → daocloud 代理域名
# 拉时用代理域名，拉完后 tag 成原始域名（让 K8s 引用能找到）
declare -A MIRRORS=(
  ["docker.io"]="docker.m.daocloud.io"
  ["registry.k8s.io"]="k8s.m.daocloud.io"
  ["nvcr.io"]="nvcr.m.daocloud.io"
  ["ghcr.io"]="ghcr.m.daocloud.io"
  ["quay.io"]="quay.m.daocloud.io"
)

pull_and_tag() {
  local original=$1
  local registry=$(echo "$original" | cut -d/ -f1)
  local mirror="${MIRRORS[$registry]:-$registry}"
  local mirrored="${original/$registry/$mirror}"

  # 已存在跳过
  if ctr -n k8s.io images ls -q | grep -qF "$original"; then
    log "[已有] $original"
    return 0
  fi

  log "[拉取] $mirrored"
  for i in 1 2 3; do
    if ctr -n k8s.io images pull "$mirrored" 2>&1 | tail -3; then
      ctr -n k8s.io images tag "$mirrored" "$original" 2>&1 | tail -1
      log "[OK]   $original"
      return 0
    fi
    log "  第 $i 次失败，等 $((i*5))s 后重试"
    sleep $((i*5))
  done
  log "[FAIL] $original"
  return 1
}

# ============ 镜像清单 ============
declare -A STAGE_IMAGES

STAGE_IMAGES[calico]="
docker.io/calico/cni:v3.28.2
docker.io/calico/node:v3.28.2
docker.io/calico/kube-controllers:v3.28.2
docker.io/calico/typha:v3.28.2
docker.io/calico/csi:v3.28.2
docker.io/calico/node-driver-registrar:v3.28.2
docker.io/calico/pod2daemon-flexvol:v3.28.2
docker.io/calico/apiserver:v3.28.2
"

STAGE_IMAGES[nfd]="
registry.k8s.io/nfd/node-feature-discovery:v0.17.2
"

STAGE_IMAGES[base]="
docker.io/vllm/vllm-openai:v0.11.2
docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z
"

STAGE_IMAGES[preloader]="
docker.io/busybox:1.36
"

STAGE_IMAGES[lmcache]="
docker.io/lmcache/vllm-openai:v0.3.15
"

STAGE_IMAGES[router]="
docker.io/lmcache/lmstack-router:latest
ghcr.io/llm-d/llm-d-cuda:v0.6.0
"

STAGE_IMAGES[webui]="
ghcr.io/open-webui/open-webui:main
"

STAGE_IMAGES[verify]="
nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
"

# ============ 执行 ============
SUCCEEDED=()
FAILED=()

run_stage() {
  local stage=$1
  local images="${STAGE_IMAGES[$stage]:-}"
  [[ -z "$images" ]] && { log "未知 stage: $stage"; return 1; }

  log "==================== Stage: $stage ===================="
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    if pull_and_tag "$img"; then
      SUCCEEDED+=("$img")
    else
      FAILED+=("$img")
    fi
  done <<< "$images"
}

if [[ "$STAGE" == "all" ]]; then
  for s in calico nfd base preloader lmcache router webui verify; do
    run_stage "$s"
  done
else
  run_stage "$STAGE"
fi

log "========================================"
log "总结：成功 ${#SUCCEEDED[@]} / 失败 ${#FAILED[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  log "失败镜像清单："
  for img in "${FAILED[@]}"; do echo "    - $img"; done
  log "可手动用其他 mirror 拉，或换主网"
  exit 1
fi
