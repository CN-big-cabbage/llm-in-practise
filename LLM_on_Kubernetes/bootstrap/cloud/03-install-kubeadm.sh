#!/usr/bin/env bash
# 安装 kubeadm / kubelet / kubectl deb 包
# 每个节点都跑
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2
  exit 1
fi

DEBS_DIR="$ROOT_DIR/offline/debs"
[[ ! -d "$DEBS_DIR" && -d "$ROOT_DIR/debs" ]] && DEBS_DIR="$ROOT_DIR/debs"
log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

if ! ls "$DEBS_DIR"/kubeadm_*.deb >/dev/null 2>&1; then
  echo "未在 $DEBS_DIR 找到 kubeadm deb 包" >&2
  exit 1
fi

# kubelet 的依赖（如果之前没装过 conntrack 等）
log "确保依赖已装"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq conntrack ebtables socat 2>/dev/null || true

log "安装 deb 包"
dpkg -i "$DEBS_DIR"/*.deb || apt-get install -f -y -qq

log "锁定版本（apt-mark hold）"
apt-mark hold kubelet kubeadm kubectl >/dev/null

log "启用 kubelet"
systemctl enable kubelet >/dev/null

# kubelet 此时启动会失败（还没 init），不用管
log "验证："
kubeadm version -o short
kubelet --version
kubectl version --client --output=yaml | head -5
