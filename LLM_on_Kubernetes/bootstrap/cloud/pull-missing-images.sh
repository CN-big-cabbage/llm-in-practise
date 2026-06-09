#!/usr/bin/env bash
# 在云节点上补拉缺失的镜像（在 02-load-images.sh 之前跑）
# 通过 docker 拉取后，用 docker save 打包为 offline/images/extra-images.tar
# 02-load-images.sh 会自动检测并导入这个补丁包
#
# 用法：
#   sudo bash cloud/pull-missing-images.sh           # 用默认缺失列表
#   sudo bash cloud/pull-missing-images.sh img1 img2 # 自定义镜像列表
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2; exit 1
fi

if ! command -v docker >/dev/null; then
  echo "需要 docker：sudo apt install -y docker.io" >&2; exit 1
fi

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# 确保 docker 配了加速源
if ! sudo cat /etc/docker/daemon.json 2>/dev/null | grep -q "registry-mirrors"; then
  log "首次运行，配置 docker 加速源"
  sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF
  sudo systemctl restart docker
  sleep 3
fi

# 默认补拉列表（基于 versions.env，与 local/02-pull-images.sh 失败时常见的几个）
DEFAULT_MISSING=(
  "docker.io/calico/cni:${CALICO_VERSION}"
  "docker.io/calico/node:${CALICO_VERSION}"
  "docker.io/calico/kube-controllers:${CALICO_VERSION}"
  "docker.io/calico/typha:${CALICO_VERSION}"
  "docker.io/calico/csi:${CALICO_VERSION}"
  "docker.io/calico/node-driver-registrar:${CALICO_VERSION}"
  "docker.io/calico/pod2daemon-flexvol:${CALICO_VERSION}"
  "docker.io/calico/apiserver:${CALICO_VERSION}"
  "nvcr.io/nvidia/gpu-feature-discovery:${NVIDIA_GFD_VERSION}"
  "registry.k8s.io/nfd/node-feature-discovery:${NFD_VERSION}"
)

if [[ $# -gt 0 ]]; then
  IMAGES=("$@")
  log "使用用户指定列表（${#IMAGES[@]} 个镜像）"
else
  IMAGES=("${DEFAULT_MISSING[@]}")
  log "使用默认缺失列表（${#IMAGES[@]} 个镜像）"
fi

SUCCEEDED=()
FAILED=()
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    log "已存在，跳过：$img"
    SUCCEEDED+=("$img")
    continue
  fi
  log "拉取：$img"
  PULLED=false
  for i in 1 2 3 4 5; do
    # 关键：直接判断 docker pull 退出码（不要 | tail 或 | grep）
    if docker pull "$img"; then
      PULLED=true
      break
    fi
    log "  第 $i 次失败，等 ${i}*5=$((i*5))s 后重试"
    sleep $((i*5))
  done
  if [[ "$PULLED" == "true" ]]; then
    SUCCEEDED+=("$img")
  else
    log "  ⚠️  $img 5 次重试均失败"
    FAILED+=("$img")
  fi
done

log "===================="
log "拉取结果：成功 ${#SUCCEEDED[@]} / 失败 ${#FAILED[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  log "失败的镜像（手动排查或换 mirror）："
  for img in "${FAILED[@]}"; do echo "    - $img"; done
fi

if [[ ${#SUCCEEDED[@]} -eq 0 ]]; then
  log "没有成功拉到的镜像，退出"
  exit 1
fi

# docker save 成 extra-images.tar，02-load-images.sh 会自动导入
EXTRA_TAR_DIR="$ROOT_DIR/offline/images"
[[ ! -d "$EXTRA_TAR_DIR" && -d "$ROOT_DIR/images" ]] && EXTRA_TAR_DIR="$ROOT_DIR/images"
mkdir -p "$EXTRA_TAR_DIR"
EXTRA_TAR="$EXTRA_TAR_DIR/extra-images.tar"

log "打包 ${#SUCCEEDED[@]} 个镜像 → $EXTRA_TAR"
docker save -o "$EXTRA_TAR" "${SUCCEEDED[@]}"
chmod 644 "$EXTRA_TAR"
log "完成，文件大小："
du -sh "$EXTRA_TAR"

log ""
log "下一步：运行 02-load-images.sh 一并导入主包 + 补丁包到 containerd"
log "  sudo bash cloud/02-load-images.sh"
