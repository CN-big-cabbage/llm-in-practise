# 端到端部署指南（2 节点云上版）

> 适用：2 台云服务器（master + 1 worker），各 1 张 RTX 3090，同云内网，**不需要 Tailscale**
> 已验证：优云智算 16C 64G + 3090 + Ubuntu 22.04 + NVIDIA 驱动 580

## 部署全景

```
[本地] 准备 offline 包（一次性）
   ↓
[云端 2 台机器开机]
   ↓
[每台] 0. 装基础工具 (install-prereqs.sh)
[每台] 1. 同步 offline 包
[每台] 2. 修复二进制完整性 (fix-offline-binaries.sh)
   ↓
[每台] 3. 节点初始化  (00-init-node.sh)
[每台] 4. 装 containerd (01-install-containerd.sh)
[每台] 5. 导入镜像     (02-load-images.sh)
[每台] 6. 装 kubeadm   (03-install-kubeadm.sh)
   ↓
[master] 7. 初始化集群 (04-init-master.sh) → 输出 join 命令
[worker] 8. 加入集群   (04b-join-worker.sh "<join>")
   ↓
[master] 9.  装 Calico        (05-install-calico.sh)
[master] 10. 打节点标签       (06a-label-nodes.sh)
[master] 11. 装核心组件       (06-install-components.sh)
[master] 12. 补拉额外镜像     (pull-extra-images.sh)   ← 关键
[master] 13. 验证 GPU         (07-verify-gpu.sh)
[master] 14. 配 MinIO + 模型  (08-setup-minio.sh)
[master] 15. 一键巡检         (check.sh)
   ↓
进入 Inference_Platfrom/PRACTICE_GUIDE.md
```

## 脚本清单

| 脚本 | 在哪跑 | 干什么 |
|---|---|---|
| `install-prereqs.sh` | 每节点 | apt 装 docker/helm/sshpass/git，配 docker 加速 |
| `fix-offline-binaries.sh` | 每节点 | 校验 offline/bins/，损坏/缺失用 ghproxy 重下 |
| `00-init-node.sh` | 每节点 | 主机名、hosts、swap、sysctl |
| `01-install-containerd.sh` | 每节点 | 装 containerd + runc + CNI |
| `02-load-images.sh` | 每节点 | ctr import 主 tar + extra tar |
| `03-install-kubeadm.sh` | 每节点 | dpkg 装 K8s deb |
| `04-init-master.sh` | master | `kubeadm init` 起集群 |
| `04b-join-worker.sh` | worker | 配 node-ip + `kubeadm join`（自适应 2/4 节点） |
| `05-install-calico.sh` | master | helm 装 Calico（MTU 从 hosts.env 读） |
| `06a-label-nodes.sh` | master | 节点 zone/has-gpu/runs-minio 标签 + 2 节点模式去 master taint |
| `06-install-components.sh` | master | MetalLB / Ingress / OpenEBS / GPU Operator / MinIO |
| `pull-extra-images.sh` | 每节点 | daocloud 加速补拉 Calico/NFD/vLLM/LMCache/Router/WebUI 等镜像 |
| `07-verify-gpu.sh` | master | cuda-vector-add 验证 GPU 调度 |
| `08-setup-minio.sh` | master | 装 mc + 建 bucket + 上传模型 + 复制 |
| `check.sh` | master | 10 个分区健康巡检 |
| `worker-bootstrap.sh` | worker | 一键跑 00/01/02/03（含 rsync offline） |

## 阶段 A：本地预下载（一次性）

任意能上外网的 Linux（有 Docker 最佳）：

```bash
git clone https://github.com/CN-big-cabbage/llm-in-practise.git
cd llm-in-practise/LLM_on_Kubernetes/bootstrap

bash local/01-download-binaries.sh    # 二进制 + deb
bash local/02-pull-images.sh          # 默认：底座 + 推理基础（~12GB）
# bash local/02-pull-images.sh --full # 全套：含监控/LMCache/Router/WebUI（~28GB）
bash local/03-pull-charts.sh          # Helm chart
bash local/04-download-model.sh       # Qwen3-8B (~16GB)
bash local/05-package.sh              # 打包 offline.tar.gz
```

📘 **完整镜像清单** → 见 [`IMAGES.md`](./IMAGES.md)（每个阶段需要哪些镜像、大小估算、补救方案）

产物：`offline.tar.gz`（默认约 25-30GB，--full 约 45-50GB），传网盘 / 对象存储。

