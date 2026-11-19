# Backend settings for local runs against the moto emulator (lab/moto.sh).
# Real environments use backend-<env>.hcl generated from the bootstrap stack.
bucket                      = "eks-gitops-tfstate-local"
region                      = "us-east-2"
use_lockfile                = true
use_path_style              = true
skip_credentials_validation = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
access_key                  = "test"
secret_key                  = "test"
insecure                    = true # moto serves a self-signed certificate
endpoints = {
  s3  = "https://127.0.0.1:15566"
  sts = "https://127.0.0.1:15566"
}
