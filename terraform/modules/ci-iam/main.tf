terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

# CI identities for the Terraform pipeline.
#
#   plan role  - assumed by every pull request through GitHub OIDC. Read-only
#                AWS access plus the state lock file; it cannot change anything.
#   apply role - assumed only from main / the protected GitHub environment.
#                Scoped to the services the platform uses and capped by a
#                permissions boundary that every role it creates must carry.
#
# No long-lived keys exist anywhere: both roles trust GitHub's OIDC issuer.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  repo       = var.github_repository

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${local.partition}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"

  boundary_name = "${var.name}-boundary"
  boundary_arn  = "arn:${local.partition}:iam::${local.account_id}:policy${var.role_path}${local.boundary_name}"

  workload_role_arn_pattern = "arn:${local.partition}:iam::${local.account_id}:role${var.workload_role_path}*"

  plan_subjects  = coalescelist(var.plan_subjects, ["repo:${local.repo}:pull_request", "repo:${local.repo}:ref:refs/heads/*"])
  apply_subjects = coalescelist(var.apply_subjects, ["repo:${local.repo}:ref:refs/heads/main", "repo:${local.repo}:environment:dev"])

  admin_policy_arns = [
    "arn:${local.partition}:iam::aws:policy/AdministratorAccess",
    "arn:${local.partition}:iam::aws:policy/IAMFullAccess",
    "arn:${local.partition}:iam::aws:policy/PowerUserAccess",
  ]

  # Global services have no region, so the region guard must not apply to them.
  global_services = [
    "iam:*", "sts:*", "organizations:*", "support:*", "budgets:*", "ce:*",
    "health:*", "pricing:*", "route53:*", "cloudfront:*", "tag:*",
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

# ---------------------------------------------------------------------------
# Permissions boundary: the most any CI-created or CI-assumed role can ever do.
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "boundary" {
  name        = local.boundary_name
  path        = var.role_path
  description = "Upper bound for every role the EKS GitOps pipeline uses or creates."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPlatformServices"
        Effect = "Allow"
        Action = [
          "ec2:*", "eks:*", "autoscaling:*", "elasticloadbalancing:*",
          "logs:*", "cloudwatch:*", "iam:*", "s3:*", "sts:*", "ssm:GetParameter*",
          "kms:Describe*", "kms:List*", "kms:Get*", "kms:CreateGrant",
          "tag:GetResources", "ecr:GetAuthorizationToken", "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer", "pricing:GetProducts",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyLongLivedCredentials"
        Effect = "Deny"
        Action = [
          "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile",
          "iam:UpdateLoginProfile", "iam:AttachUserPolicy", "iam:PutUserPolicy",
          "iam:AddUserToGroup", "iam:CreateServiceSpecificCredential",
        ]
        Resource = "*"
      },
      {
        Sid      = "DenyRolesWithoutBoundary"
        Effect   = "Deny"
        Action   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
        Resource = "*"
        Condition = {
          StringNotEquals = { "iam:PermissionsBoundary" = local.boundary_arn }
        }
      },
      {
        Sid      = "DenyBoundaryRemoval"
        Effect   = "Deny"
        Action   = ["iam:DeleteRolePermissionsBoundary", "iam:DeleteUserPermissionsBoundary"]
        Resource = "*"
      },
      {
        Sid    = "DenyBoundaryTampering"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
        ]
        Resource = local.boundary_arn
      },
      {
        Sid      = "DenyAdminPolicyAttachment"
        Effect   = "Deny"
        Action   = ["iam:AttachRolePolicy", "iam:AttachUserPolicy", "iam:AttachGroupPolicy"]
        Resource = "*"
        Condition = {
          ArnLike = { "iam:PolicyARN" = local.admin_policy_arns }
        }
      },
      {
        Sid    = "DenyRoleChangesOutsideWorkloadPath"
        Effect = "Deny"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy",
          "iam:DeleteRolePolicy", "iam:TagRole", "iam:UntagRole",
        ]
        NotResource = local.workload_role_arn_pattern
      },
      {
        Sid    = "DenyStateBucketTampering"
        Effect = "Deny"
        Action = [
          "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy",
          "s3:PutBucketVersioning", "s3:PutLifecycleConfiguration",
          "s3:PutBucketPublicAccessBlock", "s3:PutEncryptionConfiguration",
          "s3:PutBucketOwnershipControls", "s3:PutBucketAcl",
        ]
        Resource = var.state_bucket_arn
      },
      {
        Sid      = "DenyStateHistoryPurge"
        Effect   = "Deny"
        Action   = ["s3:DeleteObjectVersion"]
        Resource = "${var.state_bucket_arn}/*"
      },
      {
        Sid    = "DenyAuditTampering"
        Effect = "Deny"
        Action = [
          "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
          "cloudtrail:PutEventSelectors", "guardduty:DeleteDetector", "guardduty:UpdateDetector",
          "config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder",
          "config:DeleteDeliveryChannel",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyAccountLevelChanges"
        Effect = "Deny"
        Action = [
          "organizations:*", "account:*", "billing:*", "aws-portal:*",
          "iam:UpdateAccountPasswordPolicy", "iam:DeleteAccountPasswordPolicy",
          "iam:CreateAccountAlias", "iam:DeleteAccountAlias",
          "s3:PutAccountPublicAccessBlock", "s3:DeleteAccountPublicAccessBlock",
        ]
        Resource = "*"
      },
      {
        Sid       = "DenyOutsideAllowedRegions"
        Effect    = "Deny"
        NotAction = local.global_services
        Resource  = "*"
        Condition = {
          StringNotEquals = { "aws:RequestedRegion" = var.allowed_regions }
        }
      },
      {
        Sid      = "DenyUnapprovedInstanceTypes"
        Effect   = "Deny"
        Action   = ["ec2:RunInstances"]
        Resource = "arn:${local.partition}:ec2:*:*:instance/*"
        Condition = {
          StringNotLike = { "ec2:InstanceType" = var.allowed_instance_types }
        }
      },
      {
        Sid      = "DenyPublicBucketAcls"
        Effect   = "Deny"
        Action   = ["s3:PutBucketAcl", "s3:PutObjectAcl", "s3:CreateBucket"]
        Resource = "*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = ["public-read", "public-read-write", "authenticated-read"] }
        }
      },
      {
        Sid    = "DenyPublicImageAndSnapshotSharing"
        Effect = "Deny"
        Action = [
          "ec2:ModifySnapshotAttribute", "ec2:ModifyImageAttribute",
          "ec2:DisableEbsEncryptionByDefault", "ec2:DisableImageBlockPublicAccess",
          "ec2:DisableSnapshotBlockPublicAccess",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDeletingProtectedResources"
        Effect = "Deny"
        Action = [
          "eks:DeleteCluster", "eks:DeleteNodegroup", "ec2:DeleteVpc", "ec2:DeleteSubnet",
          "ec2:DeleteNatGateway", "ec2:DeleteSecurityGroup", "ec2:TerminateInstances",
          "logs:DeleteLogGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Protection" = "protected" }
        }
      },
      {
        Sid    = "DenyKeyDestruction"
        Effect = "Deny"
        Action = [
          "kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:PutKeyPolicy",
        ]
        Resource = "*"
      },
    ]
  })

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Trust policies
# ---------------------------------------------------------------------------
locals {
  github_trust = {
    plan  = local.plan_subjects
    apply = local.apply_subjects
  }

  trust_policies = {
    for role, subjects in local.github_trust : role => jsonencode({
      Version = "2012-10-17"
      Statement = concat(
        [{
          Sid       = "GitHubActionsOIDC"
          Effect    = "Allow"
          Principal = { Federated = local.oidc_provider_arn }
          Action    = "sts:AssumeRoleWithWebIdentity"
          Condition = {
            StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
            StringLike   = { "token.actions.githubusercontent.com:sub" = subjects }
          }
        }],
        length(var.extra_trusted_principal_arns) == 0 ? [] : [{
          Sid       = "BreakGlassTesting"
          Effect    = "Allow"
          Principal = { AWS = var.extra_trusted_principal_arns }
          Action    = ["sts:AssumeRole", "sts:TagSession"]
        }],
      )
    })
  }
}

