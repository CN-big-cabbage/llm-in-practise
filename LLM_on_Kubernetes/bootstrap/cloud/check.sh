#!/usr/bin/env bash
# 集群健康巡检：一键检查混合架构下所有关键组件是否就绪
# 只读，不会改动任何资源
# 用法：sudo bash check.sh [--verbose]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[[ -f "$ROOT_DIR/hosts.env" ]] && source "$ROOT_DIR/hosts.env"
export KUBECONFIG=/etc/kubernetes/admin.conf

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

# ---------- 颜色 / 计数 ----------
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; CYAN='\033[36m'; RESET='\033[0m'
PASS=0; FAIL=0; WARN=0
FAILED_ITEMS=()

ok()   { echo -e "  ${GREEN}✓${RESET} $*"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${RED}✗${RESET} $*"; FAIL=$((FAIL+1)); FAILED_ITEMS+=("$*"); }
warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; WARN=$((WARN+1)); }
info() { echo -e "  ${CYAN}ℹ${RESET} $*"; }
section() { echo; echo -e "${CYAN}=== $* ===${RESET}"; }
verbose() { [[ $VERBOSE -eq 1 ]] && echo "    $*"; }

# ---------- 1. 基础工具 ----------
section "基础工具"
for cmd in kubectl helm tailscale ctr; do
  if command -v "$cmd" >/dev/null; then
    ok "$cmd 已安装: $($cmd version --short 2>/dev/null | head -1 || $cmd --version 2>/dev/null | head -1)"
  else
    bad "$cmd 未安装"
  fi
done

# ---------- 2. Tailscale 网络 ----------
section "Tailscale 网络"
if tailscale status >/dev/null 2>&1; then
  TS_IP=$(tailscale ip -4)
  ok "本节点已入 Tailnet，IP=${TS_IP}"

  # 检查所有目标节点是否在线
  for v in MASTER NODE01 NODE02 NODE03; do
    eval "ip=\${${v}_IP:-}"
    eval "host=\${${v}_HOST:-}"
    if [[ -z "$ip" ]]; then warn "$v 未在 hosts.env 配置"; continue; fi
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
      ok "$host ($ip) 可达"
    else
      bad "$host ($ip) 不可达 — 检查 Tailscale 状态或 hosts.env"
    fi
  done
else
  bad "Tailscale 未运行 — 跑 00a-setup-tailscale.sh"
fi

# ---------- 3. K8s 控制平面 ----------
section "K8s 控制平面"
if kubectl cluster-info >/dev/null 2>&1; then
  ok "API Server 可达"
  K8S_VER=$(kubectl version --output=json 2>/dev/null | grep -o '"gitVersion":"v[^"]*"' | head -1 | cut -d'"' -f4)
  info "K8s 版本: ${K8S_VER}"
else
  bad "API Server 不可达 — 检查 /etc/kubernetes/admin.conf 和 kubelet"
fi

# ---------- 4. 节点状态 ----------
section "节点状态（应全部 Ready，且 INTERNAL-IP 为 100.x.x.x）"
NODE_INFO=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.addresses[?(@.type=="InternalIP")].address}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)

if [[ -z "$NODE_INFO" ]]; then
  bad "无法获取节点信息"
else
  while IFS='|' read -r name ip ready; do
    [[ -z "$name" ]] && continue
    if [[ "$ready" == "True" && "$ip" =~ ^100\. ]]; then
      ok "$name | $ip | Ready"
    elif [[ "$ready" == "True" ]]; then
      warn "$name | $ip | Ready（但 INTERNAL-IP 不是 Tailscale IP，跨节点通信可能异常）"
    else
      bad "$name | $ip | NotReady"
    fi
  done <<< "$NODE_INFO"
fi

# 节点标签
section "节点标签（zone / has-gpu / runs-minio）"
LABEL_OUT=$(kubectl get nodes -L topology.kubernetes.io/zone -L has-gpu -L runs-minio --no-headers 2>/dev/null)
if echo "$LABEL_OUT" | grep -qE 'cloud|local'; then
  ok "zone 标签已打"
  echo "$LABEL_OUT" | awk '{printf "    %-25s zone=%-6s has-gpu=%-6s runs-minio=%s\n", $1, $6, $7, $8}'
