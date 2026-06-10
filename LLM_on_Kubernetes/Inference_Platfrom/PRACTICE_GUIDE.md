# Inference_Platfrom 实践指南（执行版）

> 适配环境：优云智算 2 节点云上部署
> YAML 已批量替换：节点名、mc 镜像版本、Secret base64（详见底座 DEPLOYMENT.md）

## 全局信息（用到时查）

### 节点信息

| 节点 | SSH | 内网 IP | 配置 |
|---|---|---|---|
| master | `ssh ubuntu@117.50.186.132` | `10.60.37.205` | 16C 64G + RTX 3090 24G |
| worker | `ssh ubuntu@117.50.205.129` | `10.60.236.197` | 16C 64G + RTX 3090 24G |

> 密码请用本地 ssh-config 或环境变量保存，不要 commit 到文件

### 软件栈

| 组件 | 版本 |
|---|---|
| OS | Ubuntu 22.04.4 LTS (kernel 5.15.0-113-generic) |
| NVIDIA Driver | **580.142** |
| CUDA | **13.0** |
| Kubernetes | v1.31.4 |
| containerd | v1.7.22 |
| Calico | v3.28.2（VXLAN MTU=1450） |
| vLLM 镜像 | `vllm/vllm-openai:v0.11.2`（要 CUDA ≥ 12.9） |

### 集群运行时信息

```bash
# 命名空间
kubectl 操作主要在 namespace: llm-inference

# LoadBalancer IP（MetalLB 分配段：10.60.37.200-220）
Ingress  : 10.60.37.210      curl 时加 -H "Host: vllm.magedu.com"
MinIO    : 10.60.37.211      account: admin / admin123456
MinIO UI : 10.60.37.212:9001

# 模型路径（MinIO 上）
llm-models/Qwen3-8B/    主 bucket（Inference_Platfrom 用）
qwen/Qwen3-8B/          复制份（level-1 用）

# 模型路径（节点本地，DaemonSet 预热后生成）
/data/models/qwen3-8b/

# 当前 containerd 已有镜像版本
vllm/vllm-openai:v0.11.2                ✓ 两节点
minio/mc:RELEASE.2024-10-08T09-37-26Z   ✓ 两节点
minio/mc:RELEASE.2025-08-13T08-35-41Z   ✓ 两节点（备用）
```

### 浏览器访问（可选）

集群 LoadBalancer IP 都是云内网，在 master 上 socat 转发暴露到公网：

```bash
ssh ubuntu@117.50.186.132
sudo apt install -y socat

# 后台转发
sudo nohup socat TCP-LISTEN:9001,fork,reuseaddr TCP:10.60.37.212:9001 > /tmp/socat-9001.log 2>&1 &  # MinIO Console
sudo nohup socat TCP-LISTEN:9000,fork,reuseaddr TCP:10.60.37.211:9000 > /tmp/socat-9000.log 2>&1 &  # MinIO API
sudo nohup socat TCP-LISTEN:80,fork,reuseaddr TCP:10.60.37.210:80 > /tmp/socat-80.log 2>&1 &        # Ingress

# 云控制台开 80 / 9000 / 9001 端口安全组
```

浏览器访问：
- MinIO Console: http://117.50.186.132:9001
- Ingress（推理 API）: http://117.50.186.132/  + Host header `vllm.magedu.com`（用 Postman 或 ModHeader 插件）

## 阶段总览

| # | 目录 | 实践目的 | 难度 | 你的硬件适配 |
|---|---|---|---|---|
| **1** | `01-Base/` | **PVC + InitContainer + vLLM 基础部署** | ★ | 单副本，固定 worker 节点 |
| 2 | `02-Preloader/` | 模型从 PVC 切到 HostPath，Pod 秒启 | ★★ | 2 节点都跑 preloader |
| 3 | `03-MultiReplica/` | StatefulSet 2 副本，理解 headless service | ★★ | replicas=2 正好用满 2 卡 |
| 4 | `04-BenchMark/` | 用 vllm bench 建性能基线 | ★★ | 跑在任意节点 |
| 5 | `05-KEDA-AutoScale/` | KEDA 基于指标自动扩缩 | ★★★ | **需先装 KEDA + Prometheus** |
| 6 | `06-GPU-Timeslicing/` | 1 张卡切多份给多 Pod | ★★★ | 让扩到 2+ 副本变可能 |
| 7 | `07-L1-Cache/` | APC + LMCache 加速首 token | ★★★ | 单独镜像 `lmcache/vllm-openai` |
| 8 | `08-LLM-Router/` | Cache-Aware 路由 | ★★★★ | **拉 llm-d 或 router 镜像** |
| 9 | `09-Canary-Deployment/` | Argo Rollouts 金丝雀 | ★★★★ | **需先装 Argo Rollouts** + 改 replicas |
| 10 | `Open-WebUI/` | 浏览器聊天界面 | ★ | 拉 open-webui 镜像 |

