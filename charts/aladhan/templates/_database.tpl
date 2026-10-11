{{/* The Postgres service's in-cluster name, resolvable from a hostNetwork pod. */}}
{{- define "aladhan.databaseHost" -}}
qibla-db.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{/* What the app and every job need to reach the database. The password comes
from the Secret only — never from values, never from git. */}}
{{- define "aladhan.databaseEnv" -}}
- name: DB_HOST
  value: {{ include "aladhan.databaseHost" . | quote }}
- name: DB_PORT
  value: "5432"
- name: DB_NAME
  value: {{ .Values.database.name | quote }}
- name: DB_USER
  value: {{ .Values.database.user | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ required "database.secretName is required" .Values.database.secretName }}
      key: DB_PASSWORD
{{- end -}}
