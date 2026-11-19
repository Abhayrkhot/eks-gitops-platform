#!/usr/bin/env bash
# Baseline for the provisioning comparison: the sequential procedure from the
# Amazon EKS getting-started guide (AWS CLI path), scripted so it runs at
# machine speed. A person following it by hand is slower still; this is the
# lower bound for "no reusable modules, no parallelism".
#
#   1. VPC from AWS's sample CloudFormation template   (wait)
#   2. cluster IAM role                                 (wait)
#   3. EKS cluster with default add-ons                 (wait)
#   4. node IAM role + managed node group               (wait)
#   5. kubeconfig, Helm install of Argo CD, root app    (wait for apps)
#
# Same Kubernetes version, instance type, node count, chart versions and Git
# source as the Terraform path, so only the method differs.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGION="${REGION:-us-east-1}"
NAME="${RUNBOOK_NAME:-runbook-dev}"
STACK="${NAME}-vpc"
K8S="${K8S_VERSION:-1.34}"
TEMPLATE="https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2020-10-29/amazon-eks-vpc-private-subnets.yaml"
export KUBECONFIG="$HOME/.kube/egp-runbook.yaml"
AWS=(aws --region "$REGION")

ec2_trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
eks_trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'

stamp() { echo "[$(date -u +%T)] $*"; }

up() {
  stamp "1/5 VPC stack"
  "${AWS[@]}" cloudformation create-stack --stack-name "$STACK" --template-url "$TEMPLATE" >/dev/null
  "${AWS[@]}" cloudformation wait stack-create-complete --stack-name "$STACK"
  outputs=$("${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output json)
  subnets=$(jq -r '.[] | select(.OutputKey=="SubnetIds") | .OutputValue' <<<"$outputs")
  sg=$(jq -r '.[] | select(.OutputKey=="SecurityGroups") | .OutputValue' <<<"$outputs")
  private=$("${AWS[@]}" ec2 describe-subnets --subnet-ids ${subnets//,/ } \
    --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' --output text | tr '\t' ',')

  stamp "2/5 cluster role"
  "${AWS[@]}" iam create-role --role-name "${NAME}-cluster" --assume-role-policy-document "$eks_trust" >/dev/null
  "${AWS[@]}" iam attach-role-policy --role-name "${NAME}-cluster" --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
  cluster_role=$("${AWS[@]}" iam get-role --role-name "${NAME}-cluster" --query Role.Arn --output text)
  sleep 10 # IAM propagation, as the guide warns

  stamp "3/5 EKS cluster"
  myip=$(curl -s https://checkip.amazonaws.com)
  "${AWS[@]}" eks create-cluster --name "$NAME" --kubernetes-version "$K8S" --role-arn "$cluster_role" \
    --resources-vpc-config "subnetIds=${subnets},securityGroupIds=${sg},endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=${myip}/32" \
    --access-config authenticationMode=API --upgrade-policy supportType=STANDARD >/dev/null
  "${AWS[@]}" eks wait cluster-active --name "$NAME"

  stamp "4/5 node role + node group"
  "${AWS[@]}" iam create-role --role-name "${NAME}-node" --assume-role-policy-document "$ec2_trust" >/dev/null
  for p in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryPullOnly; do
    "${AWS[@]}" iam attach-role-policy --role-name "${NAME}-node" --policy-arn "arn:aws:iam::aws:policy/$p"
  done
  node_role=$("${AWS[@]}" iam get-role --role-name "${NAME}-node" --query Role.Arn --output text)
  sleep 10
  "${AWS[@]}" eks create-nodegroup --cluster-name "$NAME" --nodegroup-name default --subnets ${private//,/ } \
    --instance-types m7i-flex.large --ami-type AL2023_x86_64_STANDARD --node-role "$node_role" \
    --scaling-config minSize=2,maxSize=4,desiredSize=2 >/dev/null
  "${AWS[@]}" eks wait nodegroup-active --cluster-name "$NAME" --nodegroup-name default

  stamp "5/5 Argo CD + root app"
  "${AWS[@]}" eks update-kubeconfig --name "$NAME" --kubeconfig "$KUBECONFIG" >/dev/null
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm install argocd argo/argo-cd --version 10.18.1 -n argocd --create-namespace \
    -f "$ROOT/gitops/argocd/values.yaml" --wait --timeout 10m >/dev/null
  cat >/tmp/runbook-root.yaml <<EOF
applications:
  platform-root:
    namespace: argocd
    project: default
    source:
      repoURL: https://github.com/Abhayrkhot/eks-gitops-platform.git
      targetRevision: main
      path: gitops/bootstrap
      helm:
        valuesObject:
          environment: dev
          clusterName: ${NAME}
          repoURL: https://github.com/Abhayrkhot/eks-gitops-platform.git
          targetRevision: main
    destination: {server: https://kubernetes.default.svc, namespace: argocd}
    syncPolicy: {automated: {prune: true, selfHeal: true}}
EOF
  helm install platform-root argo/argocd-apps --version 2.0.8 -n argocd -f /tmp/runbook-root.yaml --wait >/dev/null
  "$ROOT/scripts/wait-platform.sh"
  stamp "runbook complete"
}

down() {
  stamp "teardown"
  "${AWS[@]}" eks delete-nodegroup --cluster-name "$NAME" --nodegroup-name default >/dev/null 2>&1 || true
  "${AWS[@]}" eks wait nodegroup-deleted --cluster-name "$NAME" --nodegroup-name default 2>/dev/null || true
  "${AWS[@]}" eks delete-cluster --name "$NAME" >/dev/null 2>&1 || true
  "${AWS[@]}" eks wait cluster-deleted --name "$NAME" 2>/dev/null || true
  for r in "${NAME}-node" "${NAME}-cluster"; do
    for p in $("${AWS[@]}" iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      "${AWS[@]}" iam detach-role-policy --role-name "$r" --policy-arn "$p"
    done
    "${AWS[@]}" iam delete-role --role-name "$r" 2>/dev/null || true
  done
  "${AWS[@]}" cloudformation delete-stack --stack-name "$STACK"
  "${AWS[@]}" cloudformation wait stack-delete-complete --stack-name "$STACK"
  stamp "teardown complete"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
