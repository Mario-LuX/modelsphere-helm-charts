#!/usr/bin/env python3
"""Keep an in-cluster copy of the model catalog and the helm chart repository.

swiss reads two things over HTTP:
  catalog    <base>/index.json, then every version file it names
             (models/<name>/<name>-<version>.yaml), each pinned by a sha256 digest;
             and <base>/index-v2.json, the index a site profile reads with
             schemaVersion v2: every variant file it names, pinned the same way,
             and each variant's history.json
  chartRepo  <base>/index.yaml, then the chart archives it lists

Upstream both live on GitHub Pages, whose reachability from some clusters is
poor (intermittent SYN loss), and the chart archives live on GitHub Releases.
This copies them into DATA_DIR, which nginx serves as /model-catalog/ and
/helm-charts/, so swiss can be pointed at the cluster instead.

Rules that keep the copy usable at every moment:
  - an index is replaced only after every file it names is on disk and verified
    (version files against the index's digest, chart archives against the digest
    their index entry carries); the replace is an atomic rename;
  - a failed round changes nothing, and the previous complete copy keeps serving;
  - files are never deleted: catalog versions and chart releases are immutable;
  - an unchanged upstream costs one conditional request per index: the ETag from
    the last round goes out as If-None-Match, and a 304 ends that half of the
    round without touching the disk.

Standard library only: the python image has no PyYAML, so the helm index is
handled as text (archive URLs, absolute or relative, rewritten to bare file
names; digests matched).

  python3 sync.py            loop forever, every INTERVAL seconds
  python3 sync.py --once     one round, exit 0 on success
"""
import hashlib, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone

CATALOG_URL = os.environ.get("CATALOG_URL", "https://modelsphere.github.io/model-catalog/")
CHARTS_URL = os.environ.get("CHARTS_URL", "https://modelsphere.github.io/helm-charts/")
DATA = os.environ.get("DATA_DIR", "/data")
INTERVAL = int(os.environ.get("INTERVAL", "1800"))
RETRY_INTERVAL = int(os.environ.get("RETRY_INTERVAL", "120"))
TIMEOUT = int(os.environ.get("TIMEOUT", "30"))
RETRIES = int(os.environ.get("RETRIES", "6"))


def log(msg):
    print(f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} {msg}", flush=True)


def fetch(url, etag=None, with_etag=False):
    """GET with retries: the upstream path drops SYNs now and then.

    With etag, the request is conditional: a 304 returns (None, etag).
    with_etag returns (body, etag) instead of the body alone."""
    last = None
    for i in range(RETRIES):
        try:
            headers = {"User-Agent": "catalog-mirror/1"}
            if etag:
                headers["If-None-Match"] = etag
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                body = r.read()
                return (body, r.headers.get("ETag")) if with_etag else body
        except urllib.error.HTTPError as e:
            last = e
            if e.code == 304:
                return (None, etag) if with_etag else None
            if 400 <= e.code < 500 and e.code != 429:
                break  # the server answered: retrying a 404 only burns time
            time.sleep(min(2 ** i, 30))
        except Exception as e:  # noqa: BLE001 -- network failures are retried
            last = e
            time.sleep(min(2 ** i, 30))
    raise RuntimeError(f"GET {url}: {last}")


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def safe_rel(rel):
    p = os.path.normpath(rel)
    if os.path.isabs(rel) or p.startswith("..") or "/../" in f"/{p}/":
        raise ValueError(f"path {rel!r} escapes the mirror")
    return p


def local_sha(path):
    try:
        with open(path, "rb") as f:
            return sha256(f.read())
    except FileNotFoundError:
        return None


ETAGS = os.path.join(DATA, ".etags.json")


def load_etags():
    try:
        with open(ETAGS) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def save_etag(key, etag):
    tags = load_etags()
    if etag and tags.get(key) != etag:
        tags[key] = etag
        write_atomic(ETAGS, json.dumps(tags, indent=1).encode())


def write_if_changed(path, data):
    if local_sha(path) != sha256(data):
        write_atomic(path, data)


