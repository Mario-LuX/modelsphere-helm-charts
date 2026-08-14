#!/usr/bin/env python3
# rdma-injector —— Mutating Admission Webhook
#
# 作用:给带 label `rdma-ib: "true"` 的 pod 自动注入「节点 RDMA 环境」的管道,让业务
#       manifest 保持干净(不用写 hostPath 挂载 / source /etc/gpu-node/nccl-ib.env)。
#
# 注入内容(幂等,已存在则跳过):
#   1) volume `gpunode` = hostPath /etc/gpu-node(node_prep_rdma.sh 生成的本机好 IB 口文件所在)
#   2) 每个容器:volumeMount gpunode → /etc/gpu-node (ro)
#   3) 每个「以 shell 起(bash/sh + -c/-lc)」的容器:在启动脚本最前面 prepend 一段 source,
#      把 /etc/gpu-node/nccl-ib.env 里的 NCCL_IB_HCA 导入环境 → NCCL 只用本机好 IB 口。
#
# 为什么在容器启动时 source 而不是 webhook 直接填值:准入(CREATE)时 pod 还没调度,webhook
# 不知道会落到哪台 → 拿不到 per-node 的 NCCL_IB_HCA 字面值;故注入「到节点再解析」的管道。
#
# 运行:复用 harbor 已有的 sglang 镜像跑本脚本(自带 python3 + ssl 标准库,air-gap 免造新镜像),
#       脚本经 ConfigMap 挂到 /app,TLS 证书经 Secret 挂到 /tls。监听 :8443。
import json, base64, ssl, os
from http.server import BaseHTTPRequestHandler, HTTPServer

GPU_NODE_DIR = "/etc/gpu-node"
ENV_FILE     = GPU_NODE_DIR + "/nccl-ib.env"
VOL_NAME     = "gpunode"
SNIPPET      = "[ -f %s ] && set -a && . %s && set +a; " % (ENV_FILE, ENV_FILE)


def build_patch(pod):
    spec = pod.get("spec", {}) or {}
    patch = []

    # 1) volume(数组不存在则整体创建)
    vols = spec.get("volumes")
    vol = {"name": VOL_NAME, "hostPath": {"path": GPU_NODE_DIR, "type": "Directory"}}
    if vols is None:
        patch.append({"op": "add", "path": "/spec/volumes", "value": [vol]})
    elif not any(v.get("name") == VOL_NAME for v in vols):
        patch.append({"op": "add", "path": "/spec/volumes/-", "value": vol})

    # 2) 每容器:volumeMount + 3) 包一层 source
    for i, c in enumerate(spec.get("containers", []) or []):
        mounts = c.get("volumeMounts")
        mnt = {"name": VOL_NAME, "mountPath": GPU_NODE_DIR, "readOnly": True}
        if mounts is None:
            patch.append({"op": "add", "path": "/spec/containers/%d/volumeMounts" % i, "value": [mnt]})
        elif not any(m.get("name") == VOL_NAME for m in mounts):
            patch.append({"op": "add", "path": "/spec/containers/%d/volumeMounts/-" % i, "value": mnt})

        cmd = c.get("command", []) or []
        args = c.get("args", []) or []
        is_shell = len(cmd) >= 2 and os.path.basename(cmd[0]) in ("bash", "sh") \
            and any(f in cmd for f in ("-c", "-lc"))
        if is_shell and args:
            j = len(args) - 1                      # 脚本正文通常是最后一个 arg
            if SNIPPET not in args[j]:
                patch.append({"op": "replace",
                              "path": "/spec/containers/%d/args/%d" % (i, j),
                              "value": SNIPPET + args[j]})
    return patch


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n))
        except Exception:
            self.send_response(400); self.end_headers(); return
        req = body.get("request", {}) or {}
        pod = req.get("object", {}) or {}
        try:
            patch = build_patch(pod)
        except Exception:
            patch = []                              # 出错也放行,绝不阻塞 pod 创建
        resp = {"apiVersion": body.get("apiVersion", "admission.k8s.io/v1"),
                "kind": "AdmissionReview",
                "response": {"uid": req.get("uid", ""), "allowed": True}}
        if patch:
            resp["response"]["patchType"] = "JSONPatch"
            resp["response"]["patch"] = base64.b64encode(json.dumps(patch).encode()).decode()
        out = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):                               # /healthz
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    httpd = HTTPServer(("0.0.0.0", 8443), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain("/tls/tls.crt", "/tls/tls.key")
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print("rdma-injector webhook serving on :8443", flush=True)
    httpd.serve_forever()
