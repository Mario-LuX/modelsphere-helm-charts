#!/usr/bin/env python3
"""
SGLang Host Cache Manager
=========================
Manages host-level compilation caches (everything under SGLANG_CACHE_DIR --
Triton, Inductor, FlashInfer, DeepGEMM, the CUDA driver cache -- plus HF_HOME)
for distributed and single-node LLM serving workloads on Kubernetes.

Responsibilities:
1. Slot Leasing:
   Leases a numbered slot (slot-0 .. slot-N) on the host node using non-blocking
   POSIX kernel file locks (flock). Guarantees that no two concurrent pods on the
   same node ever write to the same cache directory simultaneously. The lock files
   live in a tree of their own, outside the cache data they guard (see LOCK_ROOT).
2. Warm Cache Reuse:
   When a pod restarts on a node, it re-acquires the unlocked slot and immediately
   reuses the existing compiled kernels, reducing restart latency from ~40 mins
   to ~10 mins.
3. Filesystem & Environment Wiring:
   Sets SGLANG_CACHE_DIR -- the one root sglang puts Triton, Inductor, FlashInfer,
   DeepGEMM and the CUDA driver cache under -- to the leased slot, and links
   ~/.cache/sglang to it so sglang's own default path resolves there too.
4. Safe Garbage Collection:
   Keeps historyLimit templates per model, the current one included, ranked by a
   `.last_used` access marker. Of the older ones, a template whose lease it can
   take exclusively has no live pods, and its data directory is purged to prevent
   node disk exhaustion.
5. In-Place Process Replacement:
   Calls os.execvp() to replace itself with the target engine process (e.g. SGLang).
   Both lock file descriptors stay open across the process lifecycle and are freed
   by the kernel when the process terminates.
"""

import fcntl
import os
import shutil
import sys

# Layout under <host>, the parent path given in SGLANG_CACHE_HOST_DIR:
#
#   <host>/
#   ├── <model>/
#   │   └── <hash>/                one template: image, flags, model config
#   │       ├── .last_used         what the GC sorts on
#   │       └── slot-N/            the cache; SGLANG_CACHE_DIR points here
#   └── .locks/
#       └── <model>/
#           └── <hash>/
#               ├── .lease         shared by every holder of this template
#               └── slot-N.lock    exclusive, one holder
#
# Two levels, two questions.
#  - slot-N.lock keeps concurrent holders out of one directory
#  - .lease keeps the GC from deleting a template out from under one compiling into it
# A holder takes it shared for its whole life, and the GC
# purges only a template it can lease exclusively -- one atomic answer, where
# scanning the slot locks would be a guess gone stale by the time it finished.
#
# The locks sit outside the data because flock is held against an inode, not a
# path. Unlink one -- the GC purging the tree around it, anything sweeping <host>
# -- and its holder keeps an orphaned inode while the next arrival locks a fresh
# one at the same path, both believing they own the slot. So the lock tree is
# never purged: the files are empty, and deleting them to tidy up is that bug.
#
# Only the shared acquisition ever waits, and it waits holding nothing (the GC
# always asks exclusive, non-blocking), so the two levels cannot deadlock. The
# kernel drops every lock when its holder exits, crash included.
LOCK_ROOT = ".locks"


