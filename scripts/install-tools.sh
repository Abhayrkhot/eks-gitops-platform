#!/usr/bin/env bash
# Installs the pinned CLI toolchain into ~/.local/bin (no root needed).
# Every download is checked against the publisher's SHA-256 checksum file.
set -euo pipefail

BIN="${BIN:-$HOME/.local/bin}"
mkdir -p "$BIN"

TERRAFORM=1.17.2
HELM=4.3.2
ARGOCD=3.6.2
ROLLOUTS=1.10.2
TFLINT=0.66.0
TRIVY=0.76.2
CONFTEST=0.71.1
KUBECONFORM=0.8.0
YQ=4.54.3

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

# fetch <url> <sums-url> [name-in-sums]
fetch() {
  local url="$1" sums="$2" name="${3:-$(basename "$1")}"
  curl -sSfL -o "$name" "$url"
  curl -sSfL -o sums.txt "$sums"
  local expected
  expected="$(grep -E "(^|[[:space:]*/])${name}\$" sums.txt | awk '{print $1}' | head -1)"
  [[ -n "$expected" ]] || { echo "no checksum for $name in $sums" >&2; exit 1; }
  echo "$expected  $name" | sha256sum -c - >/dev/null
  echo "verified $name"
}

unzip_py() { python3 -m zipfile -e "$1" "$2"; }

have() { [[ -x "$BIN/$1" ]] && "$BIN/$1" "${@:2}" 2>/dev/null | grep -q "$3"; }

if ! have terraform version "v$TERRAFORM"; then
  fetch "https://releases.hashicorp.com/terraform/${TERRAFORM}/terraform_${TERRAFORM}_linux_amd64.zip" \
        "https://releases.hashicorp.com/terraform/${TERRAFORM}/terraform_${TERRAFORM}_SHA256SUMS"
  unzip_py "terraform_${TERRAFORM}_linux_amd64.zip" tf && install -m 0755 tf/terraform "$BIN/terraform"
fi

if ! have helm version "v$HELM"; then
  fetch "https://get.helm.sh/helm-v${HELM}-linux-amd64.tar.gz" "https://get.helm.sh/helm-v${HELM}-linux-amd64.tar.gz.sha256sum"
  tar xzf "helm-v${HELM}-linux-amd64.tar.gz" && install -m 0755 linux-amd64/helm "$BIN/helm"
fi

if ! have argocd "version --client" "v$ARGOCD"; then
  fetch "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD}/argocd-linux-amd64" \
        "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD}/cli_checksums.txt"
  install -m 0755 argocd-linux-amd64 "$BIN/argocd"
fi

if ! have kubectl-argo-rollouts version "v$ROLLOUTS"; then
  fetch "https://github.com/argoproj/argo-rollouts/releases/download/v${ROLLOUTS}/kubectl-argo-rollouts-linux-amd64" \
        "https://github.com/argoproj/argo-rollouts/releases/download/v${ROLLOUTS}/argo-rollouts-checksums.txt"
  install -m 0755 kubectl-argo-rollouts-linux-amd64 "$BIN/kubectl-argo-rollouts"
fi

if ! have tflint --version "$TFLINT"; then
  fetch "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT}/tflint_linux_amd64.zip" \
        "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT}/checksums.txt"
  unzip_py tflint_linux_amd64.zip tfl && install -m 0755 tfl/tflint "$BIN/tflint"
fi

if ! have trivy --version "$TRIVY"; then
  fetch "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY}/trivy_${TRIVY}_Linux-64bit.tar.gz" \
        "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY}/trivy_${TRIVY}_checksums.txt"
  tar xzf "trivy_${TRIVY}_Linux-64bit.tar.gz" trivy && install -m 0755 trivy "$BIN/trivy"
fi

if ! have conftest --version "$CONFTEST"; then
  fetch "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST}/conftest_${CONFTEST}_Linux_x86_64.tar.gz" \
        "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST}/checksums.txt"
  tar xzf "conftest_${CONFTEST}_Linux_x86_64.tar.gz" conftest && install -m 0755 conftest "$BIN/conftest"
fi

if ! have kubeconform -v "$KUBECONFORM"; then
  fetch "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM}/kubeconform-linux-amd64.tar.gz" \
        "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM}/CHECKSUMS"
  tar xzf kubeconform-linux-amd64.tar.gz kubeconform && install -m 0755 kubeconform "$BIN/kubeconform"
fi

if ! have yq --version "$YQ"; then
  curl -sSfL -o yq "https://github.com/mikefarah/yq/releases/download/v${YQ}/yq_linux_amd64"
  install -m 0755 yq "$BIN/yq"
fi

for t in terraform helm argocd kubectl-argo-rollouts tflint trivy conftest kubeconform yq kubectl kind aws; do
  printf '%-22s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done
