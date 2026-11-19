{{/* Sync policy shared by every child Application. */}}
{{- define "root.syncPolicy" -}}
automated:
  prune: {{ .Values.syncPolicy.automated.prune }}
  selfHeal: {{ .Values.syncPolicy.automated.selfHeal }}
retry:
{{ toYaml .Values.syncPolicy.retry | indent 2 }}
{{- end -}}

{{- define "root.labels" -}}
app.kubernetes.io/part-of: eks-gitops-platform
platform.gitops/environment: {{ .Values.environment }}
{{- end -}}
