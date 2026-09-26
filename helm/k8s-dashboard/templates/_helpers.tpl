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
