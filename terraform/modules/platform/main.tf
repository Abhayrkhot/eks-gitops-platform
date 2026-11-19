terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

# One environment = one VPC + one EKS cluster + its node groups + add-ons.
# Every environment (local emulator, dev, staging) instantiates this module
# with different inputs; nothing environment-specific lives in here.

locals {
  cluster_name = "${var.name}-${var.environment}"
}

module "vpc" {
  source = "../vpc"

  name         = local.cluster_name
  cidr         = var.vpc_cidr
  azs          = var.azs
  nat_gateway  = var.nat_gateway
  cluster_name = local.cluster_name
  tags         = var.tags
}

module "cluster" {
  source = "../eks-cluster"

  name                     = local.cluster_name
  kubernetes_version       = var.kubernetes_version
  support_type             = var.cluster_support_type
  subnet_ids               = module.vpc.private_subnet_ids
  endpoint_public_access   = var.endpoint_public_access
  public_access_cidrs      = var.public_access_cidrs
  enabled_log_types        = var.cluster_log_types
  admin_principal_arns     = var.admin_principal_arns
  enable_access_entries    = var.enable_access_entries
  before_compute_addons    = var.before_compute_addons
  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = var.tags
}

module "node_groups" {
  source   = "../eks-node-group"
  for_each = var.node_groups

  cluster_name             = module.cluster.name
  name                     = each.key
  subnet_ids               = module.vpc.private_subnet_ids
  instance_types           = each.value.instance_types
  capacity_type            = each.value.capacity_type
  desired_size             = each.value.desired_size
  min_size                 = each.value.min_size
  max_size                 = each.value.max_size
  disk_size_gib            = each.value.disk_size_gib
  labels                   = each.value.labels
  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = var.tags

  # The VPC CNI must be running before nodes can report Ready.
  depends_on = [module.cluster]
}

# Add-ons that schedule pods (CoreDNS, metrics-server) need nodes first.
module "workload_addons" {
  source = "../eks-addons"

  cluster_name = module.cluster.name
  addons       = var.after_compute_addons
  tags         = var.tags

  depends_on = [module.node_groups]
}
