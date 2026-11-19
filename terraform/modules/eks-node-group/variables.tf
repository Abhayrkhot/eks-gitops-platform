variable "cluster_name" {
  type = string
}

variable "name" {
  description = "Node group name, unique within the cluster."
  type        = string
  default     = "default"
}

variable "subnet_ids" {
  description = "Private subnets the nodes run in."
  type        = list(string)
}

variable "instance_types" {
  type    = list(string)
  default = ["m7i-flex.large"]
}

variable "capacity_type" {
  type    = string
  default = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "ami_type" {
  type    = string
  default = "AL2023_x86_64_STANDARD"
}

variable "desired_size" {
  type    = number
  default = 2
}

variable "min_size" {
  type    = number
  default = 1
}

variable "max_size" {
  type    = number
  default = 4
}

variable "disk_size_gib" {
  type    = number
  default = 30
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "taints" {
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  default = []
}

variable "iam_path" {
  type    = string
  default = "/eks-gitops/"
}

variable "permissions_boundary_arn" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