---

## 阶段 1：vLLM 基础部署（`01-Base/vLLM/`）

**实践目的**：跑通最简单的 vLLM 推理服务：PVC 存模型 + InitContainer 从 MinIO 拉模型 + 主容器加载到 GPU + Service + Ingress 暴露 OpenAI API。
这是 K8s 推理部署的最朴素形态，理解后续阶段都是在此基础上的演进。

**核心组件**：
- **`vllm-model-pvc.yaml`**：OpenEBS LocalPV 30Gi PVC（`volumeBindingMode: WaitForFirstConsumer`，跟 Pod 走）
- **`vllm-deployment.yaml`**：
  - InitContainer `model-puller`：用 `mc mirror` 从 MinIO 拉 Qwen3-8B 到 PVC（带 `.ready` 文件做幂等）
  - 主容器 `vllm`：`vllm/vllm-openai:v0.11.2` 加载模型、起 OpenAI API on :8000
  - `nodeSelector: kubernetes.io/hostname=k8s-node01` 固定节点（与 LocalPV 同节点）
- **`vllm-ingress.yaml`**：Ingress 暴露 `vllm.magedu.com` → vllm-service:8000

### 前置准备

```bash
ssh ubuntu@117.50.186.132
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/01-Base/vLLM

# 1. 创建命名空间
kubectl create namespace llm-inference

# 2. 创建 MinIO Secret（用当前 MinIO 实际凭据，覆盖仓库里的旧 modelskey）
kubectl create secret generic minio-credentials -n llm-inference \
  --from-literal=MINIO_ACCESS_KEY=admin \
  --from-literal=MINIO_SECRET_KEY=admin123456 \
  --dry-run=client -o yaml | kubectl apply -f -

# 验证
kubectl get secret minio-credentials -n llm-inference -o yaml | grep -A 2 data
```

### 操作步骤

```bash
# 1. 部署 PVC（initial Pending → WaitForFirstConsumer，正常）
kubectl apply -f vllm-model-pvc.yaml
kubectl get pvc -n llm-inference
# 期望：qwen3-8b-model-pvc-vllm   Pending   ... openebs-hostpath
# 这是 OpenEBS LocalPV 的设计：等 Pod 引用后才 Bound

# 2. 部署 Deployment + Ingress
kubectl apply -f vllm-deployment.yaml
kubectl apply -f vllm-ingress.yaml

# 3. 监控 Pod 状态
kubectl get pods -n llm-inference -w
# 期望流程：Init:0/1 → PodInitializing → 1/1 Running
```

### 验证方法

**Step 1：InitContainer 拉模型（1-3 分钟）**

```bash
POD=$(kubectl get pods -n llm-inference -l app=vllm-qwen3-8b -o name | head -1)
kubectl logs -n llm-inference $POD -c model-puller -f
# 期望看到：
#   [xxx] 首次同步：从MinIO下载qwen/qwen3-8b ...
#   [xxx] 同步完成。总大小: 15G（或类似）
#   [xxx] 关键文件校验通过
```

**Step 2：vLLM 加载模型（30-90 秒）**

```bash
kubectl logs -n llm-inference $POD -c vllm -f
# 期望看到：
#   INFO ... Loading model from /data/models/qwen3-8b
#   INFO ... Loaded weights ...
#   INFO ... Application startup complete
#   INFO ... Uvicorn running on http://0.0.0.0:8000
```

**Step 3：等 Pod Ready**

```bash
kubectl wait --for=condition=Ready pod -l app=vllm-qwen3-8b -n llm-inference --timeout=10m
kubectl get pods -n llm-inference
# 期望：vllm-qwen3-8b-xxx  1/1  Running
```

**Step 4：调 API 测试**

```bash
INGRESS_IP=10.60.37.210

# 列出模型
curl -s http://$INGRESS_IP/v1/models -H "Host: vllm.magedu.com" | jq

# 中文对话
curl -s http://$INGRESS_IP/v1/chat/completions \
  -H "Host: vllm.magedu.com" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-8b",
    "messages": [{"role":"user","content":"你好，一句话介绍一下自己"}],
    "max_tokens": 200,
    "chat_template_kwargs": {"enable_thinking": false}
  }' | jq -r '.choices[0].message.content'
```

**期望响应**（关思考模式后直接回答）：
```
你好！我是通义千问（Qwen），由阿里云开发的人工智能助手...
```

