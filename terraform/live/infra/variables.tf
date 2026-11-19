variable "environment" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_endpoint" {
  description = "AWS API emulator endpoint for local runs; null on real AWS."
  type        = string
  default     = null
}

variable "name" {
  type    = string
  default = "gitops"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
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
  description = "Operator CIDRs for the public API endpoint (the Makefile passes the caller's /32)."
  type        = list(string)
  default     = []
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
  description = "Boundary from the bootstrap stack; every role this stack creates carries it."
  type        = string
  default     = null
}

variable "protect_resources" {
  description = "Tag everything Protection=protected so the CI apply role cannot delete it."
  type        = bool
  default     = false
}

variable "cluster_support_type" {
  type    = string
  default = "STANDARD"
}
