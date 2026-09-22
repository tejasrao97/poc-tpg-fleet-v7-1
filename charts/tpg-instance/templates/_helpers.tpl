{{- define "tpg.required" -}}
{{- if not .Values.instance.name }}{{ fail "instance.name is required" }}{{ end -}}
{{- if not .Values.instance.postgresVersion }}{{ fail "instance.postgresVersion is required" }}{{ end -}}
{{- if not .Values.backup.container }}{{ fail "backup.container is required" }}{{ end -}}
{{- end -}}
