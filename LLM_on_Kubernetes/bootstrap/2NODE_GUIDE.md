# 2 节点云上部署速记

适用：2 台同云内网的服务器，各 16C 64G + 1 张 3090，**不用 Tailscale**。

```
master   (16C 64G + 3090)  control-plane + Ingress/MinIO + GPU worker（taint 已去）
worker01 (16C 64G + 3090)  纯 GPU worker
```

脚本会自动识别：**`hosts.env` 里 NODE02_IP 留空，即进入 2 节点模式**。

## 流程总览

| 步骤 | 在哪跑 | 命令 | 备注 |
|---|---|---|---|
| 0a Tailscale | — | **跳过** | 同云内网不需要 |
| 0  init node | 两台 | `sudo bash cloud/00-init-node.sh <hostname>` | 自动只写填了 IP 的节点到 /etc/hosts |
| 1  containerd | 两台 | `sudo bash cloud/01-install-containerd.sh` | — |
| 2  load images | 两台 | `sudo bash cloud/02-load-images.sh` | — |
| 3  kubeadm | 两台 | `sudo bash cloud/03-install-kubeadm.sh` | — |
| 4  init master | master | `sudo bash cloud/04-init-master.sh` | advertiseAddress 用云内网 IP |
| 4b join worker | worker | `sudo bash cloud/04b-join-worker.sh "<join cmd>"` | **见下方修改** |
| 5  calico | master | `sudo bash cloud/05-install-calico.sh` | MTU 从 hosts.env 读取（=1450） |
| 6a label nodes | master | `sudo bash cloud/06a-label-nodes.sh` | 自动跳过空节点 + 去 master taint |
| 6  components | master | `sudo bash cloud/06-install-components.sh` | 自动用单 MetalLB 池 + Ingress 不限节点 |
| 7  verify gpu | master | `sudo bash cloud/07-verify-gpu.sh` | — |
| 8  setup minio | master | `sudo bash cloud/08-setup-minio.sh` | — |
| check | master | `sudo bash cloud/check.sh` | — |

## 准备步骤

### 1. 复制并填 hosts.env

```bash
cd /opt/offline
cp hosts.env.2node.example hosts.env
vi hosts.env
```

把 `MASTER_IP` 和 `NODE01_IP` 改成 2 台机器的**云内网 IP**（不是公网 IP）。其他字段保持默认。

确认 `CALICO_MTU=1450`、`METALLB_LOCAL_RANGE` 留空、`TAILSCALE_AUTHKEY` 留空。

### 2. 04b-join-worker.sh 的 Tailscale 检测需要绕过

脚本里默认用 `tailscale ip -4` 取 IP。2 节点模式下手动指定云内网 IP：

```bash
# worker 上跑（一行）
TS_IP=$(hostname -I | awk '{print $1}')  # 或直接写死 NODE01_IP
sudo NODE_IP=${TS_IP} bash cloud/04b-join-worker.sh "<master 输出的 kubeadm join 命令>"
```

或者更简单：直接用 `kubeadm join` 不走 04b 脚本，但 kubelet 注册的 IP 可能不对。建议改：

```bash
# 在 worker 上手动注入 node-ip 后再 join
sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo tee /etc/systemd/system/kubelet.service.d/20-nodeip.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=10.0.0.11"   # 改成 worker 云内网 IP
EOF
sudo systemctl daemon-reload

# 然后跑 master 输出的 kubeadm join 命令
sudo kubeadm join 10.0.0.10:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx \
  --node-name=k8s-node01 --cri-socket=unix:///run/containerd/containerd.sock
```

## 你和 4 节点方案相比要小心的几点

| 项 | 影响 | 建议 |
|---|---|---|
| MinIO 跟 vLLM 在同节点 | master 同时跑 control-plane + MinIO + GPU 推理，资源紧 | 留意 `kubectl top node master` |
| 副本上限 = 2 | 阶段 3 多副本最多 2，超过 Pending | 跳到阶段 6 Time-Slicing 才能扩到 4+ |
| 没节点冗余 | master 挂集群就死 | 学习场景不影响 |
| Ingress 在云 | 你从家访问要走云公网 IP | 给 Ingress LoadBalancer IP 配公网映射，或用 `kubectl port-forward` |

## 实战节奏建议

- **第 1 天**：bootstrap（0-8 + check）+ Inference_Platfrom 阶段 1（vLLM 基础）
- **第 2 天**：阶段 2-3（Preloader + 多副本）
- **第 3 天**：阶段 4-6（压测 + KEDA + Time-Slicing）
- **第 4 天**：阶段 7-9（缓存 + 路由 + 金丝雀）

## 如果想从 2 节点扩到 4 节点

把 `NODE02_IP / NODE03_IP` 填上、按 4 节点流程跑 0a 和 04b 即可。脚本里的 IS_2NODE 判断会自动切换。
