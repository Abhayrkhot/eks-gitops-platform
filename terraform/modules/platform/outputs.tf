output "cluster_name" {
  value = module.cluster.name
}

output "cluster_endpoint" {
  value = module.cluster.endpoint
}

output "cluster_certificate_authority_data" {
  value = module.cluster.certificate_authority_data
}

output "kubernetes_version" {
  value = module.cluster.kubernetes_version
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "node_role_arns" {
  value = { for k, ng in module.node_groups : k => ng.node_role_arn }
}
