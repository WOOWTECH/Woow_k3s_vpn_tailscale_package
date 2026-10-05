#!/usr/bin/env bash
# tailscale render contract: release-prefixed names (many services share one tenant
# namespace); exactly one non-headless ClusterIP Service whose first port (8080) is
# the nginx entrance; a single-replica StatefulSet on a chart-owned PVC; non-root,
# drop ALL, read-only root, no token, no host networking / NET_ADMIN / tun device;
# requests+limits on every container; the plan overlay reaches the tailscale
# container and the PVC; egress = DNS + same namespace + public minus private and
# CGNAT; a username / password change never changes the pod template (Secret-volume
# htpasswd; the username is entrance.basicAuthUsername, invalid → admin + a log line);
# the StatefulSet — the only workload — opts in to the operator's restart on
# credential reset (paas.woowtech.io/restart-on-credential-reset);
# the tenant's authkey lives outside config.sensitive, is always rendered and
# restarts the pod when it changes; tenant text only ever travels as env; exit node /
# connector / subnet-route / passthrough knobs do not exist; bad tenant values never
# fail the render (the entrypoint validates at run time).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (render-contract): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (render-contract): $1"; exit 1; }
NS=paas-ws-sentinel
OUT="$($HELM template svc-aaaa1111 "$CHART_DIR" -n "$NS")"
STS="$(printf '%s' "$OUT" | yq 'select(.kind=="StatefulSet")')"
TS="$(printf '%s' "$STS" | yq '.spec.template.spec.containers[] | select(.name=="tailscale")')"
EN="$(printf '%s' "$STS" | yq '.spec.template.spec.containers[] | select(.name=="entrance")')"
env_of() { printf '%s' "$TS" | yq ".env[] | select(.name==\"$1\") | .value"; }
sts_of() { $HELM template svc-aaaa1111 "$CHART_DIR" -n "$NS" "$@" | yq 'select(.kind=="StatefulSet")'; }

# ── names, objects ───────────────────────────────────────────────────────────
[ "$(printf '%s' "$STS" | yq '.metadata.name')" = "svc-aaaa1111-tailscale" ] || fail "StatefulSet must carry the release-prefixed fullname"
KINDS="$(printf '%s' "$OUT" | yq -N '.kind' | sort | uniq -c | tr -s ' ' | paste -sd, -)"
[ "$KINDS" = " 1 ConfigMap, 2 NetworkPolicy, 1 PersistentVolumeClaim, 1 Secret, 2 Service, 1 ServiceAccount, 1 StatefulSet" ] || fail "unexpected object set: $KINDS"
printf '%s' "$OUT" | yq -N '.metadata.namespace // ""' | grep -q . && fail "no object may hard-code a namespace"
printf '%s' "$OUT" | grep -q 'nodePort' && fail "NodePort must never be rendered"
printf '%s' "$OUT" | grep -q 'helm.sh/resource-policy' && fail "no resource-policy keep (the platform owns PVC retention)"
OTHER="$($HELM template svc-bbbb2222 "$CHART_DIR" -n "$NS")"
A="$(printf '%s' "$OUT" | yq -N '.kind + "/" + .metadata.name' | sort)"
B="$(printf '%s' "$OTHER" | yq -N '.kind + "/" + .metadata.name' | sort)"
[ -z "$(comm -12 <(echo "$A") <(echo "$B"))" ] || fail "two releases in one namespace must not share any object name"
[ "$(printf '%s' "$OTHER" | yq 'select(.kind=="StatefulSet") | .spec.template.spec.containers[0].env[] | select(.name=="TS_HOSTNAME_DEFAULT") | .value')" = "woow-svc-bbbb2222" ] || fail "default tailnet hostname must be derived from the release"
[ "$(env_of TS_HOSTNAME_DEFAULT)" = "woow-svc-aaaa1111" ] || fail "default tailnet hostname must be woow-<release>"
for sel in app.kubernetes.io/name app.kubernetes.io/instance; do
  [ -n "$(printf '%s' "$STS" | yq ".spec.selector.matchLabels[\"$sel\"]")" ] || fail "selector must carry $sel"
done
[ "$(printf '%s' "$STS" | yq '.metadata.labels["app.kubernetes.io/component"]')" = "vpn-node" ] || fail "component label"

# ── entrance Service ─────────────────────────────────────────────────────────
ENTRANCE="$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service" and .spec.clusterIP != "None")')"
[ "$(printf '%s' "$ENTRANCE" | yq -N '.metadata.name' | wc -l | tr -d ' ')" = "1" ] || fail "exactly one non-headless Service"
[ "$(printf '%s' "$ENTRANCE" | yq '.metadata.name')" = "svc-aaaa1111-tailscale" ] || fail "entrance Service must be the un-suffixed fullname"
[ "$(printf '%s' "$ENTRANCE" | yq '.spec.type')" = "ClusterIP" ] || fail "entrance Service must be ClusterIP"
[ "$(printf '%s' "$ENTRANCE" | yq '.spec.ports | length')" = "1" ] || fail "entrance Service publishes ONLY the entrance port"
[ "$(printf '%s' "$ENTRANCE" | yq '.spec.ports[0].port')" = "8080" ] || fail "the first (platform-routed) port must be 8080"
[ "$(printf '%s' "$ENTRANCE" | yq '.spec.ports[0].targetPort')" = "http" ] || fail "the first port must target the nginx entrance"
[ "$(printf '%s' "$EN" | yq '.ports[0].name + ":" + (.ports[0].containerPort|tostring)')" = "http:8080" ] || fail "nginx owns containerPort http/8080"
[ "$(printf '%s' "$TS" | yq '.ports // [] | length')" = "0" ] || fail "the tailscale container publishes no port"
HL="$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service" and .spec.clusterIP=="None")')"
[ "$(printf '%s' "$HL" | yq '.metadata.name')" = "$(printf '%s' "$STS" | yq '.spec.serviceName')" ] || fail "the headless Service governs the StatefulSet"

