terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }

  # Partial config: bucket/region come from backend-<env>.hcl, written by
  # `make backend-config`; the key is <env>/infra.tfstate. Locking uses an
  # S3 lock object (use_lockfile), so concurrent applies fail fast.
  backend "s3" {}
}

locals {
  emulated = var.aws_endpoint != null
  # S3 Control prefixes the account id to the host; *.localhost resolves locally.
  s3control_endpoint = local.emulated ? replace(var.aws_endpoint, "127.0.0.1", "localhost") : null

  tags = merge({
    Project     = "eks-gitops-platform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "platform-team"
    Stack       = "infra"
  }, var.protect_resources ? { Protection = "protected" } : {})
}

provider "aws" {
  region = var.region

  access_key                  = local.emulated ? "test" : null
  secret_key                  = local.emulated ? "test" : null
  skip_credentials_validation = local.emulated
  skip_metadata_api_check     = local.emulated
  s3_use_path_style           = local.emulated
  insecure                    = local.emulated

  endpoints {
    ec2         = var.aws_endpoint
    eks         = var.aws_endpoint
    iam         = var.aws_endpoint
    logs        = var.aws_endpoint
    s3          = var.aws_endpoint
    s3control   = local.s3control_endpoint
    sts         = var.aws_endpoint
    autoscaling = var.aws_endpoint
  }

  default_tags {
    tags = local.tags
  }
}

module "platform" {
  source = "../../modules/platform"

  name                     = var.name
  environment              = var.environment
  vpc_cidr                 = var.vpc_cidr
  azs                      = var.azs
  nat_gateway              = var.nat_gateway
  kubernetes_version       = var.kubernetes_version
  cluster_support_type     = var.cluster_support_type
  endpoint_public_access   = var.endpoint_public_access
  public_access_cidrs      = var.public_access_cidrs
  cluster_log_types        = var.cluster_log_types
  admin_principal_arns     = var.admin_principal_arns
  enable_access_entries    = var.enable_access_entries
  before_compute_addons    = var.before_compute_addons
  after_compute_addons     = var.after_compute_addons
  node_groups              = var.node_groups
  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = {}
}
