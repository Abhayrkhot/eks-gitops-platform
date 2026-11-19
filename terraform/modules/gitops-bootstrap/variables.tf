variable "environment" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "namespace" {
  type    = string
  default = "argocd"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.18.1"
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.8"
}

variable "argocd_values_files" {
  description = "Values files for the argo-cd chart, applied in order."
  type        = list(string)
  default     = []
}

variable "argocd_values" {
  description = "Extra argo-cd chart values merged last."
  type        = any
  default     = {}
}

variable "repo_url" {
  description = "Git repository Argo CD reconciles from."
  type        = string
}

variable "target_revision" {
  type    = string
  default = "main"
}

variable "root_path" {
  description = "Path of the app-of-apps chart inside the repository."
  type        = string
  default     = "gitops/bootstrap"
}

variable "apps" {
  description = "Per-app overrides passed to the app-of-apps chart."
  type        = any
  default     = {}
}
