# Inference_Platfrom 实践计划

> 按目录顺序（01 → 09 + Open-WebUI）逐级演进。每个阶段独立可验证，跑通一个再进下一个。
> 适配硬件：1 master + 1 node01（本地无 GPU）+ 2 node（云端各 1 张 RTX 3090，共 2 卡）。

## 阶段地图

| # | 目录 | README 阶段编号 | 你能学到 | 难度 | 预计耗时 |
|---|---|---|---|---|---|
| 0 | （bootstrap） | 一、二 | 集群 / GPU / MinIO 模型仓 | — | 已完成 |
| 1 | `01-Base/` | 四 | vLLM 与 SGLang 引擎部署 | ★ | 1-2h |
| 2 | `02-Preloader/` | 五 | DaemonSet 模型预加载 + HostPath | ★★ | 1h |
| 3 | `03-MultiReplica/` | 六 | StatefulSet 多副本 + Service 负载均衡 | ★★ | 1h |
| 4 | `04-BenchMark/` | 七 | 压测建基线（TTFT / TPOT / QPS） | ★★ | 2h |
| 5 | `05-KEDA-AutoScale/` | 八 | KEDA 基于 Prometheus 指标自动扩缩 | ★★★ | 2-3h |
| 6 | `06-GPU-Timeslicing/` | 十二 | 1 张卡跑 N 个 Pod（对你 2 卡环境很有用） | ★★★ | 2h |
| 7 | `07-L1-Cache/` | 九 | LMCache + APC 前缀缓存加速 | ★★★ | 2-3h |
| 8 | `08-LLM-Router/` | 十 | llm-d 或 vLLM-Router 智能路由 | ★★★★ | 3-4h |
| 9 | `09-Canary-Deployment/` | 十八 | Argo Rollouts 金丝雀发布 | ★★★★ | 3h |
| 10 | `Open-WebUI/` | — | Web UI 接入 vLLM | ★ | 30min |

阶段 11（L2/L3 缓存）README 里有文字描述但**没有 YAML 文件**，跳过。

## 前置（已在 bootstrap 完成）

- [x] K8s 1.31 集群跑起来（4 节点全 Ready）
- [x] GPU Operator 装好，`kubectl get nodes -L has-gpu` 显示 node02/03 有 GPU
- [x] MinIO 部署到 node02，bucket `llm-models/Qwen3-8B/` 和 `qwen/Qwen3-8B/` 都有内容
- [x] OpenEBS LocalPV、MetalLB、Ingress-Nginx 就绪
- [x] `bootstrap/check.sh` 通过

如果还没装好，先回 `bootstrap/` 跑完。

---

## 阶段 1：基础部署（`01-Base/`）

**目标**：把 Qwen3-8B 用 vLLM 跑起来，理解最朴素的"PVC + initContainer 拉模型"模式。

### 涉及文件
- `01-Base/vLLM/vllm-model-pvc.yaml`：模型 PVC（OpenEBS LocalPV）
- `01-Base/vLLM/vllm-deployment.yaml`：vLLM Deployment + initContainer
- `01-Base/vLLM/vllm-ingress.yaml`：Ingress 暴露
- `01-Base/SGLang/*`：同上但用 SGLang（可选对比）

### 前置准备
1. 创建命名空间和 MinIO Secret：
   ```bash
   kubectl create ns llm-inference
   kubectl apply -f Inference_Platfrom/minio-credentials.yaml
   # 或用 bootstrap/minio-credentials.generated.yaml
   ```

### 步骤
```bash
cd Inference_Platfrom/01-Base/vLLM
kubectl apply -f vllm-model-pvc.yaml
kubectl apply -f vllm-deployment.yaml
kubectl apply -f vllm-ingress.yaml

# 监控
kubectl get pods -n llm-inference -w
kubectl logs -n llm-inference deploy/vllm-qwen3-8b -c model-init -f
```

### 验证
- Pod 状态 Running 1/1
- `kubectl logs deploy/vllm-qwen3-8b -n llm-inference` 看到 `Uvicorn running on http://0.0.0.0:8000`
- 调用 API：
  ```bash
  curl http://<ingress-ip>/v1/chat/completions -H "Content-Type: application/json" \
    -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"你好"}],"max_tokens":50}'
  ```

