#!/usr/bin/env python3
"""
Tests for files/cache_manager.py. Standard library only, no pytest:

    python3 charts/sglang/test-cache-manager.py

Exits non-zero on the first suite with a failure. Runs anywhere Linux flock
semantics hold (Linux, macOS) -- no cluster, no GPU, no sglang.

Two kinds of test here, and the split matters:

  - Unit tests import cache_manager and call into it. Anything about who holds
    which lock needs a SECOND PROCESS, because flock conflicts are per open file
    description: a single process can take the same lock twice over two fds and
    would report exclusion that a real pod never gets. `holder()` spawns those,
    and they block on stdin so the test decides when a lock is released rather
    than racing a sleep.
  - End-to-end tests run the script the way the chart does -- env vars in,
    `-- <cmd>` to exec -- and assert on what the exec'd command sees. That is
    the only way to cover argv handling, the exec, and the env wiring together.

Nothing here touches the real $HOME: wire_cache() replaces ~/.cache/sglang, so
every test that reaches it runs with HOME pointed into a temp dir.
"""

import fcntl
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "files", "cache_manager.py")

spec = importlib.util.spec_from_file_location("cache_manager", SRC)
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

failures = []
current = ""


def check(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'}  {name}" + (f"   [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(f"{current}: {name}")


def suite(name):
    global current
    current = name
    print(f"\n{name}")


# ---- helpers ---------------------------------------------------------------

HOLDER = """
import fcntl, os, sys
path, mode = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(path), exist_ok=True)
fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX if mode == "ex" else fcntl.LOCK_SH)
print("held", flush=True)
sys.stdin.read()
"""

POD = """
import fcntl, os, sys
lock_dir, max_slots, lease_only = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "lease-only"
os.makedirs(lock_dir, exist_ok=True)
lease = os.open(os.path.join(lock_dir, ".lease"), os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(lease, fcntl.LOCK_SH)
slot = "lease-only"
if not lease_only:
    slot = "none"
    for i in range(max_slots):
        fd = os.open(os.path.join(lock_dir, "slot-%d.lock" % i), os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            slot = "slot-%d" % i
            break
        except OSError:
            os.close(fd)
print(slot, flush=True)
sys.stdin.read()
"""


LEASE_WAITER = """
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("cache_manager", sys.argv[1])
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)
fd = cm.hold_template_lease(sys.argv[2])
print(os.fstat(fd).st_ino, flush=True)
sys.stdin.read()
"""


def spawn(src, *args):
    """Runs src in a child that holds its locks until release() is called."""
    p = subprocess.Popen([sys.executable, "-c", src, *[str(a) for a in args]],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    p.first_line = p.stdout.readline().strip()
    return p


def holder(path, mode):
    """Holds one lock directly -- for states a real pod would never produce."""
    return spawn(HOLDER, path, mode)


def pod(lock_dir, max_slots=4, lease_only=False):
    """Acquires in main()'s order: shared lease, then an exclusive slot."""
    return spawn(POD, lock_dir, max_slots, "lease-only" if lease_only else "full")


def release(p):
    p.stdin.close()
    p.wait(timeout=10)


def contended(path, mode):
    """True if `mode` cannot be taken on path right now."""
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, (fcntl.LOCK_EX if mode == "ex" else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def template(host, h, slots=1, mtime=None):
    """Builds a template's data directory the way main() would."""
    d = os.path.join(host, h)
    for i in range(slots):
        os.makedirs(os.path.join(d, f"slot-{i}"), exist_ok=True)
    marker = os.path.join(d, ".last_used")
    open(marker, "a").close()
    if mtime:
        os.utime(marker, (mtime, mtime))
    return d


def lock_root(host):
    """
    Mirrors the layout main() computes. It is a copy, so on its own it would
    happily agree with a main() that had stopped separating the two trees --
    "the lock tree outlives the data it guards" below is what holds main() to it.
    """
    return os.path.join(host, cm.LOCK_ROOT)


def engine(host, home, shell, hash_="h1", slots=4, history=2, block=False):
    """
    Runs the script end-to-end as the chart does, exec'ing `sh -c shell`.
    With block=True the child waits on stdin, so a second engine can be started
    while this one still holds its locks.
    """
    env = dict(os.environ)
    env.update({
        "HOME": home,
        "SGLANG_CACHE_HOST_DIR": host,
        "SGLANG_CACHE_TEMPLATE_HASH": hash_,
        "SGLANG_CACHE_MAX_SLOTS": str(slots),
        "SGLANG_CACHE_HISTORY_LIMIT": str(history),
    })
    os.makedirs(home, exist_ok=True)
    cmd = [sys.executable, SRC, "--", "sh", "-c", shell + ("; read x" if block else "")]
    if block:
        p = subprocess.Popen(cmd, env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        p.marker = next((ln.strip() for ln in iter(p.stdout.readline, "")
                         if ln.startswith("OUT=")), "")
        return p
    r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=60)
    r.marker = next((ln.strip() for ln in r.stdout.splitlines() if ln.startswith("OUT=")), "")
    return r


# ---- slot leasing ----------------------------------------------------------

def test_slot_leasing():
    suite("slot leasing: one pod per directory")
    with tempfile.TemporaryDirectory() as host:
        h = "abc123"
        data = template(host, h)
        ld = os.path.join(lock_root(host), h)

        lease_fd = cm.hold_template_lease(ld)
        a, a_fd = cm.acquire_slot(ld, 4)
        b, b_fd = cm.acquire_slot(ld, 4)
        check("concurrent holders get different slots", a != b, f"{a} vs {b}")
        check("lock files live under .locks", os.path.exists(os.path.join(ld, f"{a}.lock")))
        check("no lock file in the data tree",
              not any(f.endswith((".lock", ".lease")) for f in os.listdir(data)),
              str(os.listdir(data)))
        for fd in (lease_fd, a_fd, b_fd):
            os.close(fd)

    suite("slot leasing: exhaustion is loud, not silent sharing")
    with tempfile.TemporaryDirectory() as host:
        ld = os.path.join(lock_root(host), "h")
        fds = [cm.acquire_slot(ld, 2)[1] for _ in range(2)]
        try:
            cm.acquire_slot(ld, 2)
            check("exits when every slot is taken", False, "returned a slot instead")
        except SystemExit as e:
            check("exits when every slot is taken", e.code == 1, f"exit {e.code}")
        for fd in fds:
            os.close(fd)


# ---- the template lease ----------------------------------------------------

def test_lease():
    suite("lease: shared among pods, exclusive against the GC")
    with tempfile.TemporaryDirectory() as host:
        ld = os.path.join(lock_root(host), "h")
        p1, p2 = pod(ld), pod(ld)
        lease = os.path.join(ld, ".lease")
        check("two pods hold it at once", p1.first_line != p2.first_line,
              f"{p1.first_line} vs {p2.first_line}")
        check("it stays available to further pods", not contended(lease, "sh"))
        check("the GC cannot take it exclusively", contended(lease, "ex"))
        release(p1)
        check("one remaining pod still blocks the GC", contended(lease, "ex"))
        release(p2)
        check("the last pod leaving frees it", not contended(lease, "ex"))

    suite("lease: a purge in flight keeps new pods out")
    with tempfile.TemporaryDirectory() as host:
        ld = os.path.join(lock_root(host), "h")
        os.makedirs(ld, exist_ok=True)
        lease = os.path.join(ld, ".lease")
        purging = holder(lease, "ex")
        check("pod cannot take the lease mid-purge", contended(lease, "sh"))
        release(purging)
        fd = cm.hold_template_lease(ld)   # hangs here if the release were broken
        check("pod takes it once the purge ends", True)
        os.close(fd)

    suite("lease: a pod that waited through a purge takes the lease that replaced it")
    with tempfile.TemporaryDirectory() as host:
        # The purge deletes the lease file last, so a pod already blocked on it
        # wakes holding an inode that no path names. Locking that proves
        # nothing: the next GC opens the new file and takes it exclusively
        # while this pod thinks it is protected.
        ld = os.path.join(lock_root(host), "h")
        lease = os.path.join(ld, ".lease")
        os.close(cm.open_lock(lease))
        orphan = os.stat(lease).st_ino

        purging = holder(lease, "ex")           # stands in for a GC mid-purge
        waiter = subprocess.Popen([sys.executable, "-c", LEASE_WAITER, SRC, ld],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        # Nothing observable says "blocked in flock", so this one races a sleep.
        time.sleep(0.5)
        os.unlink(lease)                        # the purge's last step
        release(purging)

        held = waiter.stdout.readline().strip()
        check("it does not settle for the unlinked inode", held != str(orphan), held)
        check("but locks the lease now at the path",
              os.path.exists(lease) and held == str(os.stat(lease).st_ino), held)
        check("and a GC cannot take that one from under it", contended(lease, "ex"))
        release(waiter)


    suite("lease: a GC that locked an orphan does not get to call it exclusive")
    with tempfile.TemporaryDirectory() as host:
        # The mirror image of the case above, and the one a holder's own check
        # cannot save it from: the purge lands between the GC's open and its
        # flock, so the GC locks an inode no path names while a pod holds the
        # lease that replaced it. Raced deterministically by running the purge,
        # and the pod that follows it, inside the open.
        ld = os.path.join(lock_root(host), "h")
        lease = os.path.join(ld, ".lease")
        os.close(cm.open_lock(lease))
        orphan = os.stat(lease).st_ino

        original, raced, live = cm.open_lock, [], []

        def purge_mid_open(path):
            fd = original(path)
            if not raced:                       # the first attempt only
                raced.append(True)
                os.unlink(path)                 # the purge's last step
                live.append(pod(ld, max_slots=1))   # a pod creates and holds the next lease
            return fd

        cm.open_lock = purge_mid_open
        try:
            fd = cm.take_lease(ld, fcntl.LOCK_EX | fcntl.LOCK_NB)
            check("the orphan it locked is not taken for the lease", fd is None,
                  "" if fd is None else f"locked {os.fstat(fd).st_ino}, orphan is {orphan}")
            if fd is not None:
                os.close(fd)
            check("the live pod's lease is a different inode",
                  os.stat(lease).st_ino != orphan)

            for p in live:
                release(p)
            fd = cm.take_lease(ld, fcntl.LOCK_EX | fcntl.LOCK_NB)   # no race left
            check("and once nothing holds that one, the GC takes it",
                  fd is not None and os.fstat(fd).st_ino == os.stat(lease).st_ino)
            if fd is not None:
                os.close(fd)
        finally:
            cm.open_lock = original


# ---- garbage collection ----------------------------------------------------

def test_gc():
    suite("gc: purges the abandoned, spares the live")
    with tempfile.TemporaryDirectory() as host:
        old = template(host, "old", mtime=1000)
        mid = template(host, "mid", mtime=2000)
        cur = template(host, "cur", mtime=3000)
        lr = lock_root(host)

        live = pod(os.path.join(lr, "old"))
        cm.garbage_collect(host, lr, "cur", 1)
        check("a leased template survives", os.path.isdir(old))
        check("an unleased one beyond historyLimit is purged", not os.path.isdir(mid))
        check("the current template is never a candidate", os.path.isdir(cur))
        release(live)

        # The window that made a slot-lock scan unsafe: a pod that has taken the
        # lease but not yet a slot is invisible to any scan of the slot locks.
        starting = pod(os.path.join(lr, "old"), lease_only=True)
        cm.garbage_collect(host, lr, "cur", 1)
        check("a pod still starting up is not purged out from under",
              os.path.isdir(old), "purged before it reached its slot")
        release(starting)

        cm.garbage_collect(host, lr, "cur", 1)
        check("purged once nothing holds it", not os.path.isdir(old))

    suite("gc: historyLimit counts the current template")
    with tempfile.TemporaryDirectory() as host:
        old = template(host, "old", mtime=1000)
        prev = template(host, "prev", mtime=2000)
        cur = template(host, "cur", mtime=3000)
        lr = lock_root(host)

        cm.garbage_collect(host, lr, "cur", 2)
        check("the current template is kept", os.path.isdir(cur))
        check("with the newest previous one, two in all", os.path.isdir(prev))
        check("and the rest purged", not os.path.isdir(old))

    suite("gc: a purge takes both of the template's directories")
    with tempfile.TemporaryDirectory() as host:
        old = template(host, "old", mtime=1000)
        template(host, "cur", mtime=3000)
        lr = lock_root(host)

        # Give the template a lock tree, then purge it with nothing holding it.
        release(pod(os.path.join(lr, "old")))
        old_lock = os.path.join(lr, "old")
        check("the pod left lock files behind",
              os.path.exists(os.path.join(old_lock, "slot-0.lock")))
        cm.garbage_collect(host, lr, "cur", 1)

        check("the data directory is gone", not os.path.isdir(old))
        check("so is the lock directory", not os.path.isdir(old_lock))
        check("but not the lock tree itself", os.path.isdir(lr))

        # Whatever a purge deletes, two pods must never end up owning one slot.
        live = pod(old_lock, max_slots=1)
        try:
            _, fd = cm.acquire_slot(old_lock, 1)
            os.close(fd)
            check("a held slot cannot be re-leased after a purge", False, "two owners")
        except SystemExit:
            check("a held slot cannot be re-leased after a purge", True)
        release(live)

    suite("gc: a live holder's lock files are never unlinked")
    with tempfile.TemporaryDirectory() as host:
        # The purge is safe because it cannot start: the holder's shared lease
        # blocks it. Nothing below is allowed to disappear.
        old = template(host, "old", mtime=1000)
        template(host, "cur", mtime=3000)
        lr = lock_root(host)
        live = pod(os.path.join(lr, "old"))
        lock_path = os.path.join(lr, "old", "slot-0.lock")
        inode = os.stat(lock_path).st_ino

        cm.garbage_collect(host, lr, "cur", 1)

        check("its data survives", os.path.isdir(old))
        check("its lock file survives, inode and all",
              os.path.exists(lock_path) and os.stat(lock_path).st_ino == inode)
        check("and so does its lease", os.path.exists(os.path.join(lr, "old", ".lease")))
        release(live)

    suite("gc: the lock tree is not a template")
    with tempfile.TemporaryDirectory() as host:
        # .locks sits beside the template directories now that the host dir is
        # the model's own. Mistaken for a template it is a candidate like any
        # other -- and purging it unlinks the lock file of every pod on the node
        # at once, which is the one deletion this layout exists to make
        # impossible.
        template(host, "cur", mtime=3000)
        lr = lock_root(host)
        release(pod(os.path.join(lr, "cur")))   # leaves a lock file behind
        lock = os.path.join(lr, "cur", "slot-0.lock")
        inode = os.stat(lock).st_ino

        cm.garbage_collect(host, lr, "cur", 1)
        check("the lock tree survives a purge pass", os.path.isdir(lr))
        check("with its lock files intact",
              os.path.exists(lock) and os.stat(lock).st_ino == inode)


# ---- cache wiring ----------------------------------------------------------

def test_wiring():
    saved_home = os.environ.get("HOME")
    try:
        with tempfile.TemporaryDirectory() as root:
            slot = os.path.join(root, "host", "m", "h", "slot-0")
            os.makedirs(slot)

            def wire(home, prep=None):
                os.environ["HOME"] = home
                for k in ("SGLANG_CACHE_DIR", "HF_HOME"):
                    os.environ.pop(k, None)
                link = os.path.join(home, ".cache", "sglang")
                if prep:
                    prep(link)
                cm.wire_cache(slot)
                return link

            suite("wiring: SGLANG_CACHE_DIR resolves to the leased slot")
            link = wire(os.path.join(root, "h1"))
            check("SGLANG_CACHE_DIR is the slot itself",
                  os.environ["SGLANG_CACHE_DIR"] == slot, os.environ["SGLANG_CACHE_DIR"])
            check("and ~/.cache/sglang is a symlink to it",
                  os.path.islink(link) and os.path.realpath(link) == os.path.realpath(slot),
                  os.path.realpath(link))
            open(os.path.join(link, "probe"), "w").write("x")
            check("writes through the default path land on the host disk",
                  os.path.exists(os.path.join(slot, "probe")))
            check("HF_HOME sits under it -- SGLANG_CACHE_DIR does not cover the HF hub",
                  os.environ["HF_HOME"] == os.path.join(slot, "huggingface"))
            check("no per-library variable is set, which would opt that cache back out",
                  not any(k in os.environ for k in ("TRITON_CACHE_DIR", "TORCHINDUCTOR_CACHE_DIR",
                                                    "FLASHINFER_WORKSPACE_BASE", "SGLANG_DG_CACHE_DIR")))

            suite("wiring: replaces whatever was at ~/.cache/sglang")
            def real_dir(p):
                os.makedirs(p)
                open(os.path.join(p, "stale"), "w").write("from the image")
            link = wire(os.path.join(root, "h2"), real_dir)
            check("a real directory shipped in the image",
                  os.path.islink(link) and os.path.realpath(link) == os.path.realpath(slot))

            other = os.path.join(root, "host", "m", "h", "slot-7")
            os.makedirs(other)
            def stale_link(p):
                os.makedirs(os.path.dirname(p))
                os.symlink(other, p)
            link = wire(os.path.join(root, "h3"), stale_link)
            check("a stale symlink to another slot",
                  os.path.realpath(link) == os.path.realpath(slot), os.path.realpath(link))

            suite("wiring: ~/.cache may be a mounted volume")
            home = os.path.join(root, "h4")
            os.makedirs(os.path.join(home, ".cache"))
            open(os.path.join(home, ".cache", "other-tool"), "w").write("keep me")
            link = wire(home)
            check("the symlink is made inside it", os.path.islink(link))
            check("its other contents are untouched",
                  os.path.exists(os.path.join(home, ".cache", "other-tool")))

            # Two pods on one node sharing ~/.cache: the second repoints the
            # link. Had the variable gone through it, the first pod's cache
            # would now resolve into the second one's slot.
            suite("wiring: a repointed ~/.cache/sglang does not move SGLANG_CACHE_DIR")
            home = os.path.join(root, "h5")
            wire(home)
            first = os.environ["SGLANG_CACHE_DIR"]
            os.environ["HOME"] = home
            cm.wire_cache(other)
            check("the first pod's cache still resolves to its own slot",
                  os.path.realpath(first) == os.path.realpath(slot), os.path.realpath(first))

            suite("wiring: no usable home still yields a warm cache")
            os.environ["HOME"] = "relative-nonsense"
            os.environ.pop("SGLANG_CACHE_DIR", None)
            cm.wire_cache(slot)
            check("SGLANG_CACHE_DIR is still the slot",
                  os.environ.get("SGLANG_CACHE_DIR") == slot, os.environ.get("SGLANG_CACHE_DIR"))
    finally:
        if saved_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = saved_home


# ---- end to end ------------------------------------------------------------

def test_end_to_end():
    suite("end to end: the engine starts under the cache it was given")
    with tempfile.TemporaryDirectory() as root:
        host, home = os.path.join(root, "host"), os.path.join(root, "home")
        r = engine(host, home, 'echo "OUT=$SGLANG_CACHE_DIR"')
        check("exec'd the command after --", r.returncode == 0, r.stderr[-200:])
        check("with SGLANG_CACHE_DIR set", r.marker.startswith("OUT=/"), r.marker)
        slot = os.path.realpath(r.marker[len("OUT="):])
        check("pointing into the host dir", slot.startswith(os.path.realpath(host)), slot)
        check("at a leased slot of this template", slot.endswith("h1/slot-0"), slot)

    suite("end to end: a restart reuses the warm cache")
    with tempfile.TemporaryDirectory() as root:
        host, home = os.path.join(root, "host"), os.path.join(root, "home")
        first = engine(host, home,
                       'echo "OUT=$SGLANG_CACHE_DIR"; echo kernels > "$SGLANG_CACHE_DIR/compiled.bin"')
        # The marker only prints if the file is there, so an empty one is a miss.
        second = engine(host, home,
                        'test -f "$SGLANG_CACHE_DIR/compiled.bin" && echo "OUT=$SGLANG_CACHE_DIR"')
        check("the replacement finds the previous run's kernels", second.marker != "",
              second.stdout[-200:])
        check("because it took the slot the first one released",
              second.marker == first.marker, f"{first.marker} -> {second.marker}")

    suite("end to end: the lock tree is separate from the data, and goes with it")
    with tempfile.TemporaryDirectory() as root:
        # Exercised through main() so it covers where main() actually puts the
        # locks -- not where a test thinks it should. The locks are kept out of
        # the data tree so that a purge unlinks them in its own order, holding
        # the lease, rather than as a side effect of deleting the cache.
        host, home = os.path.join(root, "host"), os.path.join(root, "home")
        engine(host, home, 'echo kernels > "$SGLANG_CACHE_DIR/compiled.bin"', hash_="h1", history=1)
        data = os.path.join(host, "h1")
        lock = os.path.join(host, cm.LOCK_ROOT, "h1", "slot-0.lock")
        check("no lock is written into the data tree",
              not [f for f in os.listdir(data) if f.endswith((".lock", ".lease"))],
              str(os.listdir(data)))
        check("the slot lock is in the lock tree", os.path.exists(lock), lock)

        # historyLimit 1: the next template's GC finds this one abandoned.
        engine(host, home, 'true', hash_="h2", history=1)
        check("the purge removes the data", not os.path.isdir(data))
        check("and the template's lock directory with it",
              not os.path.isdir(os.path.dirname(lock)))
        check("leaving the lock tree for the live template",
              os.path.isdir(os.path.join(host, cm.LOCK_ROOT, "h2")))

    suite("end to end: a running engine is not purged by one starting alongside")
    with tempfile.TemporaryDirectory() as root:
        # A rollout: `a` still serving on the old template, `b` starting on the
        # new one and running the GC, which finds the old template beyond
        # historyLimit. `a` holds its lease, so the GC has to leave it alone --
        # deleting a cache out from under a live engine is the failure the lease
        # exists to prevent, and it is invisible until the engine faults on it.
        host = os.path.join(root, "host")
        a = engine(host, os.path.join(root, "home-a"),
                   'echo "OUT=$SGLANG_CACHE_DIR"; echo kernels > "$SGLANG_CACHE_DIR/compiled.bin"',
                   hash_="h1", history=1, block=True)
        engine(host, os.path.join(root, "home-b"), 'true', hash_="h2", history=1)
        slot_a = os.path.realpath(a.marker[len("OUT="):])
        check("the running engine's cache survives", os.path.isdir(slot_a), slot_a)
        check("kernels and all", os.path.exists(os.path.join(slot_a, "compiled.bin")))
        release(a)

    suite("end to end: a different template hash gets a cold directory")
    with tempfile.TemporaryDirectory() as root:
        host, home = os.path.join(root, "host"), os.path.join(root, "home")
        engine(host, home, 'echo kernels > "$SGLANG_CACHE_DIR/compiled.bin"', hash_="h1")
        upgraded = engine(host, home, 'test -f "$SGLANG_CACHE_DIR/compiled.bin" || echo "OUT=COLD"', hash_="h2")
        check("an image or flag change does not reuse old kernels",
              upgraded.marker == "OUT=COLD", upgraded.stdout[-200:])

    suite("end to end: concurrent engines never share a directory")
    with tempfile.TemporaryDirectory() as root:
        # Same host dir (one node), separate HOMEs (each its own container).
        # `a` blocks on stdin, so it still holds its slot when `b` starts.
        host = os.path.join(root, "host")
        a = engine(host, os.path.join(root, "home-a"), 'echo "OUT=$SGLANG_CACHE_DIR"', block=True)
        b = engine(host, os.path.join(root, "home-b"), 'echo "OUT=$SGLANG_CACHE_DIR"')
        slot_a, slot_b = (os.path.realpath(p.marker[len("OUT="):]) for p in (a, b))
        check("the second engine gets a different slot", slot_a != slot_b, f"{slot_a} vs {slot_b}")
        check("both under the same template", os.path.dirname(slot_a) == os.path.dirname(slot_b),
              f"{slot_a} vs {slot_b}")
        release(a)

    suite("end to end: refuses to run with nothing to exec")
    with tempfile.TemporaryDirectory() as root:
        env = dict(os.environ, HOME=root, SGLANG_CACHE_HOST_DIR=os.path.join(root, "host"))
        r = subprocess.run([sys.executable, SRC], env=env, capture_output=True, text=True, timeout=60)
        check("exits non-zero", r.returncode != 0, str(r.returncode))
        check("saying what is missing", "No command specified" in r.stderr, r.stderr[-200:])


def main():
    for t in (test_slot_leasing, test_lease, test_gc, test_wiring, test_end_to_end):
        t()
    print()
    if failures:
        print(f"FAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