如果**不关思考模式**，Qwen3 默认会先 `<think>...</think>` 推理过程再给答案：
```json
{
  "choices": [{
    "message": {
      "content": "<think>\n好的，用户让我介绍一下自己...\n</think>\n\n你好！我是..."
    }
  }]
}
```

### ✅ 阶段 1 完成清单

- [x] PVC 状态 Bound（Pod 引用后自动绑定）
- [x] InitContainer 日志「关键文件校验通过」
- [x] vLLM 日志「Uvicorn running on http://0.0.0.0:8000」
- [x] `kubectl get pods` 显示 `1/1 Running`
- [x] `curl /v1/models` 列出 `qwen3-8b`
- [x] `curl /v1/chat/completions` 返回中文回复

### 实测踩坑（已规避）

| 现象 | 原因 | 处理（已在脚本/文档里固化） |
|---|---|---|
| Pod Pending `kubernetes.io/hostname` 不匹配 | 原 YAML 节点名 `k8s-node01.magedu.com` | 批量 sed 改成 `k8s-node01` |
| InitContainer 401 Unauthorized | YAML 里 Secret base64 是旧的 `modelskey` | 用 `kubectl create secret` 直接覆盖 |
| vLLM CrashLoop `Model architectures ['Qwen3ForCausalLM'] are not supported` | 镜像 `v0.6.3.post1` 不支持 Qwen3 | 改成 **`v0.11.2`**（vLLM ≥ 0.8.5 才支持） |
| CrashLoop `cuda>=12.9 not satisfied` | v0.11.2 要 CUDA 12.9，节点驱动 570 只支持 12.8 | **升级驱动到 580**（用 `cloud/upgrade-nvidia-driver.sh 580`） |
| InitContainer 拉模型卡住 | MinIO `minio.minio.svc.cluster.local` 解析失败 | 看 CoreDNS / 检查 Service IP `kubectl -n minio get svc` |
| livenessProbe 一直 fail | 模型加载 > 5 分钟 | YAML 已设 `initialDelaySeconds: 300`，足够 |
| Ingress 404 | 没传 Host header | curl 必须加 `-H "Host: vllm.magedu.com"` |

### 进入下一阶段前清理（可选）

阶段 1 用 PVC，阶段 2 改用 HostPath。阶段 2 操作步骤会先 `kubectl delete` 阶段 1 的 Deployment，**PVC 可以保留**作为备份，或者：

```bash
kubectl delete pvc qwen3-8b-model-pvc-vllm -n llm-inference --ignore-not-found
```

---

## 阶段 2：DaemonSet Preloader（`02-Preloader/`）

**实践目的**：阶段 1 用 PVC + InitContainer 每次 Pod 启动都拉 16GB 模型，重建 Pod 慢。
本阶段引入 DaemonSet 在 GPU 节点上**一次性预热模型到 HostPath**（`/data/models/qwen3-8b/`），Pod 用 hostPath 挂载，启动从分钟级降到秒级。

**新增组件**：
- DaemonSet：跑在每个 GPU 节点上的 pause + mc 容器，幂等同步 MinIO → 节点本地盘
- HostPath Volume：节点级共享，跨 Pod 重建保留

### 操作步骤

```bash
ssh ubuntu@117.50.186.132
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/02-Preloader

# 1. 清掉阶段 1 的 vLLM（保留 PVC 也可以，本阶段不用）
kubectl delete -f ../01-Base/vLLM/vllm-deployment.yaml --ignore-not-found
kubectl delete -f ../01-Base/vLLM/vllm-ingress.yaml --ignore-not-found

# 2. 部署 preloader DaemonSet（master + node01 各一个 Pod）
kubectl apply -f model-preloader-daemonset.yaml

# 3. 监控两节点同步
kubectl get pods -n llm-inference -l app=model-preloader -w
# 等到两个 Pod 都 Running（其中 puller init 容器 Completed）

# 看其中一个的日志
POD=$(kubectl get pods -n llm-inference -l app=model-preloader -o name | head -1)
kubectl logs -n llm-inference $POD -c model-puller

# 4. 部署 vLLM（hostPath 版）+ Ingress
kubectl apply -f vllm-deployment.yaml
kubectl apply -f vllm-ingress.yaml
```

### 验证方法

