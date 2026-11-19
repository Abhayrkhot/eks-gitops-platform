# Design

## What it does

```
            pull request                      merge to main
                 │                                  │
   ┌─────────────▼─────────────┐        ┌───────────▼────────────┐
   │ CI: fmt, validate, tflint, │        │ terraform apply         │
   │ trivy, conftest verify     │        │ (apply role: OIDC,      │
   │ terraform plan (plan role, │        │  permissions boundary)  │
   │ read-only) -> conftest gate│        └───────────┬────────────┘
   └────────────────────────────┘                    │
                                                     ▼
 S3 state bucket ─┬─ <env>/infra.tfstate   VPC ─ EKS ─ node group ─ add-ons
 (versioned, SSE, │                                  │
  lockfile)       └─ <env>/gitops.tfstate  Argo CD ─ root Application
                                                     │  (app of apps, from Git)
                         ┌───────────────┬───────────┼──────────────┐
                         ▼               ▼           ▼              ▼
                   argo-rollouts   metrics-server  storefront   tenants (ApplicationSet)
                                                   Rollout       6 team namespaces:
                                                   canary +      quota, limits, RBAC,
                                                   smoke analysis default-deny netpol, PSA
```

## Terraform

- **Modules** (`terraform/modules`): `vpc`, `eks-cluster`, `eks-node-group`, `eks-addons`, `state-backend`, `ci-iam`, `gitops-bootstrap`. `platform` composes the first four. Each environment instantiates `platform` with its own tfvars, and nothing environment-specific lives in a module.
- **Layered stacks**: `live/infra` owns AWS resources and `live/gitops` owns what Terraform installs into the cluster. The gitops stack reads cluster details from the infra stack through `terraform_remote_state`. Pull-request plans of the infra stack therefore need only AWS APIs, never cluster access.
- **Remote state**: one S3 bucket per account, with versioning, SSE, bucket-owner-enforced ownership, a public access block, a TLS-only policy, and a lifecycle on old versions. Locking uses S3 conditional writes (`use_lockfile = true`, Terraform 1.10 and later), with no DynamoDB table. A second concurrent plan fails with "Error acquiring the state lock". This was tested against the emulator.
- **Cost guards**: one NAT gateway, `upgrade_policy = STANDARD` (never paid extended support), Free-plan-eligible `m7i-flex.large` nodes, and 7-day log retention.
- **Security defaults**: private API endpoint by default, and a public endpoint only with operator CIDRs. Authentication is EKS access entries with `authentication_mode = API` (no aws-auth ConfigMap). Nodes require IMDSv2 with a hop limit of 1 and use encrypted gp3 volumes. Every role carries the permissions boundary.

## CI identities (`modules/ci-iam`)

| Role | Trusted by | Can |
|---|---|---|
| `eks-gitops-plan` | GitHub OIDC, `repo:<repo>:pull_request` and branches | `ReadOnlyAccess`, read state, write only `*.tflock` |
| `eks-gitops-apply` | GitHub OIDC, `main` and the `dev` environment | ec2/eks/autoscaling/elb/logs; IAM only for roles under `/eks-gitops/` |

Both roles use a **permissions boundary** that allows only the platform's services and denies a set of dangerous actions outright:

- creating IAM users or keys
- creating a role without the boundary, removing a boundary, or editing the boundary itself
- attaching admin policies
- touching roles outside `/eks-gitops/`, which covers the CI roles themselves
- tampering with the state bucket or purging its history
- changes to CloudTrail, GuardDuty or AWS Config
- account-level changes
- other regions
- instance types outside the allowlist
- public ACLs or snapshots
- deleting anything tagged `Protection=protected`
- destroying KMS keys

## Plan-time policy gate (`policy/terraform/guardrails.rego`)

There are 24 rules, TF001–TF024, evaluated by conftest on `terraform show -json`. Each deny message starts with its rule ID, so tests can assert on the exact rule. They cover:

