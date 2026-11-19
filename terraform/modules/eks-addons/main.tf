terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

# Managed EKS add-ons. A null version lets EKS pick the default for the
# cluster's Kubernetes version, which keeps upgrades a one-line change.
resource "aws_eks_addon" "this" {
  for_each = var.addons

  cluster_name                = var.cluster_name
  addon_name                  = each.key
  addon_version               = each.value.version
  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  timeouts {
    create = "15m"
    update = "15m"
  }
}
