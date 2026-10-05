# Mirror provenance

This repository is a **read-only mirror** of the "VPN node (Tailscale
compatible)" cloud service that runs on the WOOW PaaS platform. The source of
truth is the internal Gitea (`git-prod.woowtech.io`). Changes land there first,
go through those repos' review and prod approval gates, and are then synced here
with [`scripts/sync-from-gitea.sh`](scripts/sync-from-gitea.sh).

**Do not edit `chart/` or `image/` here, and pull requests against them are not
accepted** — the next sync overwrites them. Open the change against the Gitea
repositories instead (`woow-paas/woow-paas-charts` for the chart,
`woow-paas/paas-odoo-ci` for the image). Only the mirror's own files (README,
MIRROR.md, CHANGELOG, `scripts/`, `.github/`) are maintained in this repository.

## Current sync

<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->
| Mirror path | Source repository | Source path | Commit |
|---|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` | `charts/tailscale/` | `578abff6667f8c8385c701e97a36c2a57de3169b` |
| `image/` | `woow-paas/paas-odoo-ci` | `tailscale/` | `bbc98cf2ab1044c9532955172f3429ffe0772b90` |
| `image/ci/` | `woow-paas/paas-odoo-ci` | `.gitea/workflows/build-tailscale-image.yml` | `bbc98cf2ab1044c9532955172f3429ffe0772b90` |

Upstream base image (official Tailscale image, consumed by digest): `docker.io/tailscale/tailscale:v1.102.5@sha256:c507f3a2a6ab1cabd8d809b98edeb41edbd5c3fb6ad9632ffd098b4c7d0b4065`

Chart `0.1.1` / appVersion `1.102.5` — synced 2026-10-05 02:49 UTC.
<!-- END GENERATED -->

## Production image

The chart defaults leave `image.tag` empty; the platform template (`tailscale`
in `odoo-addons/woow_paas_platform`) always pins the image by `tag@sha256`.
Pinned as of 2026-10-05 (platform `.209`, chart `0.1.1`):

```
jcr-prod.woowtech.io/woow-paas-docker-local/tailscale:20261004.0747@sha256:1868576adfe7a81fb0b36189cc224c6f5f3116971d2d8b32986365fbd4fb28cf
```

That image was built from `paas-odoo-ci` `main` at the commit recorded above
for `image/` (Tailscale 1.102.5). This line is maintained by hand: update it
when the platform template moves to a new image.

## Where each piece comes from

| Piece | Source | Published as |
|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` `charts/tailscale/` | `oci://jcr-prod.woowtech.io/woow-paas-docker-local/tailscale` (private) |
| `image/` | `woow-paas/paas-odoo-ci` `tailscale/` (build → verify → candidate tag → prod approval → promote) | `jcr-prod.woowtech.io/woow-paas-docker-local/tailscale:<YYYYMMDD.HHMM>` (private) |
| `image/ci/` | `woow-paas/paas-odoo-ci` `.gitea/workflows/build-tailscale-image.yml` | — (reference copy of the Gitea build pipeline; GitHub never runs it) |
| base image | official [`tailscale/tailscale`](https://hub.docker.com/r/tailscale/tailscale) (Docker Hub), pinned by index digest in `image/Dockerfile` | — |

The image is **derived from**
[`WOOWTECH/Woow_podman_vpn_tailscale_package`](https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package)
at `4d4a735` (its `Containerfile` and `entrypoint.sh`): same base, same extras,
same env-driven entrypoint, re-cut for k3s — see
[`image/README.md`](image/README.md) ("與 podman 版的差異") and the main
[README](README.md#how-it-differs-from-the-podman-package).

## Resyncing

```bash
scripts/sync-from-gitea.sh                         # both repos at main
scripts/sync-from-gitea.sh <charts-ref> <ci-ref>
```

Needs read access to both Gitea repositories. The result is committed here
through a pull request (CI must be green).

## Gitea copy

`woow-paas/Woow_k3s_vpn_tailscale_package` on the internal Gitea is a pull
mirror of this GitHub repository (8 h interval), so both hosts carry the same
commits.