## 阶段 B：开机器、配凭据

1. 优云开 2 台机器：
   - master：16C 64G + 3090 + 400G 磁盘
   - worker：16C 64G + 3090 + 200G 磁盘
2. 拿到公网 + 内网 IP
3. 改默认密码或上传 SSH key：
   ```bash
   ssh-copy-id ubuntu@<MASTER_PUBLIC>
   ssh-copy-id ubuntu@<WORKER_PUBLIC>
   ```
4. clone 仓库到两台机器：
   ```bash
   # 两台都做
   sudo apt update && sudo apt install -y git
   sudo git clone https://github.com/CN-big-cabbage/llm-in-practise.git /opt/llm-in-practise
   sudo chown -R ubuntu:ubuntu /opt/llm-in-practise
   ```
5. 在 **master** 上配 `hosts.env`：
   ```bash
   cd /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap
   cp hosts.env.2node.example hosts.env
   vi hosts.env
   # 改：
   #   MASTER_IP=<master 内网 IP>
   #   NODE01_IP=<worker 内网 IP>
   #   METALLB_CLOUD_RANGE=<云内网未占用段>
   #   MINIO_ROOT_PASSWORD=<强密码>
   ```

## 阶段 C：同步 offline 包

### 方式 1：本地推（推荐家宽快的）

```bash
# 本地
rsync -avzP --partial offline/ ubuntu@<MASTER_PUBLIC>:/opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/offline/
```

### 方式 2：云上拉网盘（推荐家宽慢的）

云 master 上从网盘 wget / curl 下载 `offline.tar.gz`，解压到 `bootstrap/offline/`。

### 然后 master → worker 内网推（飞快）

```bash
ssh ubuntu@<MASTER_PUBLIC>
cd /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap

# 用 sshpass 或 ssh key（如果你 setup 过）
rsync -avzP offline/ ubuntu@<WORKER_INTERNAL>:/opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/offline/

# hosts.env 也推过去
rsync -avz hosts.env ubuntu@<WORKER_INTERNAL>:/opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/hosts.env
```

## 阶段 D：节点准备（两节点并行）

**每台机器都跑** —— 推荐开两个终端并行执行：

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap

# 1. 装基础工具
sudo bash cloud/install-prereqs.sh

# 2. 校验 + 修复 offline 二进制（关键：避免 rsync 中断造成的部分文件）
sudo bash cloud/fix-offline-binaries.sh

# 3. 节点初始化
sudo bash cloud/00-init-node.sh k8s-master01   # 在 master 跑
# 或：
sudo bash cloud/00-init-node.sh k8s-node01     # 在 worker 跑

# 4. 装 containerd（worker 上若有预装 v2.x，会被覆盖成 v1.7.22 跟 master 一致）
sudo bash cloud/01-install-containerd.sh

# 5. 导入镜像（21 主 + extra）
sudo bash cloud/02-load-images.sh

# 6. 装 kubeadm
sudo bash cloud/03-install-kubeadm.sh
```

## 阶段 E：组装集群

### master 起集群

```bash
ssh ubuntu@<MASTER_PUBLIC>
cd /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap

sudo bash cloud/04-init-master.sh
# 末尾会打印 kubeadm join 命令，复制下来
```

### worker 加入

```bash
ssh ubuntu@<WORKER_PUBLIC>
cd /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap

# 粘贴 master 输出的整条 join 命令作为参数
sudo bash cloud/04b-join-worker.sh "kubeadm join <MASTER_INTERNAL>:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx"
```

### 验证

```bash
# master 上
kubectl get nodes -o wide
# 期望两节点 Ready，INTERNAL-IP 是云内网 IP
```

## 阶段 F：装核心组件

```bash
ssh ubuntu@<MASTER_PUBLIC>
cd /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap

# 装 Calico
sudo bash cloud/05-install-calico.sh
# 等 2 分钟，看 kubectl get pods -n calico-system 全 Running

# 打节点标签（2 节点模式会自动去 master taint）
sudo bash cloud/06a-label-nodes.sh

# 装 MetalLB / Ingress / OpenEBS / GPU Operator / MinIO
sudo bash cloud/06-install-components.sh

