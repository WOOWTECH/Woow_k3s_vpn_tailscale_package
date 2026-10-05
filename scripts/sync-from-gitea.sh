#!/usr/bin/env bash
# Sync this mirror from the Gitea source of truth.
#
# This repository is a read-only MIRROR of the WOOW PaaS "VPN node (Tailscale
# compatible)" cloud service. The authoritative copy lives on the internal Gitea
# (git-prod.woowtech.io); edits made here are overwritten by the next sync.
#
#   chart/     <- woow-paas/woow-paas-charts  charts/tailscale/
#   image/     <- woow-paas/paas-odoo-ci      tailscale/   (Dockerfile, entrypoint.sh, tests, README)
#   image/ci/  <- woow-paas/paas-odoo-ci      .gitea/workflows/build-tailscale-image.yml
#                 (reference copy only: GitHub runs .github/workflows/, never image/ci/)
#
# The image is built and published by paas-odoo-ci (build -> verify -> candidate
# tag -> prod approval -> promote), never from here. The platform's pinned image
# reference is not in the chart defaults (the platform always overrides
# image.tag), so MIRROR.md records the upstream base image digest from
# image/Dockerfile and the chart version; the production pin is kept by hand in
# MIRROR.md / README.
#
# Usage:  scripts/sync-from-gitea.sh [woow-paas-charts-ref] [paas-odoo-ci-ref]   (default "main" "main")
#
# Needs git read access to both Gitea repos (e.g. a credential helper for
# https://git-prod.woowtech.io). Writes the resolved commits into MIRROR.md so
# every mirrored file can be traced back to the exact source revision.
set -Eeuo pipefail

GITEA="${GITEA_URL:-https://git-prod.woowtech.io}"
CHARTS_REF="${1:-main}"
CI_REF="${2:-main}"
WORKFLOW=".gitea/workflows/build-tailscale-image.yml"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # <dir> <repo> <ref>
    git init -q "$WORK/$1"
    git -C "$WORK/$1" fetch -q --depth 1 "$GITEA/$2.git" "$3"
    git -C "$WORK/$1" checkout -q FETCH_HEAD
    git -C "$WORK/$1" rev-parse HEAD
}
CHARTS_SHA="$(fetch charts woow-paas/woow-paas-charts "$CHARTS_REF")"
CI_SHA="$(fetch ci woow-paas/paas-odoo-ci "$CI_REF")"

copy() { # <src dir> <dest dir>
    [ -d "$1" ] || { echo "missing source directory: $1" >&2; exit 1; }
    rm -rf "$2"
    mkdir -p "$2"
    cp -a "$1/." "$2/"
}
copy "$WORK/charts/charts/tailscale" "$ROOT/chart"
copy "$WORK/ci/tailscale" "$ROOT/image"
[ -f "$WORK/ci/$WORKFLOW" ] || { echo "missing source workflow: $WORKFLOW" >&2; exit 1; }
[ ! -e "$ROOT/image/ci" ] || { echo "paas-odoo-ci tailscale/ now has its own ci/ — update this script" >&2; exit 1; }
mkdir -p "$ROOT/image/ci"
cp -a "$WORK/ci/$WORKFLOW" "$ROOT/image/ci/"

CHART_VERSION="$(sed -n 's/^version: *//p' "$ROOT/chart/Chart.yaml")"
APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$ROOT/chart/Chart.yaml")"

# Rewrite only the generated block of MIRROR.md; the prose around it is kept.
python3 - "$ROOT/MIRROR.md" "$ROOT/image/Dockerfile" "$CHARTS_SHA" "$CI_SHA" "$CHART_VERSION" "$APP_VERSION" <<'PY'
import sys, re, datetime
path, dockerfile, charts, ci, chart_ver, app_ver = sys.argv[1:7]
df = open(dockerfile, encoding="utf-8").read()
base = re.search(r'^ARG BASE=(\S+)$', df, re.M).group(1)
block = (
    "<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->\n"
    "| Mirror path | Source repository | Source path | Commit |\n"
    "|---|---|---|---|\n"
    f"| `chart/` | `woow-paas/woow-paas-charts` | `charts/tailscale/` | `{charts}` |\n"
    f"| `image/` | `woow-paas/paas-odoo-ci` | `tailscale/` | `{ci}` |\n"
    f"| `image/ci/` | `woow-paas/paas-odoo-ci` | `.gitea/workflows/build-tailscale-image.yml` | `{ci}` |\n"
    "\n"
    f"Upstream base image (official Tailscale image, consumed by digest): `{base}`\n"
    "\n"
    f"Chart `{chart_ver}` / appVersion `{app_ver}` — synced "
    f"{datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC.\n"
    "<!-- END GENERATED -->"
)
text = open(path, encoding="utf-8").read()
new, n = re.subn(r"<!-- BEGIN GENERATED.*?<!-- END GENERATED -->", block, text, flags=re.S)
if n != 1:
    sys.exit("MIRROR.md is missing its generated block markers")
open(path, "w", encoding="utf-8").write(new)
PY

echo "synced: woow-paas-charts@${CHARTS_SHA:0:8} paas-odoo-ci@${CI_SHA:0:8}  chart ${CHART_VERSION} / ${APP_VERSION}"
