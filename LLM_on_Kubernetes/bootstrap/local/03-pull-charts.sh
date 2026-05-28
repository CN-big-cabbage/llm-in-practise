#!/usr/bin/env bash
# 下载所有 Helm chart 到本地 tgz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/versions.env"

CHARTS_DIR="$ROOT_DIR/offline/charts"
mkdir -p "$CHARTS_DIR"

log() { echo -e "\033[36m[$(date +%H:%M:%S)] $*\033[0m"; }

if ! command -v helm >/dev/null; then
  echo "需要 helm，请先安装：https://helm.sh/docs/intro/install/" >&2
  exit 1
fi

log "添加 repo"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo add openebs https://openebs.github.io/openebs >/dev/null 2>&1 || true
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo add projectcalico https://docs.tigera.io/calico/charts >/dev/null 2>&1 || true
helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null

log "拉 chart 到 $CHARTS_DIR"
helm pull nvidia/gpu-operator --version "${GPU_OPERATOR_CHART_VERSION#v}" -d "$CHARTS_DIR"
helm pull openebs/openebs --version "${OPENEBS_CHART_VERSION}" -d "$CHARTS_DIR"
helm pull metallb/metallb --version "${METALLB_CHART_VERSION}" -d "$CHARTS_DIR"
helm pull ingress-nginx/ingress-nginx --version "${INGRESS_NGINX_CHART_VERSION}" -d "$CHARTS_DIR"
helm pull projectcalico/tigera-operator --version "${CALICO_CHART_VERSION}" -d "$CHARTS_DIR"
helm pull minio/minio -d "$CHARTS_DIR"

log "完成："
ls -lh "$CHARTS_DIR"
