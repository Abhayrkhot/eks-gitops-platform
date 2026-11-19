terraform {
  required_version = ">= 1.10"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }

  # Key <env>/gitops.tfstate; same bucket as the infra stack.
  backend "s3" {}
}

locals {
  emulated = var.aws_endpoint != null
  use_eks  = var.kubeconfig_path == null
  infra    = data.terraform_remote_state.infra.outputs
}

# Layered stacks: the GitOps layer reads the cluster it targets from the infra
# stack's remote state instead of re-declaring it.
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket       = var.state_bucket
    key          = "${var.environment}/infra.tfstate"
    region       = var.region
    use_lockfile = true

    access_key                  = local.emulated ? "test" : null
    secret_key                  = local.emulated ? "test" : null
    skip_credentials_validation = local.emulated
    skip_requesting_account_id  = local.emulated
    skip_metadata_api_check     = local.emulated
    use_path_style              = local.emulated
    insecure                    = local.emulated
    endpoints                   = local.emulated ? { s3 = var.aws_endpoint, sts = var.aws_endpoint } : null
  }
}

# Real EKS: short-lived token from `aws eks get-token`. Local runs: a kind
# kubeconfig stands in for the emulated cluster, which has no real API server.
provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context

    host                   = local.use_eks ? local.infra.cluster_endpoint : null
    cluster_ca_certificate = local.use_eks ? base64decode(local.infra.cluster_certificate_authority_data) : null
    exec = local.use_eks ? {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.infra.cluster_name, "--region", var.region, "--output", "json"]
    } : null
  }
}

module "gitops" {
  source = "../../modules/gitops-bootstrap"

  environment          = var.environment
  cluster_name         = local.infra.cluster_name
  argocd_chart_version = var.argocd_chart_version
  argocd_values_files = compact([
    "${path.root}/../../../gitops/argocd/values.yaml",
    fileexists("${path.root}/../../../gitops/argocd/values-${var.environment}.yaml") ? "${path.root}/../../../gitops/argocd/values-${var.environment}.yaml" : "",
  ])
  repo_url        = var.repo_url
  target_revision = var.target_revision
  apps            = var.apps
}
