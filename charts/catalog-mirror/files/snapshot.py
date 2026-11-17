#!/usr/bin/env python3
"""Put a packed copy of the mirror on the volume, before nginx serves it.

For a cluster that cannot reach upstream at all: the copy is made where upstream
is reachable (an air-gapped install bundle, say), packed as a gzip'd tar holding
the two trees nginx serves -- model-catalog/ and helm-charts/ -- and handed over
in a ConfigMap. Nothing else may be in the archive.

The archive is checked whole before anything is written, by the rules sync.py
follows for upstream, so a broken snapshot fails this init container instead of
leaving a Ready pod that answers 404s:
  - model-catalog/index.json, model-catalog/index-v2.json (what swiss reads
    with catalog schema v2) and helm-charts/index.yaml are present;
  - every version file index.json names, and every variant file index-v2.json
    names, is in the archive with the sha256 its index pins; every history it
    names is there;
  - index.yaml names its archives by bare file name -- an absolute URL would
    send helm upstream -- and each one is in the archive with a digest the
    index lists.

Then, as sync.py does, so a pod that restarts halfway never serves a torn copy:
every file goes in by atomic rename, and the indexes only after everything
they name. Files are never deleted. The ETags sync.py keeps are dropped: they
belong to the upstream copy the snapshot may just have rewound, and kept, a
304 would leave the snapshot's indexes in place until upstream next changed.

status.json says the copy came from a snapshot, in the shape verify.py reads.

  python3 snapshot.py <archive>
  SNAPSHOT_OPTIONAL=1   sync is on, and the snapshot is only where a fresh volume
                        starts from. A volume that already holds a mirror is left
                        alone: sync has kept it current, and the snapshot is older.
                        A missing or broken snapshot is reported, not fatal: it
                        must not take down a mirror that sync can fill.
"""
import hashlib, json, os, re, sys, tarfile
from datetime import datetime, timezone

DATA = os.environ.get("DATA_DIR", "/data")
TREES = ("model-catalog", "helm-charts")
INDEXES = ("index.json", "index-v2.json", "index.yaml")
REQUIRED = ("model-catalog/index.json", "model-catalog/index-v2.json", "helm-charts/index.yaml")
URL_LINE = re.compile(r"^\s*-\s*(\S+\.tgz)\s*$", re.M)
DIGEST_LINE = re.compile(r"^\s*digest:\s*([0-9a-f]{64})\s*$", re.M)


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
    parts = p.split("/")
    if parts[0] not in TREES or len(parts) < 2:
        raise ValueError(f"path {rel!r} is not a file under {' or '.join(TREES)}")
    return p


def sha(b):
    return hashlib.sha256(b).hexdigest()


def check(files):
    """Every reason the archive cannot be served as it is; empty when it can."""
    bad = [f"{r} is missing" for r in REQUIRED if r not in files]
    if bad:
        return bad

    def under_catalog(rel, what):
        # The archive's names went through safe_rel, so the index's must too:
        # "./models/x" and "models//x" name the same file nginx serves.
        try:
            return safe_rel(f"model-catalog/{rel}")
        except ValueError as e:
            bad.append(f"{what} {rel}: {e}")
            return None

    def pinned(rel, digest, what):
        algo, _, want = (digest or "").partition(":")
        key = under_catalog(rel, what)
        if key is None:
            return
        if algo != "sha256" or not want:
            bad.append(f"{what} {rel}: no sha256 digest in the index")
        elif key not in files:
            bad.append(f"{what} {rel}: named by the index, not in the archive")
        elif sha(files[key]) != want:
            bad.append(f"{what} {rel}: sha256 {sha(files[key])[:12]} != index digest {want[:12]}")

    for m in json.loads(files["model-catalog/index.json"]).get("models", []):
        for v in m.get("versions", []):
            pinned(v.get("path", ""), v.get("digest"), "catalog v1")
    for m in json.loads(files["model-catalog/index-v2.json"]).get("models", []):
        for v in m.get("variants", []):
            pinned(v.get("path", ""), v.get("digest"), "catalog v2")
            if v.get("history"):
                key = under_catalog(v["history"], "catalog v2")
                if key is not None and key not in files:
                    bad.append(f"catalog v2 {v['history']}: named by the index, not in the archive")

    text = files["helm-charts/index.yaml"].decode()
    digests = set(DIGEST_LINE.findall(text))
    urls = URL_LINE.findall(text)
    if not urls:
        bad.append("helm-charts/index.yaml lists no .tgz archives")
    for u in urls:
        if "/" in u:
            bad.append(f"index.yaml names {u}: archives must be bare file names, or helm fetches them upstream")
        elif f"helm-charts/{u}" not in files:
            bad.append(f"index.yaml names {u}, which is not in the archive")
        elif sha(files[f"helm-charts/{u}"]) not in digests:
            bad.append(f"{u}: sha256 matches no digest in index.yaml")
    return bad


def read(archive):
    files = {}
    with tarfile.open(archive, "r:gz") as t:
        for m in t.getmembers():
            if m.isdir():
                continue
            if not m.isfile():
                raise ValueError(f"{m.name}: only regular files may be in a snapshot")
            files[safe_rel(m.name)] = t.extractfile(m).read()
    return files


def main():
    archive = sys.argv[1]
    seed_only = os.environ.get("SNAPSHOT_OPTIONAL") == "1"
    if seed_only and all(os.path.exists(os.path.join(DATA, r)) for r in REQUIRED):
        # Writing the snapshot here would rewind what sync has moved forward,
        # and readiness would pass at once on the older copy.
        print("snapshot: the volume already holds a mirror, which sync keeps current; not applied", flush=True)
        return
    if seed_only and not os.path.exists(archive):
        print(f"snapshot: no {archive} -- if a snapshot was meant to seed this volume, "
              "check snapshot.key against the ConfigMap's key. Sync will fill the volume.",
              file=sys.stderr, flush=True)
        return
    try:
        files = read(archive)
        problems = check(files)
    except (OSError, EOFError, tarfile.TarError, ValueError, UnicodeDecodeError) as e:
        problems = [f"{archive}: {e}"]
    if problems:
        for p in problems[:50]:
            print(f"snapshot: {p}", file=sys.stderr)
        if seed_only:
            print(f"snapshot: {len(problems)} problem(s), not applied; sync will fill the volume",
                  file=sys.stderr, flush=True)
            return
        raise SystemExit(f"snapshot: {len(problems)} problem(s), nothing written")
    order = sorted(files, key=lambda r: os.path.basename(r) in INDEXES)  # indexes last
    for rel in order:
        write_atomic(os.path.join(DATA, rel), files[rel])
    try:
        os.remove(os.path.join(DATA, ".etags.json"))
    except FileNotFoundError:
        pass
    n = {tree: sum(rel.startswith(tree + "/") for rel in files) for tree in TREES}
    status = {
        "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source": "snapshot",
        "catalog": {"ok": True, "detail": f"from the snapshot: {n['model-catalog']} files"},
        "charts": {"ok": True, "detail": f"from the snapshot: {n['helm-charts']} files"},
    }
    write_atomic(os.path.join(DATA, "status.json"), json.dumps(status, indent=1).encode())
    print(f"snapshot: {n['model-catalog']} catalog files, {n['helm-charts']} chart files -> {DATA}", flush=True)


if __name__ == "__main__":
    main()
