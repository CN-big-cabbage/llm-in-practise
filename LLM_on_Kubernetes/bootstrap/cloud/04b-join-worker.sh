#!/usr/bin/env bash
# 在每个 worker 上跑：加入集群，强制使用 Tailscale IP 注册
# 用法：sudo bash 04b-join-worker.sh <join-command-from-master>
#
# 示例（一行粘贴 master 输出的 join 命令）：
#   sudo bash 04b-join-worker.sh "kubeadm join 100.64.0.1:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/hosts.env"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2; exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "用法：$0 \"<kubeadm join ... 完整命令>\"" >&2
  exit 1
fi

JOIN_CMD="$1"
log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# 确认本节点的 Tailscale IP
TS_IP=$(tailscale ip -4 2>/dev/null || true)
if [[ -z "$TS_IP" ]]; then
  echo "未检测到 Tailscale IP，请先跑 00a-setup-tailscale.sh" >&2
  exit 1
fi
HOSTNAME_NOW=$(hostname)
log "当前节点 ${HOSTNAME_NOW}（Tailscale IP=${TS_IP}）"

# 提前给 kubelet 准备 node-ip 参数（join 后立刻生效）
mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/20-tailscale-nodeip.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=${TS_IP}"
EOF
systemctl daemon-reload

log "执行 kubeadm join"
eval "${JOIN_CMD} --node-name=${HOSTNAME_NOW} --cri-socket=unix:///run/containerd/containerd.sock"

log "确认 kubelet 使用 Tailscale IP"
systemctl restart kubelet
sleep 5
systemctl status kubelet --no-pager | head -10

log "完成。请到 master 节点跑 kubectl get nodes -o wide 验证 INTERNAL-IP 是否为 ${TS_IP}"
