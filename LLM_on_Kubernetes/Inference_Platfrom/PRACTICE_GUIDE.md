# Inference_Platfrom 实践指南（执行版）

> 适配环境：优云智算 2 节点云上部署
> YAML 已批量替换：节点名、mc 镜像版本、Secret base64（详见底座 DEPLOYMENT.md）

## 全局信息（用到时查）

### 节点信息

| 节点     | SSH                         | 内网 IP           | 配置                     |
| ------ | --------------------------- | --------------- | ---------------------- |
| master | `ssh ubuntu@117.50.186.132` | `10.60.37.205`  | 16C 64G + RTX 3090 24G |
| worker | `ssh ubuntu@117.50.205.129` | `10.60.236.197` | 16C 64G + RTX 3090 24G |

> 密码请用本地 ssh-config 或环境变量保存，不要 commit 到文件

### 软件栈

| 组件            | 版本                                       |
| ------------- | ---------------------------------------- |
| OS            | Ubuntu 22.04.4 LTS (kernel 5.15.0-113-generic) |
| NVIDIA Driver | **580.142**                              |
| CUDA          | **13.0**                                 |
| Kubernetes    | v1.31.4                                  |
| containerd    | v1.7.22                                  |
| Calico        | v3.28.2（VXLAN MTU=1450）                  |
| vLLM 镜像       | `vllm/vllm-openai:v0.11.2`（要 CUDA ≥ 12.9） |

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

| #     | 目录                      | 实践目的                                 | 难度   | 你的硬件适配                             |
| ----- | ----------------------- | ------------------------------------ | ---- | ---------------------------------- |
| **1** | `01-Base/`              | **PVC + InitContainer + vLLM 基础部署**  | ★    | 单副本，固定 worker 节点                   |
| 2     | `02-Preloader/`         | 模型从 PVC 切到 HostPath，Pod 秒启           | ★★   | 2 节点都跑 preloader                   |
| 3     | `03-MultiReplica/`      | StatefulSet 2 副本，理解 headless service | ★★   | replicas=2 正好用满 2 卡                |
| 4     | `04-BenchMark/`         | 用 vllm bench 建性能基线                   | ★★   | 跑在任意节点                             |
| 5     | `05-KEDA-AutoScale/`    | KEDA 基于指标自动扩缩                        | ★★★  | **需先装 KEDA + Prometheus**          |
| 6     | `06-GPU-Timeslicing/`   | 1 张卡切多份给多 Pod                        | ★★★  | 让扩到 2+ 副本变可能                       |
| 7     | `07-L1-Cache/`          | APC + LMCache 加速首 token              | ★★★  | 单独镜像 `lmcache/vllm-openai`         |
| 8     | `08-LLM-Router/`        | Cache-Aware 路由                       | ★★★★ | **拉 llm-d 或 router 镜像**            |
| 9     | `09-Canary-Deployment/` | Argo Rollouts 金丝雀                    | ★★★★ | **需先装 Argo Rollouts** + 改 replicas |
| 10    | `Open-WebUI/`           | 浏览器聊天界面                              | ★    | 拉 open-webui 镜像                    |

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

| 现象                                       | 原因                                       | 处理（已在脚本/文档里固化）                           |
| ---------------------------------------- | ---------------------------------------- | ---------------------------------------- |
| Pod Pending `kubernetes.io/hostname` 不匹配 | 原 YAML 节点名 `k8s-node01.magedu.com`       | 批量 sed 改成 `k8s-node01`                   |
| InitContainer 401 Unauthorized           | YAML 里 Secret base64 是旧的 `modelskey`     | 用 `kubectl create secret` 直接覆盖           |
| vLLM CrashLoop `Model architectures ['Qwen3ForCausalLM'] are not supported` | 镜像 `v0.6.3.post1` 不支持 Qwen3              | 改成 **`v0.11.2`**（vLLM ≥ 0.8.5 才支持）       |
| CrashLoop `cuda>=12.9 not satisfied`     | v0.11.2 要 CUDA 12.9，节点驱动 570 只支持 12.8    | **升级驱动到 580**（用 `cloud/upgrade-nvidia-driver.sh 580`） |
| InitContainer 拉模型卡住                      | MinIO `minio.minio.svc.cluster.local` 解析失败 | 看 CoreDNS / 检查 Service IP `kubectl -n minio get svc` |
| livenessProbe 一直 fail                    | 模型加载 > 5 分钟                              | YAML 已设 `initialDelaySeconds: 300`，足够    |
| Ingress 404                              | 没传 Host header                           | curl 必须加 `-H "Host: vllm.magedu.com"`    |

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

