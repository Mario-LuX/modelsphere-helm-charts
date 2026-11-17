#!/usr/bin/env python3
"""helm test: read the mirror through its Service the way swiss and helm do.

  - status.json: the last sync round succeeded for both halves. This fails
    while the upstream is unreachable even though the copy itself is intact:
    a mirror that has stopped following its upstream is a problem worth a red
    test, and the message says which half failed and why;
  - catalog: every version file index.json names is served and matches its
    sha256 digest (swiss refuses a version whose digest does not match); the
    same for every variant file index-v2.json names, when there is one;
  - charts: index.yaml names its archives by relative name (so helm fetches
    them from the mirror, not from upstream), and every archive is served
    and matches a digest in the index;
  - a path that does not exist is a 404, so a catch-all answer cannot pass.

  python3 verify.py http://<service>.<namespace>.svc
"""
import hashlib, json, re, sys, urllib.error, urllib.request

base = sys.argv[1].rstrip("/")
failures = []


def get(path):
    with urllib.request.urlopen(f"{base}/{path}", timeout=30) as r:
        return r.read()


def check(ok, msg):
    print(("ok    " if ok else "FAIL  ") + msg, flush=True)
    if not ok:
        failures.append(msg)


def section(fn):
    """A section that cannot even read its index fails, and the others still run."""
    try:
        fn()
    except Exception as e:  # noqa: BLE001
        check(False, f"{fn.__name__}: {e}")


def last_sync():
    status = json.loads(get("status.json"))
    for half in ("catalog", "charts"):
        s = status.get(half, {})
        if s.get("ok") is True:
            check(True, f"last sync of {half}: {s.get('detail')}")
        else:
            check(False, f"last sync of {half} failed at {status.get('time')} "
                         f"(the copy still serves, but no longer follows upstream): {s.get('error')}")


def catalog():
    idx = json.loads(get("model-catalog/index.json"))
    n = bad = 0
    for m in idx.get("models", []):
        for v in m.get("versions", []):
            n += 1
            want = v.get("digest", "").partition(":")[2]
            try:
                got = hashlib.sha256(get(f"model-catalog/{v['path']}")).hexdigest()
            except Exception as e:  # noqa: BLE001
                got = f"error: {e}"
            if got != want:
                bad += 1
                print(f"      {v['path']}: {got[:16]} != {want[:16]}")
    check(n > 0 and bad == 0, f"catalog: {n - bad}/{n} version files match their digest")


def catalog_v2():
    try:
        idx = json.loads(get("model-catalog/index-v2.json"))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("skip  catalog v2: no index-v2.json served", flush=True)
            return
        raise
    n = bad = 0
    for m in idx.get("models", []):
        for v in m.get("variants", []):
            n += 1
            want = v.get("digest", "").partition(":")[2]
            try:
                got = hashlib.sha256(get(f"model-catalog/{v['path']}")).hexdigest()
                if v.get("history"):
                    get(f"model-catalog/{v['history']}")
            except Exception as e:  # noqa: BLE001
                got = f"error: {e}"
            if got != want:
                bad += 1
                print(f"      {v['path']}: {got[:16]} != {want[:16]}")
    check(n > 0 and bad == 0, f"catalog v2: {n - bad}/{n} variant files match their digest, histories served")


def charts():
    text = get("helm-charts/index.yaml").decode()
    digests = set(re.findall(r"^\s*digest:\s*([0-9a-f]{64})\s*$", text, re.M))
    urls = re.findall(r"^\s*-\s*(\S+\.tgz)\s*$", text, re.M)
    absolute = [u for u in urls if "://" in u]
    check(urls and not absolute, f"charts: {len(urls)} archives, {len(absolute)} still point upstream")
    bad = 0
    for u in urls:
        if "://" in u:
            continue
        try:
            ok = hashlib.sha256(get(f"helm-charts/{u}")).hexdigest() in digests
        except Exception as e:  # noqa: BLE001
            ok = False
            print(f"      {u}: {e}")
        bad += not ok
    check(urls and bad == 0, f"charts: {len(urls) - bad}/{len(urls)} archives served and match a digest")


def control():
    try:
        get("helm-charts/no-such-chart-0.0.0.tgz")
        check(False, "control: a missing archive is a 404 (got 200)")
    except urllib.error.HTTPError as e:
        check(e.code == 404, f"control: a missing archive is a 404 (got {e.code})")


for fn in (last_sync, catalog, catalog_v2, charts, control):
    section(fn)

sys.exit(1 if failures else 0)
