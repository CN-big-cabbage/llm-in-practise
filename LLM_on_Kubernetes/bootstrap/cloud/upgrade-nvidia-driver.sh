#!/usr/bin/env bash
# 升级 NVIDIA 驱动到指定主版本
# 解决 vLLM 等新镜像需要 CUDA >= 12.9（要驱动 >= 580）的问题
#
# 用法：sudo bash upgrade-nvidia-driver.sh [TARGET_MAJOR] [--yes] [--skip-reboot]
#   示例：sudo bash upgrade-nvidia-driver.sh 580
#         sudo bash upgrade-nvidia-driver.sh 580 --yes        # 跳过确认
#         sudo bash upgrade-nvidia-driver.sh 580 --skip-reboot # 不自动重启
#
# 注意：
#   - 升级需要 reboot 才生效
#   - 如果在 K8s 集群里，建议先 `kubectl drain` 该节点
#   - 两台节点都需要升级才能让所有 vLLM Pod 都跑通
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 或 sudo 运行" >&2; exit 1
fi

TARGET_MAJOR="${1:-580}"
SKIP_PROMPT=false
SKIP_REBOOT=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) SKIP_PROMPT=true ;;
    --skip-reboot) SKIP_REBOOT=true ;;
  esac
done

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }

# ---------- 1. 检测当前驱动 ----------
if ! command -v nvidia-smi >/dev/null; then
  log "未检测到 nvidia-smi，假定本机无 NVIDIA 驱动"
  CURRENT=""
  CURRENT_MAJOR=0
else
  CURRENT=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
  CURRENT_MAJOR=$(echo "$CURRENT" | cut -d. -f1)
  [[ -z "$CURRENT_MAJOR" ]] && CURRENT_MAJOR=0
fi

log "当前驱动: ${CURRENT:-(未装)}（主版本=${CURRENT_MAJOR}）"
log "目标主版本: ${TARGET_MAJOR}"

if [[ $CURRENT_MAJOR -ge $TARGET_MAJOR ]]; then
  green "✓ 当前驱动已 >= ${TARGET_MAJOR}，无需升级"
  exit 0
fi

# ---------- 2. 警告 + 确认 ----------
red "================================================"
red "  升级会 reboot 节点，GPU 工作负载会暂停！"
red "================================================"
if command -v kubectl >/dev/null 2>&1; then
  HOSTNAME_NOW=$(hostname)
  log "如果该节点在 K8s 集群里，强烈建议先 drain："
  log "  kubectl drain ${HOSTNAME_NOW} --ignore-daemonsets --delete-emptydir-data --force"
  log "升级完后再："
  log "  kubectl uncordon ${HOSTNAME_NOW}"
fi

if [[ "$SKIP_PROMPT" != "true" ]]; then
  read -p "确认升级到 nvidia-driver-${TARGET_MAJOR} 吗？[y/N] " confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { log "已取消"; exit 1; }
fi

# ---------- 3. 添加驱动源（优先 NVIDIA 官方，回退 PPA）----------
log "添加驱动源"

# 方式 A：NVIDIA cuda-keyring（推荐，国内可用）
if [[ ! -f /etc/apt/sources.list.d/cuda-ubuntu*.list ]]; then
  log "下载 cuda-keyring"
  UBUNTU_VER=$(lsb_release -rs | tr -d '.')  # 22.04 → 2204
  KEYRING_DEB=/tmp/cuda-keyring.deb
  if curl -fL --retry 3 -o "$KEYRING_DEB" \
       "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VER}/$(dpkg --print-architecture)/cuda-keyring_1.1-1_all.deb"; then
    dpkg -i "$KEYRING_DEB"
    log "cuda-keyring 安装完成"
  else
    log "cuda-keyring 拉取失败，回退用 PPA"
    add-apt-repository -y ppa:graphics-drivers/ppa
  fi
fi

# 方式 B：万一 cuda-keyring 没装上，加 PPA 兜底
if ! apt-cache search "^nvidia-driver-${TARGET_MAJOR}$" 2>/dev/null | grep -q "nvidia-driver-${TARGET_MAJOR}"; then
  log "源里没找到 nvidia-driver-${TARGET_MAJOR}，加 graphics-drivers PPA"
  add-apt-repository -y ppa:graphics-drivers/ppa
fi

apt-get update -qq

# ---------- 4. 卸载冲突包 + 安装新驱动 ----------
log "检查源里 nvidia-driver-${TARGET_MAJOR} 是否可用"
if ! apt-cache show "nvidia-driver-${TARGET_MAJOR}" >/dev/null 2>&1; then
  red "源里找不到 nvidia-driver-${TARGET_MAJOR}"
  red "可用版本："
  apt-cache search "^nvidia-driver-[0-9]+$" | sort -V
  exit 1
fi

log "安装 nvidia-driver-${TARGET_MAJOR}"
DEBIAN_FRONTEND=noninteractive apt-get install -y "nvidia-driver-${TARGET_MAJOR}"

# ---------- 5. reboot 或提示 ----------
log "驱动包安装完成。需要 reboot 才生效。"
if [[ "$SKIP_REBOOT" == "true" ]]; then
  log "已指定 --skip-reboot，跳过自动重启"
  red "请手动重启：sudo reboot"
  red "重启后验证：nvidia-smi"
else
  log "10 秒后自动 reboot（Ctrl-C 取消）"
  for i in 10 9 8 7 6 5 4 3 2 1; do
    echo -n "$i "
    sleep 1
  done
  echo
  reboot
fi
