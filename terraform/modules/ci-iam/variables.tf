variable "name" {
  description = "Name prefix for the CI roles and boundary policy."
  type        = string
  default     = "eks-gitops"
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI roles."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be owner/repo, with no wildcards."
  }
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider (only one may exist per account)."
  type        = bool
  default     = true
}

variable "plan_subjects" {
  description = "OIDC sub claims allowed to assume the plan role (default: PRs and branches of the repo)."
  type        = list(string)
  default     = []
}

variable "apply_subjects" {
  description = "OIDC sub claims allowed to assume the apply role (default: main and the dev environment)."
  type        = list(string)
  default     = []
}

variable "extra_trusted_principal_arns" {
  description = "Extra IAM principals that may assume the roles. Only for proving the guardrails in tests."
  type        = list(string)
  default     = []
}

variable "state_bucket_arn" {
  type = string
}

variable "allowed_regions" {
  type    = list(string)
  default = ["us-east-1"]
}

variable "allowed_instance_types" {
  description = "Instance type patterns the apply role may launch directly."
  type        = list(string)
  default     = ["t3.micro", "t3.small", "t3.medium", "m7i-flex.large", "c7i-flex.large"]
}

variable "role_path" {
  description = "IAM path for the CI roles and boundary (outside the workload path on purpose)."
  type        = string
  default     = "/eks-gitops-ci/"
}

variable "workload_role_path" {
  description = "IAM path the apply role may create roles under."
  type        = string
  default     = "/eks-gitops/"
}

variable "tags" {
  type    = map(string)
  default = {}
}
