#!/usr/bin/env python3
"""Stand-in for `sglang serve` and `vllm serve`.

Answers every HTTP path with 200 (the chart probes /health, /health_generate
and /metrics) and records one start in the cache directory the host cache
manager handed over, so a later pod can see that the slot was warm.
"""

import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Both charts' preStop hooks treat a missing series as "cannot tell" and then
# wait out drainSeconds. Zero gauges make a quiet pod look idle immediately.
METRICS = """\
# mock engine
vllm:num_requests_running 0
vllm:num_requests_waiting 0
sglang:num_running_reqs 0
sglang:num_queue_reqs 0
"""


def arg_value(flag: str) -> str | None:
    for i, arg in enumerate(sys.argv):
        if arg == flag and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
        prefix = flag + "="
        if arg.startswith(prefix):
            return arg[len(prefix):]
    return None


def cache_dir() -> str:
    for key in ("SGLANG_CACHE_DIR", "VLLM_CACHE_ROOT"):
        value = os.environ.get(key)
        if value:
            return value
    sys.stderr.write("[mock] ERROR: neither SGLANG_CACHE_DIR nor VLLM_CACHE_ROOT is set\n")
    sys.exit(1)


def bump_marker(directory: str) -> int:
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "compiled.marker")
    count = 0
    try:
        with open(path) as fh:
            count = int(fh.readline().strip() or "0")
    except FileNotFoundError:
        count = 0
    count += 1
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(f"{count}\n")
    os.replace(tmp, path)
    return count


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        body = METRICS.encode() if path == "/metrics" else b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_GET
    do_PUT = do_GET

    def log_message(self, fmt, *args):
        return


def main():
    port_raw = arg_value("--port")
    if not port_raw:
        sys.stderr.write("[mock] ERROR: --port is required\n")
        sys.exit(1)
    host = arg_value("--host") or "0.0.0.0"
    directory = cache_dir()
    count = bump_marker(directory)
    print(f"[mock] compiled.marker={count} dir={directory} listen={host}:{port_raw}", flush=True)

    # PID 1 ignores signals it does not handle. Exit so the slot flock drops.
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    signal.signal(signal.SIGINT, lambda *_: os._exit(0))

    server = ThreadingHTTPServer((host, int(port_raw)), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
