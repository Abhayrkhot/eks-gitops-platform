variable "name" {
  description = "Cluster name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,38}$", var.name))
    error_message = "Cluster name must be 3-39 lowercase letters, digits or dashes."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version, e.g. 1.34."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.34."
  }
}

variable "subnet_ids" {
  description = "Subnets for the control-plane ENIs (private subnets in at least two AZs)."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Expose the API server endpoint publicly. Off by default; turning it on requires operator CIDRs (policy TF002)."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Never 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "enabled_log_types" {
  description = "Control-plane log types to ship to CloudWatch."
  type        = list(string)
  default     = ["audit", "authenticator"]
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "kms_key_arn" {
  description = "Optional customer KMS key for envelope-encrypting Secrets."
  type        = string
  default     = null
}

variable "admin_principal_arns" {
  description = "IAM principals granted cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "enable_access_entries" {
  description = "Manage EKS access entries (off only for API emulators that lack them)."
  type        = bool
  default     = true
}

variable "before_compute_addons" {
  description = "Managed add-ons installed before any node group exists."
  type = map(object({
    version              = optional(string)
    configuration_values = optional(string)
  }))
  default = {
    vpc-cni                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}
  }
}

variable "iam_path" {
  type    = string
  default = "/eks-gitops/"
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every IAM role this module creates."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "support_type" {
  description = "EKS support policy. STANDARD stops the cluster drifting into paid extended support; null only for emulators."
  type        = string
  default     = "STANDARD"
}
