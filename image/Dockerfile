# tailscale — PaaS cloud-service image「VPN 節點（相容 Tailscale）」(woow-paas-charts charts/tailscale).
#
# Derived from the WOOWTECH podman image (WOOWTECH/Woow_podman_vpn_tailscale_package @ 4d4a735:
# Containerfile + entrypoint.sh). Same base (the official tailscale/tailscale image, Alpine +
# tailscaled + tailscale CLI), same extras (bash / jq / tini) and the same env-driven entrypoint,
# re-cut for k3s (see README.md "與 podman 版的差異"):
#   1. base bumped 1.102.3 → 1.102.5 and pinned by DIGEST (podman pins the tag only)
#   2. entrypoint k8s mode (WOOW_TS_MODE=k8s, the default here): userspace networking, state on
#      the PVC, socket in an emptyDir, exit node / app connector / subnet routes / SSH forced off,
#      authkey only while the node needs a login, run-time-validated serve forwards to Services of
#      the pod's own namespace, `tailscale web` read-only on 127.0.0.2 behind the chart's password
#      proxy. WOOW_TS_MODE=podman keeps the 4d4a735 behaviour.
#   3. non-root: USER 1000 (the podman image runs as root); state / socket dirs owned by 1000
#   4. CMD reset (the base CMD is containerboot, which this image never runs)
# Not used: upstream containerboot (TS_KUBE_SECRET defaults to a kube Secret + RBAC, a 60 s boot
# timeout that kills interactive logins, TS_DEST_IP unsupported in userspace — notes/tailscale.md §3).
#
# Registry: jcr-prod.woowtech.io/woow-paas-docker-local/tailscale:{tag} (UTC YYYYMMDD.HHMM,
# candidate tag → /approve → promote; never :latest). The platform pins tag@sha256.
# Bump = change the tag AND the digest together (docker manifest inspect tailscale/tailscale:<v>).
ARG BASE=docker.io/tailscale/tailscale:v1.102.5@sha256:c507f3a2a6ab1cabd8d809b98edeb41edbd5c3fb6ad9632ffd098b4c7d0b4065
FROM ${BASE}

# Entrypoint dependencies (same list as podman minus iptables / ip6tables / iproute2, which the
# base already ships and userspace mode never uses).
RUN apk add --no-cache \
      bash \
      ca-certificates \
      jq \
      tini

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh \
 && mkdir -p /var/lib/tailscale /var/run/tailscale \
 && chown 1000:1000 /var/lib/tailscale /var/run/tailscale \
 && chmod 0700 /var/lib/tailscale

# Node identity lives here (the chart mounts its PVC). Losing it = a new machine on the tailnet.
VOLUME ["/var/lib/tailscale"]

ENV WOOW_TS_MODE=k8s \
    STATE_DIR=/var/lib/tailscale \
    TS_SOCKET=/var/run/tailscale/tailscaled.sock \
    HOME=/tmp

# Documentation only. 41641/udp = WireGuard direct; 8088/tcp = `tailscale web`, which k8s mode
# binds to 127.0.0.2 (never reachable from outside the pod; the chart's nginx fronts it).
EXPOSE 41641/udp

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "-g", "--", "/entrypoint.sh"]
CMD []

LABEL org.opencontainers.image.title="Woow Tailscale (PaaS k3s)" \
      org.opencontainers.image.description="Tailscale client for WOOW PaaS: userspace, non-root, workspace-private TCP forwards; exit node / app connector / subnet routes disabled." \
      org.opencontainers.image.vendor="WoowTech" \
      org.opencontainers.image.version="1.102.5" \
      org.opencontainers.image.licenses="MIT AND BSD-3-Clause" \
      org.opencontainers.image.source="https://git-prod.woowtech.io/woow-paas/paas-odoo-ci" \
      io.woowtech.derived-from="https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package/tree/4d4a735"
