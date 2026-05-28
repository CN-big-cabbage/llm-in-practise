#!/usr/bin/env bash
# 验证 GPU 可被 K8s 调度
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG=/etc/kubernetes/admin.conf

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

log "等 GPU Operator 全部就绪（最长 10 分钟）"
for i in {1..60}; do
  PENDING=$(kubectl get pods -n gpu-operator --no-headers 2>/dev/null | grep -vE 'Running|Completed' | wc -l)
  if [[ $PENDING -eq 0 ]]; then
    log "gpu-operator 命名空间所有 Pod 已就绪"
    break
  fi
  sleep 10
done
kubectl get pods -n gpu-operator

log "节点 GPU 资源："
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name): nvidia.com/gpu=\(.status.allocatable["nvidia.com/gpu"] // "0")"'

log "执行 CUDA vector-add 测试"
kubectl delete pod cuda-vector-add --ignore-not-found
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vector-add
spec:
  restartPolicy: OnFailure
  containers:
    - name: cuda-vector-add
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

log "等待容器跑完（最长 3 分钟）"
for i in {1..18}; do
  PHASE=$(kubectl get pod cuda-vector-add -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]]; then
    break
  fi
  sleep 10
done

log "Pod 日志："
kubectl logs cuda-vector-add || true

if kubectl logs cuda-vector-add 2>/dev/null | grep -q "Test PASSED"; then
  log "✅ GPU 调度验证通过！集群已就绪，可以进入 LLM_on_Kubernetes/one-node 跑第一个推理服务"
  kubectl delete pod cuda-vector-add
else
  log "❌ 验证未通过，请检查 kubectl describe pod cuda-vector-add 和 gpu-operator pods 日志"
  exit 1
fi