```bash
# 1) 节点本地真的有模型
ssh ubuntu@10.60.236.197 'sudo ls -lh /data/models/qwen3-8b/ | head -5'
# 应看到 5 个 safetensors + tokenizer

ssh ubuntu@10.60.37.205 'sudo ls -lh /data/models/qwen3-8b/ | head -5'
# 同上

# 2) vLLM Pod 启动时间 < 30 秒（对比阶段 1 几分钟）
kubectl get pods -n llm-inference -l app=vllm-qwen3-8b
# AGE 应该很短，1/1 Running

# 3) API 仍可用
curl -s http://10.60.37.210/v1/chat/completions \
  -H "Host: vllm.magedu.com" -H "Content-Type: application/json" \
  -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"在么"}],"max_tokens":50,"chat_template_kwargs":{"enable_thinking":false}}' | jq -r '.choices[0].message.content'

# 4) 删 vLLM Pod，看重新拉起速度
kubectl delete pod -n llm-inference -l app=vllm-qwen3-8b
time kubectl wait --for=condition=Ready pod -l app=vllm-qwen3-8b -n llm-inference --timeout=3m
# 期望 30-60 秒（因为没了 16GB 模型下载，但 vLLM 加载模型到 GPU 还要 30 秒）
```

### 常见坑
- preloader Pod 一直 ContainerCreating → 看 events 是否 hostPath 目录权限问题；先在节点上 `sudo mkdir -p /data/models && sudo chmod 777 /data/models`
- vLLM 报 `model not found` → 路径不对，确认 hostPath 是 `/data/models` 挂载到容器 `/data/models`，args 用 `/data/models/qwen3-8b`

---

## 阶段 3：StatefulSet 多副本（`03-MultiReplica/`）

**实践目的**：把 Deployment 换成 **StatefulSet**（有序、稳定网络标识、可独立挂载存储）+ ClusterIP Service 做负载均衡 + Headless Service 给 StatefulSet 用。
理解 K8s 里**有状态服务**的部署模式。

**新增概念**：
- StatefulSet 与 Deployment 的差别
- Headless Service（`clusterIP: None`）的作用
- Pod 索引化命名（`vllm-qwen3-8b-0`, `vllm-qwen3-8b-1`）

### 操作步骤

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/03-MultiReplica

# 1. 清掉阶段 2 的 vLLM Deployment（DaemonSet 保留，本阶段共用）
kubectl delete -f ../02-Preloader/vllm-deployment.yaml --ignore-not-found

# 2. apply 本阶段（DaemonSet 已存在，apply 会跳过/upgrade）
kubectl apply -f .
# 顺序：daemonset、statefulset、services、ingress
```

### 验证方法

```bash
# 1) 看到两个有序 Pod，分别在 master 和 node01
kubectl get pods -n llm-inference -l app=vllm-qwen3-8b -o wide
# 期望：
#   vllm-qwen3-8b-0   Running   k8s-master01 或 k8s-node01
#   vllm-qwen3-8b-1   Running   另一个节点

# 2) GPU 都被分配
kubectl describe nodes | grep -A 2 "nvidia.com/gpu"
# 两节点都应显示 nvidia.com/gpu  1/1

# 3) Service 负载均衡（多发请求看 Pod 日志，应该都收到）
for i in $(seq 1 10); do
  curl -s http://10.60.37.210/v1/chat/completions \
    -H "Host: vllm.magedu.com" -H "Content-Type: application/json" \
    -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"Hi #'$i'"}],"max_tokens":10}' \
    > /dev/null
done

# 看每个副本收到几个
kubectl logs -n llm-inference vllm-qwen3-8b-0 | grep -c "POST /v1/chat"
kubectl logs -n llm-inference vllm-qwen3-8b-1 | grep -c "POST /v1/chat"
# 两个数加起来 = 10，分布相对均匀
```

### 常见坑
- replicas=3 会 Pending：你只有 2 GPU，3 副本第三个排队。检查 YAML `replicas: 2`
- StatefulSet Pod 1 一直 Pending：检查 anti-affinity，可能两 Pod 想挤一个节点；YAML 应有 topologySpreadConstraints 让分散到不同节点

---

## 阶段 4：压测建基线（`04-BenchMark/`）

**实践目的**：用 vllm 自带的 `benchmark_serving` 工具压测，记录关键指标，作为后续优化对比基准。

**核心指标**：
- **TTFT**（Time To First Token，首 token 时延，P50/P99）
- **TPOT**（Time Per Output Token，每 token 时延）
- **吞吐量**（tokens/sec）
- **QPS / 并发数**

### 操作步骤

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/04-BenchMark
cat benchmark-client.yaml | head -30   # 先看一眼客户端配置（target URL、并发数等）

kubectl apply -f benchmark-client.yaml

# 跟着客户端 Pod 跑（通常是 Job 形式）
POD=$(kubectl get pods -n llm-inference -l app=vllm-benchmark -o name | head -1)
kubectl logs -n llm-inference $POD -f
```

### 验证方法

```bash
# 1) Benchmark 输出格式（示例，实际看 stdout）
# Successful requests: ...
# Request throughput (req/s): ...
# Median TTFT (ms): ...
# Median TPOT (ms): ...
# P99 TTFT (ms): ...

# 2) 把数据填到下面的表，后续阶段对比
```

