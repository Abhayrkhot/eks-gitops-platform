variable "cluster_name" {
  description = "EKS cluster to install the add-ons into."
  type        = string
}

variable "addons" {
  description = "Add-ons keyed by EKS add-on name."
  type = map(object({
    version              = optional(string)
    configuration_values = optional(string)
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
