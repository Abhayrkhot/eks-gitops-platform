# Real AWS dev environment. public_access_cidrs and permissions_boundary_arn
# are passed by the Makefile (operator /32 and the bootstrap stack output).
environment = "dev"
# Public endpoint so operators without a VPN can reach the API; only from
# the operator /32 (public_access_cidrs), which policy TF002 enforces.
endpoint_public_access = true
kubernetes_version     = "1.34"
vpc_cidr               = "10.40.0.0/16"

node_groups = {
  default = {
    instance_types = ["m7i-flex.large"]
    desired_size   = 2
    min_size       = 2
    max_size       = 4
  }
}
