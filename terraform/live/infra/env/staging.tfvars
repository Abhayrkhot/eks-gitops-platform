# Staging: same modules, different shape. Protected resources cannot be
# deleted by the CI apply role (see DenyDeletingProtectedResources).
environment        = "staging"
kubernetes_version = "1.34"
vpc_cidr           = "10.50.0.0/16"
protect_resources  = true

node_groups = {
  default = {
    instance_types = ["m7i-flex.large"]
    desired_size   = 3
    min_size       = 3
    max_size       = 6
  }
}
