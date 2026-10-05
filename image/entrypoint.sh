#!/usr/bin/env bash
# Woow Tailscale entrypoint — PaaS (k3s) edition.
#
# Derived from WOOWTECH/Woow_podman_vpn_tailscale_package entrypoint.sh @ 4d4a735
# (see tailscale/README.md for the line-by-line differences). The podman flow and its
# env names are kept as they are:
#   tailscaled → login-server change ⇒ logout → `tailscale up` (no authkey ⇒ in the
#   background, so the web UI can start and the login URL reaches the log) →
#   optional `tailscale web`.
#
# WOOW_TS_MODE selects the behaviour:
#   podman — the 4d4a735 behaviour, unchanged (kept so the two stay diffable).
#   k8s    — the default of this image; what the woow-paas-charts `tailscale` chart runs:
#     * userspace networking always (no NET_ADMIN, no /dev/net/tun), runs as non-root;
#       state on the PVC (STATE_DIR), socket in an emptyDir, TS_KUBE_SECRET never used
#     * exit node, app connector, subnet routes, using an exit node, Tailscale SSH and the
#       tailnet-side management web client are FORCED off on every boot (`up --reset`);
#       the matching podman env vars and the TS_EXTRA_* passthroughs are ignored (logged)
#     * the authkey is read from a file (TS_AUTHKEY_FILE, a Secret volume) and handed to
#       tailscaled ONLY while the node needs a login — never on a node that is logged in
#     * TS_SERVE: `<tailnet port>=<service>:<port>,…` TCP forwards to Services of THIS
#       namespace, validated at run time — a bad entry is skipped and logged, never fatal;
#       re-applied whenever the node (re)enters Running and kept in sync
#     * every tenant-entered value (login server, hostname, tags, serve list) arrives as
#       env, is validated here and is never evaluated by a shell
#     * `tailscale web` (read-only mode: login button, no tailnet management client) is
#       bound to a 127.x address other than 127.0.0.1 — in userspace mode tailnet traffic
#       to an unserved port of the node is delivered to 127.0.0.1:<port> — and supervised
set -euo pipefail

log() { printf '[woow-tailscale] %s\n' "$*" >&2; }

# ============================================================================
# Validators (k8s mode). Pure functions — tests/test-entrypoint.sh sources this file
# with WOOW_TS_SOURCE_ONLY=1 and exercises them.
# ============================================================================

