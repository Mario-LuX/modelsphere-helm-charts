#!/usr/bin/env python3
"""
SGLang Host Cache Manager
=========================
Manages host-level compilation caches (PyTorch Inductor, Triton, HuggingFace)
for distributed and single-node LLM serving workloads on Kubernetes.

Responsibilities:
1. Slot Leasing:
   Leases a numbered slot (slot-0 .. slot-N) on the host node using non-blocking
   POSIX kernel file locks (flock). Guarantees that no two concurrent pods on the
   same node ever write to the same cache directory simultaneously.
2. Warm Cache Reuse:
   When a pod restarts on a node, it re-acquires the unlocked slot and immediately
   reuses the existing compiled kernels, reducing restart latency from ~40 mins
   to ~10 mins.
3. Filesystem & Environment Wiring:
   Sets TRITON_CACHE_DIR, TORCHINDUCTOR_CACHE_DIR, and HF_HOME, and establishes
   symlinks from /root/.cache and /root/.triton to the leased slot directory.
4. Safe Garbage Collection:
   Maintains a `.last_used` access marker and checks for older inactive template
   hashes beyond historyLimit. If an old directory's slot locks are completely free,
   it purges the directory to prevent node disk exhaustion.
5. In-Place Process Replacement:
   Calls os.execvp() to replace itself with the target engine process (e.g. SGLang).
   The open lock file descriptor remains held across the process lifecycle and is
   automatically freed by the Linux kernel when the process terminates.
"""

import fcntl
import os
import shutil
import sys
import time


def acquire_slot(template_dir: str, max_slots: int):
    """
    Acquires an exclusive lock on the first available slot in template_dir.
    Returns (slot_name, lock_fd). Exits if all slots are in use.
    """
    acquired_slot = None
    lock_fd = None

    for i in range(max_slots):
        sname = f"slot-{i}"
        lfile = os.path.join(template_dir, f"{sname}.lock")
        try:
            fd = os.open(lfile, os.O_CREAT | os.O_RDWR, 0o644)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired_slot = sname
            lock_fd = fd
            # Ensure the lock file descriptor remains open across os.execvp
            os.set_inheritable(lock_fd, True)
            break
        except (BlockingIOError, OSError):
            try:
                os.close(fd)
            except Exception:
                pass

    if acquired_slot is None:
        sys.stderr.write(
            f"[cache-mgr] ERROR: All {max_slots} cache slots in {template_dir} are in use on this node!\n"
        )
        sys.exit(1)

    return acquired_slot, lock_fd


def wire_cache_links(cache_dir: str, triton_dir: str):
    """
    Sets up symlinks for /root/.cache and /root/.triton pointing to slot directories.
    Handles existing mountpoints gracefully by creating subfolder links.
    """
    os.environ["TRITON_CACHE_DIR"] = triton_dir
    os.environ["TORCHINDUCTOR_CACHE_DIR"] = os.path.join(cache_dir, "torch_inductor")
    os.environ["HF_HOME"] = os.path.join(cache_dir, "huggingface")

    # Wire /root/.triton
    try:
        if os.path.islink("/root/.triton"):
            os.unlink("/root/.triton")
        elif os.path.isdir("/root/.triton") and not os.path.ismount("/root/.triton"):
            shutil.rmtree("/root/.triton", ignore_errors=True)
        if not os.path.exists("/root/.triton"):
            os.symlink(triton_dir, "/root/.triton")
    except Exception as e:
        sys.stderr.write(f"[cache-mgr] Warning linking /root/.triton: {e}\n")

    # Wire /root/.cache
    try:
        if os.path.islink("/root/.cache"):
            os.unlink("/root/.cache")
        elif os.path.isdir("/root/.cache") and not os.path.ismount("/root/.cache"):
            shutil.rmtree("/root/.cache", ignore_errors=True)
        if not os.path.exists("/root/.cache"):
            os.symlink(cache_dir, "/root/.cache")
        elif os.path.ismount("/root/.cache"):
            # If /root/.cache is an external mountpoint, symlink sub-components inside it
            for sub in ["torch", "huggingface", "triton"]:
                target_sub = os.path.join(cache_dir, sub)
                os.makedirs(target_sub, exist_ok=True)
                link_sub = os.path.join("/root/.cache", sub)
                if os.path.islink(link_sub):
                    os.unlink(link_sub)
                elif os.path.isdir(link_sub):
                    shutil.rmtree(link_sub, ignore_errors=True)
                if not os.path.exists(link_sub):
                    os.symlink(target_sub, link_sub)
    except Exception as e:
        sys.stderr.write(f"[cache-mgr] Warning linking /root/.cache: {e}\n")