### 你的环境注意
- 模型 16GB 从 MinIO 拉到 PVC 要 1-3 分钟（看云内网速度）
- vLLM 启动加载模型还要 30-60 秒
- 单卡 3090 24GB 跑 Qwen3-8B 显存够，但 `--gpu-memory-utilization` 建议设 0.85

### 完成后
- [ ] vLLM 服务跑通
- [ ] API 调用成功返回
- （可选）[ ] 同样的方式跑通 SGLang，对比启动速度和 token 速率

---

## 阶段 2：DaemonSet Preloader（`02-Preloader/`）

**目标**：把模型从"每个 Pod 启动时从 MinIO 拉"改成"DaemonSet 一次性预热到节点 HostPath"。后续 Pod 启动只需毫秒。

### 涉及文件
- `02-Preloader/model-preloader-daemonset.yaml`：DaemonSet 跑在 GPU 节点上，把模型同步到 `/data/models/`
- `02-Preloader/vllm-deployment.yaml`：vLLM Pod 改成挂 HostPath
- `02-Preloader/vllm-model-pvc.yaml`：可选保留作为备用
- `02-Preloader/vllm-ingress.yaml`

### 步骤
```bash
# 先清掉阶段 1 的资源（保留 PVC 也可以）
kubectl delete -f ../01-Base/vLLM/vllm-deployment.yaml -n llm-inference

cd Inference_Platfrom/02-Preloader
kubectl apply -f model-preloader-daemonset.yaml
# 等 GPU 节点上的 preloader Pod 完成同步（看 .ready 文件）
kubectl logs -n llm-inference ds/model-preloader -f

kubectl apply -f vllm-deployment.yaml
kubectl apply -f vllm-ingress.yaml
```

### 验证
- 进 GPU 节点：`ls /data/models/Qwen3-8B/` 看到完整模型文件
- 新 vLLM Pod **几秒就能 Running**（之前是几分钟）

### 你的环境注意
- HostPath 是节点本地盘，节点重建数据丢失（云上正常重启不丢）
- DaemonSet 通过 nodeSelector 只在 GPU 节点（node02/03）跑

### 完成后
- [ ] DaemonSet 在 node02/03 都完成同步
- [ ] vLLM Pod 启动时间从分钟级降到秒级

---

## 阶段 3：多副本（`03-MultiReplica/`）

**目标**：把 Deployment 改成 StatefulSet，开 2 个副本（你正好 2 卡），通过 Service 做负载均衡。

### 涉及文件
- `03-MultiReplica/model-preloader-daemonset.yaml`：复用阶段 2
- `03-MultiReplica/vllm-statefulset.yaml`：**核心**，StatefulSet 形态
- `03-MultiReplica/vllm-services.yaml`：ClusterIP（负载均衡）+ Headless（StatefulSet 必需）
- `03-MultiReplica/vllm-ingress.yaml`

### 步骤
```bash
kubectl delete -f ../02-Preloader/vllm-deployment.yaml -n llm-inference

cd Inference_Platfrom/03-MultiReplica
kubectl apply -f .
```

### 验证
- 2 个 Pod：`vllm-qwen3-8b-0` 在 node02，`vllm-qwen3-8b-1` 在 node03
- `kubectl get nodes -o jsonpath='...'` 验证两个节点的 GPU 都被分配
- 重复打 API，看不同 Pod 的日志都有请求进来

### 你的环境注意
- 副本数 = GPU 卡数（你是 2）。设 3 会 Pending
- 跑过阶段 6（Time-Slicing）后，可以把副本数提到 4-6

### 完成后
- [ ] 2 个副本各占 1 张卡
- [ ] 请求被 Service 轮询分发到不同 Pod

---

## 阶段 4：压测建基线（`04-BenchMark/`）

**目标**：用客户端 Pod 压测，记录 **TTFT**（首 token 时延）、**TPOT**（每 token 时延）、**QPS**。后续优化都用这组数据对比。

