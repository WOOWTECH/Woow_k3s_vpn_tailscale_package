# Changelog

## 1.0.0 — 2026-10-05

First release: a **read-only mirror of the WOOW PaaS "VPN node (Tailscale
compatible)" cloud service** — `woow-paas/woow-paas-charts` `charts/tailscale/`
(chart `0.1.1`, Tailscale 1.102.5) and `woow-paas/paas-odoo-ci` `tailscale/`
(image derived from `WOOWTECH/Woow_podman_vpn_tailscale_package` @ `4d4a735`).
Production image `tailscale:20261004.0747@sha256:1868576a…28cf`. See
[MIRROR.md](MIRROR.md).

- `chart/`: one Tailscale node per release — StatefulSet (1 replica) on a 1 Gi
  state PVC, tailscaled in userspace mode as uid 1000, run-time validated
  `tailscale serve` TCP forwards to Services of the same namespace, exit node /
  app connector / subnet routes / SSH forced off, read-only `tailscale web` on
  127.0.0.2 behind an nginx Basic-auth entrance (username default `admin`,
  platform-managed password), default-deny NetworkPolicy (DNS + same namespace
  + public internet minus private / CGNAT ranges), liveness watchdog for
  plain-http control servers.
- `image/`: official `tailscale/tailscale:v1.102.5` pinned by digest plus the
  WOOW entrypoint (k8s mode), non-root. Built and published by paas-odoo-ci
  behind a prod approval gate, never from here; `image/ci/` keeps a reference
  copy of that build workflow.
- `scripts/sync-from-gitea.sh` resyncs `chart/`, `image/` (with `image/ci/`)
  and the generated block of MIRROR.md.
- No parity contract with the podman package or the Home Assistant add-on
  (k3s only).
