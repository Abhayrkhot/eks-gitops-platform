terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition
}

resource "aws_iam_role" "cluster" {
  name                 = "${var.name}-cluster"
  path                 = var.iam_path
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Created ahead of the cluster so retention is ours, not "never expire".
resource "aws_cloudwatch_log_group" "cluster" {
  count = length(var.enabled_log_types) > 0 ? 1 : 0

  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# EKS envelope-encrypts all Kubernetes API data (Secrets included) with an
# AWS-owned key by default; a customer KMS key is optional.
#trivy:ignore:AVD-AWS-0039
resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = var.enabled_log_types

  # Core networking add-ons come from the managed add-ons below instead of the
  # unmanaged copies EKS would otherwise install.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  # Never slide into extended support (6x the control-plane price).
  dynamic "upgrade_policy" {
    for_each = var.support_type == null ? [] : [var.support_type]
    content {
      support_type = upgrade_policy.value
    }
  }

  dynamic "encryption_config" {
    for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]
    content {
      resources = ["secrets"]
      provider {
        key_arn = encryption_config.value
      }
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# Networking add-ons that must exist before nodes can go Ready.
module "core_addons" {
  source = "../eks-addons"

  cluster_name = aws_eks_cluster.this.name
  addons       = var.before_compute_addons
  tags         = var.tags
}

resource "aws_eks_access_entry" "admin" {
  for_each = var.enable_access_entries ? toset(var.admin_principal_arns) : toset([])

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
