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

IMG_TAR="$ROOT_DIR/images/k8s-all-images.tar"
log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

if [[ ! -f "$IMG_TAR" ]]; then
  echo "未找到 $IMG_TAR" >&2
  exit 1
fi

if ! command -v ctr >/dev/null; then
  echo "未找到 ctr，请先跑 01-install-containerd.sh" >&2
  exit 1
fi

log "导入镜像（这一步会花几分钟，文件 ~10GB）"
ctr -n k8s.io images import "$IMG_TAR"

log "已导入的镜像清单（前 30 个）："
crictl images 2>/dev/null | head -30 || ctr -n k8s.io images ls -q | head -30