#pod初始化失败--原因为pause版本使用的3.9，下载的镜像为3.10，替换后重新apply
sed -i 's|registry.k8s.io/pause:3.9|registry.k8s.io/pause:3.10|' /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/02-Preloader/model-preloader-daemonset.yaml

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
ssh ubuntu@117.50.205.129 'sudo ls -lh /data/models/qwen3-8b/ | head -15'
# 应看到 5 个 safetensors + tokenizer

ssh ubuntu@117.50.186.132 'sudo ls -lh /data/models/qwen3-8b/ | head -51'
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
# 期望 60-120 秒（因为没了 16GB 模型下载，但 vLLM 加载模型到 GPU 还要 30 秒）

⏺ 根据之前的 vLLM 启动日志，耗时分解如下：                                                                                                                                                                                             
                                                                                                                                                                                                                                       
  ┌───────────────────────────┬──────┬───────────────────────────────────────────────┐                                                                                                                                                 
  │           阶段            │ 耗时 │                     说明                      │                                                                                                                                                 
  ├───────────────────────────┼──────┼───────────────────────────────────────────────┤                                                                                                                                                 
  │ InitContainer（模型同步） │ ~10s │ HostPath 已有模型，秒跳 ✅                    │                                                                                                                                                 
  ├───────────────────────────┼──────┼───────────────────────────────────────────────┤
  │ 加载权重到 GPU            │ ~87s │ 15.3 GiB safetensors 从磁盘读入显存，主要瓶颈 │
  ├───────────────────────────┼──────┼───────────────────────────────────────────────┤
  │ torch.compile             │ ~24s │ 图编译 + CUDA graph 预热                      │
  ├───────────────────────────┼──────┼───────────────────────────────────────────────┤
  │ KV cache 初始化           │ ~2s  │ 分配 4.49 GiB 缓存                            │
  └───────────────────────────┴──────┴───────────────────────────────────────────────┘
```

### ✅ 阶段 2 完成清单

- [x] DaemonSet 两节点 Pod 均 Running（init 容器 Completed）
- [x] master 节点 `/data/models/qwen3-8b/` 有 5 个 safetensors + tokenizer
- [x] worker 节点 `/data/models/qwen3-8b/` 同上
- [x] vLLM hostPath 版 Pod `1/1 Running`
- [x] API 调用正常返回中文回复
- [x] Pod 重建耗时 ~2min（权重加载 87s + torch compile 24s，无模型下载）

### 实测踩坑（已规避）

| 现象                                       | 原因                               | 处理（已在脚本/文档里固化）        |
| ---------------------------------------- | -------------------------------- | --------------------- |
| preloader Pod `ImagePullBackOff` pause:3.9 | `registry.k8s.io` 国内超时，节点只有 3.10 | `sed` 改成 `pause:3.10` |
| Pod 重建 2min 而非预期 30-60s                  | 权重加载 87s + torch compile 24s     | 预期值已修正，属正常范围          |

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
for i in $(seq 1 100); do
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

### ✅ 阶段 3 完成清单

- [x] `vllm-qwen3-8b-0` 和 `vllm-qwen3-8b-1` 分别在 master / node01 上 Running
- [x] 两节点 GPU 均被分配（`nvidia.com/gpu 1/1`）
- [x] Service 负载均衡验证：100 次请求两副本均有收到
- [x] Headless Service + ClusterIP Service 均正常

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

# 1. 部署 benchmark 客户端 Pod（sleep infinity，exec 进去手动跑）
kubectl apply -f benchmark-client.yaml
kubectl wait --for=condition=Ready pod -l app=benchmark-client -n llm-inference --timeout=3m

# 2. 进入 Pod
kubectl exec -it -n llm-inference deploy/benchmark-client -- bash

# 3. 下载 ShareGPT 数据集（Pod 内执行，约 640MB）
curl -sL https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json -o /tmp/sharegpt.json

# 4. 执行压测（50 请求，RPS=5）
vllm bench serve --model qwen3-8b --base-url http://vllm-service:8000 --dataset-name sharegpt --dataset-path /tmp/sharegpt.json --num-prompts 50 --request-rate 5 --tokenizer /data/models/qwen3-8b
```

