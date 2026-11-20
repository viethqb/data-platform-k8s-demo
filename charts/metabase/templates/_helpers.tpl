{{- define "metabase.selector" -}}
app.kubernetes.io/name: metabase
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