# Control server URL: empty = official Tailscale; else http(s)://host[:port][/path].
# No userinfo, query, fragment, whitespace or quotes.
valid_login_server() {
  local u="$1"
  [[ -z "$u" ]] && return 0
  [[ ${#u} -le 255 ]] || return 1
  [[ "$u" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] || return 1
  local port="${BASH_REMATCH[2]#:}"
  if [[ -n "$port" ]] && (( 10#$port < 1 || 10#$port > 65535 )); then return 1; fi
  return 0
}

# Same normalisation as ipn.IsLoginServerSynonym: empty / login. / controlplane. are one.
canon_control_url() {
  local u="${1%/}"
  case "$u" in
    "" | https://controlplane.tailscale.com | https://login.tailscale.com) echo "https://controlplane.tailscale.com" ;;
    *) echo "$u" ;;
  esac
}

# Hostname: one DNS label, lower-cased. Prints the label or fails.
valid_hostname() {
  local h
  h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$h" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  printf '%s' "$h"
}

# Tags: CSV of tag:<letter>[letters digits -]*. Prints the valid ones (CSV), logs the rest.
normalize_tags() {
  local raw="$1" out="" t
  local -a parts
  IFS=',' read -r -a parts <<< "$raw"
  for t in "${parts[@]}"; do
    t="${t//[[:space:]]/}"
    [[ -z "$t" ]] && continue
    if [[ "$t" =~ ^tag:[A-Za-z][A-Za-z0-9-]{0,62}$ ]]; then
      case ",$out," in *",$t,"*) continue ;; esac
      out="${out:+$out,}$t"
    else
      log "tags: skipping invalid tag '${t}' (expected tag:<letter>[letters digits -])"
    fi
  done
  printf '%s' "$out"
}

valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

# Serve list: `<tailnet port>=<target>:<port>[,…]`. A target is a Service of THIS
# namespace: its bare name, or <name>.<ns>[.svc[.<cluster domain>]] with ns == ours.
# Prints one `<port> <name>.<ns>.svc.<cluster domain>:<port>` line per valid entry (the
# FQDN, so a missing Service is NXDOMAIN instead of falling through the resolv.conf
# search list to some outside name). Everything else — IPs, outside names, another
# namespace, unix: sockets, duplicates — is skipped and logged.
#   $1 = list, $2 = namespace, $3 = cluster domain
parse_serve() {
  local raw="$1" ns="$2" domain="$3" entry lport target tport name rest count=0 max=32
  local seen=","
  local -a parts
  if [[ -n "$raw" && -z "$ns" ]]; then
    log "serve: own namespace unknown (TS_SERVE_NAMESPACE / POD_NAMESPACE unset); ignoring the whole list"
    return 0
  fi
  IFS=',' read -r -a parts <<< "$raw"
  for entry in "${parts[@]}"; do
    entry="${entry//[[:space:]]/}"
    [[ -z "$entry" ]] && continue
    if [[ ! "$entry" =~ ^([0-9]+)=([A-Za-z0-9.-]+):([0-9]+)$ ]]; then
      log "serve: skipping '${entry}': expected <tailnet port>=<service>:<port>"
      continue
    fi
    lport="${BASH_REMATCH[1]}" target="${BASH_REMATCH[2]}" tport="${BASH_REMATCH[3]}"
    if ! valid_port "$lport" || ! valid_port "$tport"; then
      log "serve: skipping '${entry}': ports must be 1-65535"
      continue
    fi
    target="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"
    target="${target%.}"
    name="${target%%.*}"
    rest=""
    [[ "$target" == *.* ]] && rest="${target#*.}"
    case "$rest" in
      "" | "$ns" | "$ns.svc" | "$ns.svc.$domain") ;;
      *)
        log "serve: skipping '${entry}': only Services of this namespace (${ns}) are allowed"
        continue
        ;;
    esac
    if [[ ! "$name" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || [[ "$name" == "localhost" ]]; then
      log "serve: skipping '${entry}': '${name}' is not a Service name"
      continue
    fi
    case "$seen" in
      *",$lport,"*)
        log "serve: skipping '${entry}': tailnet port ${lport} is already forwarded"
        continue
        ;;
    esac
    if (( count >= max )); then
      log "serve: skipping '${entry}': at most ${max} forwards"
      continue
    fi
    seen="${seen}${lport},"
    count=$((count + 1))
    printf '%s %s.%s.svc.%s:%s\n' "$lport" "$name" "$ns" "$domain" "$tport"
  done
}

# web UI listen address in k8s mode: a 127.x.y.z:port that is NOT 127.0.0.1 (userspace
# netstack hands tailnet connections to unserved ports to 127.0.0.1:<port>).
valid_k8s_web_listen() {
  [[ "$1" =~ ^127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):([0-9]+)$ ]] || return 1
  local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" p="${BASH_REMATCH[4]}"
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 )) || return 1
  [[ "$a.$b.$c" != "0.0.1" ]] || return 1
  valid_port "$p"
}

is_true() { [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]; }

if [[ "${WOOW_TS_SOURCE_ONLY:-}" == "1" ]]; then
  # shellcheck disable=SC2317  # reached only when executed instead of sourced
  return 0 2>/dev/null || exit 0
fi

WOOW_TS_MODE="${WOOW_TS_MODE:-k8s}"
case "$WOOW_TS_MODE" in
  podman | k8s) ;;
  *) log "ERROR: WOOW_TS_MODE must be podman or k8s (got '${WOOW_TS_MODE}')"; exit 1 ;;
esac

