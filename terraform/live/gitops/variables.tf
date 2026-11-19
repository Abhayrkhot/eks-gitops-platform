variable "environment" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "aws_endpoint" {
  type    = string
  default = null
}

variable "state_bucket" {
  description = "Bucket holding the infra stack's state."
  type        = string
}

variable "kubeconfig_path" {
  description = "Local runs only: kubeconfig for the kind cluster that stands in for EKS."
  type        = string
  default     = null
}

variable "kube_context" {
  type    = string
  default = null
}

variable "argocd_chart_version" {
  type    = string
  default = "10.18.1"
}

variable "repo_url" {
  type    = string
  default = "https://github.com/Abhayrkhot/eks-gitops-platform.git"
}

variable "target_revision" {
  type    = string
  default = "main"
}

variable "apps" {
  type    = any
  default = {}
}

variable "argocd_values" {
  description = "argo-cd chart values merged over gitops/argocd/values*.yaml (used to A/B self-heal settings)."
  type        = any
  default     = {}
}
