output "cluster_name" {
  value = module.platform.cluster_name
}

output "cluster_endpoint" {
  value = module.platform.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.platform.cluster_certificate_authority_data
}

output "kubernetes_version" {
  value = module.platform.kubernetes_version
}

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.platform.vpc_id
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.platform.cluster_name}"
}
