{{/*
---------------------------------------------------------------------------
Author: Labiyb M. Said — DevSecOps Engineer
Contact: saidlabiybm@gmail.com
---------------------------------------------------------------------------
*/}}

{{/*
Common labels applied to every resource in this chart.
*/}}
{{- define "k8s-dashboard.labels" -}}
app.kubernetes.io/name: k8s-dashboard
app.kubernetes.io/part-of: k8s-dashboard
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Loki's in-cluster DNS name, used both by the dashboard's LOKI_URL env var and
by Promtail's client config. Derived from .Release.Namespace so the chart
still works when installed into a namespace other than "k8s-dashboard".
*/}}
{{- define "k8s-dashboard.lokiURL" -}}
http://loki.{{ .Release.Namespace }}.svc.cluster.local:3100
{{- end -}}

{{/*
Name of the Secret holding DASHBOARD_SECRET, ADMIN_USER/PASS, SMTP_PASSWORD,
etc — either the one this chart creates, or an existing one the caller points at.
*/}}
{{- define "k8s-dashboard.secretName" -}}
{{- if .Values.secret.existingSecretName -}}
{{ .Values.secret.existingSecretName }}
{{- else -}}
dashboard-secrets
{{- end -}}
{{- end -}}

{{/*
Generates a stable random secret value: if the value is set explicitly in
values, use it; otherwise reuse whatever's already in the live Secret (so
"helm upgrade" never rotates it and silently invalidates every session /
audit-webhook caller); otherwise generate a fresh random one for a first
install. `lookup` returns empty during `helm template`/`--dry-run=client`
(no cluster context), which is fine - that path is preview-only anyway.
Usage: {{ include "k8s-dashboard.stableSecret" (dict "root" . "value" .Values.secret.dashboardSecret "key" "DASHBOARD_SECRET" "length" 32) }}
*/}}
{{- define "k8s-dashboard.stableSecret" -}}
{{- $root := .root -}}
{{- if .value -}}
{{- .value -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" $root.Release.Namespace (include "k8s-dashboard.secretName" $root) -}}
{{- if and $existing $existing.data (index $existing.data .key) -}}
{{- index $existing.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum (.length | int) -}}
{{- end -}}
{{- end -}}
{{- end -}}
