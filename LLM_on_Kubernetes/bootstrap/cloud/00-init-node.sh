#!/usr/bin/env bash
# 节点初始化：所有 4 个节点都跑
# 用法：sudo bash 00-init-node.sh <hostname>
#       例如 sudo bash 00-init-node.sh k8s-master01
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "用法：$0 <hostname>"
  echo "示例：$0 k8s-master01"
  exit 1
fi
NEW_HOSTNAME="$1"

# 必须有 hosts.env
if [[ ! -f "$ROOT_DIR/hosts.env" ]]; then
  echo "未找到 $ROOT_DIR/hosts.env，请先从 hosts.env.example 复制并填写" >&2
  exit 1
fi
source "$ROOT_DIR/hosts.env"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# ---------- 1. 主机名 ----------
log "设置主机名 → $NEW_HOSTNAME"
hostnamectl set-hostname "$NEW_HOSTNAME"

# ---------- 2. /etc/hosts ----------
log "写入 /etc/hosts"
# 移除可能存在的旧条目
sed -i '/k8s-master01\|k8s-node0[123]/d' /etc/hosts
cat >> /etc/hosts <<EOF
${MASTER_IP} ${MASTER_HOST}
${NODE01_IP} ${NODE01_HOST}
${NODE02_IP} ${NODE02_HOST}
${NODE03_IP} ${NODE03_HOST}
EOF

# ---------- 3. 关 swap ----------
log "关闭 swap"
swapoff -a || true
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab

# ---------- 4. 内核模块 ----------
log "加载内核模块 overlay / br_netfilter"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# ---------- 5. sysctl ----------
log "写入 sysctl 网络转发参数"
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# ---------- 6. 防火墙（仅在使用 ufw 时关闭）----------
if command -v ufw >/dev/null; then
  log "关闭 ufw（云上通常用安全组替代）"
  ufw disable || true
fi

# ---------- 7. 时区与时间同步 ----------
log "设置时区为 Asia/Shanghai 并启用 NTP"
timedatectl set-timezone Asia/Shanghai
timedatectl set-ntp true || true

# ---------- 8. 必要工具 ----------
log "安装必要工具（socat, conntrack, ipset, ipvsadm）"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  socat conntrack ipset ipvsadm ebtables iptables jq curl wget \
  2>/dev/null || log "apt-get 失败，请确认有可用源（云上一般默认有）"

# ---------- 9. GPU 节点提示 ----------
if command -v nvidia-smi >/dev/null; then
  log "检测到 NVIDIA 驱动："
  nvidia-smi | head -15
else
  log "未检测到 nvidia-smi（如果这是 worker 但没有 GPU，正常忽略）"
fi

log "节点 $NEW_HOSTNAME 初始化完成"
