#!/usr/bin/env bash
# 检查 offline/bins/ 下二进制完整性，损坏或缺失的用 ghproxy 重下
# 解决「rsync 中断导致 containerd-*.tar.gz 是部分文件」这类问题
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"

BINS_DIR="$ROOT_DIR/offline/bins"
[[ ! -d "$BINS_DIR" && -d "$ROOT_DIR/bins" ]] && BINS_DIR="$ROOT_DIR/bins"
mkdir -p "$BINS_DIR"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

GHPROXY="https://gh-proxy.com/github.com"

# 验证文件并按需重下
# 用法：fix_file <local_file> <github_url_relative_to_github.com>
fix_file() {
  local file=$1
  local url_path=$2
  local fname=$(basename "$file")

  # 校验：tar.gz 用 gzip -t，runc 直接看大小
  local need_redownload=false
  if [[ ! -f "$file" ]]; then
    log "[缺失] $fname"
    need_redownload=true
  elif [[ "$fname" =~ \.(tar\.gz|tgz)$ ]]; then
    if ! gzip -t "$file" 2>/dev/null; then
      log "[损坏] $fname（gzip 校验失败）"
      need_redownload=true
    else
      log "[OK]   $fname"
    fi
  elif [[ -s "$file" ]]; then
    local size=$(stat -c%s "$file")
    if [[ $size -lt 1048576 ]]; then  # < 1MB 很可能是部分下载
      log "[可疑] $fname 仅 $((size/1024))KB"
      need_redownload=true
    else
      log "[OK]   $fname ($((size/1048576))MB)"
    fi
  fi

  if [[ "$need_redownload" == "true" ]]; then
    log "  → 重下：${GHPROXY}/${url_path}"
    if curl -fL --retry 3 -o "${file}.new" "${GHPROXY}/${url_path}"; then
      mv "${file}.new" "$file"
      log "  → 完成"
    else
      log "  → ghproxy 失败，尝试直接 GitHub"
      curl -fL --retry 3 -o "${file}.new" "https://github.com/${url_path}" && mv "${file}.new" "$file" \
        || { log "  → 直拉 GitHub 也失败"; rm -f "${file}.new"; return 1; }
    fi
  fi
}

log "=== 检查 / 修复 offline/bins/ ==="

fix_file "$BINS_DIR/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" \
  "containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"

fix_file "$BINS_DIR/runc.amd64" \
  "opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64"

fix_file "$BINS_DIR/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" \
  "containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz"

# helm 不在 github，单独
if [[ ! -f "$BINS_DIR/helm-${HELM_VERSION}-linux-amd64.tar.gz" ]]; then
  log "[缺失] helm，从 helm.sh 拉"
  curl -fL --retry 3 -o "$BINS_DIR/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
fi

# containerd.service systemd unit
if [[ ! -f "$BINS_DIR/containerd.service" ]]; then
  log "[缺失] containerd.service，拉"
  curl -fL --retry 3 -o "$BINS_DIR/containerd.service" \
    "https://raw.githubusercontent.com/containerd/containerd/main/containerd.service"
fi

# mc
if [[ ! -f "$BINS_DIR/mc" ]]; then
  log "[缺失] mc，从 dl.min.io 拉"
  curl -fL --retry 3 -o "$BINS_DIR/mc" \
    "https://dl.min.io/client/mc/release/linux-amd64/archive/mc.${MC_VERSION}"
  chmod +x "$BINS_DIR/mc"
fi

log "=== 文件清单 ==="
ls -lh "$BINS_DIR"