# ── workload shape ───────────────────────────────────────────────────────────
[ "$(printf '%s' "$STS" | yq '.spec.replicas')" = "1" ] || fail "exactly one replica (one state = one identity)"
[ "$(sts_of --set replicaCount=3 | yq '.spec.replicas')" = "1" ] || fail "replicaCount must not scale the node"
printf '%s' "$STS" | yq '.spec.volumeClaimTemplates' | grep -qv null && fail "use a chart-owned PVC, not volumeClaimTemplates (platform retention)"
[ "$(printf '%s' "$STS" | yq '.spec.template.spec.volumes[] | select(.name=="state") | .persistentVolumeClaim.claimName')" = "svc-aaaa1111-tailscale-state" ] || fail "state volume = chart PVC"
[ "$(printf '%s' "$TS" | yq '.volumeMounts[] | select(.name=="state") | .mountPath')" = "/var/lib/tailscale" ] || fail "state mounted at /var/lib/tailscale"
[ "$(env_of STATE_DIR)" = "/var/lib/tailscale/state" ] || fail "STATE_DIR must be a subdirectory of the PVC (tailscaled chmods it; the volume root is root-owned)"
[ "$(printf '%s' "$STS" | yq '.spec.template.spec.volumes[] | select(.name=="run") | has("emptyDir")')" = "true" ] || fail "socket dir is an emptyDir"
[ "$(printf '%s' "$STS" | yq '.spec.template.spec.enableServiceLinks')" = "false" ] || fail "enableServiceLinks must be false"
[ "$(printf '%s' "$STS" | yq '.spec.template.spec.containers | length')" = "2" ] || fail "two containers: tailscale + entrance"
printf '%s' "$STS" | yq '.spec.template.spec.initContainers' | grep -qv null && fail "no init containers expected"
printf '%s' "$TS" | yq '.command // [] | length' | grep -qx 0 || fail "the tailscale container must run the image ENTRYPOINT (no command override)"
printf '%s' "$TS" | yq '.args // [] | length' | grep -qx 0 || fail "the tailscale container takes no args"

