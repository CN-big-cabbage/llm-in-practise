#!/usr/bin/env bash
# 把离线镜像 tar 导入 containerd 的 k8s.io namespace
# 每个节点都跑
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2
  exit 1
fi

IMG_TAR="$ROOT_DIR/offline/images/k8s-all-images.tar"
[[ ! -f "$IMG_TAR" && -f "$ROOT_DIR/images/k8s-all-images.tar" ]] && IMG_TAR="$ROOT_DIR/images/k8s-all-images.tar"
EXTRA_TAR="$ROOT_DIR/offline/images/extra-images.tar"
[[ ! -f "$EXTRA_TAR" && -f "$ROOT_DIR/images/extra-images.tar" ]] && EXTRA_TAR="$ROOT_DIR/images/extra-images.tar"
log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

if [[ ! -f "$IMG_TAR" ]]; then
  echo "未找到 $IMG_TAR" >&2
  exit 1
fi

if ! command -v ctr >/dev/null; then
  echo "未找到 ctr，请先跑 01-install-containerd.sh" >&2
  exit 1
fi

log "导入主镜像包：$IMG_TAR"
ctr -n k8s.io images import "$IMG_TAR"

# 补丁包：在线补拉的镜像（如 calico、gpu-feature-discovery 等）
if [[ -f "$EXTRA_TAR" ]]; then
  log "检测到补丁包，导入：$EXTRA_TAR"
  ctr -n k8s.io images import "$EXTRA_TAR"
fi

log "已导入的镜像清单（前 30 个）："
crictl images 2>/dev/null | head -30 || ctr -n k8s.io images ls -q | head -30