# --- Required / high-signal env ---------------------------------------------
TS_LOGIN_SERVER="${TS_LOGIN_SERVER:-}"       # 空=官方 Tailscale，填 URL=Headscale
TS_AUTHKEY="${TS_AUTHKEY:-}"                 # tskey-auth-... (Tailscale) or pre-auth key (Headscale)
TS_HOSTNAME_RAW="${TS_HOSTNAME:-}"
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"    # 節點在 tailnet 上的顯示名

# --- Feature toggles (podman defaults; k8s mode overrides — see below) -------
TS_ACCEPT_DNS="${TS_ACCEPT_DNS:-true}"
TS_ACCEPT_ROUTES="${TS_ACCEPT_ROUTES:-true}"
TS_ADVERTISE_EXIT_NODE="${TS_ADVERTISE_EXIT_NODE:-false}"
TS_ADVERTISE_CONNECTOR="${TS_ADVERTISE_CONNECTOR:-false}"
TS_ADVERTISE_ROUTES="${TS_ADVERTISE_ROUTES:-}"          # CSV, ex: 192.168.2.0/24,10.0.0.0/24
TS_ALWAYS_USE_DERP="${TS_ALWAYS_USE_DERP:-false}"
TS_SNAT_SUBNET_ROUTES="${TS_SNAT_SUBNET_ROUTES:-true}"
TS_STATEFUL_FILTERING="${TS_STATEFUL_FILTERING:-false}"
TS_TAGS="${TS_TAGS:-}"                                   # CSV, ex: tag:server,tag:woow
TS_EXIT_NODE="${TS_EXIT_NODE:-}"                         # tailnet IP or magicdns of exit-node peer
TS_USERSPACE_NETWORKING="${TS_USERSPACE_NETWORKING:-false}"  # true=userspace tun (no NET_ADMIN)
TS_UDP_PORT="${TS_UDP_PORT:-41641}"
TS_LOG_LEVEL="${TS_LOG_LEVEL:-info}"                     # trace|debug|info|notice|warning|error|fatal

# --- Web UI toggle -----------------------------------------------------------
# `tailscale web` is a WRITABLE admin UI with no authentication: whoever reaches it can
# change this node's settings and log it out. Off by default, and bound to loopback.
TS_WEB_UI="${TS_WEB_UI:-false}"
TS_WEB_LISTEN="${TS_WEB_LISTEN:-127.0.0.1:8088}"
TS_WEB_ALLOW_NONLOCAL="${TS_WEB_ALLOW_NONLOCAL:-false}"

# --- Extra passthrough (podman only) -----------------------------------------
TS_EXTRA_UP_ARGS="${TS_EXTRA_UP_ARGS:-}"                 # 任意額外 `tailscale up` 參數
TS_EXTRA_TAILSCALED_ARGS="${TS_EXTRA_TAILSCALED_ARGS:-}" # 任意額外 tailscaled 參數

# --- k8s mode only -----------------------------------------------------------
TS_AUTHKEY_FILE="${TS_AUTHKEY_FILE:-}"                   # file holding the authkey (Secret volume)
TS_SERVE="${TS_SERVE:-}"                                 # <tailnet port>=<service>:<port>,…
TS_SERVE_NAMESPACE="${TS_SERVE_NAMESPACE:-${POD_NAMESPACE:-}}"
TS_CLUSTER_DOMAIN="${TS_CLUSTER_DOMAIN:-cluster.local}"
TS_HOSTNAME_DEFAULT="${TS_HOSTNAME_DEFAULT:-woow-tailscale}"
TS_NO_LOGS_NO_SUPPORT="${TS_NO_LOGS_NO_SUPPORT:-true}"   # tailscaled --no-logs-no-support
TS_SERVE_SYNC_SECONDS="${TS_SERVE_SYNC_SECONDS:-15}"

# --- State dir / socket ------------------------------------------------------
STATE_DIR="${STATE_DIR:-/var/lib/tailscale}"
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
mkdir -p "$STATE_DIR"

