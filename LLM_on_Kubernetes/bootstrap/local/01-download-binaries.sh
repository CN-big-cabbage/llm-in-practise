#!/usr/bin/env bash
# 下载所有节点二进制和 Kubernetes deb 包
# 输出到 ../offline/bins 和 ../offline/debs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT_DIR/versions.env"

OFFLINE_DIR="$ROOT_DIR/offline"
BINS_DIR="$OFFLINE_DIR/bins"
DEBS_DIR="$OFFLINE_DIR/debs"
mkdir -p "$BINS_DIR" "$DEBS_DIR"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# ---------- 二进制 ----------
cd "$BINS_DIR"

if [[ ! -f "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" ]]; then
  log "下载 containerd ${CONTAINERD_VERSION}"
  wget -q --show-progress "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
fi

if [[ ! -f containerd.service ]]; then
  log "下载 containerd.service"
  wget -q "https://raw.githubusercontent.com/containerd/containerd/main/containerd.service"
fi

if [[ ! -f "runc.amd64" ]]; then
  log "下载 runc ${RUNC_VERSION}"
  wget -q --show-progress "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64"
fi

if [[ ! -f "cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" ]]; then
  log "下载 CNI plugins ${CNI_PLUGINS_VERSION}"
  wget -q --show-progress "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz"
fi

if [[ ! -f "helm-${HELM_VERSION}-linux-amd64.tar.gz" ]]; then
  log "下载 Helm ${HELM_VERSION}"
  wget -q --show-progress "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
fi

if [[ ! -f "mc" ]]; then
  log "下载 MinIO client (mc)"
  wget -q --show-progress "https://dl.min.io/client/mc/release/linux-amd64/archive/mc.${MC_VERSION}" -O mc
  chmod +x mc
fi

# ---------- Kubernetes deb 包 ----------
# 需要在 Ubuntu 22.04 / Debian 12 类系统上跑（apt 下载）
# 若本机不是 Ubuntu/Debian，请改用 docker：
#   docker run --rm -v "$DEBS_DIR":/out ubuntu:22.04 bash -c "脚本里的 apt 命令 + cp /var/cache/apt/archives/*.deb /out/"

cd "$DEBS_DIR"
if ! ls kubeadm_*.deb >/dev/null 2>&1; then
  if ! command -v apt-get >/dev/null; then
    log "未检测到 apt-get，将用 docker 容器下载 deb 包"
    docker run --rm -v "$DEBS_DIR":/out ubuntu:22.04 bash -c "
      set -e
      apt-get update -qq
      apt-get install -y -qq curl gpg apt-transport-https
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/k8s.gpg
      echo 'deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/ /' > /etc/apt/sources.list.d/k8s.list
      apt-get update -qq
      cd /var/cache/apt/archives
      apt-get install --download-only -y kubelet=${K8S_DEB_VERSION} kubeadm=${K8S_DEB_VERSION} kubectl=${K8S_DEB_VERSION}
      cp /var/cache/apt/archives/*.deb /out/
      chown -R $(id -u):$(id -g) /out/
    "
  else
    log "用宿主 apt 下载 K8s deb 包"
    sudo mkdir -p /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/k8s.gpg ]]; then
      curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/k8s.gpg
      echo "deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/k8s.list >/dev/null
      sudo apt-get update -qq
    fi
    sudo apt-get install --download-only -y \
      "kubelet=${K8S_DEB_VERSION}" \
      "kubeadm=${K8S_DEB_VERSION}" \
      "kubectl=${K8S_DEB_VERSION}"
    sudo cp /var/cache/apt/archives/*.deb "$DEBS_DIR/"
    sudo chown -R "$(id -u):$(id -g)" "$DEBS_DIR/"
  fi
fi

log "完成。产物："
ls -lh "$BINS_DIR"
ls -lh "$DEBS_DIR"
