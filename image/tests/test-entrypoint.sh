#!/usr/bin/env bash
# Unit tests for the k8s-mode validators in tailscale/entrypoint.sh (sourced with
# WOOW_TS_SOURCE_ONLY=1, so nothing is started). Runs on the host (`bash
# tailscale/tests/test-entrypoint.sh`) and inside the built image (the build workflow pipes
# it into `bash -s` with ENTRYPOINT_SH=/entrypoint.sh).
set -euo pipefail
ENTRYPOINT_SH="${ENTRYPOINT_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/entrypoint.sh}"
# shellcheck source=/dev/null  # the entrypoint (path decided at run time)
WOOW_TS_SOURCE_ONLY=1 source "$ENTRYPOINT_SH"
set +e

fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
expect_ok() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
expect_no() { if "${@:2}" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# ── login server ─────────────────────────────────────────────────────────────
expect_ok "login: empty = official" valid_login_server ""
expect_ok "login: https host" valid_login_server "https://hs.example.com"
expect_ok "login: in-cluster http with port" valid_login_server "http://svc-1a2b3c4d-headscale:8080"
expect_ok "login: path" valid_login_server "https://example.com/headscale/"
expect_no "login: ftp scheme" valid_login_server "ftp://example.com"
expect_no "login: userinfo" valid_login_server "https://user:pw@example.com"
expect_no "login: whitespace" valid_login_server "https://example.com/ x"
expect_no "login: query" valid_login_server "https://example.com/?a=b"
# shellcheck disable=SC2016  # literal on purpose
expect_no "login: shell metachar" valid_login_server 'https://example.com/$(id)'
expect_no "login: port 0" valid_login_server "http://example.com:0"
expect_no "login: port too big" valid_login_server "http://example.com:70000"
expect_no "login: no host" valid_login_server "https://"
expect_eq "canon: empty" "$(canon_control_url "")" "https://controlplane.tailscale.com"
expect_eq "canon: login synonym" "$(canon_control_url "https://login.tailscale.com/")" "https://controlplane.tailscale.com"
expect_eq "canon: trailing slash" "$(canon_control_url "http://hs:8080/")" "http://hs:8080"

# ── hostname ─────────────────────────────────────────────────────────────────
expect_eq "hostname: lower-cased" "$(valid_hostname "My-Node1")" "my-node1"
expect_no "hostname: underscore" valid_hostname "my_node"
expect_no "hostname: leading dash" valid_hostname "-node"
expect_no "hostname: dot" valid_hostname "a.b"
expect_no "hostname: 64 chars" valid_hostname "$(printf 'a%.0s' {1..64})"
expect_ok "hostname: 63 chars" valid_hostname "$(printf 'a%.0s' {1..63})"
expect_no "hostname: empty" valid_hostname ""

# ── tags ─────────────────────────────────────────────────────────────────────
expect_eq "tags: valid kept, invalid dropped, dedup" \
  "$(normalize_tags " tag:woow-paas, bad ,tag:9x,tag:woow-paas,tag:ok;rm" 2>/dev/null)" "tag:woow-paas"
expect_eq "tags: two" "$(normalize_tags "tag:a,tag:b-2" 2>/dev/null)" "tag:a,tag:b-2"
expect_eq "tags: empty" "$(normalize_tags "" 2>/dev/null)" ""

# ── serve list ───────────────────────────────────────────────────────────────
NS=paas-ws-1a2b3c4d
D=cluster.local
serve() { parse_serve "$1" "$NS" "$D" 2>/dev/null; }
expect_eq "serve: short name → FQDN" "$(serve "8069=svc-1a2b3c4d-woow-odoo:8069")" \
  "8069 svc-1a2b3c4d-woow-odoo.$NS.svc.$D:8069"
expect_eq "serve: own-namespace FQDN forms" \
  "$(serve "1=a.$NS:1,2=b.$NS.svc:2,3=c.$NS.svc.$D:3,4=D.$NS.SVC.CLUSTER.LOCAL.:4" | paste -sd'|' -)" \
  "1 a.$NS.svc.$D:1|2 b.$NS.svc.$D:2|3 c.$NS.svc.$D:3|4 d.$NS.svc.$D:4"
expect_eq "serve: spaces tolerated" "$(serve " 8123 = ha : 8123 ")" "8123 ha.$NS.svc.$D:8123"
expect_eq "serve: IPv4 rejected" "$(serve "9000=10.43.0.1:443")" ""
expect_eq "serve: IP with ns-looking tail rejected" "$(serve "9000=1.2.3.4:80")" ""
expect_eq "serve: other namespace rejected" "$(serve "9000=svc-x.paas-ws-other:80")" ""
expect_eq "serve: other namespace FQDN rejected" "$(serve "9000=svc-x.kube-system.svc.$D:443")" ""
expect_eq "serve: outside domain rejected" "$(serve "9000=example.com:443")" ""
expect_eq "serve: other cluster domain rejected" "$(serve "9000=a.$NS.svc.evil.com:443")" ""
expect_eq "serve: unix socket rejected" "$(serve "9000=unix:/var/run/tailscale/tailscaled.sock")" ""
expect_eq "serve: scheme rejected" "$(serve "9000=tcp://a:80")" ""
expect_eq "serve: localhost rejected" "$(serve "9000=localhost:8080")" ""
expect_eq "serve: IPv6 rejected" "$(serve "9000=[::1]:80")" ""
expect_eq "serve: port 0 rejected" "$(serve "0=a:80,9000=a:0")" ""
expect_eq "serve: port 65536 rejected" "$(serve "65536=a:80")" ""
expect_eq "serve: leading zero rejected" "$(serve "080=a:80")" ""
# shellcheck disable=SC2016  # literal on purpose
expect_eq "serve: shell metachar rejected" "$(serve '9000=$(id):80,9001=a;b:80,9002=a`x`:1')" ""
expect_eq "serve: name must start with a letter" "$(serve "9000=1abc:80")" ""
expect_eq "serve: duplicate tailnet port keeps the first" "$(serve "80=a:80,80=b:81")" "80 a.$NS.svc.$D:80"
expect_eq "serve: valid entries survive invalid neighbours" \
  "$(serve "x,8069=odoo:8069,9=10.0.0.1:1,8123=ha:8123" | paste -sd'|' -)" \
  "8069 odoo.$NS.svc.$D:8069|8123 ha.$NS.svc.$D:8123"
many="$(for i in $(seq 1 40); do printf '%s=s%s:80,' "$((1000 + i))" "$i"; done)"
expect_eq "serve: capped at 32 forwards" "$(serve "$many" | wc -l | tr -d ' ')" "32"
expect_eq "serve: no namespace → nothing" "$(parse_serve "80=a:80" "" "$D" 2>/dev/null)" ""
expect_eq "serve: empty list" "$(serve "")" ""
if parse_serve "9000=10.43.0.1:443" "$NS" "$D" 2>&1 >/dev/null | grep -q "skipping '9000=10.43.0.1:443'"; then
  ok "serve: a skipped entry is logged"
else
  bad "serve: a skipped entry is logged"
fi

# ── web listen (k8s) ─────────────────────────────────────────────────────────
expect_ok "web: 127.0.0.2" valid_k8s_web_listen "127.0.0.2:8088"
expect_ok "web: 127.1.2.3" valid_k8s_web_listen "127.1.2.3:8088"
expect_no "web: 127.0.0.1 (netstack delivers tailnet traffic there)" valid_k8s_web_listen "127.0.0.1:8088"
expect_no "web: localhost" valid_k8s_web_listen "localhost:8088"
expect_no "web: all interfaces" valid_k8s_web_listen "0.0.0.0:8088"
expect_no "web: pod IP" valid_k8s_web_listen "10.42.1.5:8088"
expect_no "web: bad octet" valid_k8s_web_listen "127.0.0.256:8088"

if (( fails > 0 )); then
  echo "test-entrypoint: ${fails} failure(s)"
  exit 1
fi
echo "test-entrypoint: all passed"