def garbage_collect(model_root: str, current_hash: str, history_limit: int):
    """
    Prunes inactive template hash directories beyond history_limit.
    Safely skips directories with active locks held by draining/canary pods.
    """
    if not os.path.isdir(model_root) or history_limit <= 0:
        return

    try:
        entries = []
        for ent in os.listdir(model_root):
            p = os.path.join(model_root, ent)
            if os.path.isdir(p):
                m = os.path.join(p, ".last_used")
                mt = os.path.getmtime(m) if os.path.exists(m) else os.path.getmtime(p)
                entries.append((mt, p, ent))

        # Sort newest first
        entries.sort(key=lambda x: x[0], reverse=True)
        # Identify candidates beyond the retention limit
        candidates = [e for e in entries if e[2] != current_hash][(history_limit - 1):]

        for _, opath, ohash in candidates:
            in_use = False
            if os.path.exists(opath):
                for f in os.listdir(opath):
                    if f.endswith(".lock"):
                        lp = os.path.join(opath, f)
                        try:
                            tfd = os.open(lp, os.O_RDWR)
                            fcntl.flock(tfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            os.close(tfd)
                        except (BlockingIOError, OSError):
                            in_use = True
                            break

                if not in_use:
                    sys.stdout.write(f"[cache-mgr] GC: Purging abandoned template cache {ohash}\n")
                    shutil.rmtree(opath, ignore_errors=True)
                else:
                    sys.stdout.write(f"[cache-mgr] GC: Cache {ohash} has active pods, skipping\n")
    except Exception as e:
        sys.stderr.write(f"[cache-mgr] Warning during garbage collection: {e}\n")


def main():
    host_dir = os.environ.get("SGLANG_CACHE_HOST_DIR", "/var/cache/sglang-host")
    model_name = os.environ.get("SGLANG_CACHE_MODEL_NAME", "default")
    template_hash = os.environ.get("SGLANG_CACHE_TEMPLATE_HASH", "base")
    max_slots = int(os.environ.get("SGLANG_CACHE_MAX_SLOTS", "8"))
    history_limit = int(os.environ.get("SGLANG_CACHE_HISTORY_LIMIT", "2"))

    model_safe = model_name.replace("/", "--").replace(":", "--")
    model_root = os.path.join(host_dir, model_safe)
    template_dir = os.path.join(model_root, template_hash)
    os.makedirs(template_dir, exist_ok=True)

    # Touch access marker
    marker = os.path.join(template_dir, ".last_used")
    try:
        with open(marker, "a"):
            os.utime(marker, None)
    except Exception:
        pass

    # Acquire node slot lease
    acquired_slot, _ = acquire_slot(template_dir, max_slots)
    slot_dir = os.path.join(template_dir, acquired_slot)
    cache_dir = os.path.join(slot_dir, "cache")
    triton_dir = os.path.join(slot_dir, "triton")
    os.makedirs(cache_dir, exist_ok=True)
    os.makedirs(triton_dir, exist_ok=True)
    sys.stdout.write(f"[cache-mgr] Acquired {acquired_slot} for template {template_hash}\n")

    # Wire filesystem paths and environment
    wire_cache_links(cache_dir, triton_dir)

    # Perform background garbage collection on old hashes
    garbage_collect(model_root, template_hash, history_limit)

    sys.stdout.flush()
    sys.stderr.flush()

    # Determine command to exec (everything after '--')
    idx = sys.argv.index("--") if "--" in sys.argv else 0
    cmd = sys.argv[idx + 1:] if idx > 0 else sys.argv[1:]

    if not cmd:
        sys.stderr.write("[cache-mgr] ERROR: No command specified to execute after '--'\n")
        sys.exit(1)

    # In-place process replacement; PID 1 is retained and lock FD stays open
    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
