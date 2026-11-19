{{- define "silo.labels" -}}
app.kubernetes.io/name: silo
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "silo.selector" -}}
app.kubernetes.io/name: silo
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