### 涉及文件
- `04-BenchMark/benchmark-client.yaml`：Job/Pod，跑 `vllm bench serve` 或类似工具

### 步骤
```bash
kubectl apply -f 04-BenchMark/benchmark-client.yaml
kubectl logs -n llm-inference -l job-name=benchmark-client -f
```

### 记录这些数据（写到下面表格）
| 指标 | 阶段 3 基线 | 阶段 7 (LMCache) | 阶段 6 (Time-Slicing) |
|---|---|---|---|
| TTFT P50/P99 (ms) | | | |
| TPOT P50/P99 (ms) | | | |
| 吞吐 (tokens/s) | | | |
| 并发 QPS | | | |

### 你的环境注意
- 跨 Tailscale 的压测要从云端节点上的 Pod 发起，避免 VPN 成为瓶颈
- 压测时间 ≥ 3 分钟才有意义（短时不稳定）

### 完成后
- [ ] 记录基线数据
- [ ] 截图保存 Pod 资源使用（kubectl top pod）

---

## 阶段 5：KEDA 自动扩缩容（`05-KEDA-AutoScale/`）

**目标**：装 KEDA、基于 Prometheus 队列深度自动扩缩 vLLM 副本。

### 前置：装 Prometheus + KEDA
- Prometheus：用 kube-prometheus-stack helm chart（你可能要单独下镜像）
- KEDA：`helm install keda kedacore/keda -n keda --create-namespace`
- 配置 ServiceMonitor 让 Prometheus 抓 vLLM 的 `/metrics`

### 涉及文件
- `05-KEDA-AutoScale/vllm-statefulset-overload.yaml`：在 vLLM 启动参数里加 backpressure
- `05-KEDA-AutoScale/vllm-services.yaml`
- `05-KEDA-AutoScale/vllm-ingress-backpressure.yaml`：返回 429 而非排队
- `05-KEDA-AutoScale/keda-scaledobject.yaml`：**核心**，定义扩缩规则
- `05-KEDA-AutoScale/model-preloader-daemonset.yaml`

### 验证
- 启动压测，看 `kubectl get hpa -n llm-inference -w`，副本数随负载变化
- 注意上限：你只有 2 卡（除非启用 Time-Slicing）

### 你的环境注意
- **副本扩到 3+ 会 Pending**，因为只有 2 张物理卡
- 想测真正扩容必须先做阶段 6（Time-Slicing）

### 完成后
- [ ] KEDA 安装并能看到指标
- [ ] 压测时副本随队列深度增减

---

## 阶段 6：GPU Time-Slicing（`06-GPU-Timeslicing/`）

**目标**：把 1 张 3090 切成多个虚拟 GPU，让多个 Pod 共享一张卡（时间片轮询）。对你 2 卡环境特别有用。

### 涉及文件
- `06-GPU-Timeslicing/Time-Slicing/nvidia-time-slicing-config.yaml`：**核心**，ConfigMap 定义切片数
- `06-GPU-Timeslicing/vllm-statefulset.yaml`：副本数提高
- `06-GPU-Timeslicing/keda-scaledobject.yaml`：扩缩上限提高
- `06-GPU-Timeslicing/vllm-services.yaml`
- `06-GPU-Timeslicing/vllm-ingress-backpressure.yaml`
- `06-GPU-Timeslicing/model-preloader-daemonset.yaml`

### 步骤要点
1. apply Time-Slicing ConfigMap
2. patch GPU Operator 让 device plugin 用新 config
3. 验证 `kubectl describe node node02 | grep nvidia.com/gpu` 显示数量变成 N（默认 4-8）
4. 重新部署 vLLM，副本数提到 4

### 你的环境注意
- **3090 24GB 切 2-3 份**比较安全（Qwen3-8B FP16 ≈16GB，剩 8GB 给 KV cache 不够 2 个 Pod 用）
- 真要切多份，要么用更小模型（Qwen3-1.8B），要么开 INT8/INT4 量化
- Time-Slicing 不是真隔离，只是分时；显存仍然共享，超就 OOM

### 实测踩坑（已规避）

