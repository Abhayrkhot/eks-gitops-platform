variable "bucket_name" {
  description = "Globally unique state bucket name."
  type        = string
}

variable "force_destroy" {
  description = "Allow destroying the bucket with state still in it. Keep false outside throwaway labs."
  type        = bool
  default     = false
}

variable "noncurrent_version_days" {
  description = "How long superseded state versions are kept for rollback."
  type        = number
  default     = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enforce_tls" {
  description = "Attach the deny-non-TLS bucket policy."
  type        = bool
  default     = true
}
