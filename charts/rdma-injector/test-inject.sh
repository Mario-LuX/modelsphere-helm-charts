#!/usr/bin/env bash
# rdma-injector chart 端到端测试:helm install → 用 --dry-run=server(真走 webhook 不落盘)
# 验证带 rdma-ib:"true" 的 pod 被注入(/etc/gpu-node 挂载 + 启动 source),不带 label 的不注入 → helm uninstall。
# 在能 kubectl 的机器上跑(如 k8s-cpu-20)。用法:  HELM=/root/helm CHART=./rdma-injector bash test-inject.sh
set -uo pipefail
HELM=${HELM:-helm}
CHART=${CHART:-/tmp/rdma-injector}
NS=${NS:-kube-system}          # 可装任意 ns(证书 SAN 自动跟随)

echo "===== 1) helm install (ns=$NS) ====="
$HELM upgrade --install rdma-injector "$CHART" -n "$NS" --create-namespace 2>&1 | tail -6
echo "===== 2) 等 webhook 就绪 ====="
kubectl -n "$NS" rollout status deploy/rdma-injector --timeout=90s
kubectl -n "$NS" get pods -l app=rdma-injector -o wide --no-headers | awk '{print "  pod:",$1,$2,$3,$7}'

echo "===== 3) 带 label 的 pod 应被注入(--dry-run=server 走真 webhook)====="
cat > /tmp/pod-labeled.yaml <<POD
apiVersion: v1
kind: Pod
metadata: { name: rdma-test-labeled, namespace: default, labels: { rdma-ib: "true" } }
spec:
  containers:
  - name: c
    image: harbor.4pd.io/hardcore-tech/python:3.12-alpine
    command: ["sh","-c"]
    args: ["echo hi; sleep 1"]
POD
kubectl create -f /tmp/pod-labeled.yaml --dry-run=server -o yaml > /tmp/mutated.yaml 2>&1
grep -q "name: gpunode"   /tmp/mutated.yaml && echo "  ✓ volume gpunode 已注入"        || echo "  ✗ 无 gpunode volume"
grep -q "/etc/gpu-node"   /tmp/mutated.yaml && echo "  ✓ volumeMount /etc/gpu-node 已注入" || echo "  ✗ 无挂载"
grep -q "nccl-ib.env"     /tmp/mutated.yaml && echo "  ✓ 启动 source 片段已注入"        || echo "  ✗ 无 source 片段"

echo "===== 4) 不带 label 的 pod 应【不】被注入(对照)====="
sed 's/rdma-test-labeled/rdma-test-plain/; /rdma-ib/d' /tmp/pod-labeled.yaml > /tmp/pod-plain.yaml
kubectl create -f /tmp/pod-plain.yaml --dry-run=server -o yaml 2>&1 | grep -q "gpunode" \
  && echo "  ✗ 不该注入却注入了" || echo "  ✓ 未注入(对照正确)"

echo "===== 5) 清理 ====="
$HELM uninstall rdma-injector -n "$NS" 2>&1 | tail -1