**基线表（填一下）**：

| 指标 | 阶段 3 基线 | 阶段 5 KEDA | 阶段 6 Time-Slice | 阶段 7 LMCache |
|---|---|---|---|---|
| Median TTFT (ms) | | | | |
| P99 TTFT (ms) | | | | |
| Median TPOT (ms) | | | | |
| 吞吐 (tokens/s) | | | | |
| QPS | | | | |

### 常见坑
- 客户端 Pod 报连接超时：vllm-service 名字对不对（默认 `vllm-service.llm-inference.svc.cluster.local:8000`）
- 数据集没准备：benchmark client 通常需要 ShareGPT 或类似数据集，看 YAML 里 args 怎么指定

---

## 阶段 5：KEDA 自动扩缩容（`05-KEDA-AutoScale/`）

**实践目的**：基于 Prometheus 指标（队列深度、TTFT P99）让 vLLM 副本数自动扩缩，应对突发流量。

**新增组件**：
- **KEDA**（Kubernetes Event-Driven Autoscaler）
- **Prometheus + ServiceMonitor**（抓 vLLM 暴露的 `/metrics`）
- **ScaledObject** 资源（KEDA CRD，定义扩缩规则）
- 应用层 **backpressure**（vLLM 启动加参数返回 429 而非排队）

### 前置依赖（必装）

```bash
# 1. 装 Prometheus
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.service.type=LoadBalancer

# 2. 装 KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda -n keda --create-namespace

# 3. 验证 KEDA CRD
kubectl get crd scaledobjects.keda.sh
```

⚠️ Prometheus 镜像挺多（kube-state-metrics、node-exporter、alertmanager、grafana），云上拉用 daocloud 加速；离线包没有，要现拉。

### 操作步骤

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/05-KEDA-AutoScale

# 1. 清掉阶段 3 的 vLLM
kubectl delete -f ../03-MultiReplica/vllm-statefulset.yaml
kubectl delete -f ../03-MultiReplica/vllm-ingress.yaml

# 2. apply 本阶段（注意有 ScaledObject）
kubectl apply -f .

# 3. 看 ScaledObject 状态
kubectl get scaledobject -n llm-inference
kubectl describe scaledobject -n llm-inference vllm-scaledobject
```

### 验证方法

```bash
# 1) KEDA Operator 看到 ScaledObject
kubectl get hpa -n llm-inference
# 应有 keda-hpa-vllm-scaledobject

# 2) Prometheus 抓到 vLLM 指标
# 浏览器打开 grafana LoadBalancer IP，或 port-forward：
kubectl -n monitoring port-forward svc/kube-prometheus-prometheus 9090 &
# 然后访问 http://localhost:9090，搜索 `vllm:` 应有指标

# 3) 压测看副本数变化
kubectl get pods -n llm-inference -l app=vllm-qwen3-8b -w
# 在另一个终端跑压测，观察 Pod 数从 1 升到 N 再降回
```

### 常见坑
- 副本扩不上去：你只有 2 GPU，扩到 3+ 会 Pending。**必须先跑阶段 6 Time-Slicing**
- ScaledObject ACTIVE = False：Prometheus 没抓到指标，检查 ServiceMonitor 或 vLLM Pod 的 prometheus.io annotation
- Grafana 看不到 vLLM 指标：用 PromQL 直接查 `vllm:num_requests_running`，没有就是没 scrape 到

---

## 阶段 6：GPU Time-Slicing（`06-GPU-Timeslicing/`）

**实践目的**：把 1 张 3090 切成 N 个虚拟 GPU（时间片轮询），让多副本能挤同一张卡。
对你 2 卡场景特别有用：扩容到 4-6 副本变可能。

**新增概念**：
- NVIDIA Time-Slicing ConfigMap
- patch GPU Operator 让 device-plugin 用新配置
- `replicas` 字段控制切几份

### 操作步骤

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/06-GPU-Timeslicing

# 1. 看 Time-Slicing 配置（默认切几份）
cat Time-Slicing/nvidia-time-slicing-config.yaml
# 找 replicas: N 字段，N 是切片数。3090 24G 跑 Qwen3-8B (~16G) 建议 N=2

# 2. apply ConfigMap
kubectl apply -f Time-Slicing/nvidia-time-slicing-config.yaml

# 3. 让 GPU Operator 使用新配置
kubectl patch clusterpolicy/cluster-policy \
  -n gpu-operator --type merge \
  -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'

# 4. 重启 device-plugin DaemonSet
kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n gpu-operator

# 5. 等几分钟，看 GPU 资源数量变化
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
# 期望：master=N, node01=N（N>1）

# 6. 部署本阶段 vLLM（KEDA scaledobject 上限也可以拉高）
kubectl delete -f ../05-KEDA-AutoScale/ --ignore-not-found
kubectl apply -f .
```

