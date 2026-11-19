#!/usr/bin/env bash
# The whole real-AWS measurement run, unattended, with teardown on any failure.
#
#   1. preflight (identity, EKS version support, instance type offered)
#   2. bootstrap: state bucket + CI roles (+ break-glass trust for the IAM tests)
#   3. provisioning cycles: empty -> every app Healthy, then teardown (last cycle kept)
#   4. IAM guardrails, policy gate against real state
#   5. drift repair (tuned, then upstream-default self-heal backoff)
#   6. failed-release recovery (storefront pointed at the in-cluster Git server)
#   7. teardown, baseline CLI runbook cycle, bootstrap trust removed, results rendered
#
# Run on the box inside tmux:  scripts/aws-phase.sh 2>&1 | tee .work/aws-phase.log
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."

ENV=dev
REGION=us-east-2   # the account's SCP allows EC2/EKS only in us-east-2
export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION
CYCLES="${CYCLES:-3}"
PER_MODE="${PER_MODE:-8}"
export KUBECONFIG="$HOME/.kube/egp-${ENV}.yaml"
UV=(uv run -q --with-requirements experiments/requirements.txt)
LAB_GIT_URL="http://lab-git.lab-git.svc.cluster.local:3000/lab/eks-gitops-platform.git"
mkdir -p .work

say() { echo; echo "=== [$(date -u +%T)] $*"; }

teardown() {
  say "TEARDOWN (trap)"
  make down ENV=$ENV || true
  experiments/provisioning/baseline-runbook.sh down || true
}
trap teardown ERR INT TERM

say "1. preflight"
ADMIN_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "caller: $ADMIN_ARN"
case "$ADMIN_ARN" in *:root) echo "use an IAM user or role, not root (root cannot assume the CI roles)"; exit 1;; esac
echo "on-demand vCPU quota: $(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query Quota.Value --output text)"
aws eks describe-cluster-versions --region $REGION --query 'clusterVersions[].[clusterVersion,versionStatus]' --output text | head -8
aws ec2 describe-instance-type-offerings --region $REGION --location-type availability-zone \
  --filters Name=instance-type,Values=m7i-flex.large --query 'InstanceTypeOfferings[].Location' --output text

say "2. bootstrap (state bucket, OIDC provider, CI roles)"
cat > .work/bootstrap-test.tfvars.json <<EOF
{"extra_trusted_principal_arns": ["$ADMIN_ARN"]}
EOF
make bootstrap ENV=$ENV BOOTSTRAP_ARGS="-auto-approve -var-file=$PWD/.work/bootstrap-test.tfvars.json"
BUCKET=$(terraform -chdir=terraform/bootstrap output -state=terraform.$ENV.tfstate -raw state_bucket)

say "3. provisioning cycles ($CYCLES, last one kept up)"
"${UV[@]}" experiments/provisioning/run.py --env $ENV --cycles "$CYCLES" --keep-last

say "4a. IAM guardrails"
"${UV[@]}" --with boto3 experiments/iam/run.py --env $ENV --state-bucket "$BUCKET" || echo "IAM harness reported failures"

say "4b. policy gate against real state"
"${UV[@]}" experiments/policy/run.py --env $ENV --workers 4 || echo "policy suite reported failures"

say "5a. drift repair, tuned backoff"
"${UV[@]}" experiments/drift/run.py --env $ENV --rounds 6 --single 30 --tag tuned || echo "drift (tuned) reported failures"

say "5b. drift repair, upstream default backoff"
cat > .work/argocd-defaults.tfvars.json <<'EOF'
{"argocd_values": {"configs": {"params": {
  "controller.self.heal.backoff.timeout.seconds": "2",
  "controller.self.heal.backoff.factor": "3",
  "controller.self.heal.backoff.cap.seconds": "300"}}}}
EOF
make gitops ENV=$ENV GITOPS_ARGS="-var-file=$PWD/.work/argocd-defaults.tfvars.json"
make wait ENV=$ENV
"${UV[@]}" experiments/drift/run.py --env $ENV --rounds 3 --single 0 --timeout 900 --tag defaults || echo "drift (defaults) reported failures"

say "6. failed releases (storefront from the in-cluster Git server)"
lab/lab-git.sh deploy
lab/lab-git.sh seed
cat > .work/storefront-labgit.tfvars.json <<EOF
{"apps": {"storefront": {"repoURL": "$LAB_GIT_URL"}}}
EOF
make gitops ENV=$ENV GITOPS_ARGS="-var-file=$PWD/.work/storefront-labgit.tfvars.json"
lab/lab-git.sh hook
make wait ENV=$ENV
"${UV[@]}" experiments/rollouts/run.py --env $ENV --per-mode "$PER_MODE" --good "$PER_MODE" || echo "rollouts reported failures"

say "7a. teardown (timed)"
start=$(date +%s)
make down ENV=$ENV
echo "teardown took $(( $(date +%s) - start ))s"

say "7b. baseline: sequential CLI runbook"
"${UV[@]}" experiments/provisioning/run.py --env $ENV --cycles 1 --baseline

say "7c. remove the break-glass test trust from the CI roles"
make bootstrap ENV=$ENV BOOTSTRAP_ARGS="-auto-approve"

trap - ERR INT TERM
python3 scripts/results-table.py
say "done: results in results/$ENV, docs/results.md"
