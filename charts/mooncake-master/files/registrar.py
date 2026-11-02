#!/usr/bin/env python3
"""Keep NVMe-oF (NoF) volumes registered on whichever Mooncake master is leading.

Runs as a sidecar next to each mooncake_master replica:

    python3 registrar.py --volumes /etc/mooncake/volumes.conf \\
        --master <pod-ip>:50051 --metrics-port 9003

Only meaningful with a Mooncake build that supports NoF segments (it imports
mooncake.store.MooncakeDistributedNoFRegister); upstream builds do not.

Why it exists: volume registration lives only in the master's memory. After a
failover the new leader starts with an EMPTY segment table -- the volumes are
still on the array, but nothing knows about them, and clients fail reads with
no clue as to why. Without re-registration an HA pair is HA in name only.

Design:

* Only the leader registers. Leadership is read from whether this master's own
  RPC port accepts a connection: with the etcd backend only the elected leader
  starts its RPC server, a standby keeps it closed. The ha_standby_state gauge
  is NOT usable for this -- measured with two masters on the etcd backend, it
  read 0 on the leader and on the standby alike, and none of the other exported
  metrics differ between the two roles.

* The RPC port is bound to --rpc_address (the pod IP), not to loopback, so
  --master must be the pod IP; 127.0.0.1 is refused even on the leader.

* Idempotent and self-healing. Every cycle compares the master's reported NoF
  capacity with the total declared in the volume file and registers only when
  it falls short. That covers a failover and a plain master restart alike,
  without keeping state here.

* It never UNREGISTERS. Unregistration is callable by anyone, and a volume
  removed by mistake takes down every client using it -- with a symptom
  identical to the master's heartbeat eviction. Removal stays a deliberate
  human action.
"""

import argparse
import os
import re
import socket
import sys
import time
import urllib.request

ALIGN = 2 * 1024 * 1024


def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def parse_volumes(path):
    """One volume per line: nqn traddr port size_bytes; '#' starts a comment."""
    vols = []
    for lineno, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 4:
            log("config error line %d: need 4 fields, got %d" % (lineno, len(parts)))
            continue
        nqn, traddr, port, size = parts[:4]
        try:
            port, size = int(port), int(size)
        except ValueError:
            log("config error line %d: port/size must be integers" % lineno)
            continue
        if size % ALIGN:
            log("config error line %d: size not 2 MiB aligned" % lineno)
            continue
        vols.append((nqn, traddr, port, size))
    return vols


def metrics(port, host="127.0.0.1"):
    """Return {name: value} for the gauges this sidecar reads, or None if unreadable."""
    want = ("ha_standby_state", "master_total_nof_capacity_bytes")
    out = {}
    try:
        with urllib.request.urlopen("http://%s:%d/metrics" % (host, port), timeout=5) as resp:
            for line in resp.read().decode("utf-8", "replace").splitlines():
                if line.startswith("#"):
                    continue
                for w in want:
                    if line.startswith(w + " "):
                        try:
                            out[w] = float(line.split()[1])
                        except (IndexError, ValueError):
                            pass
    except Exception as exc:  # noqa: BLE001 -- any failure means "unknown"
        log("metrics unreadable: %s" % exc)
        return None            # distinct from "read it and everything was 0"
    return out


def rpc_listening(master, timeout=2.0):
    """True when this master's RPC port accepts a TCP connection, i.e. it leads."""
    host, _, port = master.rpartition(":")
    try:
        with socket.create_connection((host or "127.0.0.1", int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def short_name(nqn):
    m = re.search(r"-(in\d+)-", nqn)
    return m.group(1) if m else nqn[-12:]


def register_all(vols, master):
    """Register every volume. Returns how many succeeded."""
    os.environ.setdefault("GLOG_minloglevel", "2")
    try:
        from mooncake.store import MooncakeDistributedNoFRegister
    except ImportError as exc:
        log("cannot import MooncakeDistributedNoFRegister (%s) -- "
            "this Mooncake build has no NoF support" % exc)
        return 0
    reg = MooncakeDistributedNoFRegister()
    ok = 0
    for nqn, traddr, port, size in vols:
        rc = reg.real_register(nqn, 1, traddr, port, 0, size, master)
        log("  register %-12s via %s:%d -> rc=%s" % (short_name(nqn), traddr, port, rc))
        if rc == 0:
            ok += 1
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--volumes", required=True)
    ap.add_argument("--master", required=True,
                    help="<pod-ip>:<rpc-port> of the master in this pod (not loopback)")
    ap.add_argument("--metrics-port", type=int, default=9003)
    ap.add_argument("--metrics-host", default="127.0.0.1")
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--tolerance", type=float, default=0.99,
                    help="register when capacity falls below this fraction of expected")
    ap.add_argument("--dry-run", action="store_true",
                    help="decide leader/standby as usual but only log what would be registered")
    args = ap.parse_args()

    vols = parse_volumes(args.volumes)
    if not vols:
        sys.exit("no usable volumes in %s -- refusing to run" % args.volumes)
    want = sum(v[3] for v in vols)
    log("watching %d volume(s), expecting %.2f TiB%s" % (
        len(vols), want / 2**40, "  [DRY-RUN: nothing will be registered]" if args.dry_run else ""))

    was_leader = None
    while True:
        m = metrics(args.metrics_port, args.metrics_host)
        if m is None:
            # The master may still be starting. Do nothing rather than guess.
            time.sleep(args.interval)
            continue

        cap = m.get("master_total_nof_capacity_bytes", 0.0)
        leader = rpc_listening(args.master)
        if leader != was_leader:
            log("role -> %s (rpc %s %s)" % ("LEADER" if leader else "standby", args.master,
                                             "open" if leader else "closed"))
            was_leader = leader

        if leader and cap < want * args.tolerance:
            log("capacity %.2f/%.2f TiB -- registering" % (cap / 2**40, want / 2**40))
            if args.dry_run:
                log("DRY-RUN: would register %d volume(s): %s"
                    % (len(vols), " ".join(short_name(v[0]) for v in vols)))
            else:
                ok = register_all(vols, args.master)
                log("registered %d/%d" % (ok, len(vols)))

        time.sleep(args.interval)


if __name__ == "__main__":
    main()
