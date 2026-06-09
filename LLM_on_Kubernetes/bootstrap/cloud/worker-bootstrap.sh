#!/usr/bin/env bash
# Worker 节点一键脚本（在 worker 上跑，不是 master）
# 干的事：从 master scp offline → 装 docker → 跑 00/01/02/03 → 准备 kubelet node-ip
# 跑完后，手动粘贴 master 输出的 kubeadm join 命令即可
#
# 用法：sudo bash worker-bootstrap.sh <MASTER_INTERNAL_IP> [WORKER_HOSTNAME]
#   例如：sudo bash worker-bootstrap.sh 10.60.37.205 k8s-node01
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2; exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "用法：$0 <MASTER_INTERNAL_IP> [WORKER_HOSTNAME=k8s-node01]" >&2
  exit 1
fi

MASTER_IP="$1"
WORKER_HOSTNAME="${2:-k8s-node01}"
log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# Worker 内网 IP（自动探测）
WORKER_IP=$(ip route get "$MASTER_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
[[ -z "$WORKER_IP" ]] && WORKER_IP=$(hostname -I | awk '{print $1}')
log "Worker IP=${WORKER_IP}  hostname=${WORKER_HOSTNAME}  master=${MASTER_IP}"

# ---------- 1. 从 master scp offline 全部 ----------
log "============== 1. scp offline 从 master ==============="
log "需要 master 的 ubuntu 密码，会提示输入"
mkdir -p /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap
cd /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap

# clone 仓库（如果没有）
if [[ ! -d cloud ]]; then
  log "scp 仓库结构（cloud/ local/ *.sh *.example）"
  rsync -avzP "ubuntu@${MASTER_IP}:/opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/{cloud,local,versions.env,hosts.env,hosts.env.2node.example,README.md,2NODE_GUIDE.md}" ./
fi

# scp offline 主体（不重传已存在的）
log "scp offline/ 全部 (~28G，云内网 5-10 分钟)"
rsync -avzP --partial "ubuntu@${MASTER_IP}:/opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/offline/" ./offline/

# 也把 .env 文件单独拷过来（防止上面 brace expansion 没生效）
rsync -avz "ubuntu@${MASTER_IP}:/opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/hosts.env" ./hosts.env
rsync -avz "ubuntu@${MASTER_IP}:/opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/versions.env" ./versions.env

# 修正 hosts.env 里 NODE01_IP（如果 master 还没填）
if grep -q "^NODE01_IP=$" hosts.env; then
  log "回填 NODE01_IP=${WORKER_IP} 到 hosts.env"
  sed -i "s|^NODE01_IP=.*|NODE01_IP=${WORKER_IP}|" hosts.env
fi

# ---------- 2. 装必要工具 ----------
log "============== 2. apt 依赖 ==============="
apt-get update -qq
apt-get install -y -qq curl wget rsync openssh-client socat conntrack ipset ipvsadm ebtables iptables jq

# ---------- 3. 跑 cloud/00 init-node ----------
log "============== 3. cloud/00-init-node.sh ==============="
bash cloud/00-init-node.sh "${WORKER_HOSTNAME}"

# ---------- 4. 跑 cloud/01 containerd ----------
log "============== 4. cloud/01-install-containerd.sh ==============="
bash cloud/01-install-containerd.sh

# ---------- 5. 跑 cloud/02 load-images ----------
log "============== 5. cloud/02-load-images.sh ==============="
bash cloud/02-load-images.sh

# ---------- 6. 跑 cloud/03 kubeadm ----------
log "============== 6. cloud/03-install-kubeadm.sh ==============="
bash cloud/03-install-kubeadm.sh

# ---------- 7. 准备 kubelet node-ip 配置 ----------
log "============== 7. 配置 kubelet --node-ip=${WORKER_IP} ==============="
mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/20-nodeip.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=${WORKER_IP}"
EOF
systemctl daemon-reload

log "===================="
log "Worker 准备完成。下一步：在 worker 上跑 master 输出的 kubeadm join 命令"
log ""
log "格式（请把 master 上 04-init-master.sh 输出的内容粘进来）："
log "  sudo kubeadm join ${MASTER_IP}:6443 --token <TOKEN> \\"
log "    --discovery-token-ca-cert-hash sha256:<HASH> \\"
log "    --node-name=${WORKER_HOSTNAME} \\"
log "    --cri-socket=unix:///run/containerd/containerd.sock"
log ""
log "如果 master 还没跑 04-init-master.sh，先回 master 跑："
log "  sudo bash cloud/04-init-master.sh"
log "===================="
