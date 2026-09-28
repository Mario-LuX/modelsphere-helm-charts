#!/usr/bin/env python3
"""Render the chart repository's landing page from its index.yaml.

chart-releaser writes index.yaml and nothing else, so without this the root of
the GitHub Pages site is a bare 404 -- fine for Helm, which only ever asks for
index.yaml, but it gives a person no way to tell a working chart repository from
a broken one.

    render_index_html.py <index.yaml> <index.html>

Reads the published index, not the charts, so the page can never claim a version
that was not actually released.
"""
import html
import sys

import yaml

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ModelSphere Helm Charts</title>
<style>
  :root {{ color-scheme: light dark; --fg:#1a1a1a; --bg:#fff; --muted:#666; --line:#e2e2e2; --code-bg:#f5f5f5; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --fg:#e6e6e6; --bg:#0f1115; --muted:#9aa0a6; --line:#2a2d34; --code-bg:#1a1d23; }}
  }}
  body {{ margin:0; padding:3rem 1.25rem; background:var(--bg); color:var(--fg);
         font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }}
  main {{ max-width:56rem; margin:0 auto; }}
  h1 {{ font-size:1.8rem; margin:0 0 .4rem; }}
  p.lede {{ color:var(--muted); margin:0 0 2rem; }}
  header {{ display:flex; align-items:center; gap:1rem; margin:0 0 2rem; }}
  header img {{ width:72px; height:72px; border-radius:12px; flex:none; }}
  header .lede {{ margin:0; }}
  pre {{ background:var(--code-bg); border:1px solid var(--line); border-radius:6px;
        padding:.9rem 1rem; overflow-x:auto; }}
  code {{ font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:.9em; }}
  .tablewrap {{ overflow-x:auto; }}
  table {{ border-collapse:collapse; width:100%; margin:.5rem 0 2rem; }}
  th,td {{ text-align:left; padding:.55rem .7rem; border-bottom:1px solid var(--line); vertical-align:top; }}
  th {{ font-size:.8rem; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); font-weight:600; }}
  td:nth-child(2),td:nth-child(3) {{ white-space:nowrap; }}
  a {{ color:inherit; }}
  footer {{ margin-top:3rem; padding-top:1.5rem; border-top:1px solid var(--line);
           color:var(--muted); font-size:.9rem; }}
</style>
</head>
<body>
<main>
  <header>
    <img src="https://avatars.githubusercontent.com/u/331933824?s=144&amp;v=4"
         alt="" width="72" height="72">
    <div>
      <h1>ModelSphere Helm Charts</h1>
      <p class="lede">Helm charts for running large language models on Kubernetes.</p>
    </div>
  </header>

<pre><code>helm repo add modelsphere https://modelsphere.github.io/helm-charts
helm repo update
helm search repo modelsphere</code></pre>

  <div class="tablewrap">
  <table>
    <thead><tr><th>Chart</th><th>Version</th><th>App version</th><th>Description</th></tr></thead>
    <tbody>
{rows}
    </tbody>
  </table>
  </div>

  <footer>
    Source and documentation:
    <a href="https://github.com/modelsphere/helm-charts">github.com/modelsphere/helm-charts</a>
    &middot; Apache License 2.0
    &middot; The machine-readable index is at <a href="index.yaml">index.yaml</a>.
  </footer>
</main>
</body>
</html>
"""

ROW = ('      <tr><td><code>modelsphere/{name}</code></td><td>{version}</td>'
       '<td>{app}</td><td>{desc}</td></tr>')


def main(src, dst):
    entries = (yaml.safe_load(open(src)) or {}).get("entries") or {}
    rows = []
    for name in sorted(entries):
        # Newest by publication time, not by version string: a chart repository
        # may carry a patch for an older line published after a newer minor.
        latest = sorted(entries[name], key=lambda v: v.get("created", ""), reverse=True)[0]
        rows.append(ROW.format(
            name=html.escape(name),
            version=html.escape(str(latest.get("version", ""))),
            app=html.escape(str(latest.get("appVersion", ""))),
            desc=html.escape(str(latest.get("description", ""))),
        ))
    open(dst, "w").write(PAGE.format(rows="\n".join(rows)))
    print("rendered %s from %d charts" % (dst, len(rows)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