# ---------------------------------------------------------------------------
# Plan role (pull requests)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "plan" {
  name                 = "${var.name}-plan"
  path                 = var.role_path
  description          = "terraform plan from pull requests (read-only)"
  assume_role_policy   = local.trust_policies.plan
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state" {
  name = "terraform-state-lock"
  role = aws_iam_role.plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadState"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetObject"]
        Resource = [var.state_bucket_arn, "${var.state_bucket_arn}/*"]
      },
      {
        Sid      = "LockOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${var.state_bucket_arn}/*.tflock"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Apply role (main branch / protected environment)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "apply" {
  name                 = "${var.name}-apply"
  path                 = var.role_path
  description          = "terraform apply from main (boundary-capped)"
  assume_role_policy   = local.trust_policies.apply
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy" "apply" {
  name = "eks-platform-apply"
  role = aws_iam_role.apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PlatformServices"
        Effect   = "Allow"
        Action   = ["ec2:*", "eks:*", "autoscaling:*", "elasticloadbalancing:*", "logs:*", "cloudwatch:*"]
        Resource = "*"
      },
      {
        Sid    = "ReadOnlySupport"
        Effect = "Allow"
        Action = [
          "iam:Get*", "iam:List*", "kms:Describe*", "kms:List*", "ssm:GetParameter*",
          "sts:GetCallerIdentity", "tag:GetResources", "pricing:GetProducts",
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageWorkloadRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
          "iam:TagRole", "iam:UntagRole", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
        ]
        Resource = [
          local.workload_role_arn_pattern,
          "arn:${local.partition}:iam::${local.account_id}:instance-profile${var.workload_role_path}*",
        ]
      },
      {
        Sid      = "PassWorkloadRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = local.workload_role_arn_pattern
        Condition = {
          StringEquals = { "iam:PassedToService" = ["eks.amazonaws.com", "ec2.amazonaws.com"] }
        }
      },
      {
        Sid      = "ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = [
              "eks.amazonaws.com", "eks-nodegroup.amazonaws.com",
              "autoscaling.amazonaws.com", "elasticloadbalancing.amazonaws.com",
            ]
          }
        }
      },
      {
        Sid      = "StateBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
        Resource = var.state_bucket_arn
      },
      {
        Sid      = "StateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${var.state_bucket_arn}/*"
      },
    ]
  })
}