# 补拉额外镜像（NFD、Calico 缺失部分等）
sudo bash cloud/pull-extra-images.sh nfd
sudo bash cloud/pull-extra-images.sh calico   # 如果 06 装 Calico 时有 ImagePullBackOff
# 也可以一次性拉所有阶段需要的：
# sudo bash cloud/pull-extra-images.sh all
```

⚠️ `pull-extra-images.sh` 要在**两台节点都跑**（GPU Operator NFD pod 会调度到两节点）：

```bash
# worker 上
ssh ubuntu@<WORKER_PUBLIC>
sudo bash /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/cloud/pull-extra-images.sh nfd
```

## 阶段 G：验证 + 模型仓

```bash
# 在 master 上
sudo bash cloud/07-verify-gpu.sh
# 期望：Test PASSED

sudo bash cloud/08-setup-minio.sh
# mc alias 配置 + 创建 bucket llm-models / qwen + 上传 Qwen3-8B + 服务端复制

# 巡检
sudo bash cloud/check.sh
# 注意：2 节点模式下 check.sh 会报 Tailscale 未装 + local-pool 缺失（误报），可忽略
```

## 阶段 H：进入 Inference_Platfrom

集群就绪后，按 `Inference_Platfrom/PRACTICE_GUIDE.md` 的 10 个阶段实践。

---

## 可选：升级 NVIDIA 驱动

如果你的 vLLM 镜像需要更新的 CUDA（如 **v0.11.2 需要 CUDA >= 12.9 → 驱动 >= 580**），但云上预装的驱动只有 570（对应 CUDA 12.8），需要升级。

### 何时需要

| 驱动版本 | 支持的 CUDA | 能跑的 vLLM |
|---|---|---|
| 535 / 545 | <= 12.4 | <= v0.8.x（不支持 Qwen3） |
| 570 | 12.8 | v0.11.0（最高） |
| **580+** | **12.9 / 13.0** | **v0.11.2+（含 Qwen3 全功能）** |

跑 `nvidia-smi` 看当前驱动版本，对照表决定要不要升。

### 升级脚本

```bash
ssh ubuntu@<NODE_PUBLIC>
cd /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap

# 升级到 580，会自动 reboot
sudo bash cloud/upgrade-nvidia-driver.sh 580

# 或跳过 reboot 自己手动重启
sudo bash cloud/upgrade-nvidia-driver.sh 580 --skip-reboot
sudo reboot

# 或无人值守（CI 用）
sudo bash cloud/upgrade-nvidia-driver.sh 580 --yes
```

脚本干的事：
1. 检测当前驱动版本，如果已 >= 目标版本就跳过
2. 优先用 NVIDIA 官方 cuda-keyring（国内可达）
3. 回退到 PPA `graphics-drivers/ppa`（万一前者拉不到）
4. `apt install nvidia-driver-XXX`
5. 提示或自动 reboot

### 升级顺序建议（K8s 集群中）

**强烈推荐先 worker、后 master**，集群不全离线：

```bash
# Step 1：worker 上 drain + 升级
ssh ubuntu@<WORKER_PUBLIC>
kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data --force   # 注意需要 kubectl 配置
sudo bash /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/cloud/upgrade-nvidia-driver.sh 580
# 自动 reboot

# Step 2：等 worker 起来 + 自动 uncordon
ssh ubuntu@<MASTER_PUBLIC>
kubectl get nodes   # worker 应该 Ready
kubectl uncordon <worker-hostname>

# Step 3：master 上同样操作
sudo bash /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap/cloud/upgrade-nvidia-driver.sh 580
# 自动 reboot，期间 kubectl 短暂不可用（2-3 分钟）
```

### 升级后验证

```bash
nvidia-smi | head -3
# 期望：Driver Version: 580.xx.xx     CUDA Version: 12.9 / 13.0

# 集群恢复
kubectl get nodes
kubectl get pods -A | grep -v "Running\|Completed"   # 应为空

# GPU 仍然可调度
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

### 升级踩坑

| 现象 | 处理 |
|---|---|
| `apt install nvidia-driver-580` 报源里没有 | 脚本会自动加 PPA，PPA 在国内有时慢；改用 cuda-keyring（脚本已优先用） |
| 装完 `nvidia-smi` 还是旧版本 | 没 reboot；脚本默认 10 秒后自动 reboot |
| reboot 后 `nvidia-smi` Failed to initialize | nouveau 没禁用，`sudo modprobe -r nouveau && sudo reboot` |
| 卡在 BIOS Secure Boot | 第一次装驱动需要在 BIOS 输 MOK 密码；云上一般没这问题 |
| GPU Operator Pod CrashLoop | 驱动跟 container-toolkit 版本错位；`kubectl delete pod -n gpu-operator --all`，等自愈 |
| `kubectl drain` 卡在 PDB | `--disable-eviction` 强制驱逐 |