else
  bad "节点未打 zone 标签 — 跑 06a-label-nodes.sh"
fi

# ---------- 5. Calico ----------
section "Calico CNI"
CAL_PODS=$(kubectl get pods -n calico-system --no-headers 2>/dev/null)
if [[ -n "$CAL_PODS" ]]; then
  NOT_READY=$(echo "$CAL_PODS" | grep -vE 'Running|Completed' | wc -l)
  if [[ $NOT_READY -eq 0 ]]; then
    ok "calico-system 所有 Pod Running"
  else
    bad "calico-system 有 ${NOT_READY} 个 Pod 未就绪"
    echo "$CAL_PODS" | grep -vE 'Running|Completed' | sed 's/^/    /'
  fi
  # MTU 检查
  MTU=$(kubectl get installation default -o jsonpath='{.spec.calicoNetwork.mtu}' 2>/dev/null)
  if [[ "$MTU" == "1230" ]]; then
    ok "Calico MTU=1230（适配 Tailscale）"
  else
    warn "Calico MTU=${MTU:-默认}，跨 Tailscale 节点的大包可能丢，建议 1230"
  fi
else
  bad "未找到 calico-system Pod — 跑 05-install-calico.sh"
fi

# Pod 跨节点连通性快测
section "Pod 跨节点连通性"
COREDNS_CNT=$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep Running | wc -l)
if [[ $COREDNS_CNT -ge 1 ]]; then
  ok "CoreDNS 有 $COREDNS_CNT 个实例 Running"
else
  bad "CoreDNS 未就绪"
fi

