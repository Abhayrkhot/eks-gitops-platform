output "argocd_namespace" {
  value = module.gitops.argocd_namespace
}

output "cluster_name" {
  value = local.infra.cluster_name
}