if [[ "$WOOW_TS_MODE" == "k8s" ]]; then
  # Never let anything in this pod pick up containerboot's kube-Secret state store.
  unset TS_KUBE_SECRET
  # Forced settings. The podman knobs that would widen what this node does for the
  # tailnet are ignored, loudly, rather than honoured.
  forced=""
  [[ "$TS_ADVERTISE_EXIT_NODE" != "false" ]] && forced+=" TS_ADVERTISE_EXIT_NODE"
  [[ "$TS_ADVERTISE_CONNECTOR" != "false" ]] && forced+=" TS_ADVERTISE_CONNECTOR"
  [[ -n "$TS_ADVERTISE_ROUTES" ]] && forced+=" TS_ADVERTISE_ROUTES"
  [[ -n "$TS_EXIT_NODE" ]] && forced+=" TS_EXIT_NODE"
  [[ -n "$TS_EXTRA_UP_ARGS" ]] && forced+=" TS_EXTRA_UP_ARGS"
  [[ -n "$TS_EXTRA_TAILSCALED_ARGS" ]] && forced+=" TS_EXTRA_TAILSCALED_ARGS"
  [[ "$TS_WEB_ALLOW_NONLOCAL" != "false" ]] && forced+=" TS_WEB_ALLOW_NONLOCAL"
  [[ -n "$TS_AUTHKEY" ]] && forced+=" TS_AUTHKEY(use TS_AUTHKEY_FILE)"
  if [[ -n "$forced" ]]; then
    log "k8s mode: ignoring${forced} (exit node / app connector / subnet routes / passthrough are not offered)"
  fi
  TS_ADVERTISE_EXIT_NODE=false TS_ADVERTISE_CONNECTOR=false TS_ADVERTISE_ROUTES="" TS_EXIT_NODE=""
  TS_EXTRA_UP_ARGS="" TS_EXTRA_TAILSCALED_ARGS="" TS_WEB_ALLOW_NONLOCAL=false TS_AUTHKEY=""
  TS_USERSPACE_NETWORKING=true
  # userspace: tailscaled never touches the pod's DNS or routes; keep the prefs honest.
  TS_ACCEPT_DNS=false TS_ACCEPT_ROUTES=false

  LOGIN_OK=true
  if ! valid_login_server "$TS_LOGIN_SERVER"; then
    log "ERROR: login server '${TS_LOGIN_SERVER}' is not an http(s):// URL; leaving the node's login as it is (fix the setting)"
    LOGIN_OK=false
  fi
  TS_LOGIN_SERVER="${TS_LOGIN_SERVER%/}"
  # Hostname: the tenant's value when it is a DNS label, else the chart's per-release
  # default (never the pod name: two releases in one namespace must not collide).
  TS_HOSTNAME="$TS_HOSTNAME_DEFAULT"
  if [[ -n "$TS_HOSTNAME_RAW" ]]; then
    if h="$(valid_hostname "$TS_HOSTNAME_RAW")"; then
      TS_HOSTNAME="$h"
    else
      log "hostname: '${TS_HOSTNAME_RAW}' is not a DNS label (letters, digits, '-', <= 63); using ${TS_HOSTNAME_DEFAULT}"
    fi
  fi
  TS_TAGS="$(normalize_tags "$TS_TAGS")"
  SERVE_SPEC="$(parse_serve "$TS_SERVE" "$TS_SERVE_NAMESPACE" "$TS_CLUSTER_DOMAIN")"
fi

# ============================================================================
# 1. Start tailscaled
# ============================================================================
tailscaled_args=(
  --statedir="$STATE_DIR"
  --state="$STATE_DIR/tailscaled.state"
  --socket="$TS_SOCKET"
  --port="$TS_UDP_PORT"
)

if [[ "$TS_USERSPACE_NETWORKING" == "true" ]]; then
  tailscaled_args+=(--tun=userspace-networking)
  log "userspace networking enabled (no NET_ADMIN required, subnet-router/exit-node still work but slower)"
fi

# TS_LOG_LEVEL was parsed but never used. tailscaled's knob is --verbose.
case "$TS_LOG_LEVEL" in
  trace) tailscaled_args+=(--verbose=2) ;;
  debug) tailscaled_args+=(--verbose=1) ;;
esac

if [[ "$WOOW_TS_MODE" == "k8s" ]] && is_true "$TS_NO_LOGS_NO_SUPPORT"; then
  tailscaled_args+=(--no-logs-no-support)
