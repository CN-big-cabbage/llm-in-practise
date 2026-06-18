# 快速开始

本指南帮助你在自己的 GPU 集群上复现完整的 LLM 推理平台实践（10 个阶段）。

## 前置要求

| 项目 | 最低要求 |
|---|---|
| 节点数 | 2 个（master + worker） |
| GPU | 每节点 1 张，显存 ≥ 24GB（如 RTX 3090）|
| OS | Ubuntu 22.04 |
| 网络 | 节点间内网互通，master 可 SSH 到 worker |
| 磁盘 | master节点 300G,woker节点 200G |

GPU 数量不够？阶段 6（GPU Time-Slicing）可以把 1 张 GPU 虚拟成多个槽位，2 张卡就能跑完全部阶段。

---

## 第一步：克隆仓库

```bash
git clone https://github.com/CN-big-cabbage/llm-in-practise.git
cd llm-in-practise/LLM_on_Kubernetes
```

> 这是原课程仓库（[iKubernetes/llm-in-practise](https://github.com/iKubernetes/llm-in-practise)）的 fork，
> YAML 已针对 2 节点云上集群修正了已知问题（`maxSurge` 整数、Prometheus 地址、镜像源等）。

---

## 第二步：准备 K8s 集群

**已有集群**（节点 Ready、GPU Operator 装好、MinIO 就绪）→ 直接跳第三步。

**没有集群**：按 [`bootstrap/README.md`](bootstrap/README.md) 搭建，支持：
- 本地 PVE 虚机 + 云端 GPU 混合架构（通过 Tailscale 打通）
- 纯云端 2 节点部署

搭完后用 `bootstrap/cloud/check.sh` 一键巡检确认就绪：

```bash
sudo bash bootstrap/cloud/check.sh
# 全部 PASS 后再继续
```

---

## 第三步：适配你的环境

打开 [`Inference_Platfrom/PRACTICE_GUIDE.md`](Inference_Platfrom/PRACTICE_GUIDE.md)，找到"适配自己的环境"表格，把以下占位符替换为真实值：

| 占位符 | 查询方式 |
|---|---|
| `<MASTER_PUBLIC_IP>` | master 节点公网 IP（云控制台或 `curl ifconfig.me`） |
| `<NODE01_PUBLIC_IP>` | worker 节点公网 IP |
| `<LB_INGRESS_IP>` | `kubectl get svc -n ingress-nginx` 的 EXTERNAL-IP |
| `<LB_MINIO_IP>` | `kubectl get svc -n minio` 的 EXTERNAL-IP |

替换完成后，PRACTICE_GUIDE.md 里所有命令可以直接复制执行。

---

## 第四步：按阶段逐步实践

所有操作步骤、验证命令、踩坑记录都在 `Inference_Platfrom/PRACTICE_GUIDE.md` 对应章节。

| # | 阶段 | 目录 | 你能学到 | 预计耗时 |
|---|---|---|---|---|
| 1 | Base | `01-Base/` | vLLM 基础部署：PVC + InitContainer + Ingress | 1-2h |
| 2 | Preloader | `02-Preloader/` | DaemonSet 预热模型到 HostPath，Pod 秒级冷启动 | 1h |
| 3 | MultiReplica | `03-MultiReplica/` | StatefulSet 2 副本 + Headless Service + 反亲和 | 1h |
| 4 | BenchMark | `04-BenchMark/` | vllm bench 建性能基线（TTFT / TPOT / 吞吐） | 2h |
| 5 | KEDA | `05-KEDA-AutoScale/` | 基于 Prometheus 指标自动扩缩容 | 2-3h |
| 6 | GPU Time-Slicing | `06-GPU-Timeslicing/` | 1 张卡虚拟成多个槽位，提升 GPU 利用率 | 2h |
| 7 | L1-Cache | `07-L1-Cache/` | APC 前缀缓存 + LMCache 加速（最高 4x） | 2-3h |
| 8 | LLM-Router | `08-LLM-Router/` | vLLM-Router Cache-Aware 智能路由 | 3-4h |
| 9 | Canary | `09-Canary-Deployment/` | Argo Rollouts 金丝雀发布 + Prometheus 自动验收 | 3h |
| 10 | Open-WebUI | `Open-WebUI/` | 浏览器聊天界面接入 vLLM | 30min |

每个阶段结尾都有 **✅ 完成清单**，对照勾选后再进入下一阶段。

---

## 遇到问题

1. 先查当前阶段的"实测踩坑"表格——常见问题都已记录在 PRACTICE_GUIDE.md 对应章节
2. 再查文档末尾的"通用排错速查"表
3. 仍未解决可在 [Issues](https://github.com/CN-big-cabbage/llm-in-practise/issues) 提问，附上 `kubectl describe pod` 和错误日志