def open_lock(path: str) -> int:
    """
    Opens a lock file, creating it and its directory. The fd is left inheritable
    so the lock it carries survives the exec into the engine.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    os.set_inheritable(fd, True)
    return fd


def hold_template_lease(lock_dir: str) -> int:
    """
    Takes this template's lease, shared, for the life of the process. Waits only
    on a GC purge of this same template, which holds the lease exclusively for
    one rmtree. Returns the lease fd. Exits if the lease cannot be taken: without
    it, the GC in a pod starting alongside is free to delete the tree underneath.
    """
    try:
        fd = open_lock(os.path.join(lock_dir, ".lease"))
        fcntl.flock(fd, fcntl.LOCK_SH)
        return fd
    except OSError as e:
        sys.stderr.write(f"[cache-mgr] ERROR: Cannot lease template in {lock_dir}: {e}\n")
        sys.exit(1)


def acquire_slot(lock_dir: str, max_slots: int):
    """
    Acquires an exclusive lock on the first free slot, taking the lock files from
    lock_dir. The cache data for the slot lives in the data tree, not here.
    Returns (slot_name, lock_fd). Exits if all slots are in use.
    """
    for i in range(max_slots):
        sname = f"slot-{i}"
        fd = None
        try:
            fd = open_lock(os.path.join(lock_dir, f"{sname}.lock"))
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return sname, fd
        except (BlockingIOError, OSError):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass

    sys.stderr.write(
        f"[cache-mgr] ERROR: All {max_slots} cache slots are in use on this node "
        f"(locks: {lock_dir})!\n"
    )
    sys.exit(1)


def wire_cache(slot_dir: str):
    """
    Points sglang at the leased slot.

    Everything sglang compiles -- Triton, Inductor, FlashInfer, DeepGEMM, the
    CUDA driver cache -- sits under SGLANG_CACHE_DIR, so that one variable moves
    the lot and none of the per-library variables need setting. Setting any of
    them would in fact opt that cache back out of SGLANG_CACHE_DIR, which is why
    they are conspicuously absent here.

    The variable names the slot itself, and ~/.cache/sglang is made a symlink to
    it for code assuming the default, so both land on the host disk. The variable
    does not go through the link: if ~/.cache were a volume shared across pods,
    the next pod on the node would repoint the link and carry this one's cache
    into its slot. The link is a leaf sglang owns: unlike ~/.cache it can be
    replaced without touching anything the image shipped or anything else
    mounted there.
    """
    home = os.path.expanduser("~")
    link = os.path.join(home, ".cache", "sglang")

    if os.path.isabs(home):
        try:
            os.makedirs(os.path.dirname(link), exist_ok=True)
            if os.path.islink(link) or os.path.isfile(link):
                os.unlink(link)
            elif os.path.isdir(link):
                shutil.rmtree(link, ignore_errors=True)
            os.symlink(slot_dir, link)
        except OSError as e:
            # Not fatal: the variable names the slot regardless, so the cache is
            # warm either way; only the default path misses out.
            sys.stderr.write(f"[cache-mgr] Warning linking {link}: {e}\n")

    os.environ["SGLANG_CACHE_DIR"] = slot_dir
    # Not covered by SGLANG_CACHE_DIR -- the HF hub cache is its own namespace,
    # and left alone it writes into the container and dies with it.
    os.environ["HF_HOME"] = os.path.join(slot_dir, "huggingface")


def garbage_collect(model_root: str, lock_root: str, current_hash: str, history_limit: int):
    """
    Keeps history_limit template hash directories, current_hash included, and
    prunes the older ones, each under that template's lease held exclusively, so
    a template a draining or canary pod still holds cannot be purged and one
    being purged cannot be joined.

    Only the data tree is purged; the matching lock directory stays, for the
    reason spelled out at LOCK_ROOT.
    """
    if not os.path.isdir(model_root) or history_limit <= 0:
        return

    try:
        entries = []
        for hash in os.listdir(model_root):
            p = os.path.join(model_root, hash)
            if os.path.isdir(p):
                m = os.path.join(p, ".last_used")
                mt = os.path.getmtime(m) if os.path.exists(m) else os.path.getmtime(p)
                entries.append((mt, p, hash))

        # Sort newest first
        entries.sort(key=lambda x: x[0], reverse=True)
        # The current template takes one of the history_limit places
        candidates = [e for e in entries if e[2] != current_hash][(history_limit - 1):]

        for _, opath, ohash in candidates:
            if not os.path.exists(opath):
                continue
            lease_fd = None
            try:
                lease_fd = open_lock(os.path.join(lock_root, ohash, ".lease"))
                fcntl.flock(lease_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                # Held shared by a live pod -- or not openable at all, which is
                # every bit as good a reason to delete nothing.
                sys.stdout.write(f"[cache-mgr] GC: Cache {ohash} is leased, skipping\n")
            else:
                sys.stdout.write(f"[cache-mgr] GC: Purging abandoned template cache {ohash}\n")
                shutil.rmtree(opath, ignore_errors=True)
            finally:
                # Also on the skip path: the fd is inheritable, and left open it
                # would ride the exec into the engine.
                if lease_fd is not None:
                    os.close(lease_fd)
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
    # Parallel to the data tree, not under it, so model_root holds template
    # hashes and nothing else -- the GC walks it and purges what it finds there.
    lock_root = os.path.join(host_dir, LOCK_ROOT, model_safe)
    lock_dir = os.path.join(lock_root, template_hash)

    # Both fds are bound and never closed on purpose: the kernel holds the two
    # locks for as long as this process (and the engine it execs into) lives, and
    # drops them the moment the container exits.
    #
    # The lease comes first, before anything under template_dir is created, so
    # the template exists for the GC in every pod starting alongside this one
    # only in the state of being in use.
    lease_fd = hold_template_lease(lock_dir)
    os.makedirs(template_dir, exist_ok=True)

    # Touch access marker
    marker = os.path.join(template_dir, ".last_used")
    try:
        with open(marker, "a"):
            os.utime(marker, None)
    except Exception:
        pass

    # Acquire node slot lease. The slot directory is the cache root itself --
    # sglang lays out triton/, inductor/, flashinfer/ and the rest inside it.
    acquired_slot, lock_fd = acquire_slot(lock_dir, max_slots)
    slot_dir = os.path.join(template_dir, acquired_slot)
    os.makedirs(slot_dir, exist_ok=True)
    sys.stdout.write(
        f"[cache-mgr] Acquired {acquired_slot} (fd {lock_fd}) "
        f"for template {template_hash} (lease fd {lease_fd})\n"
    )

    # Publish it: SGLANG_CACHE_DIR and the ~/.cache/sglang default both resolve here
    wire_cache(slot_dir)
    sys.stdout.write(f"[cache-mgr] SGLANG_CACHE_DIR={slot_dir}\n")

    # Garbage-collect old hashes; synchronous, so a large purge delays the exec
    garbage_collect(model_root, lock_root, template_hash, history_limit)

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
