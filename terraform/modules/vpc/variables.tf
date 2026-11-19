variable "name" {
  description = "Name prefix for every VPC resource."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr, 0))
    error_message = "cidr must be a valid IPv4 CIDR block."
  }
}

variable "azs" {
  description = "Availability zones to spread subnets across (2 or more)."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2 && length(var.azs) <= 4
    error_message = "EKS needs subnets in at least two AZs; this module supports up to four."
  }
}

variable "subnet_newbits" {
  description = "Bits added to the VPC prefix for each subnet (4 on a /16 gives /20 subnets)."
  type        = number
  default     = 4
}

variable "nat_gateway" {
  description = "Create a single NAT gateway so private subnets can reach the internet."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "EKS cluster that will use these subnets (adds the kubernetes.io/cluster tag)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags for every resource."
  type        = map(string)
  default     = {}
}