| 现象 | 原因 | 处理 |
|---|---|---|
| Pod `FailedMount: configmap "time-slicing-config" not found` | patch 命令 `name` 与 YAML 中 ConfigMap 名 `time-slicing-rtx3090` 不一致 | patch 改为 `name: time-slicing-rtx3090, default: rtx-3090` |
| 手动 `scale --replicas=2` 后 pod-1 瞬间消失 | KEDA Prometheus 指标获取失败，兜底缩回 minReplicas=1 | 验证前先暂停 KEDA：`kubectl annotate scaledobject vllm-qwen3-8b-scaler -n llm-inference autoscaling.keda.sh/paused=true --overwrite` |

### 完成后
- [x] 单节点显示 `nvidia.com/gpu=2`（Time-Slicing replicas=2 生效）
- [x] `vllm-qwen3-8b-0`（k8s-master01）和 `vllm-qwen3-8b-1`（k8s-node01）均 `1/1 Running`
- [x] API 调用正常返回中文回复
- [ ] （可选）回头跑阶段 5 KEDA，验证能真正扩容到 4 副本

> 进入阶段 7 前恢复 KEDA：
> ```bash
> kubectl annotate scaledobject vllm-qwen3-8b-scaler -n llm-inference autoscaling.keda.sh/paused- --overwrite
> ```

---

## 阶段 7：LMCache L1 缓存（`07-L1-Cache/`）

**目标**：装 LMCache，给 vLLM 加 KV cache 前缀复用。重复 prompt 的请求 TTFT 大幅下降。

### 涉及文件
- `07-L1-Cache/LMCache/vllm-statefulset-lmcache.yaml`：**核心**，vLLM 启动加 LMCache 后端
- `07-L1-Cache/LMCache/lmcache-deployment.yaml`：（可能的）LMCache server
- `07-L1-Cache/LMCache/test_lmcache.sh`：测试脚本
- `07-L1-Cache/vllm-statefulset-apc.yaml`：开启 Automatic Prefix Caching（vLLM 内置）
- `07-L1-Cache/keda-scaledobject.yaml`、`07-L1-Cache/model-preloader-daemonset.yaml`、`07-L1-Cache/vllm-services.yaml`、`07-L1-Cache/vllm-ingress-backpressure.yaml`

### 两个子主题
1. **APC**（vLLM 内置）：启动加 `--enable-prefix-caching`，跑 `vllm-statefulset-apc.yaml`
2. **LMCache**（外部 KV cache 服务）：跑 `vllm-statefulset-lmcache.yaml`

### 验证
- 重复发同一 prompt，第二次 TTFT 比第一次低 80%+
- 跑 `test_lmcache.sh` 看命中率

### 完成后
- [ ] APC 验证生效
- [ ] LMCache 与 vLLM 联通
- [ ] 记录开启缓存后的 TTFT 数据到阶段 4 的表格

---

## 阶段 8：智能路由（`08-LLM-Router/`）

**目标**：替换简单的 Service 轮询，用 Cache-Aware 路由把同前缀请求路由到同一 Pod，最大化缓存命中。

### 两个方案
- `08-LLM-Router/vLLM-Router/`：vLLM 官方 Router（推荐先做这个）
  - `helm/`、`vllm-router-deployment.yaml`、`vllm-router-rbac.yaml`、`vllm-router-ingress.yaml`
- `08-LLM-Router/llm-d/`：CNCF llm-d 项目（更复杂、更强）
  - `llm-d-config.yaml`、`llm-d-deployment.yaml`、`llm-d-rbac.yaml`、`llm-d-ingress.yaml`

### 步骤建议
1. 先跑 vLLM-Router（架构简单）
2. 跑通后再尝试 llm-d 对比

### 验证
- Ingress IP 改指 Router，而不是直接指 vLLM Service
- 同前缀的请求被路由到同一 Pod（看后端 Pod 日志）

### 完成后
- [ ] Router 起来
- [ ] 验证 Cache-Aware 路由生效
- [ ] 与阶段 7 联调，缓存命中率提升

---