### 实测结果（2026-06-15，单副本 RTX 3090，Qwen3-8B）

```
============ Serving Benchmark Result ============
Successful requests:                     50
Failed requests:                         0
Request rate configured (RPS):           5.00
Benchmark duration (s):                  20.97
Total input tokens:                      12332
Total generated tokens:                  10349
Request throughput (req/s):              2.38
Output token throughput (tok/s):         493.57
Peak output token throughput (tok/s):    1072.00
Peak concurrent requests:                32.00
Total Token throughput (tok/s):          1081.72
---------------Time to First Token----------------
Mean TTFT (ms):                          116.16
Median TTFT (ms):                        119.96
P99 TTFT (ms):                           245.53
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          25.12
Median TPOT (ms):                        24.48
P99 TPOT (ms):                           31.28
---------------Inter-token Latency----------------
Mean ITL (ms):                           24.37
Median ITL (ms):                         22.72
P99 ITL (ms):                            103.09
==================================================
```

**基线表**：

| 指标               | 阶段 4 基线（单副本） | 阶段 5 KEDA | 阶段 6 Time-Slice | 阶段 7 LMCache |
| ---------------- | ------------ | --------- | --------------- | ------------ |
| Median TTFT (ms) | 119.96       |           |                 |              |
| P99 TTFT (ms)    | 245.53       |           |                 |              |
| Median TPOT (ms) | 24.48        |           |                 |              |
| 吞吐 (tok/s)       | 493.57       |           |                 |              |
| 峰值吞吐 (tok/s)     | 1072.00      |           |                 |              |
| 请求吞吐 (req/s)     | 2.38         |           |                 |              |

### ✅ 阶段 4 完成清单

- [x] benchmark-client Pod Running，可 exec 进入
- [x] ShareGPT 数据集下载成功（~640MB）
- [x] `vllm bench serve` 50 请求全部成功（0 失败）
- [x] 基线指标已记录：TTFT P50=120ms / P99=246ms，TPOT P50=24ms，吞吐 494 tok/s
- [x] 基线表已填入文档，供后续阶段对比

### 实测踩坑（已规避）

| 现象                              | 原因                                    | 处理（已在脚本/文档里固化） |
| ------------------------------- | ------------------------------------- | -------------- |
| `run_batch` 报缺参数                | 用错了命令，应该用 `vllm bench serve`          | 文档已修正为正确命令     |
| `dataset_path must be provided` | sharegpt 数据集需手动下载并指定 `--dataset-path` | 操作步骤已加入下载步骤    |

### 常见坑
- 客户端 Pod 报连接超时：vllm-service 名字对不对（默认 `vllm-service.llm-inference.svc.cluster.local:8000`）
- 数据集没准备：benchmark client 通常需要 ShareGPT 或类似数据集，需先 `curl` 下载到 `/tmp/sharegpt.json`

---

## 阶段 5：KEDA 自动扩缩容（`05-KEDA-AutoScale/`）

**实践目的**：基于 Prometheus 指标（队列深度、TTFT P99）让 vLLM 副本数自动扩缩，应对突发流量。

**新增组件**：
- **KEDA**（Kubernetes Event-Driven Autoscaler）
- **Prometheus + ServiceMonitor**（抓 vLLM 暴露的 `/metrics`）
- **ScaledObject** 资源（KEDA CRD，定义扩缩规则）
- 应用层 **backpressure**（vLLM 启动加参数返回 429 而非排队）

### 前置准备：镜像预拉取

⚠️ **本阶段镜像最多，全部来自国外源（ghcr.io / quay.io / registry.k8s.io），必须提前用 DaoCloud 代理拉取到两节点，否则 Pod 会长时间卡在 ContainerCreating。**

建议在 **master 节点**上拉取（网速更快），然后 `ctr export` + `scp` 传到 node01。