### 验证方法

```bash
# 1) 单节点能跑多个 vLLM Pod（之前 1 张卡只能 1 Pod）
kubectl get pods -n llm-inference -o wide
# 期望：master 和 node01 上都有 >1 个 vllm pod

# 2) 跑压测触发扩容，看能扩到 4
kubectl get hpa -n llm-inference -w

# 3) GPU 真的在共享（多 Pod 用同一卡）
ssh ubuntu@10.60.37.205 'nvidia-smi'
# Processes 列看到多个 PID 占同一 GPU
```

### 常见坑
- 切多了 OOM：3090 24G 切 3 份就紧张了，每份 ≈ 8G，跑不动 Qwen3-8B（需要 16G）；推荐 **N=2**
- ConfigMap apply 后 GPU 数没变：检查 `kubectl get clusterpolicy -o yaml | grep -A 5 devicePlugin`，确认 patch 生效
- 多 Pod 共卡，但请求慢：Time-Slicing 是分时不是真并行，多 Pod 会互相抢，QPS 不会真线性上升

---

## 阶段 7：LMCache + APC（`07-L1-Cache/`）

**实践目的**：开启 vLLM 的 **Automatic Prefix Caching (APC)** 和外部 **LMCache** KV cache 后端。
重复或部分重复的 prompt 第二次请求 TTFT 大幅下降（80%+）。

**新增组件**：
- vLLM 启动加 `--enable-prefix-caching`
- LMCache（外部 KV cache 服务，可 CPU/GPU/磁盘后端）
- 用 **`lmcache/vllm-openai:v0.3.15`** 镜像（不是普通 vLLM）

### 前置依赖

```bash
# 拉 LMCache 镜像（国外 ghcr/docker hub，daocloud 代理）
# 两节点都做
sudo ctr -n k8s.io images pull docker.m.daocloud.io/lmcache/vllm-openai:v0.3.15
sudo ctr -n k8s.io images tag docker.m.daocloud.io/lmcache/vllm-openai:v0.3.15 docker.io/lmcache/vllm-openai:v0.3.15
```

### 操作步骤

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/07-L1-Cache

# 路径 A：vLLM 内置 APC（更简单）
kubectl delete -f ../06-GPU-Timeslicing/vllm-statefulset.yaml --ignore-not-found
kubectl apply -f vllm-statefulset-apc.yaml
kubectl apply -f vllm-services.yaml
kubectl apply -f vllm-ingress-backpressure.yaml

# 路径 B：LMCache 外部缓存（更强大）
kubectl apply -f LMCache/vllm-statefulset-lmcache.yaml
cat LMCache/test_lmcache.sh   # 看测试脚本
bash LMCache/test_lmcache.sh
```

### 验证方法

```bash
# 1) 同一 prompt 重复请求，第二次 TTFT 大幅下降
LONG_PROMPT="请详细解释 Kubernetes 的核心架构，包括 control plane、kubelet、kube-proxy、etcd、scheduler、controller-manager 等组件的职责。"

# 第一次（冷启动，cache miss）
time curl -s http://10.60.37.210/v1/chat/completions \
  -H "Host: vllm.magedu.com" -H "Content-Type: application/json" \
  -d "{\"model\":\"qwen3-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"$LONG_PROMPT\"}],\"max_tokens\":1,\"chat_template_kwargs\":{\"enable_thinking\":false}}" > /dev/null

# 第二次（cache hit）
time curl -s http://10.60.37.210/v1/chat/completions \
  -H "Host: vllm.magedu.com" -H "Content-Type: application/json" \
  -d "{\"model\":\"qwen3-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"$LONG_PROMPT\"}],\"max_tokens\":1,\"chat_template_kwargs\":{\"enable_thinking\":false}}" > /dev/null

# 期望第二次比第一次快 50%-80%