## 阶段 9：金丝雀发布（`09-Canary-Deployment/`）

**目标**：用 Argo Rollouts 做新模型 / 新 vLLM 版本灰度发布。10% 流量到新版，观察指标，自动 promote / abort。

### 前置：装 Argo Rollouts
```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

### 涉及文件
- `09-Canary-Deployment/vllm-rollout.yaml`：Rollout 资源（替代 Deployment）
- `09-Canary-Deployment/vllm-canary-services.yaml`：stable + canary 两个 Service
- `09-Canary-Deployment/vllm-canary-ingress.yaml`
- `09-Canary-Deployment/analysis-template.yaml`：基于 Prometheus 指标自动评估
- `09-Canary-Deployment/keda-rollout.yaml`：KEDA 配合 Rollout
- `09-Canary-Deployment/verify-canary.sh`：验证脚本

### 验证
- 跑 `verify-canary.sh`，观察流量从 10% 逐步切到 100%
- 故意制造金丝雀失败（健康检查不过），看 AnalysisRun 自动 abort

### 完成后
- [ ] Argo Rollouts 装好
- [ ] 完整跑通一次金丝雀升级
- [ ] 故意触发回滚演练一次

---

## 阶段 10：Open-WebUI（`Open-WebUI/`）

**目标**：装个 ChatGPT 风格的前端，接到 vLLM 上，用浏览器聊天。

### 涉及文件
- `Open-WebUI/openwebui-deployment.yaml`
- `Open-WebUI/openwebui-ingress.yaml`

### 步骤
```bash
kubectl apply -f Open-WebUI/
# Ingress 部署在 local zone 节点，浏览器从家里直接访问 IP
```

### 完成后
- [ ] Web UI 可访问
- [ ] 跟 Qwen3-8B 对话流畅

---

## 进度总览（打勾用）

| 阶段 | 状态 | 完成日期 | 备注 |
|---|---|---|---|
| 0  bootstrap | ☐ | | 集群底座 |
| 1  Base | ☐ | | vLLM 跑通 |
| 2  Preloader | ☐ | | HostPath 预加载 |
| 3  MultiReplica | ☐ | | 2 副本 |
| 4  BenchMark | ☐ | | 基线数据 |
| 5  KEDA | ☐ | | 自动扩缩 |
| 6  Time-Slicing | ✅ | 2026-06-18 | GPU 共享，双节点各 gpu=2 |
| 7  L1-Cache | ☐ | | LMCache + APC |
| 8  LLM-Router | ☐ | | Cache-Aware |
| 9  Canary | ☐ | | Argo Rollouts |
| 10 Open-WebUI | ☐ | | 前端 |

## 常见踩坑速查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| Pod Pending，no GPU | 副本数 > GPU 总数 | 减副本或先做 Time-Slicing |
| initContainer 一直拉模型 | MinIO Endpoint 解析失败 | 检查 minio-credentials Secret，用 ClusterIP 替代域名 |
| vLLM OOM | KV cache 配置过大 | 降 `--gpu-memory-utilization` 到 0.85，或限 `--max-model-len` |
| 启动慢 | 还在用 PVC + initContainer | 跳到阶段 2 用 DaemonSet Preloader |
| 跨节点请求超时 | Tailscale + MTU 错 | 检查 Calico MTU=1230 |
| KEDA 不扩容 | Prometheus 指标抓不到 | `kubectl get servicemonitor`，看 vLLM 是否暴露 metrics |
| Time-Slicing 无效 | device plugin 没重启 | `kubectl rollout restart ds/nvidia-device-plugin-daemonset -n gpu-operator` |

## 下一步建议节奏

- **第 1 天**：阶段 1-3（基础 → 预加载 → 多副本），打通流水线
- **第 2 天**：阶段 4-5（压测 + KEDA），建立可观测性
- **第 3 天**：阶段 6-7（Time-Slicing + 缓存），性能优化
- **第 4 天**：阶段 8-10（路由 + 金丝雀 + UI），生产形态

每阶段跑通后，**先把 YAML 删掉再跑下一阶段**（资源清干净，避免端口/PVC 冲突）。