def sync_catalog():
    root = os.path.join(DATA, "model-catalog")
    base = CATALOG_URL if CATALOG_URL.endswith("/") else CATALOG_URL + "/"
    index_path = os.path.join(root, "index.json")
    raw, etag = fetch(urllib.parse.urljoin(base, "index.json"),
                      etag=load_etags().get("catalog") if os.path.exists(index_path) else None, with_etag=True)
    if raw is None:
        return "catalog: unchanged (304)"
    idx = json.loads(raw)
    got = kept = reports = 0
    for m in idx.get("models", []):
        for v in m.get("versions", []):
            rel = safe_rel(v["path"])
            algo, _, want = v.get("digest", "").partition(":")
            if algo != "sha256" or not want:
                raise ValueError(f"{m['name']} {v.get('version')}: no sha256 digest")
            dst = os.path.join(root, rel)
            if local_sha(dst) == want:
                kept += 1
                continue
            body = fetch(urllib.parse.urljoin(base, rel))
            if sha256(body) != want:
                raise ValueError(f"{rel}: sha256 {sha256(body)[:12]} != index digest {want[:12]}")
            write_atomic(dst, body)
            got += 1
        # Perf reports are links on the pages, not part of a deploy: best effort.
        # A bare report name lives in the model's directory, which is NOT always the
        # model name (gemma-4-26b-a4b-it is in models/gemma-4-26b-a4b/): take the
        # directory from the model's version paths, which the index spells out.
        dirs = {os.path.dirname(v["path"]) for v in m.get("versions", []) if v.get("path")}
        mdir = dirs.pop() if len(dirs) == 1 else f"models/{m['name']}"
        for t in m.get("tuning") or []:
            name = t.get("report")
            if not name:
                continue
            rel = safe_rel(name if "/" in name else f"{mdir}/{name}")
            dst = os.path.join(root, rel)
            if os.path.exists(dst):
                continue
            try:
                write_atomic(dst, fetch(urllib.parse.urljoin(base, rel)))
                reports += 1
            except Exception as e:  # noqa: BLE001
                log(f"catalog: report {rel} skipped: {e}")
    write_if_changed(index_path, raw)  # last: everything it names is in place
    save_etag("catalog", etag)
    return f"catalog: {len(idx.get('models', []))} models, {got} version files fetched, {kept} unchanged, {reports} reports"


def sync_catalog_v2():
    """index-v2.json and what it names. A catalog that publishes no v2 index is
    not an error: older catalogs, and other mirrors, have only index.json."""
    root = os.path.join(DATA, "model-catalog")
    base = CATALOG_URL if CATALOG_URL.endswith("/") else CATALOG_URL + "/"
    index_path = os.path.join(root, "index-v2.json")
    try:
        raw, etag = fetch(urllib.parse.urljoin(base, "index-v2.json"),
                          etag=load_etags().get("catalog-v2") if os.path.exists(index_path) else None,
                          with_etag=True)
    except RuntimeError as e:
        if "HTTP Error 404" in str(e):
            return "catalog v2: upstream publishes no index-v2.json"
        raise
    if raw is None:
        return "catalog v2: unchanged (304)"
    idx = json.loads(raw)
    got = kept = hist = reports = 0
    for m in idx.get("models", []):
        for v in m.get("variants", []):
            rel = safe_rel(v["path"])
            algo, _, want = v.get("digest", "").partition(":")
            if algo != "sha256" or not want:
                raise ValueError(f"{m['name']} {v.get('id')}: no sha256 digest")
            dst = os.path.join(root, rel)
            if local_sha(dst) == want:
                kept += 1
            else:
                body = fetch(urllib.parse.urljoin(base, rel))
                if sha256(body) != want:
                    raise ValueError(f"{rel}: sha256 {sha256(body)[:12]} != index digest {want[:12]}")
                write_atomic(dst, body)
                got += 1
            # A history grows with every release of its variant, so unlike the
            # variant files it is not immutable: fetched whenever the index moved.
            if v.get("history"):
                h = safe_rel(v["history"])
                write_if_changed(os.path.join(root, h), fetch(urllib.parse.urljoin(base, h)))
                hist += 1
        dirs = {os.path.dirname(v["path"]) for v in m.get("variants", []) if v.get("path")}
        mdir = dirs.pop() if len(dirs) == 1 else f"models/{m['name']}"
        for name in m.get("reports") or []:
            rel = safe_rel(name if "/" in name else f"{mdir}/{name}")
            dst = os.path.join(root, rel)
            if os.path.exists(dst):
                continue
            try:
                write_atomic(dst, fetch(urllib.parse.urljoin(base, rel)))
                reports += 1
            except Exception as e:  # noqa: BLE001 -- reports are links, not deploy inputs
                log(f"catalog v2: report {rel} skipped: {e}")
    write_if_changed(index_path, raw)  # last: everything it names is in place
    save_etag("catalog-v2", etag)
    return (f"catalog v2: {len(idx.get('models', []))} models, {got} variant files fetched, "
            f"{kept} unchanged, {hist} histories, {reports} reports")