```bash
# ========== 在 master 上执行 ==========

# --- Prometheus 镜像（6 个）---
sudo ctr -n k8s.io images pull quay.m.daocloud.io/prometheus-operator/prometheus-operator:v0.91.0
sudo ctr -n k8s.io images tag quay.m.daocloud.io/prometheus-operator/prometheus-operator:v0.91.0 quay.io/prometheus-operator/prometheus-operator:v0.91.0

sudo ctr -n k8s.io images pull quay.m.daocloud.io/prometheus-operator/prometheus-config-reloader:v0.91.0
sudo ctr -n k8s.io images tag quay.m.daocloud.io/prometheus-operator/prometheus-config-reloader:v0.91.0 quay.io/prometheus-operator/prometheus-config-reloader:v0.91.0

sudo ctr -n k8s.io images pull quay.m.daocloud.io/prometheus/prometheus:v3.12.0-distroless
sudo ctr -n k8s.io images tag quay.m.daocloud.io/prometheus/prometheus:v3.12.0-distroless quay.io/prometheus/prometheus:v3.12.0-distroless

sudo ctr -n k8s.io images pull quay.m.daocloud.io/prometheus/alertmanager:v0.33.0
sudo ctr -n k8s.io images tag quay.m.daocloud.io/prometheus/alertmanager:v0.33.0 quay.io/prometheus/alertmanager:v0.33.0

sudo ctr -n k8s.io images pull quay.m.daocloud.io/prometheus/node-exporter:v1.11.1-distroless
sudo ctr -n k8s.io images tag quay.m.daocloud.io/prometheus/node-exporter:v1.11.1-distroless quay.io/prometheus/node-exporter:v1.11.1-distroless

sudo ctr -n k8s.io images pull k8s.m.daocloud.io/kube-state-metrics/kube-state-metrics:v2.19.1
sudo ctr -n k8s.io images tag k8s.m.daocloud.io/kube-state-metrics/kube-state-metrics:v2.19.1 registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.1

# --- Grafana 镜像（2 个）---
sudo ctr -n k8s.io images pull docker.m.daocloud.io/grafana/grafana:13.0.2
sudo ctr -n k8s.io images tag docker.m.daocloud.io/grafana/grafana:13.0.2 docker.io/grafana/grafana:13.0.2

sudo ctr -n k8s.io images pull quay.m.daocloud.io/kiwigrid/k8s-sidecar:2.7.3
sudo ctr -n k8s.io images tag quay.m.daocloud.io/kiwigrid/k8s-sidecar:2.7.3 quay.io/kiwigrid/k8s-sidecar:2.7.3

# --- Admission Webhook（helm install 时用 override 替代）---
# 原镜像 ghcr.io/jkroepke/kube-webhook-certgen:1.8.3 拉不到
# 安装时用 --set 替换为 registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4（节点已有）

# --- KEDA 镜像（3 个）---
sudo ctr -n k8s.io images pull ghcr.m.daocloud.io/kedacore/keda:2.20.1
sudo ctr -n k8s.io images tag ghcr.m.daocloud.io/kedacore/keda:2.20.1 ghcr.io/kedacore/keda:2.20.1

sudo ctr -n k8s.io images pull ghcr.m.daocloud.io/kedacore/keda-admission-webhooks:2.20.1
sudo ctr -n k8s.io images tag ghcr.m.daocloud.io/kedacore/keda-admission-webhooks:2.20.1 ghcr.io/kedacore/keda-admission-webhooks:2.20.1

sudo ctr -n k8s.io images pull ghcr.m.daocloud.io/kedacore/keda-metrics-apiserver:2.20.1
sudo ctr -n k8s.io images tag ghcr.m.daocloud.io/kedacore/keda-metrics-apiserver:2.20.1 ghcr.io/kedacore/keda-metrics-apiserver:2.20.1

# ========== 传到 node01 ==========
# 批量导出、传输、导入（以 keda 为例，其他镜像同理）
for IMG in "ghcr.io/kedacore/keda:2.20.1" "ghcr.io/kedacore/keda-admission-webhooks:2.20.1" "ghcr.io/kedacore/keda-metrics-apiserver:2.20.1" "quay.io/prometheus/prometheus:v3.12.0-distroless" "quay.io/prometheus/alertmanager:v0.33.0" "quay.io/prometheus-operator/prometheus-config-reloader:v0.91.0" "docker.io/grafana/grafana:13.0.2"; do
  FNAME=$(echo $IMG | tr '/:' '__')
  sudo ctr -n k8s.io images export /tmp/${FNAME}.tar ${IMG}
  scp /tmp/${FNAME}.tar ubuntu@10.60.236.197:/tmp/
  ssh ubuntu@10.60.236.197 "sudo ctr -n k8s.io images import /tmp/${FNAME}.tar"
  echo "✓ $IMG 已传到 node01"
done
```

