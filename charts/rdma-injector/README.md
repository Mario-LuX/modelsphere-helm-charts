# rdma-injector（Helm chart 版）

给带 label `rdma-ib: "true"` 的 pod 自动注入「节点 RDMA 环境」的 mutating admission webhook：
`/etc/gpu-node` hostPath 挂载 + 启动时 `source /etc/gpu-node/nccl-ib.env`（本机好 IB 口 → `NCCL_IB_HCA`），
业务 manifest 保持零 RDMA 样板。逻辑见 `image/inject_webhook.py`。

## 相比老版（`../webhook/`，deploy.sh + ConfigMap 注入）的变化
- **代码烤进镜像**（`image/`），不再用 ConfigMap 挂代码；
- **serving 证书由 Helm 在 install 时自签**（`genSignedCert`，SAN=`rdma-injector.<Release.Namespace>.svc`）→ 塞进 Secret 挂到 `/tls`，caBundle 由 helm 自动填 → **可装到任意 namespace**（`helm install -n <ns>`）；
- 首次 install 签一次;之后 `helm upgrade` 用 `lookup` **复用**已有 Secret 的证书，**不重签**；
- 部署 = 一条 `helm install`，不再需要 deploy.sh 现签 + 手动注 caBundle。

## 目录
```
rdma-injector/
  Chart.yaml  values.yaml  README.md  test-inject.sh
  image/  Dockerfile  inject_webhook.py          # 只烤代码,不烤证书
  templates/
    deployment.yaml   # 挂 helm 生成的 Secret(/tls)
    service.yaml
    webhook.yaml      # 自签证书 → Secret + MutatingWebhookConfiguration(caBundle)
```

## 用法

### 1) 构建 + push 镜像（改了代码才需要重做；证书不再进镜像）
```bash
cd image
docker build -t harbor.4pd.io/hardcore-tech/rdma-injector:0.2.0 .
docker push harbor.4pd.io/hardcore-tech/rdma-injector:0.2.0
```

### 2) 安装 chart（任意 ns）
```bash
helm install rdma-injector ./rdma-injector -n kube-system
# 装别的 ns 也行,证书 SAN 会按该 ns 自签:
#   helm install rdma-injector ./rdma-injector -n rdma-system --create-namespace
# 升级(复用证书不重签):
#   helm upgrade rdma-injector ./rdma-injector -n <ns>
```
之后给任意 pod（非 webhook 所在 ns）打 `label rdma-ib: "true"` 即自动注入。

### 端到端测试
```bash
HELM=helm CHART=./rdma-injector bash test-inject.sh   # helm install + dry-run=server 验注入 + uninstall
```

## 证书说明
- 证书由 Helm `genSignedCert` 自签，SAN=`rdma-injector.<安装ns>.svc`；apiserver 调 webhook 时用 caBundle（同一 CA）校验，故 SAN 必须匹配 Service DNS —— helm 用 `Release.Namespace` 自动对齐，所以换 ns 无需任何改动。
- 有效期 `values.certValidityDays`（默认 3650 天）。`lookup` 复用逻辑保证 upgrade 不换证书；要强制重签：删掉 Secret `rdma-injector-certs` 再 upgrade。

## 设计要点（沿用老版）
- `failurePolicy: Fail`（fail-closed）：webhook 挂了就拒绝带 label 的 pod 创建 → 故 `replicas: 2` HA；webhook 自身不带 `rdma-ib` label + `namespaceSelector` 排除自己 ns → 无自我死锁。
- 注入用「到节点再 source」的管道而非 webhook 直接填值：准入（CREATE）时 pod 还没调度，webhook 不知落到哪台、拿不到 per-node 的 `NCCL_IB_HCA` 字面值。
