{{/*
---------------------------------------------------------------------------
Author: Labiyb M. Said — DevSecOps Engineer
Contact: saidlabiybm@gmail.com
---------------------------------------------------------------------------
*/}}

{{- define "k8s-collector.labels" -}}
app.kubernetes.io/name: k8s-audit-collector
app.kubernetes.io/part-of: audit-collector
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Name of the Secret holding the Postgres connection string (key "url") —
either the one this chart creates, or an existing one the caller points at.
*/}}
{{- define "k8s-collector.dbSecretName" -}}
{{- if .Values.db.existingSecretName -}}
{{ .Values.db.existingSecretName }}
{{- else -}}
audit-collector-db
{{- end -}}
{{- end -}}
