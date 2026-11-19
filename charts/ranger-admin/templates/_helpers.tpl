{{- define "ranger.selector" -}}
app.kubernetes.io/name: ranger-admin
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