# 2) Prometheus 指标看命中率
# vllm:num_preemptions_total / vllm:gpu_cache_usage_perc
```

### 常见坑
- LMCache 镜像启动失败：镜像基础是 vLLM 但版本可能跟 v0.11.2 不同，注意启动参数兼容性
- APC 没生效：确认 vLLM args 有 `--enable-prefix-caching`
- 重复请求 TTFT 没变：可能 KV cache 太小被驱逐，调 `--num-gpu-blocks-override`

---

## 阶段 8：Cache-Aware 路由（`08-LLM-Router/`）

**实践目的**：替换简单的 Service 轮询，用智能路由器把 **同前缀** 请求送到 **同一后端 Pod**，最大化缓存命中。

**两个方案**：
- **`vLLM-Router/`**（推荐先做）：vLLM 官方路由（`lmcache/lmstack-router:latest`）
- **`llm-d/`**：CNCF llm-d 项目（`ghcr.io/llm-d/llm-d-cuda:v0.6.0`，更复杂、更强）

### 前置依赖

```bash
# vLLM-Router 镜像
sudo ctr -n k8s.io images pull docker.m.daocloud.io/lmcache/lmstack-router:latest
sudo ctr -n k8s.io images tag docker.m.daocloud.io/lmcache/lmstack-router:latest docker.io/lmcache/lmstack-router:latest

# llm-d 镜像（ghcr.io 国内访问难，用 daocloud）
sudo ctr -n k8s.io images pull ghcr.m.daocloud.io/llm-d/llm-d-cuda:v0.6.0
sudo ctr -n k8s.io images tag ghcr.m.daocloud.io/llm-d/llm-d-cuda:v0.6.0 ghcr.io/llm-d/llm-d-cuda:v0.6.0
```

### 操作步骤（先做 vLLM-Router）

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/08-LLM-Router/vLLM-Router

kubectl apply -f vllm-router-rbac.yaml
kubectl apply -f vllm-router-deployment.yaml
kubectl apply -f vllm-router-ingress.yaml
# 注意：原 vLLM Service 保留作为后端，Ingress 改指 Router

kubectl get pods -n llm-inference -l app=vllm-router
```

### 验证方法

```bash
# 1) 同前缀请求路由到同一 Pod
LONG_CTX="你是一个 Kubernetes 专家。请回答："

for q in "什么是 Pod" "什么是 Service" "什么是 Pod"; do
  curl -s http://10.60.37.210/v1/chat/completions \
    -H "Host: vllm.magedu.com" -H "Content-Type: application/json" \
    -d "{\"model\":\"qwen3-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"$LONG_CTX $q\"}],\"max_tokens\":1}" > /dev/null
done

# 看 Pod 日志，相同 q 的请求应该落在同一 Pod
kubectl logs vllm-qwen3-8b-0 -n llm-inference | tail -20
kubectl logs vllm-qwen3-8b-1 -n llm-inference | tail -20
```

### 常见坑
- Router 启动失败：看日志是否有 KV indexer 相关错误，可能要先确保所有 vLLM 实例都开启了 APC
- 配置太复杂：`llm-d-config.yaml` 里有 inferencePool / inferenceModel CRD，需要先理解 llm-d 概念
- Ingress 改指错：原 ingress 指 vllm-service:8000，本阶段应指 vllm-router-service

---

## 阶段 9：金丝雀发布（`09-Canary-Deployment/`）

**实践目的**：用 Argo Rollouts 做 vLLM 版本/模型的灰度发布。10% 流量 → 监控指标 → 自动 promote 或 abort。

**新增组件**：
- **Argo Rollouts CRD + Controller**
- **Rollout** 资源（替代 Deployment/StatefulSet）
- **AnalysisTemplate**（基于 Prometheus 自动评估金丝雀健康度）
- stable + canary 两套 Service

⚠️ **YAML 里 replicas=3**，你只有 2 GPU，**必须先做阶段 6 Time-Slicing**，或者把 replicas 改成 2。

### 前置依赖

```bash
# 装 Argo Rollouts
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# 装 kubectl 插件（可选，方便观察）
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

# 验证
kubectl get crd rollouts.argoproj.io
```

### 操作步骤

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/09-Canary-Deployment

# 如果你没做阶段 6 Time-Slicing，先改 replicas
sed -i 's|replicas: 3|replicas: 2|' vllm-rollout.yaml

# 清掉之前的 statefulset
kubectl delete statefulset vllm-qwen3-8b -n llm-inference --ignore-not-found

# 部署本阶段
kubectl apply -f .

# 观察 Rollout（推荐用插件）
kubectl argo rollouts get rollout vllm-rollout -n llm-inference -w

# 触发金丝雀升级（改镜像或配置）
kubectl argo rollouts set image vllm-rollout vllm=vllm/vllm-openai:v0.11.2 -n llm-inference
# 流量按 step 设置 10% → 25% → 50% → 100%

# 跑验证脚本
bash verify-canary.sh
```

### 验证方法

```bash
# 1) 流量按比例分配
# 持续打请求，看 stable / canary Pod 收到的比例

# 2) 故意触发失败，AnalysisRun 自动 abort
# 部署一个会启动失败的镜像版本：
kubectl argo rollouts set image vllm-rollout vllm=vllm/vllm-openai:v0.0.0-fake -n llm-inference
# 看 Rollout 自动 abort 并回滚