### 前置依赖安装

```bash
# 1. 装 Prometheus（注意 webhook 镜像 override）
helm repo add prometheus-community https://helm-charts.itboon.top/prometheus-community --force-update
helm repo update
helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.service.type=LoadBalancer \
  --set prometheusOperator.admissionWebhooks.patch.image.registry=registry.k8s.io \
  --set prometheusOperator.admissionWebhooks.patch.image.repository=ingress-nginx/kube-webhook-certgen \
  --set prometheusOperator.admissionWebhooks.patch.image.tag=v1.4.4

# 2. 装 KEDA（helm repo 国内也可能慢，提前 add）
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda -n keda --create-namespace \
  --set image.keda.pullPolicy=IfNotPresent \
  --set image.metricsApiServer.pullPolicy=IfNotPresent \
  --set image.webhooks.pullPolicy=IfNotPresent

# 3. 验证
kubectl get crd scaledobjects.keda.sh
kubectl get pods -n monitoring
kubectl get pods -n keda
# 期望：所有 Pod Running
```

### 操作步骤

```bash
cd /opt/llm-in-practise/LLM_on_Kubernetes/Inference_Platfrom/05-KEDA-AutoScale

# 1. 清掉阶段 3 的 vLLM
kubectl delete -f ../03-MultiReplica/vllm-statefulset.yaml --ignore-not-found
kubectl delete -f ../03-MultiReplica/vllm-ingress.yaml --ignore-not-found

# 2. 修正 ScaledObject 里的 Prometheus 地址（默认写的地址可能不对）
# 确认实际 Prometheus Service 名：
kubectl get svc -n monitoring | grep prometheus
# 替换为实际地址（helm 安装的名称）：
sed -i 's|http://prometheus-server.monitoring.svc.cluster.local:9090|http://kube-prometheus-kube-prome-prometheus.monitoring.svc.cluster.local:9090|g' keda-scaledobject.yaml

# 3. 部署本阶段
kubectl apply -f .

# 4. 创建 ServiceMonitor（让 Prometheus 抓 vLLM 指标）
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vllm-metrics
  namespace: llm-inference
  labels:
    app: vllm-qwen3-8b
spec:
  selector:
    matchLabels:
      app: vllm-qwen3-8b
  endpoints:
  - port: http
    path: /metrics
    interval: 15s
EOF

# 5. 验证 ScaledObject 状态
kubectl get scaledobject -n llm-inference
kubectl get hpa -n llm-inference
```

### 验证方法

```bash
# 1) KEDA ScaledObject 状态
kubectl get scaledobject -n llm-inference
# 期望：READY=True  ACTIVE=True

kubectl get hpa -n llm-inference
# 期望：keda-hpa-vllm-qwen3-8b-scaler 存在

# 2) Prometheus 能抓到 vLLM 指标（等 1-2 分钟后执行）
kubectl run -n monitoring prom-test --rm -it --image=busybox --restart=Never -- \
  wget -qO- 'http://kube-prometheus-kube-prome-prometheus.monitoring.svc.cluster.local:9090/api/v1/query?query=vllm:num_requests_running'
# 期望返回 JSON，result 数组有 vllm-qwen3-8b 的数据

# 3) Grafana 浏览器访问（可选）
# master 上 socat 转发：
sudo nohup socat TCP-LISTEN:3000,fork,reuseaddr TCP:10.60.37.213:80 > /tmp/socat-3000.log 2>&1 &
# 浏览器：http://117.50.186.132:3000（安全组放行 3000 端口）
# 密码：kubectl get secret -n monitoring kube-prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo

# 4) 压测触发扩容
# 终端 1：监控 Pod 变化
kubectl get pods -n llm-inference -l app=vllm-qwen3-8b -w

# 终端 2：进 benchmark-client 发压
kubectl exec -it -n llm-inference deploy/benchmark-client -- bash
vllm bench serve --model qwen3-8b --base-url http://vllm-service:8000 --dataset-name sharegpt --dataset-path /tmp/sharegpt.json --num-prompts 100 --request-rate 10 --tokenizer /data/models/qwen3-8b

# 期望：vllm-qwen3-8b-1 被拉起（1→2 副本）

# 5) 等待缩容（压测结束后 5 分钟，cooldownPeriod=300s）
watch -n 30 'kubectl get hpa -n llm-inference; echo "---"; kubectl get pods -n llm-inference -l app=vllm-qwen3-8b'
# 期望：REPLICAS 从 2 降回 1，vllm-qwen3-8b-1 被删除
```