# ── hardening ────────────────────────────────────────────────────────────────
PSC="$(printf '%s' "$STS" | yq '.spec.template.spec.securityContext')"
[ "$(printf '%s' "$PSC" | yq '.runAsNonRoot')" = "true" ] || fail "runAsNonRoot"
[ "$(printf '%s' "$PSC" | yq '.runAsUser')" = "1000" ] || fail "runAsUser 1000"
[ "$(printf '%s' "$PSC" | yq '.seccompProfile.type')" = "RuntimeDefault" ] || fail "seccomp RuntimeDefault"
[ "$(printf '%s' "$STS" | yq '.spec.template.spec.automountServiceAccountToken')" = "false" ] || fail "no SA token"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="ServiceAccount") | .automountServiceAccountToken')" = "false" ] || fail "SA automount false"
for c in tailscale entrance; do
  SC="$(printf '%s' "$STS" | yq ".spec.template.spec.containers[] | select(.name==\"$c\") | .securityContext")"
  [ "$(printf '%s' "$SC" | yq '.allowPrivilegeEscalation')" = "false" ] || fail "$c: allowPrivilegeEscalation false"
  [ "$(printf '%s' "$SC" | yq '.capabilities.drop | join(",")')" = "ALL" ] || fail "$c: drop ALL"
  [ "$(printf '%s' "$SC" | yq '.capabilities.add // [] | length')" = "0" ] || fail "$c: no added capabilities"
  [ "$(printf '%s' "$SC" | yq '.readOnlyRootFilesystem')" = "true" ] || fail "$c: read-only root filesystem"
  for k in cpu memory; do
    for t in requests limits; do
      [ "$(printf '%s' "$STS" | yq ".spec.template.spec.containers[] | select(.name==\"$c\") | .resources.$t.$k")" != "null" ] || fail "$c: resources.$t.$k missing (workspace ResourceQuota)"
    done
  done
done
POD="$(printf '%s' "$STS" | yq '.spec.template.spec')"
for k in hostNetwork hostPID hostIPC; do
  [ "$(printf '%s' "$POD" | yq ".$k // false")" = "false" ] || fail "no $k"
done
[ "$(printf '%s' "$POD" | yq '[.volumes[] | select(has("hostPath"))] | length')" = "0" ] || fail "no hostPath volume (no /dev/net/tun)"
[ "$(printf '%s' "$POD" | yq '[.containers[] | select(.securityContext.privileged == true)] | length')" = "0" ] || fail "no privileged container"
[ "$(printf '%s' "$POD" | yq '[.containers[].ports[]? | select(has("hostPort"))] | length')" = "0" ] || fail "no hostPort"
printf '%s' "$OUT" | grep -qE 'NET_ADMIN|NET_RAW|/dev/net/tun' && fail "no NET_ADMIN / NET_RAW / tun device"
[ "$(printf '%s' "$STS" | yq '.spec.template.spec.nodeSelector["kubernetes.io/arch"]')" = "amd64" ] || fail "nodeSelector amd64"

# ── image & pull secrets ─────────────────────────────────────────────────────
APPV="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CHART_DIR/Chart.yaml")"
[ "$(printf '%s' "$TS" | yq '.image')" = "jcr-prod.woowtech.io/woow-paas-docker-local/tailscale:$APPV" ] || fail "default image must follow appVersion"
PIN="20261004.0300@sha256:$(printf 'a%.0s' {1..64})"
[ "$(sts_of --set-string image.tag="$PIN" | yq '.spec.template.spec.containers[0].image')" = "jcr-prod.woowtech.io/woow-paas-docker-local/tailscale:$PIN" ] || fail "platform tag@sha256 pin must be used verbatim"
[ "$(sts_of --set-string image.tag=20261004.0300 --set-string image.digest="sha256:$(printf 'b%.0s' {1..64})" | yq '.spec.template.spec.containers[0].image')" = "jcr-prod.woowtech.io/woow-paas-docker-local/tailscale:20261004.0300@sha256:$(printf 'b%.0s' {1..64})" ] || fail "image.digest must be appended to a bare tag"
printf '%s' "$EN" | yq '.image' | grep -q '@sha256:' || fail "the entrance image must be digest-pinned"
[ "$(printf '%s' "$STS" | yq '.spec.template.spec.imagePullSecrets[0].name')" = "paas-registry" ] || fail "paas-registry pull secret by default"
[ "$(sts_of --set 'global.imagePullSecrets[0]=extra' | yq '.spec.template.spec.imagePullSecrets | map(.name) | join(",")')" = "paas-registry,extra" ] || fail "global.imagePullSecrets must be merged"

# ── plan overlay (platform writes TOP-LEVEL resources / persistence.size) ────
OV="$($HELM template t "$CHART_DIR" --set resources.requests.cpu=1 --set resources.limits.cpu=1 --set resources.requests.memory=512Mi --set resources.limits.memory=512Mi --set persistence.size=3Gi)"
[ "$(printf '%s' "$OV" | yq 'select(.kind=="StatefulSet") | .spec.template.spec.containers[] | select(.name=="tailscale") | .resources.requests.cpu + "/" + .resources.limits.memory')" = "1/512Mi" ] || fail "plan overlay (top-level resources) must reach the tailscale container"
[ "$(printf '%s' "$OV" | yq 'select(.kind=="PersistentVolumeClaim") | .spec.resources.requests.storage')" = "3Gi" ] || fail "plan persistence.size must size the state PVC"
[ "$(printf '%s' "$OUT" | yq 'select(.kind=="PersistentVolumeClaim") | .spec.resources.requests.storage')" = "1Gi" ] || fail "state PVC defaults to 1Gi"
[ "$($HELM template t "$CHART_DIR" --set persistence.storageClass=longhorn-delete | yq 'select(.kind=="PersistentVolumeClaim") | .spec.storageClassName')" = "longhorn-delete" ] || fail "flat persistence.storageClass must reach the PVC"

# ── NetworkPolicy ────────────────────────────────────────────────────────────
DENY="$(printf '%s' "$OUT" | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="svc-aaaa1111-tailscale-default-deny")')"
[ "$(printf '%s' "$DENY" | yq '.spec.policyTypes | join(",")')" = "Ingress,Egress" ] || fail "default-deny covers Ingress and Egress"
ALLOW="$(printf '%s' "$OUT" | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="svc-aaaa1111-tailscale-allow")')"
[ "$(printf '%s' "$ALLOW" | yq '.spec.ingress | length')" = "0" ] || fail "no chart ingress rule (platform baseline governs ingress)"
[ "$(printf '%s' "$ALLOW" | yq '.spec.egress | length')" = "3" ] || fail "egress = DNS + same namespace + public"
[ "$(printf '%s' "$ALLOW" | yq '.spec.egress[0].to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] + ":" + (.spec.egress[0].ports | map(.protocol + "/" + (.port|tostring)) | join(","))')" = "kube-system:UDP/53,TCP/53" ] || fail "DNS rule"
[ "$(printf '%s' "$ALLOW" | yq '.spec.egress[1].to[0].podSelector | length')" = "0" ] || fail "same-namespace rule (podSelector {})"
[ "$(printf '%s' "$ALLOW" | yq '.spec.egress[1].to | length')" = "1" ] || fail "same-namespace rule must not carry a namespaceSelector"
[ "$(printf '%s' "$ALLOW" | yq '.spec.egress[2].to[0].ipBlock.cidr')" = "0.0.0.0/0" ] || fail "public rule"
[ "$(printf '%s' "$ALLOW" | yq '.spec.egress[2].to[0].ipBlock.except | join(",")')" = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10" ] || fail "public egress must exclude private, link-local and CGNAT (100.64/10)"
[ "$(printf '%s' "$ALLOW" | yq '.spec.egress[2].ports // [] | length')" = "0" ] || fail "public egress is any port / protocol (WireGuard + STUN are UDP on varying ports)"
printf '%s' "$ALLOW" | yq '.spec.egress[]' | grep -qx '{}' && fail "no allow-all egress rule"
$HELM template t "$CHART_DIR" --set networkPolicy.allowAllEgress=true | yq -N 'select(.kind=="NetworkPolicy") | .spec.egress[]' | grep -qx '{}' && fail "there is no allow-all switch"

# ── credentials ──────────────────────────────────────────────────────────────
SEC="$(printf '%s' "$OUT" | yq -N 'select(.kind=="Secret")')"
AUTHVOL="$(printf '%s' "$STS" | yq '.spec.template.spec.volumes[] | select(.name=="entrance-auth")')"
GEN="$(printf '%s' "$SEC" | yq '.stringData.admin_password')"
[ ${#GEN} -ge 20 ] || fail "generated admin_password too short"
[ "$(printf '%s' "$SEC" | yq '.stringData.htpasswd')" = "admin:{PLAIN}$GEN" ] || fail "htpasswd must be admin:{PLAIN}<admin_password>"
PINPW="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=pinnedByPlatform1 | yq -N 'select(.kind=="Secret") | .stringData.htpasswd')"
[ "$PINPW" = "admin:{PLAIN}pinnedByPlatform1" ] || fail "platform-pinned admin_password must reach the htpasswd"
CRLF="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=$'a\r\nevil:{PLAIN}x' | yq -N 'select(.kind=="Secret") | .stringData.htpasswd')"
[ "$(printf '%s\n' "$CRLF" | wc -l | tr -d ' ')" = "1" ] || fail "CR/LF in the password must not inject a second htpasswd line"
# username (entrance.basicAuthUsername = the platform's admin_username_helm_path)
[ "$(printf '%s' "$SEC" | yq '.stringData.admin_username')" = "admin" ] || fail "default basic-auth username must be admin"
USR="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=pw1 --set-string entrance.basicAuthUsername=ops.team@x-1_ | yq -N 'select(.kind=="Secret") | .stringData')"
[ "$(printf '%s' "$USR" | yq '.htpasswd')" = "ops.team@x-1_:{PLAIN}pw1" ] || fail "entrance.basicAuthUsername must reach the htpasswd"
[ "$(printf '%s' "$USR" | yq '.admin_username')" = "ops.team@x-1_" ] || fail "the Secret records the username in effect"
[ "$(printf '%s' "$USR" | yq '.entrance_notice')" = "" ] || fail "a valid username leaves no entrance notice"
[ "$(printf '%s' "$SEC" | yq '.stringData | has("entrance_notice")')" = "true" ] || fail "entrance_notice must always be rendered (empty clears a stale notice)"
for bad in 'bad user:x' 'a:b' $'x\nevil:{PLAIN}y' "$(printf 'u%.0s' {1..65})"; do
  BADU="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=pw1 --set-string entrance.basicAuthUsername="$bad" 2>&1)" || fail "an invalid username must never fail the render (got: $bad)"
  BS="$(printf '%s' "$BADU" | yq -N 'select(.kind=="Secret") | .stringData')"
  [ "$(printf '%s' "$BS" | yq '.htpasswd')" = "admin:{PLAIN}pw1" ] || fail "an invalid username must fall back to admin (never split / add an htpasswd line)"
  [ "$(printf '%s' "$BS" | yq '.admin_username')" = "admin" ] || fail "admin_username must record the fallback"
  printf '%s' "$BS" | yq '.entrance_notice' | grep -q 'basicAuthUsername is not a valid username' || fail "an invalid username must leave an entrance notice (logged at start)"
  case "$bad" in *$'\n'*) ;; *) printf '%s' "$BS" | yq '.entrance_notice' | grep -qF -- "$bad" && fail "the notice must never echo the rejected value" ;; esac
done
# the entrance prints the notice at start, then runs the image's own entrypoint
[ "$(printf '%s' "$EN" | yq '.command | join(" ")')" = "/bin/sh -c" ] || fail "entrance: /bin/sh -c wrapper"
printf '%s' "$EN" | yq '.args[0]' | grep -qx "exec /docker-entrypoint.sh nginx -g 'daemon off;'" || fail "entrance must exec the image entrypoint + CMD"
printf '%s' "$EN" | yq '.args[0]' | grep -q 'cat /etc/nginx/auth/notice' || fail "entrance must read the notice from the Secret volume"
printf '%s' "$BADU" | yq 'select(.kind=="StatefulSet")' | grep -q 'not a valid username' && fail "the notice travels in the Secret, never in the pod spec"
[ "$(printf '%s' "$AUTHVOL" | yq '.secret.items[1].key + ">" + .secret.items[1].path')" = "entrance_notice>notice" ] || fail "the notice comes from the Secret volume"
# helm_secret reset = `helm upgrade --reset-values --atomic --timeout 15s` FIRST (a
# changed pod template would make helm wait for a new pod → time out → roll back),
# THEN the operator's rollout restart. Username and password must stay out of it.
T1="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=firstPassword1 | yq 'select(.kind=="StatefulSet") | .spec.template')"
T2="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=secondPassword2 | yq 'select(.kind=="StatefulSet") | .spec.template')"
[ "$T1" = "$T2" ] || fail "a password change must not change the pod template (operator reset = helm upgrade --atomic --timeout 15s)"
T3="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=thirdPassword3 --set-string entrance.basicAuthUsername=someone.else | yq 'select(.kind=="StatefulSet") | .spec.template')"
[ "$T1" = "$T3" ] || fail "a username change must not change the pod template either"
T4="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=firstPassword1 --set-string 'entrance.basicAuthUsername=bad user' | yq 'select(.kind=="StatefulSet") | .spec.template')"
[ "$T1" = "$T4" ] || fail "an invalid username (notice) must not change the pod template"
# opt-in restart on credential reset (operator #1398): the chart has no Deployment
RST='paas.woowtech.io/restart-on-credential-reset'
[ "$(printf '%s' "$STS" | yq ".metadata.labels[\"$RST\"]")" = "true" ] || fail "the StatefulSet must carry $RST=\"true\" (no Deployment here: without it the operator's reset finds nothing to restart and rolls back)"
[ "$(printf '%s' "$STS" | yq ".metadata.labels[\"$RST\"] | type")" = "!!str" ] || fail "$RST must be the STRING \"true\""
[ "$(printf '%s' "$OUT" | yq -N "select(.metadata.labels[\"$RST\"] != null) | .kind + \"/\" + .metadata.name")" = "StatefulSet/svc-aaaa1111-tailscale" ] || fail "only the tailscale StatefulSet may opt in"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="StatefulSet" or .kind=="Deployment") | .kind' | sort | uniq -c | tr -s ' ')" = " 1 StatefulSet" ] || fail "exactly one workload (one StatefulSet, no Deployment)"
[ "$(printf '%s' "$STS" | yq ".spec.template.metadata.labels[\"$RST\"] // \"\"")" = "" ] || fail "$RST belongs on the StatefulSet, not the pod template"
[ "$(printf '%s' "$STS" | yq ".spec.selector.matchLabels[\"$RST\"] // \"\"")" = "" ] || fail "$RST must not join the (immutable) selector"
[ "$(printf '%s' "$AUTHVOL" | yq '.secret.items[0].key + ">" + .secret.items[0].path')" = "htpasswd>.htpasswd" ] || fail "htpasswd comes from the Secret volume"
[ "$(printf '%s' "$EN" | yq '.volumeMounts[] | select(.name=="entrance-auth") | has("subPath")')" = "false" ] || fail "htpasswd must be a directory mount (subPath never refreshes)"

# ── authkey (tenant lane) ────────────────────────────────────────────────────
[ "$(printf '%s' "$SEC" | yq '.stringData | has("authkey")')" = "true" ] || fail "authkey must always be rendered (empty clears a stale data key)"
[ "$(printf '%s' "$SEC" | yq '.stringData.authkey')" = "" ] || fail "unset authkey renders empty"
AK="$($HELM template t "$CHART_DIR" --set-string tailscale.authKey=$'tskey-auth-k123\n')"
[ "$(printf '%s' "$AK" | yq -N 'select(.kind=="Secret") | .stringData.authkey')" = "tskey-auth-k123" ] || fail "tailscale.authKey (tenant lane) must reach the Secret, trimmed"
printf '%s' "$AK" | yq 'select(.kind=="StatefulSet")' | grep -q 'tskey-auth-k123' && fail "the authkey must never appear in the pod spec"
[ "$($HELM template t "$CHART_DIR" --set-string config.sensitive.authKey=x | yq -N 'select(.kind=="Secret") | .stringData.authkey')" = "" ] || fail "config.sensitive is the platform's lane — the authkey must not be read from it"
K1="$(printf '%s' "$AK" | yq 'select(.kind=="StatefulSet") | .spec.template.metadata.annotations["checksum/authkey"]')"
K0="$(printf '%s' "$STS" | yq '.spec.template.metadata.annotations["checksum/authkey"]')"
[ "$K1" != "$K0" ] || fail "an authkey change must restart the pod (checksum/authkey)"
[ "$(printf '%s' "$TS" | yq '.env[] | select(.name=="TS_AUTHKEY_FILE") | .value')" = "/etc/woow-tailscale/authkey/authkey" ] || fail "authkey reaches the entrypoint as a file"
printf '%s' "$TS" | yq '.env[] | .name' | grep -qx TS_AUTHKEY && fail "never pass the authkey as plain env"
[ "$(printf '%s' "$STS" | yq '.spec.template.spec.volumes[] | select(.name=="authkey") | .secret.optional')" = "true" ] || fail "authkey volume optional"

# ── forced-off features & k8s mode ───────────────────────────────────────────
[ "$(env_of WOOW_TS_MODE)" = "k8s" ] || fail "entrypoint must run in k8s mode"
[ "$(env_of TS_WEB_LISTEN)" = "127.0.0.2:8088" ] || fail "tailscale web on 127.0.0.2 (netstack delivers tailnet traffic to 127.0.0.1)"
[ "$(env_of TS_NO_LOGS_NO_SUPPORT)" = "true" ] || fail "--no-logs-no-support by default"
[ "$(sts_of --set tailscale.noLogs=false | yq '.spec.template.spec.containers[0].env[] | select(.name=="TS_NO_LOGS_NO_SUPPORT") | .value')" = "false" ] || fail "noLogs=false must reach the entrypoint"
FORCE="$(sts_of --set tailscale.advertiseExitNode=true --set tailscale.advertiseConnector=true --set-string tailscale.advertiseRoutes=10.43.0.0/16 --set-string tailscale.exitNode=100.64.0.9 --set-string tailscale.extraUpArgs=--ssh --set 'tailscale.extraEnv[0].name=TS_ADVERTISE_EXIT_NODE' --set 'tailscale.extraEnv[0].value=true')"
[ "$FORCE" = "$(sts_of)" ] || fail "exit node / connector / routes / passthrough values must have no effect at all"
printf '%s' "$TS" | yq '.env[] | .name' | grep -qE '^TS_(ADVERTISE_EXIT_NODE|ADVERTISE_CONNECTOR|ADVERTISE_ROUTES|EXIT_NODE|EXTRA_UP_ARGS|EXTRA_TAILSCALED_ARGS|WEB_ALLOW_NONLOCAL|KUBE_SECRET|SOCKS5_SERVER|OUTBOUND_HTTP_PROXY_LISTEN)$' && fail "forbidden knob rendered into env"

# ── tenant text: env only, never a render failure ────────────────────────────
NASTY='8069=odoo:8069,9000=$(id):1;`reboot`,x"y'
# A values file, like the platform sends (helm --set would choke on the commas itself).
VF="$(mktemp)"; trap 'rm -f "$VF"' EXIT
cat > "$VF" <<'VALUES'
tailscale:
  serve: '8069=odoo:8069,9000=$(id):1;`reboot`,x"y'
  hostname: 'Bad Host!'
  loginServer: 'not a url'
  tags: 'tag:ok,bad tag'
VALUES
BAD="$($HELM template t "$CHART_DIR" -f "$VF" 2>&1)" || fail "invalid tenant values must still render (the entrypoint skips them at run time)"
BTS="$(printf '%s' "$BAD" | yq 'select(.kind=="StatefulSet") | .spec.template.spec.containers[] | select(.name=="tailscale")')"
[ "$(printf '%s' "$BTS" | yq '.env[] | select(.name=="TS_SERVE") | .value')" = "$NASTY" ] || fail "the serve list must travel verbatim as env"
[ "$(printf '%s' "$BTS" | yq '.env[] | select(.name=="TS_LOGIN_SERVER") | .value')" = "not a url" ] || fail "login server travels as env"
[ "$(printf '%s' "$BTS" | yq '.env[] | select(.name=="TS_HOSTNAME") | .value')" = "Bad Host!" ] || fail "hostname travels as env"
printf '%s' "$BAD" | yq 'select(.kind=="ConfigMap")' | grep -q 'reboot' && fail "tenant text must never reach a ConfigMap / script"
[ "$(printf '%s' "$BAD" | yq 'select(.kind=="ConfigMap") | .data["nginx.conf"]')" = "$(printf '%s' "$OUT" | yq 'select(.kind=="ConfigMap") | .data["nginx.conf"]')" ] || fail "tenant values must not change the nginx config"

# ── probes ───────────────────────────────────────────────────────────────────
for p in startupProbe readinessProbe; do
  [ "$(printf '%s' "$TS" | yq ".$p.exec.command | join(\" \")")" = "tailscale --socket=/var/run/tailscale/tailscaled.sock status --json --peers=false" ] || fail "tailscale $p must be 'status --json' (ready while NeedsLogin)"
done
# liveness: same socket check + the out-of-sync watchdog for plain-http control servers
LIVE="$(printf '%s' "$TS" | yq '.livenessProbe.exec.command')"
[ "$(printf '%s' "$LIVE" | yq '.[0] + " " + .[1]')" = "/bin/sh -c" ] || fail "tailscale liveness is a /bin/sh -c script"
LS="$(printf '%s' "$LIVE" | yq '.[2]')"
printf '%s' "$LS" | grep -qF 's="$(tailscale --socket=/var/run/tailscale/tailscaled.sock status --json --peers=false)" || exit 1' || fail "liveness must still fail when tailscaled does not answer"
printf '%s' "$LS" | grep -qF '[Hh][Tt][Tt][Pp]://*)' || fail "the out-of-sync restart applies to plain-http control servers only"
printf '%s' "$LS" | grep -qF '*"Unable to connect to the Tailscale coordination server"*)' || fail "liveness must react to tailscaled's out-of-sync health warning"
printf '%s' "$LS" | grep -q '\$TS_LOGIN_SERVER' || fail "the watchdog reads the login server from the env"
[ "$(printf '%s' "$TS" | yq '.livenessProbe.failureThreshold')" = "5" ] || fail "liveness failureThreshold"
[ "$(printf '%s' "$BTS" | yq '.livenessProbe')" = "$(printf '%s' "$TS" | yq '.livenessProbe')" ] || fail "tenant values must never reach the liveness script"
[ "$(printf '%s' "$EN" | yq '.livenessProbe.httpGet.path')" = "/healthz" ] || fail "entrance liveness is nginx-local"

# ── nginx entrance ───────────────────────────────────────────────────────────
CONF="$(printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and (.metadata.name|test("-entrance$"))) | .data["nginx.conf"]')"
printf '%s' "$CONF" | grep -q 'listen 8080;' || fail "nginx listens on 8080"
printf '%s' "$CONF" | grep -q 'worker_processes 1;' || fail "nginx worker_processes pinned"
printf '%s' "$CONF" | grep -q 'proxy_pass http://127.0.0.2:8088;' || fail "nginx proxies to tailscale web on 127.0.0.2:8088"
printf '%s' "$CONF" | grep -q 'auth_basic_user_file /etc/nginx/auth/.htpasswd;' || fail "basic auth from the Secret volume"
printf '%s' "$CONF" | grep -q 'deny 127.0.0.0/8;' || fail "loopback peers (= tailnet traffic via netstack) must be refused"
printf '%s' "$CONF" | grep -q 'proxy_set_header Authorization "";' || fail "basic-auth credentials must not be forwarded"
printf '%s' "$CONF" | grep -q 'proxy_set_header Host $http_host;' || fail "Host must be kept for the web client's CSRF check"
printf '%s' "$CONF" | awk '/location \/ \{/,/}/' | grep -q 'auth_basic ' || fail "/ must be behind basic auth"
E1="$(printf '%s' "$STS" | yq '.spec.template.metadata.annotations["checksum/entrance"]')"
[ -n "$E1" ] && [ "$E1" != "null" ] || fail "entrance config change must roll the pod"

# ── packaging ────────────────────────────────────────────────────────────────
grep -qx 'tests/' "$CHART_DIR/.helmignore" || fail ".helmignore must exclude tests/"

echo "PASS (render-contract): names, entrance, StatefulSet+PVC, hardening, image pin, plan overlay, NetworkPolicy, credentials (username + password, byte-identical template, reset opt-in label), authkey lane, forced-off knobs, env-only tenant text, probes, nginx."
