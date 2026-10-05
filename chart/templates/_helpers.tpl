{{/* tailscale helpers. Deployed per-tenant by paas-operator as svc-{ref[:8]} into paas-ws-*. */}}
{{- define "tailscale.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "tailscale.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- define "tailscale.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "tailscale.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tailscale.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "tailscale.labels" -}}
helm.sh/chart: {{ include "tailscale.chart" . }}
{{ include "tailscale.selectorLabels" . }}
app.kubernetes.io/component: vpn-node
app.kubernetes.io/part-of: tailscale
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}
{{- define "tailscale.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "tailscale.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
{{- define "tailscale.headlessServiceName" -}}
{{- printf "%s-headless" (include "tailscale.fullname" .) -}}
{{- end -}}
{{- define "tailscale.secretName" -}}
{{- printf "%s-secret" (include "tailscale.fullname" .) -}}
{{- end -}}
{{- define "tailscale.entranceConfigMapName" -}}
{{- printf "%s-entrance" (include "tailscale.fullname" .) -}}
{{- end -}}
{{- define "tailscale.pvcName" -}}
{{- default (printf "%s-state" (include "tailscale.fullname" .)) .Values.persistence.existingClaim -}}
{{- end -}}

{{/* Main image: tag (may already carry @sha256) + optional separate digest. */}}
{{- define "tailscale.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- if and .Values.image.digest (not (contains "@" $tag)) -}}
{{- printf "%s:%s@%s" .Values.image.repository $tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/* imagePullSecrets: top-level list (operator) ∪ global.imagePullSecrets (strings or dicts). */}}
{{- define "tailscale.imagePullSecrets" -}}
{{- $names := list -}}
{{- range (concat (.Values.imagePullSecrets | default list) (.Values.global.imagePullSecrets | default list)) -}}
{{- $n := "" -}}
{{- if kindIs "map" . -}}{{- $n = .name | default "" -}}{{- else -}}{{- $n = toString . -}}{{- end -}}
{{- if and $n (not (has $n $names)) -}}{{- $names = append $names $n -}}{{- end -}}
{{- end -}}
{{- range $names }}
- name: {{ . | quote }}
{{- end -}}
{{- end -}}

{{/*
Default tailnet hostname: woow-<release> (a DNS label; unique per release, so two
nodes in one workspace never collide). The tenant's tailscale.hostname wins when
the entrypoint finds it valid.
*/}}
{{- define "tailscale.defaultHostname" -}}
{{- $h := printf "woow-%s" .Release.Name | lower -}}
{{- regexReplaceAll "[^a-z0-9-]" $h "-" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
explicit value wins; else the live Secret's value (stable across upgrades); else
generate once.
*/}}
{{- define "tailscale.adminPassword" -}}
{{- $val := .Values.config.sensitive.admin_password | default "" | toString -}}
{{- if not $val -}}
  {{- $live := lookup "v1" "Secret" .Release.Namespace (include "tailscale.secretName" .) -}}
  {{- if $live -}}
    {{- with $live.data -}}
      {{- with .admin_password -}}
        {{- $val = . | b64dec -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not $val -}}
  {{- $val = randAlphaNum 24 -}}
{{- end -}}
{{- $val -}}
{{- end -}}

{{/*
Basic-auth username of the entrance (entrance.basicAuthUsername; the platform's
admin_username_helm_path). Same rule as charts/headscale and the platform's
TENANT_ADMIN_USERNAME_RE. An invalid value never fails the render (EMQX 0.1.1
lesson): it falls back to admin, and tailscale.entranceNotice tells the entrance
to log why.
*/}}
{{- define "tailscale.basicAuthUsername" -}}
{{- $u := .Values.entrance.basicAuthUsername | default "admin" | toString -}}
{{- if regexMatch "^[A-Za-z0-9._@-]{1,64}$" $u -}}{{ $u }}{{- else -}}admin{{- end -}}
{{- end -}}

{{/*
One line the entrance container prints to its log at start ("" = nothing to
say). Never echoes the rejected value (it may carry control characters).
*/}}
{{- define "tailscale.entranceNotice" -}}
{{- $u := .Values.entrance.basicAuthUsername | default "admin" | toString -}}
{{- if not (regexMatch "^[A-Za-z0-9._@-]{1,64}$" $u) -}}
entrance.basicAuthUsername is not a valid username (1-64 characters: letters, digits and . _ @ -); basic auth uses "admin" instead
{{- end -}}
{{- end -}}

{{/* The tenant's authkey (tailscale.authKey — the tenant lane), CR/LF stripped. */}}
{{- define "tailscale.authKey" -}}
{{- .Values.tailscale.authKey | default "" | toString | replace "\r" "" | replace "\n" "" | trim -}}
{{- end -}}

{{/*
Resources of the tailscale container: the platform's plan overlay (TOP-LEVEL
`resources`, #332) deep-merged over tailscale.resources.
*/}}
{{- define "tailscale.mainResources" -}}
{{- $base := deepCopy .Values.tailscale.resources -}}
{{- toYaml (mergeOverwrite $base (deepCopy (.Values.resources | default dict))) -}}
{{- end -}}

{{/* State volume size: the plan's persistence.size, else defaultSize. */}}
{{- define "tailscale.stateSize" -}}
{{- .Values.persistence.size | default .Values.persistence.defaultSize -}}
{{- end -}}