fi

if [[ "$TS_ALWAYS_USE_DERP" == "true" ]]; then
  export TS_DEBUG_ALWAYS_USE_DERP=true
  log "TS_DEBUG_ALWAYS_USE_DERP=true — all traffic routed via DERP"
fi

# Passthrough for advanced users (podman only; emptied in k8s mode above)
if [[ -n "$TS_EXTRA_TAILSCALED_ARGS" ]]; then
  # shellcheck disable=SC2206
  extra=($TS_EXTRA_TAILSCALED_ARGS)
  tailscaled_args+=("${extra[@]}")
fi

mkdir -p "$(dirname "$TS_SOCKET")"
log "launching tailscaled with: ${tailscaled_args[*]}"
tailscaled "${tailscaled_args[@]}" &
TAILSCALED_PID=$!

ts() { tailscale --socket="$TS_SOCKET" "$@"; }

# Wait for socket ready
for _ in {1..60}; do
  [[ -S "$TS_SOCKET" ]] && break
  sleep 0.5
done
if ! [[ -S "$TS_SOCKET" ]]; then
  log "ERROR: tailscaled socket did not appear within 30s"
  kill "$TAILSCALED_PID" 2>/dev/null || true
  exit 1
fi

# On SIGTERM (pod stop) stop the background helpers and tailscaled, then exit with it.
helper_pids=()
# shellcheck disable=SC2329  # invoked by the trap below
on_term() {
  log "stopping"
  for p in "${helper_pids[@]}"; do kill "$p" 2>/dev/null || true; done
  kill -TERM "$TAILSCALED_PID" 2>/dev/null || true
}
trap on_term TERM INT

# ============================================================================
# 2. login_server migration (mirror HA reconcile-login-server logic)
# ============================================================================
STATE_LOGIN="$STATE_DIR/.last_login_server"
SWITCHED_CONTROL=false
if [[ "$WOOW_TS_MODE" == "podman" ]]; then
  # If TS_LOGIN_SERVER differs from the one this state directory was enrolled with, force a
  # logout so the node re-registers against the new control plane.
  if [[ -f "$STATE_LOGIN" ]]; then
    PREV_LOGIN="$(cat "$STATE_LOGIN")"
  else
    PREV_LOGIN=""
  fi
  if [[ -n "$PREV_LOGIN" && "$PREV_LOGIN" != "$TS_LOGIN_SERVER" ]]; then
    log "login_server changed ($PREV_LOGIN → ${TS_LOGIN_SERVER:-<official>}); logging out to re-register"
    ts logout || true
  fi
  echo -n "$TS_LOGIN_SERVER" > "$STATE_LOGIN"
elif [[ "$LOGIN_OK" == "true" ]]; then
  # k8s: compare with the control URL the state is actually enrolled with (the podman
  # marker cannot tell "official" from "never recorded", so official → Headscale never
  # logged out there). Only a node that has an identity is logged out. Right after start
  # the backend can still be NoState while it loads the state file — wait that out, or
  # a node that turns Running a moment later would refuse the new --login-server.
  backend=""
  for _ in {1..20}; do
    backend="$(ts status --json --peers=false 2>/dev/null | jq -r '.BackendState // ""' || true)"
    [[ -n "$backend" && "$backend" != "NoState" ]] && break
    sleep 0.5
  done
  cur_ctrl="$(ts debug prefs 2>/dev/null | jq -r '.ControlURL // ""' || true)"
  want="$(canon_control_url "$TS_LOGIN_SERVER")"
  have="$(canon_control_url "$cur_ctrl")"
  if [[ "$backend" != "NoState" && "$backend" != "NeedsLogin" && -n "$backend" && "$have" != "$want" ]]; then
    log "login_server changed (${have} → ${want}); logging out to re-register (new node identity and tailnet IP)"
    timeout 30 tailscale --socket="$TS_SOCKET" logout || log "WARN: logout did not complete cleanly; continuing"
    SWITCHED_CONTROL=true
  fi
  echo -n "$TS_LOGIN_SERVER" > "$STATE_LOGIN"