# ---------- 6. MetalLB ----------
section "MetalLB"
if kubectl get ns metallb-system >/dev/null 2>&1; then
  MLB_NOT_READY=$(kubectl -n metallb-system get pods --no-headers 2>/dev/null | grep -vE 'Running|Completed' | wc -l)
  if [[ $MLB_NOT_READY -eq 0 ]]; then
    ok "MetalLB controller / speaker 全部 Running"
  else
    bad "MetalLB 有 ${MLB_NOT_READY} 个 Pod 未就绪"
  fi

  POOLS=$(kubectl -n metallb-system get ipaddresspool -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  for p in cloud-pool local-pool; do
    if [[ " $POOLS " =~ \ $p\  ]]; then
      ok "IP 池 $p 存在"
    else
      bad "IP 池 $p 缺失 — 跑 06-install-components.sh"
    fi
  done
else
  bad "metallb-system 不存在 — 跑 06-install-components.sh"
fi

# ---------- 7. Ingress-Nginx ----------
section "Ingress-Nginx"
if kubectl get ns ingress-nginx >/dev/null 2>&1; then
  ING_NODE=$(kubectl -n ingress-nginx get pod -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  ING_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [[ -n "$ING_NODE" ]]; then
    NODE_ZONE=$(kubectl get node "$ING_NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
    if [[ "$NODE_ZONE" == "local" ]]; then
      ok "Ingress 跑在 $ING_NODE (local zone)"
    else
      warn "Ingress 跑在 $ING_NODE (zone=$NODE_ZONE)，预期 local — 本地访问会绕一圈"
    fi
  else
    bad "Ingress controller 未就绪"
  fi
  if [[ -n "$ING_IP" ]]; then
    ok "Ingress LoadBalancer IP = $ING_IP（应在 local-pool 段内）"
  else
    warn "Ingress 未拿到 LoadBalancer IP"
  fi
else
  bad "ingress-nginx 命名空间不存在"
fi

# ---------- 8. OpenEBS ----------
section "OpenEBS LocalPV"
if kubectl get sc openebs-hostpath >/dev/null 2>&1; then
  DEFAULT=$(kubectl get sc openebs-hostpath -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')
  if [[ "$DEFAULT" == "true" ]]; then
    ok "openebs-hostpath 是默认 StorageClass"
  else
    warn "openebs-hostpath 不是默认 SC — 建议 kubectl patch"
  fi
else
  bad "未找到 openebs-hostpath StorageClass"
fi

# ---------- 9. GPU Operator ----------
section "GPU Operator"
if kubectl get ns gpu-operator >/dev/null 2>&1; then
  GPU_NOT_READY=$(kubectl -n gpu-operator get pods --no-headers 2>/dev/null | grep -vE 'Running|Completed' | wc -l)
  if [[ $GPU_NOT_READY -eq 0 ]]; then
    ok "gpu-operator 所有 Pod 就绪"
  else
    bad "gpu-operator 有 ${GPU_NOT_READY} 个 Pod 未就绪"
    [[ $VERBOSE -eq 1 ]] && kubectl -n gpu-operator get pods | grep -vE 'Running|Completed' | sed 's/^/    /'
  fi

  # GPU 资源
  TOTAL_GPU=0
  while read -r node alloc; do
    [[ -z "$node" ]] && continue
    if [[ "$alloc" =~ ^[0-9]+$ ]] && [[ $alloc -gt 0 ]]; then
      ok "$node 暴露 nvidia.com/gpu=$alloc"
      TOTAL_GPU=$((TOTAL_GPU+alloc))
    fi
  done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}')

  if [[ $TOTAL_GPU -eq 0 ]]; then
    bad "集群中没有可分配的 GPU — 检查 nvidia-device-plugin 日志"
  else
    info "集群可调度 GPU 总数: ${TOTAL_GPU}"
  fi
else
  bad "gpu-operator 命名空间不存在"
fi

# ---------- 10. MinIO ----------
section "MinIO"
if kubectl get ns minio >/dev/null 2>&1; then
  MINIO_NODE=$(kubectl -n minio get pod -l app=minio -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  if [[ -n "$MINIO_NODE" ]]; then
    MINIO_ZONE=$(kubectl get node "$MINIO_NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
    if [[ "$MINIO_ZONE" == "cloud" ]]; then
      ok "MinIO 跑在 $MINIO_NODE (cloud zone) ✓"
    else
      warn "MinIO 跑在 $MINIO_NODE (zone=$MINIO_ZONE)，预期 cloud — 模型分发会跨网"
    fi
  fi

  MINIO_IP=$(kubectl -n minio get svc minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [[ -n "$MINIO_IP" ]]; then
    ok "MinIO LoadBalancer IP = $MINIO_IP"
    if curl -fsS -m 3 -o /dev/null "http://${MINIO_IP}:9000/minio/health/ready"; then
      ok "MinIO 健康检查通过"
    else
      bad "MinIO 健康检查失败"
    fi
  else
    bad "MinIO 未拿到 LoadBalancer IP"
  fi

  # bucket
  if command -v mc >/dev/null && [[ -n "$MINIO_IP" ]]; then
    mc alias set _check "http://${MINIO_IP}:9000" "${MINIO_ROOT_USER:-admin}" "${MINIO_ROOT_PASSWORD:-admin12345}" --api S3v4 >/dev/null 2>&1
    for b in llm-models qwen; do
      if mc ls "_check/$b" >/dev/null 2>&1; then
        COUNT=$(mc ls --recursive "_check/$b/Qwen3-8B/" 2>/dev/null | wc -l)
        if [[ $COUNT -gt 5 ]]; then
          ok "Bucket $b/Qwen3-8B 有 $COUNT 个对象"
        else
          warn "Bucket $b 存在但 Qwen3-8B 内容不足（$COUNT 对象）"
        fi
      else
        warn "Bucket $b 不存在 — 跑 08-setup-minio.sh"
      fi
    done
    mc alias remove _check >/dev/null 2>&1 || true
  fi
else
  bad "minio 命名空间不存在"
fi

# ---------- 总结 ----------
section "巡检总结"
echo -e "  ${GREEN}通过: ${PASS}${RESET}    ${YELLOW}警告: ${WARN}${RESET}    ${RED}失败: ${FAIL}${RESET}"
if [[ $FAIL -gt 0 ]]; then
  echo
  echo -e "${RED}失败项：${RESET}"
  for item in "${FAILED_ITEMS[@]}"; do
    echo -e "  ${RED}•${RESET} $item"
  done
  exit 1
fi
if [[ $WARN -gt 0 ]]; then
  echo -e "${YELLOW}有警告但可继续，建议关注上面 ⚠ 标记的项${RESET}"
fi
echo -e "${GREEN}集群健康，可以进入业务部署阶段${RESET}"
exit 0