- network exposure and EKS settings (endpoint, auth mode, audit logs, support policy, version skew, critical add-ons, cluster-admin grants)
- compute (instance allowlist, size cap, IMDSv2, EBS encryption)
- S3 (public access, state-bucket protections)
- IAM (wildcards, admin attachments, users and keys, missing boundary, open trust, GitHub OIDC trust not pinned to a repo, a weakened boundary)
- destructive replacements of protected resources
- required tags, region, and log retention

`experiments/policy/fixtures.yaml` holds 40 unsafe and 12 safe pull requests. Many of them edit module code, the way a real PR would. Each one is applied to a copy of `terraform/`, planned against the environment's actual remote state, and gated. One limit: values that are unknown until apply, such as an ARN computed inside a policy document, can't be inspected at plan time. The live IAM boundary is the second layer for those cases.

## GitOps

- Terraform installs Argo CD (chart 10.18.1, v3.6) and one root Application through the `argocd-apps` chart. The root app renders `gitops/bootstrap`, which holds the projects, add-ons, storefront and tenant ApplicationSet. After that, every cluster change comes from Git.
- **Sync waves with Application health**: add-ons come at wave -5, so the Rollout CRDs exist before storefront syncs. This needs the Application health customization in `argocd-cm`.
- **Self-heal**: `automated: {prune, selfHeal}` on every app. The backoff is tuned to 1s ×2 with a 10s cap; upstream it's 2s ×3 with a 300s cap. Both settings are measured.
- **Projects**: `workloads` may create only Namespaces at cluster scope, `platform-tenants` owns the quotas, and `platform` owns the add-ons.
- **Push webhook**: the Git server notifies `argocd-server /api/webhook`, so a commit syncs in about 3s instead of waiting for the 120s poll.

## Progressive delivery (`gitops/charts/storefront`)

- The Rollout steps are 20% → smoke analysis → 60% → smoke analysis → 5s pause → 100%, with 5 replicas. Traffic splits by replica count across the `storefront` Service. The `-stable` and `-canary` Services are pinned to their ReplicaSets.
- **Smoke analysis**: a Job that calls the canary Service only. It checks `/healthz` and `/readyz`, then makes 40 requests, and fails as soon as there is more than one error or more than two responses slower than 250 ms.
- **Pods that never become available**: crash loop, bad image, OOM, or failing readiness are caught by `progressDeadlineSeconds: 20` with `progressDeadlineAbort`. `minReadySeconds: 5` keeps a pod that dies right after start from passing a step.
- **On abort**: `abortScaleDownDelaySeconds: 0` removes the canary immediately, and the stable ReplicaSet scales back to full.

## Measurement definitions

- **Failed release recovered**: the canary ReplicaSet is at zero replicas and zero pods, the stable ReplicaSet is fully available, the Rollout still points at the old stable hash, and so does the `storefront-stable` Service selector. The clock starts when the controller creates the canary revision. Git push to that start is reported separately.
- **Drift restored**: the live object's Git-owned field equals its pre-drift value again. For deletions, the object exists again with a new UID and the same spec. A round ends when every resource is restored and every app is Synced+Healthy.
- **Unsafe change prevented**: either the plan gate denies it with the expected rule (fixtures), or AWS returns AccessDenied/UnauthorizedOperation to the CI role for a real API call (IAM harness).
- **Platform ready**: from `terraform apply` of an empty environment until every Argo CD app is Synced+Healthy.

## Local lab and its gaps

| Real | Local stand-in | Gap (handled how) |
|---|---|---|
| AWS APIs | moto 5.2.5 (TLS) | No EKS add-ons or access entries (off in `local.tfvars`). Drops `upgradePolicy`, and the provider crashes on it (`cluster_support_type = null`). Never sets `aws:SecureTransport` (TLS bucket policy off). Invents a node-group SSH key, so plans are never empty. |
| EKS | kind 1.35, 3 nodes | Same Kubernetes APIs. The cluster isn't created by Terraform, so local provisioning time means nothing. |
| GitHub | Gitea in the cluster | Same Argo CD Git flow and webhook. Experiments push releases here. |
