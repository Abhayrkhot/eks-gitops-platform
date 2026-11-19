# EKS GitOps Platform

[![terraform](https://github.com/Abhayrkhot/eks-gitops-platform/actions/workflows/terraform.yml/badge.svg)](https://github.com/Abhayrkhot/eks-gitops-platform/actions/workflows/terraform.yml)
[![gitops](https://github.com/Abhayrkhot/eks-gitops-platform/actions/workflows/gitops.yml/badge.svg)](https://github.com/Abhayrkhot/eks-gitops-platform/actions/workflows/gitops.yml)

Terraform provisions an Amazon EKS platform from reusable modules with S3 remote state. Argo CD reconciles everything in the cluster from Git and undoes drift on its own. Argo Rollouts ships each release as a canary and rolls it back automatically when it fails. A CI gate plans every infrastructure pull request and blocks unsafe changes before they reach AWS.

Every number below comes from a harness in `experiments/` and is written to `results/`. `docs/results.md` is generated from those files; nothing is typed in by hand.

## Measured results

### Real AWS: EKS 1.34 in us-east-2, two m7i-flex.large nodes

| Area | What was measured | Result |
|---|---|---|
| Provisioning | Empty account to every Argo CD app Synced+Healthy, 3 timed cycles (`terraform apply`, kubeconfig, Argo CD, convergence from Git) | Median **15.5 min**, max **16.3 min**. `terraform apply` 10.8 min, Argo CD install 1.0 min, convergence 4.3 min. Teardown median 11.7 min |
| Progressive delivery | 56 bad releases (7 fault types × 8) shipped through Git | **56/56 rolled back automatically**, none escaped. Recovery to full stable capacity: median 25.8s, **max 27.4s**. Bad version out of traffic in at most 21.8s |
| | 8 good releases interleaved | 8/8 promoted, **0 false aborts** |
| | Client traffic during the bad releases | 90 of 20,579 requests failed (0.44%) |
| Drift repair | 84 managed resources across 13 kinds and 7 apps, all drifted at once, 6 rounds | **504/504 restored**. A whole round healed in at most **17.1s**, and every app was Synced+Healthy again within 31.2s. A single drifted resource: median 0.5s |
| | Same test with Argo CD's default self-heal backoff | 252/252 restored, but only after 243–290s per round, about **19× slower** (median 287.7s vs 15.3s) |
| Policy gate | Unsafe Terraform pull requests, planned against the real S3 remote state | **40/40 blocked** with the expected rule; all 24 rules exercised. About 12s per pull request |
| | Safe pull requests and no-change plans | **14/14 passed**, 0 false positives |
| IAM guardrails | Real API calls the CI roles must not be able to make | **28/28 denied**: 25 live by the roles' policies and permissions boundary, 3 decided by the IAM policy simulator because the live call couldn't show it (see `docs/results.md`). Controls: 5/5 allowed in the first run; in the final run one dry-run launch was blocked by the account's own organization policy |

Not measured yet: the comparison baseline, which provisions the same cluster by following AWS's getting-started CLI steps. During the run, the AWS Organization that owns the account attached a policy denying all compute creation (`eks:CreateCluster`, `ec2:RunInstances`, `cloudformation:CreateStack`, and more). It runs with `experiments/provisioning/run.py --baseline` once that is lifted.

### Local lab (kind + moto) and CI

| Area | What was measured | Result |
|---|---|---|
| Progressive delivery | 70 bad releases (7 fault types × 10) shipped through Git | **70/70 rolled back automatically**, none escaped. Recovery to full stable capacity: median 25.4s, **max 27.1s**. Bad version removed from traffic in at most 21.2s |
| | 10 good releases interleaved | 10/10 promoted, **0 false aborts** |
| | Client traffic during the bad releases | 103 of 24,398 requests failed (0.42%) |
| Drift repair | 84 managed resources across 13 kinds and 7 apps, all drifted at once, 6 rounds | **504/504 restored**. A whole round healed in at most **11.0s**; median per resource 1.2s |
| | Same test with Argo CD's default self-heal backoff | 252/252 restored, but only after **288–292s** per round, about 26× slower than the tuned backoff (median round 289.3s vs 10.9s). The reason: Argo CD counts self-heals per commit, and its default backoff grows to a 300s cap |
| Policy gate | Unsafe Terraform pull requests, planned against real remote state | **39/39 blocked** with the expected rule (24 rules). A 40th fixture needs real EKS add-ons |
| | Safe pull requests and no-change plans | **14/14 passed**, 0 false positives |
| CI | The same platform and experiments on a fresh GitHub runner | 252/252 drift repairs, 7/7 bad releases rolled back, 2/2 good releases promoted |

Fault types: crash loop, nonexistent image tag, OOM on start, never ready, failing liveness, HTTP 500s, slow responses. The first four are caught by the progress deadline and the last three by the canary smoke analysis.

## How it works

```
terraform/
  modules/        vpc, eks-cluster, eks-node-group, eks-addons, platform (composition),
                  state-backend, ci-iam (GitHub OIDC roles + permissions boundary), gitops-bootstrap
  bootstrap/      state bucket + CI roles, once per account
  live/infra/     an environment's VPC + EKS + node groups      state: <env>/infra.tfstate
  live/gitops/    Argo CD + root app, reads infra via remote state  state: <env>/gitops.tfstate
gitops/
  argocd/         argo-cd chart values (tuned self-heal backoff)
  bootstrap/      app-of-apps chart: projects, add-ons, storefront, tenant ApplicationSet
  charts/         storefront (Rollout canary + smoke analysis), tenant (namespace guardrails)
policy/           24 conftest/Rego rules for terraform plans + unit tests
experiments/      rollouts, drift, policy, iam, provisioning harnesses
lab/              local stand-ins: moto (AWS APIs), kind (EKS), Gitea (Git server)
```

- **Terraform**: the modules are composed by `platform`, so environments differ only in tfvars. State is kept in S3 with versioning, encryption, a TLS-only policy, and lockfile locking (no DynamoDB). The infra and gitops stacks are joined by `terraform_remote_state`. Every role carries a permissions boundary.
- **GitOps**: Terraform installs Argo CD and one root Application. From then on, add-ons, the storefront and six tenant namespaces come from Git through an app of apps and an ApplicationSet. Sync waves make the Rollout CRDs exist before the apps that use them.
- **Delivery**: the canary goes 20% → 60% → 100% with a fail-fast smoke analysis at each step. A 20s progress deadline and `minReadySeconds: 5` catch pods that never become available, and the canary is dropped immediately on abort.
- **CI**: fmt, validate, tflint, trivy and Rego unit tests run first. Then every fixture pull request is planned against emulated AWS and gated. When the repo is wired to AWS, PRs are also planned with a read-only OIDC role. The e2e job brings up the whole platform on kind.

See [docs/design.md](docs/design.md) for the design, measurement definitions, known limits found while measuring, and emulator gaps. See [docs/results.md](docs/results.md) for every table.

## Run it locally (no AWS account)

```bash
make tools                      # pinned CLIs into ~/.local/bin (checksum-verified)
make local-up                   # moto + bootstrap + infra + kind + lab Git + Argo CD; waits for every app
scripts/local-experiments.sh    # rollouts, drift (tuned + default backoff), policy gate -> results/local
python3 scripts/results-table.py
```

## Run it on AWS

```bash
aws configure                   # an IAM user or role in your own account
scripts/aws-phase.sh            # bootstrap, timed provisioning cycles, IAM + policy + drift + rollout
                                # experiments, CLI-runbook baseline, teardown (trap tears down on failure)
```

Or step by step: `make bootstrap ENV=dev`, `make up ENV=dev`, `make down ENV=dev`.