### 实测结果（2026-06-15，KEDA 双副本扩容，1000 请求 RPS=10）

```
============ Serving Benchmark Result ============
Successful requests:                     1000
Failed requests:                         0
Request rate configured (RPS):           10.00
Benchmark duration (s):                  207.29
Total input tokens:                      217393
Total generated tokens:                  201778
Request throughput (req/s):              4.82
Output token throughput (tok/s):         973.39
Peak output token throughput (tok/s):    1360.00
Peak concurrent requests:                508.00
Total Token throughput (tok/s):          2022.10
---------------Time to First Token----------------
Mean TTFT (ms):                          45045.18
Median TTFT (ms):                        43032.04
P99 TTFT (ms):                           97364.50
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          27.93
Median TPOT (ms):                        27.12
P99 TPOT (ms):                           47.72
---------------Inter-token Latency----------------
Mean ITL (ms):                           27.70
Median ITL (ms):                         23.89
P99 ITL (ms):                            142.89
==================================================
```

**与阶段 4 基线对比**：

| 指标 | 阶段 4 基线（单副本，50 请求） | 阶段 5 KEDA（双副本，1000 请求） | 变化 |
|---|---|---|---|
| 请求吞吐 (req/s) | 2.38 | **4.82** | **+102%** |
| 输出吞吐 (tok/s) | 493.57 | **973.39** | **+97%** |
| 总吞吐 (tok/s) | 1081.72 | **2022.10** | **+87%** |
| Median TPOT (ms) | 24.48 | 27.12 | +10% |
| Median TTFT (ms) | 119.96 | 43032 | 飙高（见分析） |
| 峰值并发 | - | 508 | - |

> **TTFT 飙高分析**：RPS=10 发 1000 请求，峰值并发 508，第二副本从触发扩容到加载模型就绪需要 ~2 分钟，期间大量请求在单副本上排队。这是冷扩容的固有延迟，非性能退化。TPOT 基本不变说明单请求处理速度不受影响，吞吐翻倍证明双副本负载均衡生效。

### ✅ 阶段 5 完成清单

- [x] Prometheus 全组件 Running（operator、server、alertmanager、grafana、node-exporter、kube-state-metrics）
- [x] KEDA 全组件 Running（operator、webhooks、metrics-apiserver）
- [x] ScaledObject 状态 READY=True, ACTIVE=True
- [x] HPA `keda-hpa-vllm-qwen3-8b-scaler` 已创建
- [x] Prometheus 能抓到 vLLM 指标（`vllm:num_requests_running`）
- [x] 压测触发扩容：1 → 2 副本（`vllm-qwen3-8b-1` 秒级拉起）
- [x] 压测结束后自动缩容：2 → 1 副本（cooldown 300s 后）
- [x] 吞吐翻倍验证通过（req/s: 2.38→4.82，tok/s: 493→973）

### 实测踩坑（已规避）