# An archive URL in index.yaml is absolute (chart-releaser: GitHub Releases) or
# relative to the repo URL (ChartMuseum, Harbor: charts/<name>.tgz). Group 3 is the
# file name the mirror stores it under.
URL_LINE = re.compile(r"^(\s*-\s*)((?:\S*/)?([^/\s]+\.tgz))\s*$", re.M)
DIGEST_LINE = re.compile(r"^\s*digest:\s*([0-9a-f]{64})\s*$", re.M)


def sync_charts():
    root = os.path.join(DATA, "helm-charts")
    base = CHARTS_URL if CHARTS_URL.endswith("/") else CHARTS_URL + "/"
    index_path = os.path.join(root, "index.yaml")
    body, etag = fetch(urllib.parse.urljoin(base, "index.yaml"),
                       etag=load_etags().get("charts") if os.path.exists(index_path) else None, with_etag=True)
    if body is None:
        return "charts: unchanged (304)"
    text = body.decode()
    digests = set(DIGEST_LINE.findall(text))
    urls = URL_LINE.findall(text)
    if not urls:
        raise ValueError("index.yaml lists no .tgz archives")
    got = kept = 0
    for _, url, name in urls:
        if "/" in name or name.startswith("."):
            raise ValueError(f"bad archive name {name!r}")
        dst = os.path.join(root, name)
        if local_sha(dst) in digests:
            kept += 1
            continue
        body = fetch(urllib.parse.urljoin(base, url))  # a relative URL resolves against the repo
        if sha256(body) not in digests:
            raise ValueError(f"{name}: sha256 {sha256(body)[:12]} matches no digest in index.yaml")
        write_atomic(dst, body)
        got += 1
    # Archive URLs become bare file names; helm resolves them against the repo URL.
    rewritten = URL_LINE.sub(lambda mo: f"{mo.group(1)}{mo.group(3)}", text)
    write_if_changed(index_path, rewritten.encode())
    save_etag("charts", etag)
    return f"charts: {len(urls)} archives, {got} fetched, {kept} unchanged"


def sync_catalog_both():
    """v1 and v2 are independent copies: one failing must not skip the other,
    nor hide that the other moved forward."""
    done, failed = [], []
    for fn in (sync_catalog, sync_catalog_v2):
        try:
            done.append(fn())
        except Exception as e:  # noqa: BLE001 -- reported below with what did succeed
            failed.append(f"{fn.__name__}: {e}")
    if failed:
        raise RuntimeError("; ".join(failed + [f"done: {d}" for d in done]))
    return "; ".join(done)


def round_once():
    status = {"time": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    ok = True
    for name, fn in (("catalog", sync_catalog_both), ("charts", sync_charts)):
        try:
            msg = fn()
            status[name] = {"ok": True, "detail": msg}
            log(msg)
        except Exception as e:  # noqa: BLE001 -- keep the other half and the old copy
            ok = False
            status[name] = {"ok": False, "error": str(e)}
            log(f"{name}: FAILED, previous copy kept: {e}")
    write_atomic(os.path.join(DATA, "status.json"), json.dumps(status, indent=1).encode())
    return ok


def main():
    if "--once" in sys.argv:
        sys.exit(0 if round_once() else 1)
    log(f"catalog-mirror: catalog={CATALOG_URL} charts={CHARTS_URL} data={DATA} interval={INTERVAL}s")
    while True:
        ok = round_once()
        time.sleep(INTERVAL if ok else RETRY_INTERVAL)


if __name__ == "__main__":
    main()
