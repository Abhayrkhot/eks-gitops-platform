terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }
  # The bootstrap stack creates the state bucket, so it keeps its own state
  # locally (gitignored) — the one chicken-and-egg exception.
}

locals {
  emulated = var.aws_endpoint != null
  # S3 Control prefixes the account id to the host; *.localhost resolves locally.
  s3control_endpoint = local.emulated ? replace(var.aws_endpoint, "127.0.0.1", "localhost") : null
  tags = {
    Project    = "eks-gitops-platform"
    ManagedBy  = "terraform"
    Stack      = "bootstrap"
    Repository = var.github_repository
  }
}

provider "aws" {
  region = var.region

  # Emulator mode (moto) for local end-to-end tests; all null on real AWS.
  access_key                  = local.emulated ? "test" : null
  secret_key                  = local.emulated ? "test" : null
  skip_credentials_validation = local.emulated
  skip_requesting_account_id  = false
  skip_metadata_api_check     = local.emulated
  s3_use_path_style           = local.emulated
  insecure                    = local.emulated

  endpoints {
    s3        = var.aws_endpoint
    s3control = local.s3control_endpoint
    iam       = var.aws_endpoint
    sts       = var.aws_endpoint
  }

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = coalesce(var.state_bucket_name, "eks-gitops-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}")
}

module "state" {
  source = "../modules/state-backend"

  bucket_name   = local.bucket_name
  force_destroy = var.force_destroy_state
  enforce_tls   = !local.emulated
}

module "ci_iam" {
  source = "../modules/ci-iam"

  github_repository            = var.github_repository
  create_oidc_provider         = var.create_oidc_provider
  state_bucket_arn             = module.state.bucket_arn
  allowed_regions              = [var.region]
  extra_trusted_principal_arns = var.extra_trusted_principal_arns
}