| 现象 | 原因 | 处理（已在文档里固化） |
|---|---|---|
| Prometheus/KEDA Pod 全部 ContainerCreating | ghcr.io / quay.io 国内不通 | 用 DaoCloud 代理预拉镜像，master 拉完 scp 传 node01 |
| `ghcr.io/jkroepke/kube-webhook-certgen:1.8.3` 403 | DaoCloud 也拉不到 | helm install 时 `--set` 替换为 `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4` |
| `quay.io/prometheus/alertmanager:v0.28.4` not found | 版本号不对，实际需要 v0.33.0 | 用 `kubectl get pod -o jsonpath` 查精确镜像版本 |
| 镜像导入后 Pod 仍在拉取 | kubelet 缓存 / imagePullPolicy=Always | 删 Pod 重建；KEDA 用 `--set image.keda.pullPolicy=IfNotPresent` |
| Prometheus 查不到 vLLM 指标 | 缺 ServiceMonitor 资源 | 手动创建 ServiceMonitor 指向 vllm-service |
| ScaledObject Fallback=True | Prometheus 地址写错（`prometheus-server` vs 实际名） | `sed` 替换为 `kube-prometheus-kube-prome-prometheus.monitoring.svc` |

### 常见坑
- 副本扩不上去：你只有 2 GPU，扩到 3+ 会 Pending。**必须先跑阶段 6 Time-Slicing**
- ScaledObject ACTIVE = False：Prometheus 没抓到指标，检查 ServiceMonitor 是否创建
- Grafana 看不到 vLLM 指标：用 PromQL 直接查 `vllm:num_requests_running`，没有就是没 scrape 到
- Prometheus 容器没有 wget/curl：用 `kubectl run busybox` 临时 Pod 测试 PromQL 查询

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

| 阶段              | 状态   | 完成日期       | 备注                                       |
| --------------- | ---- | ---------- | ---------------------------------------- |
| 1  Base         | ✅    | 2026-06-09 | vLLM v0.11.2 + Qwen3 跑通                  |
| 2  Preloader    | ✅    | 2026-06-15 | HostPath 生效，Pod 重建 ~2min（权重加载 87s + compile 24s） |
| 3  MultiReplica | ✅    | 2026-06-15 | 2 副本分布两节点，负载均衡验证通过                       |
| 4  BenchMark    | ✅    | 2026-06-15 | 单副本基线：TTFT 120ms / TPOT 24ms / 吞吐 494 tok/s |
| 5  KEDA         | ✅    | 2026-06-15 | 扩缩容验证通过，吞吐翻倍（494→973 tok/s）  |
| 6  Time-Slicing | ☐    |            |                                          |
| 7  L1-Cache     | ☐    |            | 拉 LMCache 镜像                             |
| 8  LLM-Router   | ☐    |            | 拉 llm-d 或 router 镜像                      |
| 9  Canary       | ☐    |            | 装 Argo Rollouts                          |
| 10 Open-WebUI   | ☐    |            |                                          |

---

## 通用排错速查

| 现象                                       | 原因 / 处理                                  |
| ---------------------------------------- | ---------------------------------------- |
| Pod Pending `nvidia.com/gpu` insufficient | GPU 都被占；删别的 vLLM Pod 或开 Time-Slicing     |
| ImagePullBackOff for `ghcr.io/...`       | 用 daocloud 代理：`ctr pull ghcr.m.daocloud.io/<path>` 后 retag |
| ImagePullBackOff with `@sha256:...`      | chart 用 digest 引用，helm 加 `--set image.digest=""` |
| initContainer 拉模型卡住                      | DNS 解析 minio.minio.svc 失败，看 CoreDNS 状态   |
| vLLM OOM                                 | 降 `--gpu-memory-utilization` 或 `--max-model-len` |
| livenessProbe 失败                         | vLLM 加载慢，调 `initialDelaySeconds`         |
| 跨节点 Service 不通                           | 看 Calico Pod 健康 + kube-proxy 模式          |
| Ingress 404                              | curl 加 `-H "Host: vllm.magedu.com"`      |
| KEDA 扩不上去                                | 物理 GPU 不够，做 Time-Slicing                 |
| Prometheus 没指标                           | 看 ServiceMonitor + vLLM Pod annotations  |

---

## 卡住了？

1. 描述卡在哪个阶段哪一步
2. 贴 `kubectl describe pod ...` 和 `kubectl logs ... --previous` 输出
3. 一起排查

完成所有阶段后，恭喜你掌握了 K8s 上 LLM 推理服务的**生产级部署技能**。
