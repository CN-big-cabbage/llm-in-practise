#!/usr/bin/env bash
# 下载 Qwen3-8B 模型到本地（约 16GB）
# 注意：建议在 CPU 机器上下，再上传到 MinIO，不要占用 GPU 节点时间
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"

MODELS_DIR="$ROOT_DIR/offline/models"
TARGET="$MODELS_DIR/${MODEL_DIR_NAME}"
mkdir -p "$MODELS_DIR"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

if [[ -f "$TARGET/config.json" ]] && ls "$TARGET"/*.safetensors >/dev/null 2>&1; then
  log "模型已存在于 $TARGET，跳过"
  exit 0
fi

if ! command -v modelscope >/dev/null; then
  log "安装 modelscope CLI"
  pip install --quiet modelscope
fi

log "下载 ${MODEL_ID} 到 ${TARGET}（约 16GB，支持断点续传）"
modelscope download --model "${MODEL_ID}" --local_dir "${TARGET}"

log "校验文件清单："
ls -lh "$TARGET" | head -30
log "Safetensors 完整性："
ls -lh "$TARGET"/*.safetensors
