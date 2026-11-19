# EKS GitOps platform.
#
#   Local (no AWS account needed):  make local-up / local-down
#     Terraform runs against the moto AWS emulator; a kind cluster stands in
#     for EKS; Argo CD reconciles from an in-cluster Git server.
#   Real AWS:                        make bootstrap, make up ENV=dev, make down ENV=dev
#
# Every target uses its own kubeconfig file, never the global context.

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ENV    ?= local
REGION ?= us-east-1
export PATH := $(HOME)/.local/bin:$(PATH)

MOTO_ENDPOINT := https://127.0.0.1:15566
LOCAL_BUCKET  := eks-gitops-tfstate-local

ifeq ($(ENV),local)
  KUBECONFIG_FILE ?= $(HOME)/.kube/egp-gitops.yaml
  BACKEND_HCL     := ../local.backend.hcl
else
  KUBECONFIG_FILE ?= $(HOME)/.kube/egp-$(ENV).yaml
  BACKEND_HCL     := ../backend-$(ENV).hcl
endif
export KUBECONFIG := $(KUBECONFIG_FILE)

TF_BOOT   := terraform -chdir=terraform/bootstrap
TF_INFRA  := terraform -chdir=terraform/live/infra
TF_GITOPS := terraform -chdir=terraform/live/gitops

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-22s %s\n", $$1, $$2}'

.PHONY: tools
tools: ## Install the pinned CLI toolchain into ~/.local/bin
	scripts/install-tools.sh

# ---------------------------------------------------------------- local lab
.PHONY: moto-up local-bootstrap local-infra kind-up lab-git local-gitops local-up local-down
moto-up: ## Start the moto AWS emulator
	lab/moto.sh up

local-bootstrap: moto-up ## State bucket + CI IAM on the emulator
	$(TF_BOOT) init -input=false -no-color >/dev/null
	$(TF_BOOT) apply -input=false -auto-approve -no-color \
	  -var aws_endpoint=$(MOTO_ENDPOINT) -var state_bucket_name=$(LOCAL_BUCKET) -var force_destroy_state=true

local-infra: ## VPC + EKS + node group on the emulator (remote state in emulated S3)
	$(TF_INFRA) init -input=false -no-color -reconfigure -backend-config=$(BACKEND_HCL) -backend-config=key=local/infra.tfstate >/dev/null
	$(TF_INFRA) apply -input=false -auto-approve -no-color -var-file=env/local.tfvars

kind-up: ## kind cluster that stands in for EKS
	kind get clusters | grep -qx gitops || kind create cluster --config lab/kind-config.yaml --kubeconfig $(KUBECONFIG_FILE)
	kind get kubeconfig --name gitops > $(KUBECONFIG_FILE)
	chmod 600 $(KUBECONFIG_FILE)

lab-git: ## In-cluster Git server, seeded with this working tree
	lab/lab-git.sh deploy
	lab/lab-git.sh seed

local-gitops: ## Argo CD + root app on kind (reads the infra stack's remote state)
	$(TF_GITOPS) init -input=false -no-color -reconfigure -backend-config=$(BACKEND_HCL) -backend-config=key=local/gitops.tfstate >/dev/null
	$(TF_GITOPS) apply -input=false -auto-approve -no-color -var-file=env/local.tfvars -var kubeconfig_path=$(KUBECONFIG_FILE) -var kube_context=kind-gitops
	lab/lab-git.sh hook

local-up: local-bootstrap local-infra kind-up lab-git local-gitops wait ## Whole local platform, end to end

local-down: ## Delete the kind cluster and wipe the emulator
	kind delete cluster --name gitops || true
	lab/moto.sh down
	rm -f terraform/bootstrap/terraform.tfstate*

# ---------------------------------------------------------------- real AWS
.PHONY: bootstrap backend-config infra gitops kubeconfig up down
bootstrap: ## State bucket + GitHub OIDC CI roles (local state, run once per account)
	$(TF_BOOT) init -input=false -no-color >/dev/null
	$(TF_BOOT) apply -input=false -no-color $(BOOTSTRAP_ARGS)
	$(MAKE) backend-config ENV=$(ENV)

backend-config: ## Write backend-<env>.hcl from the bootstrap outputs
	@printf 'bucket       = "%s"\nregion       = "%s"\nuse_lockfile = true\nencrypt      = true\n' \
	  "$$($(TF_BOOT) output -raw state_bucket)" "$(REGION)" > terraform/live/backend-$(ENV).hcl
	@echo "wrote terraform/live/backend-$(ENV).hcl"

infra: ## Apply the infra stack for ENV
	$(TF_INFRA) init -input=false -no-color -reconfigure -backend-config=$(BACKEND_HCL) -backend-config=key=$(ENV)/infra.tfstate >/dev/null
	$(TF_INFRA) apply -input=false -auto-approve -no-color -var-file=env/$(ENV).tfvars \
	  -var 'public_access_cidrs=["'"$$(curl -s https://checkip.amazonaws.com)"'/32"]' \
	  -var permissions_boundary_arn="$$($(TF_BOOT) output -raw permissions_boundary_arn)"

kubeconfig: ## Write the EKS kubeconfig for ENV to its own file
	aws eks update-kubeconfig --region $(REGION) --name "$$($(TF_INFRA) output -raw cluster_name)" --kubeconfig $(KUBECONFIG_FILE) >/dev/null

gitops: ## Argo CD + root app on EKS
	$(TF_GITOPS) init -input=false -no-color -reconfigure -backend-config=$(BACKEND_HCL) -backend-config=key=$(ENV)/gitops.tfstate >/dev/null
	$(TF_GITOPS) apply -input=false -auto-approve -no-color -var-file=env/$(ENV).tfvars \
	  -var state_bucket="$$($(TF_BOOT) output -raw state_bucket)" $(GITOPS_ARGS)

up: infra kubeconfig gitops wait ## Full platform on AWS for ENV

down: ## Destroy the GitOps layer, then the infra stack, for ENV
	-$(TF_GITOPS) destroy -input=false -auto-approve -no-color -var-file=env/$(ENV).tfvars \
	  -var state_bucket="$$($(TF_BOOT) output -raw state_bucket)"
	$(TF_INFRA) destroy -input=false -auto-approve -no-color -var-file=env/$(ENV).tfvars \
	  -var 'public_access_cidrs=["'"$$(curl -s https://checkip.amazonaws.com)"'/32"]' \
	  -var permissions_boundary_arn="$$($(TF_BOOT) output -raw permissions_boundary_arn)"

# ---------------------------------------------------------------- checks
.PHONY: wait status
wait: ## Block until every Argo CD app is Synced and Healthy
	scripts/wait-platform.sh

status: ## Argo CD apps and the storefront rollout
	kubectl -n argocd get applications.argoproj.io
	kubectl argo rollouts -n storefront get rollout storefront --no-color 2>/dev/null | head -25 || true
