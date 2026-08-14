# rdma-injector webhook 镜像 —— 只烤【代码】,不烤证书。
#
# 证书改由 Helm chart 在 install 时自签(SAN 按 Release.Namespace)→ 塞进 Secret 挂到 /tls,
# 所以 chart 可装到任意 namespace。见 ../templates/webhook.yaml。
#
# 构建(在能拉到 python:3.12-alpine 的机器上,如 chat):
#   cd image && docker build -t harbor.4pd.io/hardcore-tech/rdma-injector:0.2.0 .
#   docker push harbor.4pd.io/hardcore-tech/rdma-injector:0.2.0
FROM harbor.4pd.io/hardcore-tech/python:3.12-alpine

COPY inject_webhook.py /app/inject_webhook.py

EXPOSE 8443
ENTRYPOINT ["python3", "/app/inject_webhook.py"]
