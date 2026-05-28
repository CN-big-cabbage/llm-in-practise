# Bootstrap：离线部署 K8s + GPU + 推理底座（混合架构版）

为 **本地 PVE 虚机（master + node01） + 云端 2 台 3090（node02 / node03）** 设计的混合部署脚本，通过 Tailscale 把所有节点串成一个集群。

## 架构

```
本地 PVE                          云端（按小时计费）
┌────────────────┐                ┌──────────────────────┐
│ master  (2C4G+)│                │ node02 (3090, MinIO) │
│ node01  (4C8G+)│ ── Tailscale ──│ node03 (3090)        │
│   infra/ingress│   mesh VPN     │   vLLM 推理 + 模型仓 │
└────────────────┘                └──────────────────────┘
```

只有 2 台云机器计费，相比全云方案省一半。

## 目录结构

```
bootstrap/
├── versions.env                # 所有组件版本号
├── hosts.env.example           # 主机配置模板（含 Tailscale 字段）
├── local/                      # 本地预下载
│   ├── 01-download-binaries.sh
│   ├── 02-pull-images.sh
│   ├── 03-pull-charts.sh
│   ├── 04-download-model.sh
│   └── 05-package.sh
└── cloud/                      # 上云后部署
    ├── 00a-setup-tailscale.sh  # 所有节点：装 Tailscale 入网
    ├── 00-init-node.sh         # 所有节点：主机名/swap/hosts/sysctl
    ├── 01-install-containerd.sh
    ├── 02-load-images.sh
    ├── 03-install-kubeadm.sh
    ├── 04-init-master.sh       # 仅 master：kubeadm init
    ├── 04b-join-worker.sh      # 仅 worker：带 Tailscale IP 加入
    ├── 05-install-calico.sh    # 仅 master：Calico VXLAN (MTU=1230)
    ├── 06a-label-nodes.sh      # 仅 master：打 zone/has-gpu 标签
    ├── 06-install-components.sh# 仅 master：MetalLB/Ingress/OpenEBS/GPU/MinIO
    ├── 07-verify-gpu.sh
    ├── 08-setup-minio.sh       # 仅 master：建 bucket + 上传模型
    └── check.sh                # 任意时刻巡检：网络/节点/CNI/MetalLB/GPU/MinIO
```

## 流程

### 阶段 A：本地准备（一次性）

任意一台能联外网的 Linux：

```bash
cd LLM_on_Kubernetes/bootstrap
bash local/01-download-binaries.sh
bash local/02-pull-images.sh
bash local/03-pull-charts.sh
bash local/04-download-model.sh
bash local/05-package.sh        # 输出 offline.tar.gz
```

### 阶段 B：开机器、装 Tailscale

1. 在 PVE 上开 2 台 Ubuntu 22.04 虚机（master 2C4G+，node01 4C8G+）。
2. 优云租 2 台 3090 机器（Ubuntu 22.04，预装 NVIDIA 驱动）。
3. 在 [Tailscale 控制台](https://login.tailscale.com/admin/settings/keys) 生成一个 **Reusable + Pre-approved** 的 auth key。
4. 把 `offline.tar.gz` 推到 4 台机器（master 用网盘下，再 `scp` 给其它三台）。
5. **每个节点都做**：
   ```bash
   cd /opt && tar xzf offline.tar.gz && cd offline
   cp hosts.env.example hosts.env
   # 编辑 hosts.env：填 TAILSCALE_AUTHKEY；其它 IP 字段先空着
   vi hosts.env

   sudo bash cloud/00a-setup-tailscale.sh
   # 记录脚本输出的本节点 100.x.x.x IP
   ```
6. **回到任一节点**，把 4 台机器的 Tailscale IP 填进 `hosts.env` 的 `MASTER_IP / NODE01_IP / NODE02_IP / NODE03_IP`。然后把这份 hosts.env **scp 同步到所有节点**：
   ```bash
   for h in k8s-node01 k8s-node02 k8s-node03; do
     scp hosts.env $h:/opt/offline/hosts.env
   done
   ```

### 阶段 C：装容器运行时 + kubeadm（所有节点）

每个节点：

```bash
sudo bash cloud/00-init-node.sh k8s-master01   # 各自填对应 hostname
sudo bash cloud/01-install-containerd.sh
sudo bash cloud/02-load-images.sh
sudo bash cloud/03-install-kubeadm.sh
```

### 阶段 D：起集群

master 上：

```bash
sudo bash cloud/04-init-master.sh
# 末尾输出 kubeadm join 命令，复制
```

3 个 worker 上：

```bash
sudo bash cloud/04b-join-worker.sh "kubeadm join 100.64.0.1:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
```

回到 master：

```bash
kubectl get nodes -o wide       # 4 个节点都应该 Ready，且 INTERNAL-IP 是 100.x.x.x
sudo bash cloud/05-install-calico.sh
sudo bash cloud/06a-label-nodes.sh
sudo bash cloud/06-install-components.sh
sudo bash cloud/07-verify-gpu.sh
sudo bash cloud/08-setup-minio.sh
sudo bash cloud/check.sh         # 一键巡检，pass 才进入业务
```

任意阶段都可以跑 `check.sh` 看哪里出问题：

```bash
sudo bash cloud/check.sh            # 紧凑输出
sudo bash cloud/check.sh --verbose  # 失败时打印更多细节
```

## 混合架构关键设计

| 关注点 | 做法 |
|---|---|
| 节点互通 | Tailscale mesh VPN，全 4 台拿 `100.x.x.x` IP，K8s `node-ip` 都用 Tailscale IP |
| Pod 网络 MTU | Calico VXLAN MTU=1230（Tailscale 1280 - VXLAN 头 50） |
| MetalLB IP 池 | 拆两个：`cloud-pool`（云段，给 MinIO/推理）+ `local-pool`（家段，给 Ingress） |
| Ingress 调度 | `nodeSelector: zone=local`，从家里直接访问 |
| GPU 工作负载 | `has-gpu=true` 节点亲和；GPU Operator 各 DaemonSet 也只在 GPU 节点跑 |
| MinIO 调度 | `nodeSelector: runs-minio=true` → 钉到 node02，跟 GPU 同云内网 |

## 注意事项

- `04-init-master.sh` 的 `advertiseAddress` 用 `MASTER_IP`（Tailscale IP），不要写本地 192.168.x。
- `04b-join-worker.sh` 会自动给 kubelet 注入 `--node-ip=<本机Tailscale IP>`，避免 K8s 选错 IP 注册。
- 任何 Pod 跨节点通信都走 Tailscale，吞吐有上限（家宽上行常成瓶颈）；推理走云内网不受影响。
- 本地断网时云上 worker 进入 `NotReady`，但 Pod 默认要 5 分钟才被驱逐，短时抖动无影响。
- 修改版本号只改 `versions.env`，不要散落到脚本里。