fi

# ============================================================================
# 3. tailscale up (idempotent — safe to call every boot)
# ============================================================================
if [[ "$WOOW_TS_MODE" == "podman" ]]; then
  up_args=(
    --hostname="$TS_HOSTNAME"
    --accept-dns="$TS_ACCEPT_DNS"
    --accept-routes="$TS_ACCEPT_ROUTES"
    --snat-subnet-routes="$TS_SNAT_SUBNET_ROUTES"
    --stateful-filtering="$TS_STATEFUL_FILTERING"
    --advertise-exit-node="$TS_ADVERTISE_EXIT_NODE"
    --advertise-connector="$TS_ADVERTISE_CONNECTOR"
  )

  [[ -n "$TS_LOGIN_SERVER" ]]     && up_args+=(--login-server="$TS_LOGIN_SERVER")
  [[ -n "$TS_AUTHKEY" ]]          && up_args+=(--authkey="$TS_AUTHKEY")
  [[ -n "$TS_ADVERTISE_ROUTES" ]] && up_args+=(--advertise-routes="$TS_ADVERTISE_ROUTES")
  [[ -n "$TS_EXIT_NODE" ]]        && up_args+=(--exit-node="$TS_EXIT_NODE")
  [[ -n "$TS_TAGS" ]]             && up_args+=(--advertise-tags="$TS_TAGS")

  if [[ -n "$TS_EXTRA_UP_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra=($TS_EXTRA_UP_ARGS)
    up_args+=("${extra[@]}")
  fi

  log "running: tailscale up ${up_args[*]//--authkey=*/--authkey=***}"
  if [[ -n "$TS_AUTHKEY" ]]; then
    # Non-interactive: authkey means `tailscale up` completes on its own.
    if ! ts up "${up_args[@]}"; then
      log "WARN: tailscale up failed with authkey. Check log above."
    fi
  else
    # Interactive: `tailscale up` (no --authkey) BLOCKS waiting for the operator
    # to click the login URL. Backgrounding it so `tailscale web` can still start
    # and stream logs (login URL) come through.
    log "no TS_AUTHKEY set → backgrounding tailscale up (interactive login via URL / web UI)"
    ts up "${up_args[@]}" &
  fi
elif [[ "$LOGIN_OK" == "true" ]]; then
  # --reset: every setting not listed goes back to its default, so nothing set earlier by
  # hand (or by an older image) survives a restart. The forced-off list is explicit too.
  up_args=(
    --reset
    --hostname="$TS_HOSTNAME"
    --accept-dns=false
    --accept-routes=false
    --advertise-exit-node=false
    --advertise-connector=false
    --advertise-routes=
    --exit-node=
    --ssh=false
    --shields-up=false
  )
  [[ -n "$TS_LOGIN_SERVER" ]] && up_args+=(--login-server="$TS_LOGIN_SERVER")
  [[ -n "$TS_TAGS" ]]         && up_args+=(--advertise-tags="$TS_TAGS")

  # Applied to a node that is already logged in: `tailscale set` edits prefs in place,
  # without restarting the control client. Every flag here is an explicit "off".
  set_args=(
    --hostname="$TS_HOSTNAME"
    --accept-dns=false
    --accept-routes=false
    --advertise-exit-node=false
    --advertise-connector=false
    --advertise-routes=
    --exit-node=
    --ssh=false
    --webclient=false
    --shields-up=false
    --relay-server-port=
  )

  # Why a logged-in node gets `set`, not `up --reset`: `up` restarts the control client,
  # and tailscale forces its next control dial onto HTTPS :443 when the previous one was
  # less than 2 minutes ago (controlhttp forceNoise443). A same-workspace Headscale is
  # http://<service>:8080 with no :443, so a needless `up` right after boot left the node
  # logged out for 1-2 minutes in dev-sandbox. `tailscale set` edits prefs in place and
  # also reaches prefs `up` cannot (peer relay, web client); it runs on every boot.
  # `up --reset` is for nodes that need a login, or whose advertised tags changed.
  k8s_up() {
    local backend key_ok=false prefs drift
    if [[ "$SWITCHED_CONTROL" == "true" ]]; then
      log "waiting 125s before contacting the new control server (a control dial within 2 minutes of the previous one is forced onto HTTPS :443)"
      sleep 125
    fi
    log "forcing settings in place: tailscale set ${set_args[*]}"
    ts set "${set_args[@]}" || log "WARN: tailscale set failed (see above)"
    backend="$(ts status --json --peers=false 2>/dev/null | jq -r '.BackendState // ""' || true)"
    case "$backend" in
      Running | Starting | NeedsMachineAuth)
        prefs="$(ts debug prefs 2>/dev/null || echo '{}')"
        drift="$(jq -r --arg tags "$TS_TAGS" '[
            (if ((.AdvertiseRoutes // []) | length) > 0 then "routes" else empty end),
            (if (.AppConnector.Advertise // false) then "app-connector" else empty end),
            (if (.RunSSH // false) then "ssh" else empty end),
            (if (.RunWebClient // false) then "webclient" else empty end),
            (if ((.ExitNodeID // "") != "" or (.ExitNodeIP // "") != "") then "exit-node" else empty end),
            (if .RelayServerPort != null then "peer-relay" else empty end),
            (if ((.AdvertiseTags // []) | sort | join(",")) != ($tags | split(",") | map(select(. != "")) | sort | join(",")) then "tags" else empty end)
          ] | join(",")' <<< "$prefs" 2>/dev/null || echo "unreadable-prefs")"
        if [[ -z "$drift" ]]; then
          [[ -n "$TS_AUTHKEY_FILE" && -s "$TS_AUTHKEY_FILE" ]] && log "an authkey is set but the node is already logged in (${backend}); not using it"
          log "node is logged in (${backend}); settings applied without reconnecting"
          return 0
        fi
        log "node settings still differ from the wanted ones (${drift}) → tailscale up --reset (reconnects; changed tags may need a new login)"
        ;;
    esac
    if [[ -n "$TS_AUTHKEY_FILE" && -s "$TS_AUTHKEY_FILE" ]] && grep -q '[^[:space:]]' "$TS_AUTHKEY_FILE"; then
      key_ok=true
    fi
    if [[ "$key_ok" == "true" && ( "$backend" == "NeedsLogin" || "$backend" == "NoState" ) ]]; then
      log "node needs a login and an authkey is set → tailscale up --auth-key=file:… ${up_args[*]}"
      if ts up "${up_args[@]}" --auth-key="file:${TS_AUTHKEY_FILE}" --timeout=180s; then
        log "logged in with the authkey (it is not used again; clear it from the settings)"
        return 0
      fi
      log "WARN: login with the authkey failed (expired, already used or for another control server?); falling back to interactive login via the web UI"
    elif [[ "$key_ok" == "true" ]]; then
      log "an authkey is set but the node is not waiting for a login (${backend}); not using it"
    fi
    log "running: tailscale up ${up_args[*]}"
    # Logged in already → returns once Running. Needs a login → prints the login URL and
    # waits for it (in the background: the web UI and readiness do not depend on it).
    ts up "${up_args[@]}" || log "WARN: tailscale up exited with $? (see above)"
  }
  k8s_up &
  helper_pids+=("$!")
fi

# ============================================================================
# 3b. Serve forwards (k8s mode): keep the node's serve config == SERVE_SPEC
# ============================================================================
if [[ "$WOOW_TS_MODE" == "k8s" ]]; then
  desired_serve="$(awk 'NF==2 {print $1 "=" $2}' <<< "${SERVE_SPEC:-}" | sort | paste -sd, -)"
  if [[ -n "$desired_serve" ]]; then
    log "serve: forwards wanted: ${desired_serve}"
  fi
  serve_sync() {
    local last_err=""
    while :; do
      local backend cur extra out err
      backend="$(ts status --json --peers=false 2>/dev/null | jq -r '.BackendState // ""' || true)"
      if [[ "$backend" == "Running" ]]; then
        out="$(ts serve status --json 2>/dev/null || echo '{}')"
        cur="$(jq -r '[(.TCP // {}) | to_entries[] | "\(.key)=\(.value.TCPForward // "")"] | sort | join(",")' <<< "$out" 2>/dev/null || echo "?")"
        extra="$(jq -r 'del(.TCP) | keys | length' <<< "$out" 2>/dev/null || echo 1)"
        if [[ "$cur" != "$desired_serve" || "$extra" != "0" ]]; then
          err=""
          ts serve reset </dev/null >/dev/null 2>&1 || err="reset failed"
          while read -r lport target; do
            [[ -z "$lport" ]] && continue
            if ! ts serve --bg --tcp="$lport" "tcp://${target}" </dev/null >/dev/null 2>&1; then
              err="${err:+$err; }${lport}=${target} failed"
            fi
          done <<< "${SERVE_SPEC:-}"
          if [[ -z "$err" ]]; then
            log "serve: applied [${desired_serve:-none}]"
            last_err=""
          elif [[ "$err" != "$last_err" ]]; then
            log "serve: WARN ${err}; retrying"
            last_err="$err"
          fi
        fi
      fi
      sleep "$TS_SERVE_SYNC_SECONDS"
    done
  }
  serve_sync &
  helper_pids+=("$!")
fi

# ============================================================================
# 4. Optional web UI
# ============================================================================
if [[ "$TS_WEB_UI" == "true" ]]; then
  if [[ "$WOOW_TS_MODE" == "k8s" ]]; then
    if valid_k8s_web_listen "$TS_WEB_LISTEN"; then
      # Read-only mode: the same login flow (Log in → login URL, re-authenticate), but it
      # does not switch on tailscaled's management web client, which would listen on the
      # node's tailnet IP (:5252). The tenant reaches this one only through the chart's
      # password-protected proxy.
      web_loop() {
        sleep 1
        while :; do
          log "starting tailscale web (read-only) on $TS_WEB_LISTEN"
          ts web --listen "$TS_WEB_LISTEN" --readonly || true
          log "tailscale web exited; restarting in 5s"
          sleep 5
        done
      }
      web_loop &
      helper_pids+=("$!")
    else
      log "ERROR: TS_WEB_LISTEN=$TS_WEB_LISTEN must be 127.x.y.z:port and not 127.0.0.1 in k8s mode (tailnet traffic reaches 127.0.0.1); web UI not started"
    fi
  else
    case "$TS_WEB_LISTEN" in
      127.0.0.1:* | localhost:* | "[::1]:"*) ;;
      *)
        if [[ "$TS_WEB_ALLOW_NONLOCAL" != "true" ]]; then
          log "ERROR: TS_WEB_LISTEN=$TS_WEB_LISTEN is not a loopback address."
          log "The tailscale web UI is writable and has no authentication; anyone who reaches"
          log "it can log this node out. Bind it to 127.0.0.1:8088 and reach it through a tailnet"
          log "serve forward or ssh -L, or set TS_WEB_ALLOW_NONLOCAL=true if you really mean it."
          exit 1
        fi
        log "WARNING: TS_WEB_LISTEN=$TS_WEB_LISTEN exposes an unauthenticated admin UI (TS_WEB_ALLOW_NONLOCAL=true)"
        ;;
    esac
    # Small delay so tailscaled's localapi is definitely ready before `tailscale web` connects.
    sleep 1
    log "starting tailscale web on $TS_WEB_LISTEN"
    ts web --listen "$TS_WEB_LISTEN" --readonly=false &
  fi
fi

# ============================================================================
# 5. Wait on tailscaled (PID 1 via tini)
# ============================================================================
set +e
wait "$TAILSCALED_PID"
rc=$?
# A signal interrupts the first wait; collect tailscaled's real exit status.
if kill -0 "$TAILSCALED_PID" 2>/dev/null; then
  wait "$TAILSCALED_PID"
  rc=$?
fi
for p in "${helper_pids[@]}"; do kill "$p" 2>/dev/null || true; done
log "tailscaled exited ($rc)"
exit "$rc"
