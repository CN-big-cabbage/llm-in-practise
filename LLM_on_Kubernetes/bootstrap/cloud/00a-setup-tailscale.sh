#!/usr/bin/env bash
# Tailscale 安装与入网：所有 4 个节点都跑（在 00-init-node.sh 之前）
# 跑完后用 `tailscale status` 看分配到的 100.x.x.x IP，回填到 hosts.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2; exit 1
fi

if [[ ! -f "$ROOT_DIR/hosts.env" ]]; then
  echo "未找到 $ROOT_DIR/hosts.env" >&2; exit 1
fi
source "$ROOT_DIR/hosts.env"

if [[ -z "${TAILSCALE_AUTHKEY:-}" || "$TAILSCALE_AUTHKEY" == "tskey-auth-xxxxxxxxxxxxxxxxxxxxxxxx" ]]; then
  echo "请先在 hosts.env 里填 TAILSCALE_AUTHKEY" >&2; exit 1
fi

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

# ---------- 1. 装 Tailscale ----------
if ! command -v tailscale >/dev/null; then
  log "安装 Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
else
  log "Tailscale 已装：$(tailscale version | head -1)"
fi

# ---------- 2. 启动并入网 ----------
systemctl enable --now tailscaled

# 已经入网过就跳过
if tailscale status >/dev/null 2>&1 && [[ -n "$(tailscale ip -4 2>/dev/null)" ]]; then
  log "已加入 Tailnet，当前 IP："
  tailscale ip -4
else
  log "用 auth key 加入 Tailnet"
  tailscale up \
    --authkey="${TAILSCALE_AUTHKEY}" \
    --hostname="$(hostname)" \
    --accept-routes \
    --accept-dns=false
fi

# ---------- 3. 输出关键信息 ----------
TS_IP=$(tailscale ip -4)
log "本节点 Tailscale IP: ${TS_IP}"
log "回填到 hosts.env 的对应字段。然后继续跑 00-init-node.sh。"

# ---------- 4. 防火墙：放行 Tailscale 子网内 K8s 端口 ----------
# Tailscale 子网常用 100.64.0.0/10
if command -v ufw >/dev/null; then
  log "ufw 放行 Tailscale 子网"
  ufw allow from 100.64.0.0/10 || true
fi

log "完成。tailscale status 输出："
tailscale status || true