## 常见踩坑速查

| 现象 | 原因 / 处理 |
|---|---|
| `containerd-X.tar.gz: Unexpected EOF` | rsync 中断造成部分文件，跑 `fix-offline-binaries.sh` |
| GitHub release 拉不动（20KB/s） | 用 ghproxy.com 代理（已封装在 fix-offline-binaries.sh） |
| `kubeadm join` 后 INTERNAL-IP 是 docker bridge | 04b-join-worker.sh 自动注入 `--node-ip` 修复 |
| ingress-nginx `kube-webhook-certgen` ImagePullBackOff | digest 校验问题；06 脚本已加 `--set image.digest=""` 绕过 |
| GPU Operator NFD pod ErrImagePull | NFD 镜像版本不一致（v0.17.2 vs v0.16.4）；跑 `pull-extra-images.sh nfd` |
| MinIO 装失败 `cannot unmarshal bool` | `--set "nodeSelector.runs-minio=true"` 应该用 `--set-string`；06 已修 |
| 节点预装 containerd v2.x 跟我们 v1.7 冲突 | 01-install-containerd.sh 直接覆盖到 v1.7.22 |
| 模型上传一半 SSH 断 | 用 nohup 后台跑 `mc mirror`，看 `/tmp/upload-model.log` |
| vLLM v0.11.2 要 CUDA >= 12.9 | 节点驱动升级到 580+（apt + reboot） |
| YAML 节点名 `k8s-nodeXX.magedu.com` 跟实际对不上 | `find . -name "*.yaml" -exec sed -i 's\|k8s-node03\.magedu\.com\|k8s-master01\|g' {} \;` |
| MinIO Secret YAML 凭据是 modelskey | base64 改成 admin/admin123456（YWRtaW4=/YWRtaW4xMjM0NTY=） |

## 浏览器访问入口

集群 LoadBalancer IP 都是云内网，要在 master 上 socat 转发：

```bash
ssh ubuntu@<MASTER_PUBLIC>
sudo apt install -y socat

# 起后台转发（master 公网 → 集群内 IP）
sudo nohup socat TCP-LISTEN:9001,fork,reuseaddr TCP:10.60.37.212:9001 > /tmp/socat.log 2>&1 &  # MinIO Console
sudo nohup socat TCP-LISTEN:9000,fork,reuseaddr TCP:10.60.37.211:9000 > /tmp/socat.log 2>&1 &  # MinIO API
sudo nohup socat TCP-LISTEN:80,fork,reuseaddr TCP:10.60.37.210:80 > /tmp/socat.log 2>&1 &      # Ingress

# 云控制台开 80/9000/9001 端口安全组
```

浏览器：
- MinIO Console: `http://<MASTER_PUBLIC>:9001`（admin / 你的密码）
- Ingress（带 Host）: 用 Postman 或 ModHeader 插件加 `Host: vllm.magedu.com`

## 验收清单

跑通这些就算端到端 OK：

- [ ] `kubectl get nodes` → 两台 Ready
- [ ] `kubectl get pods -A` → 无 CrashLoop / ImagePullBackOff
- [ ] `kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'` → `1 1`
- [ ] `kubectl get svc -A | grep LoadBalancer` → 3 个 LB IP 都分配了
- [ ] `mc ls models/llm-models/Qwen3-8B/` → 看到 safetensors
- [ ] 跑 `Inference_Platfrom/01-Base/vLLM/`，curl `/v1/chat/completions` 返回中文回复

---

## 备份建议

- `hosts.env`（含凭据）：本地保留一份，**不要 commit**
- `offline.tar.gz`：传一份到对象存储/网盘，后续重建集群可直接用
- `kubectl config view --raw > ~/kubeconfig-prod.yaml`：保存本地，可远程操作集群

---

跑过一次记录每阶段实际耗时：

| 阶段 | 预估 | 实际 | 备注 |
|---|---|---|---|
| A 本地预下载 | 30min-2h | | 看网速 |
| B 开机 + 改密 + clone | 10min | | |
| C 同步 offline 包 | 30min-2h | | 看带宽 |
| D 节点准备（两节点并行） | 15min | | |
| E 组装集群 | 5min | | |
| F 装核心组件 | 15min | | GPU Operator 慢 |
| G 验证 + 模型仓 | 10min | | 模型上传 2 分钟 |
| **总计** | **~2-4 小时** | | |
