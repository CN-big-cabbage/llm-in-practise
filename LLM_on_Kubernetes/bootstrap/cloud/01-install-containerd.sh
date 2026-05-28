#!/usr/bin/env bash
# 安装 containerd + runc + CNI plugins，每个节点都跑
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2
  exit 1
fi

BINS_DIR="$ROOT_DIR/bins"
log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# ---------- containerd ----------
if ! command -v containerd >/dev/null || ! containerd --version 2>/dev/null | grep -q "${CONTAINERD_VERSION}"; then
  log "安装 containerd ${CONTAINERD_VERSION}"
  tar Cxzf /usr/local "$BINS_DIR/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"

  if [[ ! -f /etc/systemd/system/containerd.service ]]; then
    install -m 644 "$BINS_DIR/containerd.service" /etc/systemd/system/containerd.service
  fi
else
  log "containerd ${CONTAINERD_VERSION} 已就绪"
fi

# ---------- runc ----------
if ! command -v runc >/dev/null || ! runc --version 2>/dev/null | grep -q "${RUNC_VERSION#v}"; then
  log "安装 runc ${RUNC_VERSION}"
  install -m 755 "$BINS_DIR/runc.amd64" /usr/local/sbin/runc
else
  log "runc ${RUNC_VERSION} 已就绪"
fi

# ---------- CNI plugins ----------
if [[ ! -f /opt/cni/bin/bridge ]]; then
  log "安装 CNI plugins ${CNI_PLUGINS_VERSION}"
  mkdir -p /opt/cni/bin
  tar Cxzf /opt/cni/bin "$BINS_DIR/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz"
else
  log "CNI plugins 已存在"
fi

# ---------- 配置 ----------
log "生成 containerd 默认配置并调优"
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Cgroup 用 systemd
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# pause 镜像
sed -i "s#sandbox_image = \"registry.k8s.io/pause:3.[0-9]*\"#sandbox_image = \"${PAUSE_IMAGE}\"#" /etc/containerd/config.toml
# 国内镜像加速（如果你的云在国内）
mkdir -p /etc/containerd/certs.d/docker.io
cat > /etc/containerd/certs.d/docker.io/hosts.toml <<'EOF'
server = "https://docker.io"
[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF
sed -i 's#config_path = ""#config_path = "/etc/containerd/certs.d"#' /etc/containerd/config.toml

# ---------- 启动 ----------
log "启用并启动 containerd"
systemctl daemon-reload
systemctl enable containerd >/dev/null
systemctl restart containerd
sleep 2

# ---------- 安装 crictl 配置 ----------
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

log "验证："
containerd --version
runc --version | head -1
systemctl is-active containerd
