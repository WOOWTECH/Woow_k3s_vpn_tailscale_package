# Woow VPN node, Tailscale compatible (WOOW PaaS cloud service)

**繁體中文說明：[README_zh-TW.md](README_zh-TW.md)**

A [Tailscale](https://github.com/tailscale/tailscale)-compatible VPN node, run
as a per-tenant cloud service on the WOOW PaaS platform (catalog name「VPN
節點（相容 Tailscale）」). It joins the tenant's own tailnet and makes chosen
services of the **same workspace** reachable from the tenant's devices over
that tailnet, without a public URL.

> **This repository is a read-only mirror.** The source of truth is the
> internal Gitea (`woow-paas/woow-paas-charts` `charts/tailscale/` and
> `woow-paas/paas-odoo-ci` `tailscale/`). See [MIRROR.md](MIRROR.md) for the
> exact source commits. Pull requests against `chart/` or `image/` are not
> accepted here; changes go to the Gitea repositories.

## Production image

```
jcr-prod.woowtech.io/woow-paas-docker-local/tailscale:20261004.0747@sha256:1868576adfe7a81fb0b36189cc224c6f5f3116971d2d8b32986365fbd4fb28cf
```

Tailscale **1.102.5**, chart `tailscale` **0.1.1**. The platform pins the image
by tag and digest; the registry is private to the platform.

## What you get

| | |
|---|---|
| **Role** | A workspace-private entrance: the node joins your tailnet and forwards chosen TCP ports to services of the same workspace (`tailscale serve`) |
| **Control server** | Official Tailscale (default), or any Headscale — including a Headscale in the same workspace via its in-cluster URL `http://<release>-headscale:8080` |
| **Login** | Interactive ("Log in" in the web UI, or the login URL in the log), or an optional auth key on the service page |
| **Forwards** | `<tailnet port>=<service>:<port>,…`, e.g. `8069=svc-1a2b3c4d-woow-odoo:8069,8123=svc-5e6f7a8b-home-assistant:8123` |
| **Web UI** | `tailscale web` in read-only mode (status, log in / re-authenticate), behind HTTP Basic auth |
| **Admin credentials** | Username `admin` by default, password shown once at launch; both can be changed from the service page ("Admin Credentials"). A reset restarts the service — back within tens of seconds |
| **Storage** | 1 GB PVC holding the node identity: restarts and resets keep the same machine on the tailnet |
| **Size / price** | 1 vCPU / 0.5 GB RAM / 1 GB disk, 400 pts/month (7-day trial) |

### What it does not do

- **No exit node and no subnet routes.** Exit node, app connector and subnet
  routes are forced off at every start (the cluster's public IP is shared with
  the platform, and a subnet router would hand the pod's network reach to the
  tailnet).
- No Tailscale SSH, Funnel, Taildrop, or the SOCKS5 / HTTP proxies.
- Forwards only reach Services of the node's own namespace (the tenant's
  workspace). IP addresses, outside host names and other namespaces are
  skipped and logged.
- No log upload to Tailscale (`--no-logs-no-support`).

## Using it

