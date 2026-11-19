variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_endpoint" {
  description = "AWS API emulator endpoint (e.g. http://127.0.0.1:15566). Null on real AWS."
  type        = string
  default     = null
}

variable "github_repository" {
  type    = string
  default = "Abhayrkhot/eks-gitops-platform"
}

variable "state_bucket_name" {
  description = "Override the default eks-gitops-tfstate-<account>-<region> bucket name."
  type        = string
  default     = null
}

variable "force_destroy_state" {
  type    = bool
  default = false
}

variable "create_oidc_provider" {
  type    = bool
  default = true
}

variable "extra_trusted_principal_arns" {
  description = "Principals allowed to assume the CI roles in guardrail tests."
  type        = list(string)
  default     = []
}
