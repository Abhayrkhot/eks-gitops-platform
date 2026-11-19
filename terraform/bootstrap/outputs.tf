output "state_bucket" {
  value = module.state.bucket
}

output "plan_role_arn" {
  value = module.ci_iam.plan_role_arn
}

output "apply_role_arn" {
  value = module.ci_iam.apply_role_arn
}

output "permissions_boundary_arn" {
  value = module.ci_iam.permissions_boundary_arn
}

output "region" {
  value = var.region
}