1. **Pick the control server.** Leave it empty for official Tailscale. For a
   Headscale in the same workspace, enter `http://<release>-headscale:8080`
   (the Headscale service's release name). Changing the control server later
   logs the node out and registers it again as a new machine.
2. **Log in.** Either open the web UI and press "Log in", or paste an auth key
   (a Tailscale `tskey-auth-…` key or a Headscale pre-auth key) into the
   service page. The key is used only while the node needs a login; a
   logged-in node never reads it. Prefer one-off, pre-approved, tagged keys,
   and clear the field after the first login.
3. **Publish services.** Fill the forwards list with Services of the same
   workspace. The list is validated when the node starts (and every 15 s);
   a bad entry is skipped and logged, never a failed deployment.
4. On your devices, reach the node by its tailnet name (default
   `woow-<release>`, or the hostname you set) and the tailnet port.

## Architecture

```
tenant browser ──▶ Cloudflare tunnel (platform subdomain)
                        │
                        ▼
              Service <release>-tailscale :8080
                        │
   ┌────────────────────┴──────────────────────────────────────────┐
   │ StatefulSet <release>-tailscale (1 replica)                    │
   │  entrance   nginx :8080, Basic auth (htpasswd from the Secret) │
   │             └─▶ tailscale web --readonly on 127.0.0.2:8088     │
   │  tailscale  tailscaled --tun=userspace-networking (uid 1000)   │
   │             tailscale serve --tcp <port> → <svc>.<ns>.svc:<p>  │
   └────────────────────┬──────────────────────────────────────────┘
                        ▼
          PVC <release>-tailscale-state (1 Gi) — node identity

tenant devices ──WireGuard (direct or DERP)──▶ node ──▶ Services of the same namespace
```

- Userspace networking: no `NET_ADMIN`, no `/dev/net/tun`, no host network.
  Non-root (uid 1000), all capabilities dropped, read-only root filesystem,
  no service-account token.
- Default-deny NetworkPolicy. Egress: DNS, the same namespace (forward
  targets, a same-workspace Headscale) and the public internet minus every
  private, link-local and CGNAT range — the cluster, the node LAN and the
  apiserver are out of reach from the tailnet. Not a tenant knob.
- `kubectl port-forward` to the web UI is refused (403) by design: it arrives
  on the pod's loopback, which nginx denies because tailnet traffic to the
  node lands there too.
- The password and username live only in the Secret (an htpasswd volume), so
  changing them never changes the pod template. The StatefulSet opts in to the
  platform's restart on credential reset.
- With a plain-`http://` control server (a same-workspace Headscale), a
  liveness watchdog restarts tailscaled if it stays out of sync with the
  control server for 8+ minutes — tailscaled otherwise keeps redialing :443
  after a Headscale restart and never comes back.

## How it differs from the podman package

The image is derived from
[`WOOWTECH/Woow_podman_vpn_tailscale_package`](https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package)
at `4d4a735` (its `Containerfile` and `entrypoint.sh`) and re-cut for k3s.
Details are in [`image/README.md`](image/README.md); in short:

| | podman package (`4d4a735`) | this image |
|---|---|---|
| Base | `tailscale/tailscale:v1.102.3`, tag only | `v1.102.5`, tag **and** digest |
| User | root | `USER 1000:1000`, all capabilities dropped |
| Networking | host network; userspace on the rootless Quadlet path, kernel TUN optional (`TS_USERSPACE_NETWORKING`) | pod network, userspace only |
| Exit node / subnet routes / app connector / SSH | configurable by env | forced off at every start; those env knobs and the passthrough args are ignored and logged |
| Auth key | `TS_AUTHKEY` env | file from the chart Secret, used only while the node needs a login |
| Forwards | `tailscale serve` set up by hand, to the host's `127.0.0.1:<port>` | declared list (`TS_SERVE`), validated at run time, Services of the same namespace only, re-checked every 15 s |
| Web UI | optional, writable (`--readonly=false`), no auth, loopback only | always on, read-only, bound to `127.0.0.2`, behind the chart's Basic auth |
| Entrypoint | one flow | `WOOW_TS_MODE=podman` keeps the original flow; `k8s` (default here) is the above |

`image/ci/build-tailscale-image.yml` is a reference copy of the Gitea build
pipeline (build → verify → candidate tag → prod approval → promote). GitHub
never runs it, and nothing in this repository builds or pushes an image.

## No parity with the podman and Home Assistant packages

Unlike the WOOWTECH code-server trio, there is **no parity contract** between
this cloud service, the podman package and the Home Assistant add-on. The
Tailscale cloud service is k3s-only: the podman package and the Home Assistant
add-on are left as they are, are not upgraded together with this image, and
may differ in version and features.

## Syncing

```bash
scripts/sync-from-gitea.sh                         # both Gitea repos at main
scripts/sync-from-gitea.sh <charts-ref> <ci-ref>
```

CI here lints and renders the chart, runs the entrypoint unit tests, checks the
sync script and the mirror layout; it does not build or publish anything.

## Trademarks

Tailscale is a trademark of Tailscale Inc. This project is not affiliated with
or endorsed by Tailscale Inc.; it packages the open-source Tailscale client.
Headscale is an independent open-source project.

## License

[MIT](LICENSE) for this package; the Tailscale client is BSD-3-Clause.
