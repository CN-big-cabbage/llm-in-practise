# 镜像总清单（提前下载用）

> 整套部署 + 9 阶段实践 用到的所有镜像。约 **30 GB**。
> 在能上外网的机器上一次性拉好、`docker save` 打包，传到云上 `ctr import` 即可。

## 一键拉取脚本

直接跳到本文末尾「[一键预下载脚本](#一键预下载脚本)」。

---

## 分类清单

### 1. K8s 控制面（必备 / 阶段 0 底座）

约 700 MB。`offline/images/k8s-all-images.tar` 已含。

| 镜像 | 用途 |
|---|---|
| `registry.k8s.io/kube-apiserver:v1.31.4` | API Server |
| `registry.k8s.io/kube-controller-manager:v1.31.4` | Controller Manager |
| `registry.k8s.io/kube-scheduler:v1.31.4` | Scheduler |
| `registry.k8s.io/kube-proxy:v1.31.4` | kube-proxy（每节点 DaemonSet） |
| `registry.k8s.io/coredns/coredns:v1.11.3` | 集群 DNS |
| `registry.k8s.io/etcd:3.5.15-0` | etcd |
| `registry.k8s.io/pause:3.10` | 沙箱容器 |

### 2. Calico CNI（必备）

约 1.2 GB。**`tigera/operator` 在主 tar，其余 8 个要走 `extra-images.tar`**（v0.6.x 用 docker.io/calico/...）。

| 镜像 | 用途 |
|---|---|
| `quay.io/tigera/operator:v1.34.5` | Calico Operator |
| `docker.io/calico/cni:v3.28.2` | CNI 插件 |
| `docker.io/calico/node:v3.28.2` | calico-node DaemonSet（500 MB 最大头） |
| `docker.io/calico/kube-controllers:v3.28.2` | 控制器 |
| `docker.io/calico/typha:v3.28.2` | typha 缓存代理 |
| `docker.io/calico/csi:v3.28.2` | CSI 驱动 |
| `docker.io/calico/node-driver-registrar:v3.28.2` | 节点驱动注册 |
| `docker.io/calico/pod2daemon-flexvol:v3.28.2` | Pod → DaemonSet 通信 |
| `docker.io/calico/apiserver:v3.28.2` | Calico API Server |

### 3. 网络 / 存储 / 入口（必备）

约 900 MB。

| 镜像 | 用途 |
|---|---|
| `quay.io/metallb/controller:v0.14.8` | MetalLB Controller |
| `quay.io/metallb/speaker:v0.14.8` | MetalLB Speaker DaemonSet |
| `registry.k8s.io/ingress-nginx/controller:v1.11.3` | Ingress 控制器 |
| `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4` | 证书生成 Job |
| `docker.io/openebs/provisioner-localpv:4.1.0` | OpenEBS LocalPV |
| `docker.io/openebs/linux-utils:4.1.0` | 工具镜像 |

### 4. GPU Operator（必备）

约 2.5 GB。

| 镜像 | 用途 |
|---|---|
| `nvcr.io/nvidia/gpu-operator:v25.3.0` | GPU Operator |
| `nvcr.io/nvidia/k8s-device-plugin:v0.17.0` | GPU Device Plugin |
| `nvcr.io/nvidia/k8s/container-toolkit:v1.16.2-ubuntu20.04` | NVIDIA Container Toolkit |
| `nvcr.io/nvidia/k8s/dcgm-exporter:3.3.8-3.6.0-ubuntu22.04` | DCGM Exporter（GPU 指标） |
| `nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04` | CUDA validation 用 |
| `registry.k8s.io/nfd/node-feature-discovery:v0.17.2` | NFD（要单独拉，注意是 0.17.2 不是 0.16.4） |
| `nvcr.io/nvidia/gpu-feature-discovery:v0.17.0` | GFD（可选，可能云上拉不到） |
| `nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04` | GPU 验证测试 Pod |

### 5. MinIO 模型仓（必备）

约 250 MB。

| 镜像 | 用途 |
|---|---|
| `quay.io/minio/minio:RELEASE.2024-10-13T13-34-11Z` | MinIO Server |
| `quay.io/minio/mc:RELEASE.2024-10-08T09-37-26Z` | mc CLI（离线包用此版本） |
| `docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z` | mc CLI（Inference YAML 引用此版本） |

### 6. 推理基础（阶段 1-3）

约 6.5 GB。**最大头是 vLLM 镜像**。

| 镜像 | 用途 | 大小 |
|---|---|---|
| `docker.io/vllm/vllm-openai:v0.11.2` | vLLM（需要驱动 >= 580） | ~6 GB |
| `docker.io/busybox:1.36` | preloader pause | 10 MB |

**注**：如果你的驱动只能升到 570，用 `vllm/vllm-openai:v0.11.0`（CUDA 12.8）。

### 7. 监控 + 自动扩缩（阶段 5，KEDA + Prometheus）

约 1.5 GB。

| 镜像 | 用途 |
|---|---|
| `quay.io/prometheus/prometheus:v3.0.0` | Prometheus |
| `docker.io/grafana/grafana:11.4.0` | Grafana |
| `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0` | Kube state 指标 |
| `quay.io/prometheus/node-exporter:v1.8.2` | 节点指标 |
| `quay.io/prometheus/alertmanager:v0.27.0` | 告警 |
| `quay.io/prometheus-operator/prometheus-operator:v0.78.2` | Prometheus Operator |
| `quay.io/prometheus-operator/prometheus-config-reloader:v0.78.2` | 配置热重载 |
| `ghcr.io/kedacore/keda:2.16.0` | KEDA |
| `ghcr.io/kedacore/keda-metrics-apiserver:2.16.0` | KEDA Metrics |
| `ghcr.io/kedacore/keda-admission-webhooks:2.16.0` | KEDA Webhook |

⚠️ 版本可能随 Helm chart 自动升级，以你 `helm pull` 时的实际为准。

### 8. L1 缓存（阶段 7）

约 6 GB。

| 镜像 | 用途 |
|---|---|
| `docker.io/lmcache/vllm-openai:v0.3.15` | LMCache + vLLM 集成镜像 |

### 9. 智能路由（阶段 8）

约 5-8 GB（llm-d 镜像很大）。

| 镜像 | 用途 |
|---|---|
| `docker.io/lmcache/lmstack-router:latest` | vLLM-Router |
| `ghcr.io/llm-d/llm-d-cuda:v0.6.0` | llm-d（CNCF 项目，更复杂） |

### 10. 金丝雀发布（阶段 9）

约 300 MB。

| 镜像 | 用途 |
|---|---|
| `quay.io/argoproj/argo-rollouts:v1.7.2` | Argo Rollouts Controller |
| `quay.io/argoproj/kubectl-argo-rollouts:v1.7.2` | CLI（可选） |

### 11. Open-WebUI（阶段 10）

约 700 MB。

| 镜像 | 用途 |
|---|---|
| `ghcr.io/open-webui/open-webui:main` | ChatGPT 风格的前端 |

---

## 大小估算

| 镜像组 | 必备性 | 累计 |
|---|---|---|
| 1-5 底座 + Calico + GPU Op + MinIO | 必须 | ~5.5 GB |
| 6 推理基础 | 必须（跑阶段 1 起） | +6.5 GB → 12 GB |
| 7 监控 + KEDA | 阶段 5+ | +1.5 GB → 13.5 GB |
| 8 LMCache | 阶段 7 | +6 GB → 19.5 GB |
| 9 Router | 阶段 8 | +6-8 GB → 27.5 GB |
| 10 Argo | 阶段 9 | +0.3 GB → 27.8 GB |
| 11 WebUI | 阶段 10 | +0.7 GB → **~28.5 GB** |

加上 Qwen3-8B 模型（16 GB），总 offline 包 **~45 GB**。

---

## 一键预下载脚本

在本地能上外网的机器上跑（推荐 Linux 装 Docker）：

```bash
git clone https://github.com/CN-big-cabbage/llm-in-practise.git
cd llm-in-practise/LLM_on_Kubernetes/bootstrap

# 默认拉清单 1-6（必备 + 推理基础）
bash local/02-pull-images.sh

# 拉所有阶段镜像（清单 1-11）
bash local/02-pull-images.sh --full
```

或手动 `docker pull` + `docker save`：

```bash
# 拉
docker pull docker.io/vllm/vllm-openai:v0.11.2
docker pull docker.io/lmcache/vllm-openai:v0.3.15
# ... 等等

# 打包到一个 tar
docker save -o all-images.tar \
  docker.io/vllm/vllm-openai:v0.11.2 \
  docker.io/lmcache/vllm-openai:v0.3.15 \
  ...

# 云上导入
ctr -n k8s.io images import all-images.tar
```

### 用国内镜像加速

直拉 docker.io / ghcr.io / nvcr.io 国内慢，建议配 daocloud 加速。`local/02-pull-images.sh` 已配。手动拉时：

```bash
docker pull docker.m.daocloud.io/vllm/vllm-openai:v0.11.2
docker tag docker.m.daocloud.io/vllm/vllm-openai:v0.11.2 docker.io/vllm/vllm-openai:v0.11.2
```

对应映射：

| 原 registry | daocloud 加速 |
|---|---|
| `docker.io` | `docker.m.daocloud.io` |
| `registry.k8s.io` | `k8s.m.daocloud.io` |
| `nvcr.io` | `nvcr.m.daocloud.io` |
| `ghcr.io` | `ghcr.m.daocloud.io` |
| `quay.io` | `quay.m.daocloud.io` |

也可用 1ms.run、xuanyuan.me 等其他公共代理。

---

## 在云上补拉（如果离线包没带）

如果某些镜像没提前拉，云上跑：

```bash
# 在云节点上跑
cd /opt/llm-in-practise/LLM_on_Kubernetes/bootstrap

# 按 stage 补拉
sudo bash cloud/pull-extra-images.sh calico     # Calico 8 个
sudo bash cloud/pull-extra-images.sh nfd        # NFD
sudo bash cloud/pull-extra-images.sh base       # vLLM + mc + busybox
sudo bash cloud/pull-extra-images.sh lmcache    # LMCache
sudo bash cloud/pull-extra-images.sh router     # llm-d + vLLM-Router
sudo bash cloud/pull-extra-images.sh webui      # Open-WebUI
sudo bash cloud/pull-extra-images.sh verify     # cuda-sample

# 一次性全拉
sudo bash cloud/pull-extra-images.sh all
```

`pull-extra-images.sh` 会用 daocloud 代理拉，并 retag 成原始名字，K8s 引用能直接找到。

---

## 验证镜像清单（部署完成后）

集群里实际有哪些镜像：

```bash
# master 上
ssh ubuntu@<MASTER_PUBLIC>
sudo ctr -n k8s.io images ls -q | sort -u | wc -l   # 总数

# 看具体镜像
sudo ctr -n k8s.io images ls -q | sort -u
```

期望看到所有上面清单里的镜像（按你跑过的阶段）。

---

## 已知离线包不全的镜像

实测中发现下面这些镜像 `local/02-pull-images.sh` 默认会漏（用 `--full` 才会带，或者用 `cloud/pull-extra-images.sh` 补）：

- ❗ Calico 8 个子镜像（v3.6 默认清单只含 `tigera/operator`）
- ❗ NFD v0.17.2（GPU Operator 25.x 用这个版本，但本仓库版本号写的 v0.16.4 是错的）
- ❗ `nvcr.io/nvidia/gpu-feature-discovery:v0.17.0`（NGC 注册表可能找不到，但 GPU Operator 25.3 内置 GFD 不依赖此独立镜像）
- ❗ vllm/vllm-openai：清单默认 v0.6.3.post1，**这个版本不支持 Qwen3**，要改成 **v0.11.0**（CUDA 12.8）或 **v0.11.2**（CUDA 12.9，要驱动 580+）
- ❗ minio/mc 双版本（YAML 引用 2025-08-13，离线包是 2024-10-08）

**建议**：在 `versions.env` 里把 `VLLM_VERSION=v0.11.2`，`MC_VERSION=RELEASE.2025-08-13T08-35-41Z`，`NFD_VERSION=v0.17.2`，重跑 `local/02-pull-images.sh`。
