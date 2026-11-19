# EKS GitOps Platform

Terraform provisions an Amazon EKS platform from reusable modules with S3 remote state. Argo CD then reconciles everything in the cluster from Git. Argo Rollouts ships each release as a canary and rolls it back on its own when it fails. A CI gate plans every infrastructure pull request and blocks unsafe changes before they reach AWS.

Status: built and measured locally (moto + kind). The real-AWS runs come next, and their numbers will go in `docs/results.md`.

## Layout

```
terraform/
  modules/        vpc, eks-cluster, eks-node-group, eks-addons, platform (composition),
                  state-backend, ci-iam (GitHub OIDC roles + permissions boundary), gitops-bootstrap
  bootstrap/      state bucket + CI roles, once per account
  live/infra/     one environment's VPC + EKS + node groups   (state: <env>/infra.tfstate)
  live/gitops/    Argo CD + root app; reads infra via remote state (state: <env>/gitops.tfstate)
gitops/
  argocd/         argo-cd chart values (self-heal tuning)
  bootstrap/      app-of-apps chart: projects, add-ons, storefront, tenant ApplicationSet
  charts/         storefront (Rollout canary + smoke analysis), tenant (namespace guardrails)
policy/           conftest/Rego guardrails for terraform plans + unit tests
experiments/      drift repair, failed-release recovery, policy-gate fixtures
lab/              local stand-ins: moto (AWS API), kind (EKS), Gitea (Git server)
```

## Run it locally (no AWS account)

```bash
make tools       # pinned CLIs into ~/.local/bin
make local-up    # moto + bootstrap + infra + kind + lab Git + Argo CD, waits for every app
```

Experiments:

```bash
uv run --with-requirements experiments/requirements.txt experiments/rollouts/run.py --env local
uv run --with-requirements experiments/requirements.txt experiments/drift/run.py --env local
uv run --with-requirements experiments/requirements.txt experiments/policy/run.py --env local
```

## Run it on AWS

```bash
make bootstrap ENV=dev    # state bucket + OIDC roles (local state)
make up ENV=dev           # infra -> kubeconfig -> gitops -> wait for apps
make down ENV=dev
```
