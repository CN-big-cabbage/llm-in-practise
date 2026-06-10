#!/usr/bin/env bash
# 节点装基础工具：docker（含 daocloud 加速）、helm、sshpass、git、rsync
# 每个节点都跑一遍（在 00-init-node.sh 之前）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env" 2>/dev/null || true

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2; exit 1
fi

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# ---------- apt 包 ----------
log "更新 apt 源"
apt-get update -qq

log "装基础工具"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  docker.io \
  git \
  rsync \
  sshpass \
  wget \
  curl \
  socat \
  conntrack \
  ipset \
  ipvsadm \
  ebtables \
  iptables \
  jq \
  python3-pip

# ---------- docker 加速源 ----------
log "配置 docker 加速源（daocloud + 1ms.run + xuanyuan.me）"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF
systemctl restart docker
sleep 2

# 当前用户加入 docker 组（便于不用 sudo 跑 docker）
if [[ -n "${SUDO_USER:-}" ]]; then
  usermod -aG docker "$SUDO_USER" || true
  log "已把 ${SUDO_USER} 加入 docker 组（下次登录生效，或现在跑 newgrp docker）"
fi

# ---------- helm ----------
if ! command -v helm >/dev/null; then
  HELM_VER="${HELM_VERSION:-v3.16.2}"
  log "装 helm ${HELM_VER}"
  TMPDIR=$(mktemp -d)
  if [[ -f "$ROOT_DIR/offline/bins/helm-${HELM_VER}-linux-amd64.tar.gz" ]]; then
    tar xzf "$ROOT_DIR/offline/bins/helm-${HELM_VER}-linux-amd64.tar.gz" -C "$TMPDIR"
  else
    log "offline 无 helm，用 ghproxy 拉"
    curl -fsSL "https://gh-proxy.com/github.com/helm/helm/releases/download/${HELM_VER}/helm-${HELM_VER}-linux-amd64.tar.gz" \
      | tar xz -C "$TMPDIR"
  fi
  install -m 755 "$TMPDIR/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "$TMPDIR"
fi
helm version --short | head -1

# ---------- 验证 ----------
log "===================="
log "基础工具就绪"
docker --version
helm version --short | head -1
git --version
sshpass -V | head -1
log "===================="
