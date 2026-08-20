# templates/_helpers.tpl
{{- define "pihole.name" -}}
pihole
{{- end }}

{{- define "pihole.fullname" -}}
{{ include "pihole.name" . }}
{{- end }}