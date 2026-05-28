#!/usr/bin/env bash
# 配置 MinIO：装 mc 客户端、设 alias、创建 bucket、上传 Qwen3-8B
# 在 master 节点上跑（模型文件就在解压后的 offline/models/ 里）
#
# 仓库里两个阶段用了不同的 bucket：
#   level-1/initContainer        → models/qwen/Qwen3-8B/
#   Inference_Platfrom/*          → models/llm-models/Qwen3-8B/
# 为了兼容所有示例，脚本上传一次后再用 mc cp 在 MinIO 内部做服务端复制。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"
if [[ ! -f "$ROOT_DIR/hosts.env" ]]; then
  echo "未找到 $ROOT_DIR/hosts.env" >&2; exit 1
fi
source "$ROOT_DIR/hosts.env"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2; exit 1
fi

export KUBECONFIG=/etc/kubernetes/admin.conf
log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

BINS_DIR="$ROOT_DIR/bins"
MODEL_SRC="$ROOT_DIR/models/${MODEL_DIR_NAME}"     # offline/models/Qwen3-8B
ALIAS_NAME="models"

# ---------- 1. 安装 mc ----------
if ! command -v mc >/dev/null; then
  log "安装 mc 到 /usr/local/bin/"
  if [[ -f "$BINS_DIR/mc" ]]; then
    install -m 755 "$BINS_DIR/mc" /usr/local/bin/mc
  else
    log "未在 offline/bins 找到 mc，尝试在线下载"
    wget -q "https://dl.min.io/client/mc/release/linux-amd64/mc" -O /usr/local/bin/mc
    chmod +x /usr/local/bin/mc
  fi
fi
mc --version | head -1

# ---------- 2. 拿到 MinIO 服务地址 ----------
log "查找 MinIO LoadBalancer IP"
MINIO_IP=""
for i in {1..30}; do
  MINIO_IP=$(kubectl -n minio get svc minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "$MINIO_IP" ]]; then break; fi
  sleep 5
done

if [[ -z "$MINIO_IP" ]]; then
  log "未拿到 LoadBalancer IP，回退使用 ClusterIP"
  MINIO_IP=$(kubectl -n minio get svc minio -o jsonpath='{.spec.clusterIP}')
fi

MINIO_ENDPOINT="http://${MINIO_IP}:9000"
log "MinIO endpoint = ${MINIO_ENDPOINT}"

# ---------- 3. 等 MinIO 就绪 ----------
log "等待 MinIO 服务可达"
for i in {1..30}; do
  if curl -fsS -o /dev/null "${MINIO_ENDPOINT}/minio/health/ready"; then
    log "MinIO 已就绪"
    break
  fi
  sleep 5
  if [[ $i -eq 30 ]]; then
    echo "MinIO 30 次健康检查均失败，退出" >&2
    kubectl -n minio get pods
    exit 1
  fi
done

# ---------- 4. 配置 alias ----------
log "配置 mc alias: ${ALIAS_NAME} → ${MINIO_ENDPOINT}"
mc alias set "${ALIAS_NAME}" "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4

log "验证连接"
mc admin info "${ALIAS_NAME}" | head -5

# ---------- 5. 创建 bucket ----------
log "创建 bucket: llm-models（主），qwen（兼容 level-1 示例）"
mc mb --ignore-existing "${ALIAS_NAME}/llm-models"
mc mb --ignore-existing "${ALIAS_NAME}/qwen"
mc ls "${ALIAS_NAME}/"

# ---------- 6. 上传模型 ----------
if [[ ! -d "$MODEL_SRC" || ! -f "$MODEL_SRC/config.json" ]]; then
  log "未在 $MODEL_SRC 找到模型文件"
  log "如果模型未在离线包内，请在本机先放好 Qwen3-8B 目录或通过其他途径上传"
  exit 1
fi

log "检查 MinIO 上是否已有模型"
EXISTING=$(mc ls --recursive "${ALIAS_NAME}/llm-models/Qwen3-8B/" 2>/dev/null | wc -l)
if [[ $EXISTING -gt 5 ]]; then
  log "MinIO 上已有 $EXISTING 个对象，跳过上传"
else
  log "上传 $MODEL_SRC → ${ALIAS_NAME}/llm-models/Qwen3-8B/（约 16GB，预计 2-10 分钟视带宽）"
  mc mirror --overwrite "$MODEL_SRC/" "${ALIAS_NAME}/llm-models/Qwen3-8B/"
fi

# ---------- 7. 服务端复制到第二个 bucket ----------
log "服务端复制：llm-models/Qwen3-8B/ → qwen/Qwen3-8B/（不走本地，速度快）"
EXISTING2=$(mc ls --recursive "${ALIAS_NAME}/qwen/Qwen3-8B/" 2>/dev/null | wc -l)
if [[ $EXISTING2 -gt 5 ]]; then
  log "qwen bucket 已有内容，跳过"
else
  mc cp --recursive "${ALIAS_NAME}/llm-models/Qwen3-8B/" "${ALIAS_NAME}/qwen/Qwen3-8B/"
fi

# ---------- 8. 验证 ----------
log "验证 llm-models/Qwen3-8B/"
mc ls "${ALIAS_NAME}/llm-models/Qwen3-8B/" | head -20
echo
log "验证 qwen/Qwen3-8B/"
mc ls "${ALIAS_NAME}/qwen/Qwen3-8B/" | head -20

# ---------- 9. 输出给 K8s YAML 用的连接信息 ----------
log "========================================"
log "MinIO 配置完成。其它脚本/YAML 用到的环境变量值："
log "  MINIO_ENDPOINT  = ${MINIO_ENDPOINT}"
log "  MINIO_ACCESS_KEY = ${MINIO_ROOT_USER}"
log "  MINIO_SECRET_KEY = ${MINIO_ROOT_PASSWORD}"
log ""
log "现有 Bucket 路径："
log "  - ${ALIAS_NAME}/llm-models/Qwen3-8B/    （Inference_Platfrom 阶段用）"
log "  - ${ALIAS_NAME}/qwen/Qwen3-8B/          （level-1 阶段用）"
log "========================================"

# ---------- 10. 写一份给后续 YAML 用的 Secret 模板 ----------
SECRET_OUT="$ROOT_DIR/minio-credentials.generated.yaml"
log "生成 K8s Secret 模板：$SECRET_OUT"
cat > "$SECRET_OUT" <<EOF
# 自动生成，请按需 kubectl apply -f 到对应命名空间
# 注意：这里用集群内服务名访问，最快也最稳（不走 LoadBalancer）
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: llm-serving    # 按你的命名空间改
type: Opaque
stringData:
  MINIO_ENDPOINT: "http://minio.minio.svc.cluster.local:9000"
  MINIO_ACCESS_KEY: "${MINIO_ROOT_USER}"
  MINIO_SECRET_KEY: "${MINIO_ROOT_PASSWORD}"
EOF
log "已生成。后续跑 level-1 / Inference_Platfrom 示例前 kubectl apply 即可。"

log "下一步：cd LLM_on_Kubernetes/one-node 跑第一个推理服务"
