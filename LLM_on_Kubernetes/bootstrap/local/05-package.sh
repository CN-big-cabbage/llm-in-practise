#!/usr/bin/env bash
# 将 offline/ 目录连同 cloud/ 脚本打成单个 tar.gz，便于上传到网盘
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

OFFLINE_DIR="$ROOT_DIR/offline"
if [[ ! -d "$OFFLINE_DIR" ]]; then
  echo "未找到 $OFFLINE_DIR，请先跑 01-04" >&2
  exit 1
fi

# 把云端要用的脚本和配置一起打包
log "复制 cloud/ 脚本与 versions.env、hosts.env.example 到 offline/"
cp -r "$ROOT_DIR/cloud" "$OFFLINE_DIR/"
cp "$ROOT_DIR/versions.env" "$OFFLINE_DIR/"
cp "$ROOT_DIR/hosts.env.example" "$OFFLINE_DIR/"

# 把 LLM_on_Kubernetes 整个目录（YAML、README）也打进去
LLM_DIR="$(cd "$ROOT_DIR/.." && pwd)"
log "复制 LLM_on_Kubernetes 全目录"
rsync -a --exclude='bootstrap/offline' --exclude='bootstrap/offline.tar.gz' \
  "$LLM_DIR/" "$OFFLINE_DIR/LLM_on_Kubernetes/"

OUT="$ROOT_DIR/offline.tar.gz"
log "打包 → $OUT"
tar czf "$OUT" -C "$ROOT_DIR" offline

log "完成。大小："
du -sh "$OUT"
log "建议传网盘的路径：$OUT"
