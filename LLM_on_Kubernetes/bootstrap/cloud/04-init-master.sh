#!/usr/bin/env bash
# 仅在 master 节点跑：kubeadm init + 配置 kubeconfig
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"
if [[ ! -f "$ROOT_DIR/hosts.env" ]]; then
  echo "未找到 $ROOT_DIR/hosts.env" >&2; exit 1
fi
source "$ROOT_DIR/hosts.env"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2; exit 1
fi

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# 检查是否已 init
if [[ -f /etc/kubernetes/admin.conf ]]; then
  log "/etc/kubernetes/admin.conf 已存在，集群可能已初始化"
  log "如要重新初始化，先跑：kubeadm reset -f && rm -rf /etc/kubernetes /var/lib/etcd"
  exit 0
fi

# 生成 kubeadm 配置文件（比命令行参数更灵活）
CFG=/tmp/kubeadm-config.yaml
cat > "$CFG" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${MASTER_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  # 混合架构：强制 kubelet 用 Tailscale IP 注册节点
  kubeletExtraArgs:
    - name: node-ip
      value: ${MASTER_IP}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}
imageRepository: registry.k8s.io
controlPlaneEndpoint: ${MASTER_IP}:6443
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: 10.96.0.0/12
apiServer:
  certSANs:
    - ${MASTER_IP}
    - ${MASTER_HOST}
    - 127.0.0.1
    - localhost
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
EOF

log "开始 kubeadm init（约 1-3 分钟）"
kubeadm init --config="$CFG" --upload-certs

# 配置当前用户的 kubeconfig
USER_HOME="${SUDO_USER:+/home/${SUDO_USER}}"
USER_HOME="${USER_HOME:-/root}"
log "复制 kubeconfig 到 ${USER_HOME}/.kube/config"
mkdir -p "${USER_HOME}/.kube"
cp /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.kube"
fi
export KUBECONFIG=/etc/kubernetes/admin.conf

# 输出 join 命令
log "========================================"
log "Master 初始化完成。Worker 节点上执行下面这条 join 命令："
log "（注意混合架构：worker join 时务必加 --node-ip=<本节点Tailscale IP>）"
log "========================================"
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "$JOIN_CMD" > /tmp/kubeadm-join.cmd
echo ""
echo "本地节点 (node01) 上执行："
echo "${JOIN_CMD} --node-name=${NODE01_HOST} \\"
echo "  --cri-socket=unix:///run/containerd/containerd.sock"
echo "  # 然后修改 /var/lib/kubelet/kubeadm-flags.env 加入 --node-ip=${NODE01_IP}"
echo ""
echo "云端节点 (node02) 上执行："
echo "${JOIN_CMD} --node-name=${NODE02_HOST} \\"
echo "  --cri-socket=unix:///run/containerd/containerd.sock"
echo ""
echo "云端节点 (node03) 上执行："
echo "${JOIN_CMD} --node-name=${NODE03_HOST} \\"
echo "  --cri-socket=unix:///run/containerd/containerd.sock"
echo ""
log "（同时保存到 /tmp/kubeadm-join.cmd）"
log "========================================"
log "下一步：在 3 个 worker 上执行 join，然后在本机跑 05-install-calico.sh"
