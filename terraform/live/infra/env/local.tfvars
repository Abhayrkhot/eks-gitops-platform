# Local end-to-end run against the moto AWS emulator. Same modules and the
# same composition as dev; only the endpoint and the emulator's gaps differ.
environment = "local"
# Public endpoint so operators without a VPN can reach the API; only from
# the operator /32 (public_access_cidrs), which policy TF002 enforces.
endpoint_public_access = true
aws_endpoint           = "https://127.0.0.1:15566"
kubernetes_version     = "1.34"
vpc_cidr               = "10.40.0.0/16"
public_access_cidrs    = ["192.0.2.10/32"]

# moto has no EKS add-on or access-entry APIs (real EKS covers these in dev).
before_compute_addons = {}
after_compute_addons  = {}
enable_access_entries = false
# The boundary the local bootstrap stack created in the emulator.
permissions_boundary_arn = "arn:aws:iam::123456789012:policy/eks-gitops-ci/eks-gitops-boundary"
cluster_support_type     = null # moto drops upgradePolicy and the provider crashes on it

node_groups = {
  default = {
    instance_types = ["m7i-flex.large"]
    desired_size   = 2
    min_size       = 1
    max_size       = 4
  }
}
