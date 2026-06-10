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

# 自动探测节点 IP：优先 Tailscale（4 节点混合架构），回退云内网 IP（2 节点模式）
NODE_IP=$(tailscale ip -4 2>/dev/null || true)
if [[ -n "$NODE_IP" ]]; then
  log "使用 Tailscale IP=${NODE_IP}"
else
  # 2 节点模式：通过路由查找去 master 时本机用的 IP（最准确）
  MASTER_IP_FROM_JOIN=$(echo "$JOIN_CMD" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:6443' | cut -d: -f1)
  if [[ -n "$MASTER_IP_FROM_JOIN" ]]; then
    NODE_IP=$(ip route get "$MASTER_IP_FROM_JOIN" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  fi
  [[ -z "$NODE_IP" ]] && NODE_IP=$(hostname -I | awk '{print $1}')
  log "使用云内网 IP=${NODE_IP}（2 节点模式，无 Tailscale）"
fi
HOSTNAME_NOW=$(hostname)
log "当前节点 ${HOSTNAME_NOW}  node-ip=${NODE_IP}"

# 提前给 kubelet 准备 node-ip 参数
mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/20-nodeip.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}"
EOF
systemctl daemon-reload

log "执行 kubeadm join"
eval "${JOIN_CMD} --node-name=${HOSTNAME_NOW} --cri-socket=unix:///run/containerd/containerd.sock"

systemctl restart kubelet
sleep 5
log "完成。请到 master 跑 kubectl get nodes -o wide 验证 INTERNAL-IP=${NODE_IP}"
