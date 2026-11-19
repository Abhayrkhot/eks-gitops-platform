{{- define "storefront.labels" -}}
app.kubernetes.io/name: storefront
app.kubernetes.io/part-of: eks-gitops-platform
app.kubernetes.io/managed-by: argocd
{{- end -}}

{{- define "storefront.selector" -}}
app.kubernetes.io/name: storefront
{{- end -}}

{{- define "storefront.podSecurity" -}}
runAsNonRoot: true
runAsUser: 100
runAsGroup: 101
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "storefront.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}