# 3) 历史版本管理
kubectl argo rollouts history rollout vllm-rollout -n llm-inference
```

### 常见坑
- AnalysisTemplate 引用的 metric 在 Prometheus 找不到：检查 PromQL 在 Prometheus UI 是否查得到
- replicas=3 Pending：减到 2，或先做 Time-Slicing 让单节点能跑 2 Pod

---

## 阶段 10：Open-WebUI（`Open-WebUI/`）

**实践目的**：装一个 ChatGPT 风格的前端，接到 vLLM 的 OpenAI API，浏览器聊天。

### 前置依赖

```bash
# 拉 Open-WebUI 镜像（国外 ghcr.io）
sudo ctr -n k8s.io images pull ghcr.m.daocloud.io/open-webui/open-webui:main
sudo ctr -n k8s.io images tag ghcr.m.daocloud.io/open-webui/open-webui:main ghcr.io/open-webui/open-webui:main
```

### 操作步骤

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/Open-WebUI

# 看 deployment 配置，特别是 OPENAI_API_BASE_URL 是否指向 vllm-service
cat openwebui-deployment.yaml | grep -A 2 OPENAI

kubectl apply -f .

# 等 Pod Ready
kubectl wait --for=condition=Ready pod -l app=open-webui -n llm-inference --timeout=5m
```

### 验证方法

```bash
# Ingress host 是 openwebui.magedu.com
# 选项 A：本地 hosts 文件加映射
echo "117.50.186.132 openwebui.magedu.com" | sudo tee -a /etc/hosts
# 浏览器：http://openwebui.magedu.com

# 选项 B：socat 转发，不用改 hosts
ssh ubuntu@117.50.186.132 'sudo nohup socat TCP-LISTEN:8080,fork,reuseaddr TCP:10.60.37.210:80 &'
# 浏览器：http://117.50.186.132:8080 + 在浏览器加 Host header（用 ModHeader 插件）

# 首次注册账号，开始聊天，能调用 qwen3-8b
```

---

## 阶段间清理建议

每完成一阶段开始下一阶段前，清掉本阶段的 vLLM 副本资源（避免端口/调度冲突）：

```bash
# 通用清理
kubectl delete statefulset,deployment,rollout -n llm-inference -l app=vllm-qwen3-8b --ignore-not-found
# DaemonSet preloader 和 PVC 可以保留，跨阶段复用
```

---

## 整体进度勾选

| 阶段 | 状态 | 完成日期 | 备注 |
|---|---|---|---|
| 1  Base | ✅ | 2026-06-09 | vLLM v0.11.2 + Qwen3 跑通 |
| 2  Preloader | ☐ | | |
| 3  MultiReplica | ☐ | | |
| 4  BenchMark | ☐ | | |
| 5  KEDA | ☐ | | 装 KEDA + Prometheus |
| 6  Time-Slicing | ☐ | | |
| 7  L1-Cache | ☐ | | 拉 LMCache 镜像 |
| 8  LLM-Router | ☐ | | 拉 llm-d 或 router 镜像 |
| 9  Canary | ☐ | | 装 Argo Rollouts |
| 10 Open-WebUI | ☐ | | |

---

## 通用排错速查

| 现象 | 原因 / 处理 |
|---|---|
| Pod Pending `nvidia.com/gpu` insufficient | GPU 都被占；删别的 vLLM Pod 或开 Time-Slicing |
| ImagePullBackOff for `ghcr.io/...` | 用 daocloud 代理：`ctr pull ghcr.m.daocloud.io/<path>` 后 retag |
| ImagePullBackOff with `@sha256:...` | chart 用 digest 引用，helm 加 `--set image.digest=""` |
| initContainer 拉模型卡住 | DNS 解析 minio.minio.svc 失败，看 CoreDNS 状态 |
| vLLM OOM | 降 `--gpu-memory-utilization` 或 `--max-model-len` |
| livenessProbe 失败 | vLLM 加载慢，调 `initialDelaySeconds` |
| 跨节点 Service 不通 | 看 Calico Pod 健康 + kube-proxy 模式 |
| Ingress 404 | curl 加 `-H "Host: vllm.magedu.com"` |
| KEDA 扩不上去 | 物理 GPU 不够，做 Time-Slicing |
| Prometheus 没指标 | 看 ServiceMonitor + vLLM Pod annotations |

---

## 卡住了？

1. 描述卡在哪个阶段哪一步
2. 贴 `kubectl describe pod ...` 和 `kubectl logs ... --previous` 输出
3. 一起排查

完成所有阶段后，恭喜你掌握了 K8s 上 LLM 推理服务的**生产级部署技能**。
