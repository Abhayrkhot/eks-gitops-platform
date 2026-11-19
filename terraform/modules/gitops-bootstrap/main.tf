terraform {
  required_version = ">= 1.10"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0, < 4.0"
    }
  }
}

# Terraform's last job: install Argo CD and create one root Application.
# The root app renders gitops/bootstrap from Git (projects, add-ons,
# workloads), so everything after this point is reconciled by Argo CD.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = var.namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = concat(
    [for f in var.argocd_values_files : file(f)],
    [yamlencode(var.argocd_values)],
  )

  wait          = true
  wait_for_jobs = true
  timeout       = 600
}

resource "helm_release" "root" {
  name      = "platform-root"
  namespace = var.namespace

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      platform-root = {
        namespace = var.namespace
        project   = "default"
        source = {
          repoURL        = var.repo_url
          targetRevision = var.target_revision
          path           = var.root_path
          helm = {
            valuesObject = {
              environment    = var.environment
              clusterName    = var.cluster_name
              repoURL        = var.repo_url
              targetRevision = var.target_revision
              apps           = var.apps
            }
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = var.namespace
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
          retry = {
            limit   = 10
            backoff = { duration = "5s", factor = 2, maxDuration = "1m" }
          }
        }
      }
    }
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.argocd]
}
