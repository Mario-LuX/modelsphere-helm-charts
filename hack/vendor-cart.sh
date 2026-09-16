#!/usr/bin/env bash
# Re-vendor charts/*/charts/cart from upstream, at the version each parent pins.
#
# Why this exists: cart is developed in cache_aware_router.git (k8s/helm) and
# vendored into every chart that deploys one -- today charts/sglang and
# charts/vllm. Copying it by hand is unreviewable and silently pairs a chart
# version with contents nobody can reproduce: charts/sglang/charts/cart and
# charts/vllm/charts/cart are two trees that only a person's memory keeps in
# step with upstream. The pin in the parent's Chart.yaml
# (dependencies[name=cart].version) is the single source of truth here; this
# script makes the tree on disk match it.
#
#   ./hack/vendor-cart.sh [--check] [chart...]     default: every chart pinning cart
#
#     (no flag)   fetch each pinned version and overwrite the vendored tree
#     --check     fetch and diff only, write nothing; non-zero if any copy
#                 differs from its pinned upstream (use this in CI)
#
# ⚠️ charts/*/charts/cart is GENERATED. Do not edit it by hand -- change cart
# upstream, release a version, bump the pin in the parent Chart.yaml, re-run this.
# To move a chart to a new cart: edit that pin, then run this script.
set -euo pipefail

# ── 上游来源:待填 ──────────────────────────────────────────────────────────
# fetch_cart 必须把 cart chart 的 <version> 解包到 <dest>,使 <dest>/Chart.yaml 存在。
# 下面给了两种形态,按你们实际的留一种。CART_SOURCE 也可以从环境变量覆盖。
#
# NOTE: add helm repo hardcore-tech manully, as
#   helm repo add --ca-file <ca file> --cert-file <cert file> --key-file <key file>     --username <username> --password <password> <repo name> https://harbor.4pd.io/chartrepo/hardcore-tech
#   this repo require auth
CART_SOURCE="${CART_SOURCE:-hardcore-tech/cart}" # 例:oci://harbor.4pd.io/hardcore-tech/charts/cart

fetch_cart() { # <version> <dest>
  local version="$1" dest="$2"
  if [ -z "$CART_SOURCE" ]; then
    echo "vendor-cart: CART_SOURCE 未设置 —— 请在 hack/vendor-cart.sh 顶部填上游地址," >&2
    echo "             或 CART_SOURCE=... ./hack/vendor-cart.sh" >&2
    exit 2
  fi

  # 形态 A:OCI / HTTP chart 仓库(helm pull 按 --version 取)
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  helm pull "$CART_SOURCE" --version "$version" --untar --untardir "$tmp" >/dev/null
  mv "$tmp/cart" "$dest"

  # 形态 B:直接从 cache_aware_router.git 取 tag 下的 k8s/helm(用这种就删掉上面四行)
  #   local url; printf -v url "https://gitlab.4pd.io/.../cache_aware_router/-/archive/v%s/src-v%s.tar.gz" "$version" "$version"
  #   curl -fsSL "$url" | tar -xz -C "$tmp" --strip-components=1
  #   mv "$tmp/k8s/helm" "$dest"
}
# ───────────────────────────────────────────────────────────────────────────

check_only=false
[ "${1:-}" = "--check" ] && {
  check_only=true
  shift
}

# 点名了就只处理这几个(sglang 与 charts/sglang 都收),没点名就扫全部。
# 点名的必须真带 cart —— 打错名字时要报错,不能装作做完了。
explicit=false
if [ "$#" -gt 0 ]; then
  explicit=true
  charts=()
  for c in "$@"; do
    case "$c" in */*) charts+=("${c%/}") ;; *) charts+=("charts/$c") ;; esac
  done
else
  charts=()
  for d in charts/*/; do charts+=("${d%/}"); done
fi

status=0
for chart in "${charts[@]}"; do
  name="$(basename "$chart")"
  if [ ! -f "$chart/Chart.yaml" ]; then
    $explicit && {
      echo "FAIL $name: $chart/Chart.yaml 不存在"
      status=1
    }
    continue
  fi
  pin="$(yq -r '.dependencies[]? | select(.name == "cart") | .version' "$chart/Chart.yaml")"
  if [ -z "$pin" ]; then
    $explicit && {
      echo "FAIL $name: Chart.yaml 里没有 cart 依赖,没有版本可依据"
      status=1
    }
    continue # 扫全部时,不带 cart 的 chart 直接跳过
  fi

  work="$(mktemp -d)"
  fresh="$work/cart"
  fetch_cart "$pin" "$fresh"

  # 上游打错 tag 时早点炸,别把错版本铺进两个消费者
  got="$(yq -r '.version' "$fresh/Chart.yaml")"
  if [ "$got" != "$pin" ]; then
    echo "FAIL $name: pin 要 $pin,上游取回来的却是 $got"
    status=1
    rm -rf "$work"
    continue
  fi
  # subchart 目录名、condition(cart.enabled)、以及父 chart 直接调的 cart.* helper
  # 全都系在这个名字上;上游改名会让 subchart 悄悄失效,所以在这里挡住。
  if [ "$(yq -r '.name' "$fresh/Chart.yaml")" != "cart" ]; then
    echo "FAIL $name: 上游 chart 名不是 cart,vendored subchart 会失效"
    status=1
    rm -rf "$work"
    continue
  fi

  dest="$chart/charts/cart"
  if $check_only; then
    if diff -rq "$fresh" "$dest" >/dev/null 2>&1; then
      echo "ok   $name: charts/cart 与上游 $pin 一致"
    else
      echo "FAIL $name: charts/cart 与上游 $pin 不一致(有人手改过,或 pin 没跟上)"
      diff -rq "$fresh" "$dest" 2>&1 | sed -e "s|$fresh|上游|g" -e 's/^/       /'
      status=1
    fi
  else
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    cp -R "$fresh" "$dest"
    echo "ok   $name: charts/cart <- 上游 $pin"
  fi
  rm -rf "$work"
done

exit $status
