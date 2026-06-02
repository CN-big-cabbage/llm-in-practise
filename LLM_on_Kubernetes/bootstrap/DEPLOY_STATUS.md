# K8s 集群部署进度记录
# 更新时间: 2026-06-02 11:40

## 项目概述

基于 LLM_on_Kubernetes/bootstrap 的离线部署方案，搭建 K8s + GPU + 推理底座。

## 已完成 ✓

### 阶段 A - 离线包准备
- Step 1: 二进制 + K8s deb 包 ✓
- Step 2: 容器镜像 (39/40) ✓
- Step 3: Helm charts (6个) ✓
- Step 4: Qwen3-8B 模型 (16GB) ✓
- Step 5: 打包 ✓

### 阶段 B - Tailscale
- 跳过（直接用本地 IP 搭建）

### 阶段 C/D - 集群搭建
- kubeadm init (master) ✓
- node01 join ✓
- 节点标签 ✓
- Calico CNI ✓
- MetalLB ✓ (IP 池: 172.16.190.220-230)
- CoreDNS ✓
- Ingress-Nginx ✓ (IP: 172.16.190.220)
- OpenEBS 基础 ✓ (openebs-hostpath StorageClass)
- MinIO ✓ (IP: 172.16.190.221/222)

### 模型上传
- Qwen3-8B 模型上传到 MinIO ✓
  - minio/llm-models/Qwen3-8B/ (17 个对象, 15.27 GiB)
  - minio/qwen/Qwen3-8B/ (复制)

## 集群状态

```
节点:
  k8s-master01  Ready  172.16.190.202 (2C4G, Ubuntu 24.04)
  k8s-node01    Ready  172.16.190.203 (2C8G, Ubuntu 24.04)

核心 Pod:
  Calico:         ✓ Running
  MetalLB:        ✓ Running
  CoreDNS:        ✓ Running
  Ingress-Nginx:  ✓ Running
  MinIO:          ✓ Running
  kube-proxy:     ✓ Running

LoadBalancer 服务:
  ingress-nginx-controller: 172.16.190.220 (80/443)
  minio:                    172.16.190.221 (9000)
  minio-console:            172.16.190.222 (9001)

StorageClass:
  openebs-hostpath (default)
  manual (hostPath)
```

## MinIO 访问信息

```
Console: http://172.16.190.222:9001
API:     http://172.16.190.221:9000
账号:    admin / admin123456

Bucket:
  llm-models/Qwen3-8B/  (17 对象, 15.27 GiB)
  qwen/Qwen3-8B/        (复制)
```

## 待完成

### 本地两节点
- [ ] 安装 GPU Operator (需要 GPU 节点)
- [ ] 部署推理服务 (vLLM + Qwen3-8B)

### 云端节点 (暂无设备)
- [ ] 准备 node02 (3090 + MinIO)
- [ ] 准备 node03 (3090)
- [ ] Tailscale 组网
- [ ] 节点加入集群

## 问题记录与解决方案

1. **containerd 代理配置**
   - 问题: containerd 不自动使用 Docker 的代理
   - 解决: 创建 /etc/systemd/system/containerd.service.d/proxy.conf

2. **镜像 digest 不匹配**
   - 问题: 导入的镜像缺少 digest，pod 拉取时校验失败
   - 解决: 通过 SSH 隧道让 node01 直接从 registry.k8s.io 拉取

3. **Calico CNI TLS 超时**
   - 问题: Calico CNI 插件通过 ClusterIP (10.96.0.1) 访问 API Server 时 TLS 握手超时
   - 解决: 修改 /etc/cni/net.d/calico-kubeconfig 使用节点 IP (172.16.190.202:6443)

4. **MinIO 写权限**
   - 问题: hostPath 目录权限不足
   - 解决: chmod 777 /data/minio

5. **磁盘空间不足**
   - 问题: node01 磁盘满导致 MinIO 崩溃
   - 解决: 删除 models.tar (16G) 释放空间

6. **kubelet 版本冲突**
   - 问题: 系统有 /usr/local/bin/kubelet (v1.34.1) 和 apt 安装的 /usr/bin/kubelet (v1.31.4)
   - 解决: 删除 /usr/local/bin/kubelet

## 环境信息

### Master (172.16.190.202)
- OS: Ubuntu 24.04.3 LTS
- CPU: 2核
- 内存: 8.7GB
- 磁盘: 97GB
- containerd: v1.7.22
- K8s: v1.31.4
- 代理: v2ray 127.0.0.1:8001

### Node01 (172.16.190.203)
- OS: Ubuntu 24.04.3 LTS
- CPU: 2核
- 内存: 8.7GB
- 磁盘: 58GB
- containerd: v2.1.4
- K8s: v1.31.4
- 代理: 无（通过镜像拷贝绕过）

## 文件位置

- 项目: /opt/LLM_on_Kubernetes/bootstrap (master)
- 模型: /opt/LLM_on_Kubernetes/bootstrap/offline/models/Qwen3-8B (master)
- MinIO 数据: /data/minio (node01)
- 部署状态: DEPLOY_STATUS.md
