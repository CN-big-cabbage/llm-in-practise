# 镜像备份与恢复指南

> 记录将云服务器上的 containerd 镜像备份到百度网盘，以及从网盘恢复到新服务器的完整操作流程。

---

## 备份记录

| 项目 | 内容 |
|---|---|
| 备份时间 | 2026-06-24 |
| 源服务器 | 117.50.186.132 |
| 镜像总数 | 54 个（导出 tar） |
| 备份总大小 | ~37 GB |
| 网盘目录 | `/llm-k8s-backup/images-20260624/` |
| 大文件分块 | `/llm-k8s-backup/images-20260624/chunks/` |

### 大文件分块说明

超过 5GB 的文件无法单片上传百度 PCS，已分 4GB 一块存入 `chunks/` 子目录：

| 原始镜像 | 大小 | 分块 |
|---|---|---|
| `docker.io/lmcache/vllm-openai:v0.3.15` | 12 GB | part_aa / ab / ac |
| `docker.io/vllm/vllm-openai:v0.11.2` | 14 GB | part_aa / ab / ac / ad |

---

## 一、备份操作（源服务器）

### 1. 安装 bypy 并登录百度网盘

```bash
pip3 install bypy
export PATH=$PATH:$HOME/.local/bin

# 登录：打开输出的 URL，同意授权后粘贴授权码
bypy info
bypy quota   # 验证登录成功
```

### 2. 导出 containerd 镜像

```bash
sudo mkdir -p /data/image-backup
sudo chown ubuntu:ubuntu /data/image-backup

# 导出所有命名镜像（排除 sha256 引用和 daocloud 镜像别名）
IMAGES=$(sudo ctr -n k8s.io images ls -q \
  | grep -v '^sha256:' \
  | grep -v 'daocloud.io' \
  | grep -v '@sha256:' \
  | sort -u)

for img in $IMAGES; do
    fname=$(echo "$img" | sed 's|[/:@]|_|g')
    echo "导出: $img"
    sudo ctr -n k8s.io images export "/data/image-backup/${fname}.tar" "$img"
done
```

### 3. 上传普通文件（<5GB）

```bash
export PATH=$PATH:$HOME/.local/bin
BACKUP_DIR="/data/image-backup"
REMOTE_DIR="/llm-k8s-backup/images-20260624"

bypy mkdir "$REMOTE_DIR"

for tarfile in "$BACKUP_DIR"/*.tar; do
    fname=$(basename "$tarfile")
    # --slice 10G 强制单片上传，绕过 bypy 分片 bug
    bypy --slice 10G upload "$tarfile" "$REMOTE_DIR/$fname"
done
```

### 4. 上传超大文件（>5GB，分块处理）

```bash
CHUNK_DIR="/data/image-backup/chunks"
mkdir -p "$CHUNK_DIR"

for bigfile in \
    "docker.io_lmcache_vllm-openai_v0.3.15.tar" \
    "docker.io_vllm_vllm-openai_v0.11.2.tar"; do

    # 分割成 4GB 块
    split -b 4G "/data/image-backup/$bigfile" "$CHUNK_DIR/${bigfile}.part_"

    # 逐块上传
    for chunk in $(ls "$CHUNK_DIR/${bigfile}".part_* | sort); do
        cfname=$(basename "$chunk")
        bypy --slice 10G upload "$chunk" "$REMOTE_DIR/chunks/$cfname"
    done
done
```

---

## 二、恢复操作（目标服务器）

### 前提：安装 bypy 并登录

```bash
pip3 install bypy
export PATH=$PATH:$HOME/.local/bin
bypy info   # 登录百度网盘
```

### 1. 从百度网盘下载

```bash
sudo mkdir -p /data/image-restore
sudo chown ubuntu:ubuntu /data/image-restore

# 下载所有普通镜像
bypy downdir /llm-k8s-backup/images-20260624 /data/image-restore

# 下载大文件分块
mkdir -p /data/image-restore/chunks
bypy downdir /llm-k8s-backup/images-20260624/chunks /data/image-restore/chunks
```

