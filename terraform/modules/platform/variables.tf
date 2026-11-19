variable "name" {
  description = "Platform name; the cluster is called <name>-<environment>."
  type        = string
}

variable "environment" {
  type = string

  validation {
    condition     = contains(["local", "dev", "staging", "prod"], var.environment)
    error_message = "environment must be local, dev, staging or prod."
  }
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "nat_gateway" {
  type    = bool
  default = true
}

variable "kubernetes_version" {
  type = string
}

variable "endpoint_public_access" {
  type    = bool
  default = false
}

variable "public_access_cidrs" {
  type    = list(string)
  default = []
}

variable "cluster_log_types" {
  type    = list(string)
  default = ["audit", "authenticator"]
}

variable "admin_principal_arns" {
  type    = list(string)
  default = []
}

variable "enable_access_entries" {
  type    = bool
  default = true
}

variable "before_compute_addons" {
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

variable "after_compute_addons" {
  type = map(object({
    version              = optional(string)
    configuration_values = optional(string)
  }))
  default = {
    coredns = {}
  }
}

variable "node_groups" {
  description = "Managed node groups keyed by name."
  type = map(object({
    instance_types = optional(list(string), ["m7i-flex.large"])
    capacity_type  = optional(string, "ON_DEMAND")
    desired_size   = optional(number, 2)
    min_size       = optional(number, 1)
    max_size       = optional(number, 4)
    disk_size_gib  = optional(number, 30)
    labels         = optional(map(string), {})
  }))
  default = {
    default = {}
  }
}

variable "permissions_boundary_arn" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "cluster_support_type" {
  type    = string
  default = "STANDARD"
}