### 2. 还原大文件分块

```bash
cd /data/image-restore/chunks

# 还原 lmcache/vllm-openai:v0.3.15（12GB）
cat docker.io_lmcache_vllm-openai_v0.3.15.tar.part_aa \
    docker.io_lmcache_vllm-openai_v0.3.15.tar.part_ab \
    docker.io_lmcache_vllm-openai_v0.3.15.tar.part_ac \
    > /data/image-restore/docker.io_lmcache_vllm-openai_v0.3.15.tar

# 还原 vllm/vllm-openai:v0.11.2（14GB）
cat docker.io_vllm_vllm-openai_v0.11.2.tar.part_aa \
    docker.io_vllm_vllm-openai_v0.11.2.tar.part_ab \
    docker.io_vllm_vllm-openai_v0.11.2.tar.part_ac \
    docker.io_vllm_vllm-openai_v0.11.2.tar.part_ad \
    > /data/image-restore/docker.io_vllm_vllm-openai_v0.11.2.tar
```

### 3. 批量导入 containerd（一键脚本）

```bash
cat > /tmp/restore-images.sh << 'EOF'
#!/bin/bash
RESTORE_DIR="/data/image-restore"
LOG="$RESTORE_DIR/restore.log"

echo "=== 开始导入 $(date) ===" | tee -a "$LOG"

# 自动合并分块
if ls "$RESTORE_DIR/chunks/"*.part_aa >/dev/null 2>&1; then
    echo "合并分块文件..." | tee -a "$LOG"
    for part_aa in "$RESTORE_DIR/chunks/"*.part_aa; do
        base=$(basename "$part_aa" .part_aa)
        outfile="$RESTORE_DIR/$base"
        if [ ! -f "$outfile" ]; then
            echo "合并 $base" | tee -a "$LOG"
            cat "$RESTORE_DIR/chunks/${base}".part_* > "$outfile"
        fi
    done
fi

# 批量导入
TOTAL=$(ls "$RESTORE_DIR"/*.tar 2>/dev/null | wc -l)
COUNT=0
for tar in "$RESTORE_DIR"/*.tar; do
    [ -f "$tar" ] || continue
    COUNT=$((COUNT+1))
    echo "[$COUNT/$TOTAL] 导入 $(basename $tar)" | tee -a "$LOG"
    sudo ctr -n k8s.io images import "$tar" 2>&1 | tail -1 | tee -a "$LOG"
done

echo "=== 导入完成 $(date) ===" | tee -a "$LOG"
sudo ctr -n k8s.io images ls -q | grep -v '^sha256:' | wc -l | \
    xargs -I{} echo "共 {} 个镜像已就绪" | tee -a "$LOG"
EOF

bash /tmp/restore-images.sh
```

### 4. 验证镜像

```bash
# 查看总数
sudo ctr -n k8s.io images ls -q | grep -v '^sha256:' | grep -v 'daocloud' | wc -l

# 确认关键镜像
sudo ctr -n k8s.io images ls -q | grep -E 'vllm|lmcache|gpu-operator|calico/node|kube-apiserver'
```

### 5. 清理恢复目录（可选）

```bash
# 导入完成后释放磁盘空间
rm -rf /data/image-restore
```

---

## 三、注意事项

| 事项 | 说明 |
|---|---|
| 下载限速 | 百度网盘非会员约 1-2 MB/s，37 GB 约需 5-10 小时，建议提前一晚下载 |
| bypy 分片 bug | 上传时必须加 `--slice 10G`，否则大于 20MB 的文件会因 Slice MD5 mismatch 失败 |
| 磁盘空间 | 恢复时需要约 80 GB 可用空间（下载 37 GB + 分块合并临时文件） |
| 导入顺序 | 无顺序要求，containerd 自动去重相同层 |
| daocloud 别名 | 无需单独恢复，导入原始镜像后手动 `ctr tag` 即可（K8s 部署时按需添加） |
