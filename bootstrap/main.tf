# One-off bootstrap, applied locally with your own admin credentials:
#   - S3 bucket + DynamoDB table for remote state and locking
#   - GitHub OIDC identity provider (one per account)
#   - an IAM role GitHub Actions assumes for this repository (no access keys)
#
#   cd bootstrap && terraform init && terraform apply -var 'github_repo=Westace10/aws-bedrock-rag-api-terraform'

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "github_repo" {
  description = "owner/repo allowed to assume the deploy role."
  type        = string
}

variable "resource_prefix" {
  description = "Prefix of the IAM roles the pipeline may create (matches var.project in the root module)."
  type        = string
  default     = "rag"
}

variable "create_oidc_provider" {
  description = "Set false if the GitHub OIDC provider already exists in this account (e.g. you bootstrapped another repo first)."
  type        = bool
  default     = true
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  repo_name  = element(split("/", var.github_repo), 1)
}

# ---------------------------------------------------------------------------
# Remote state
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = "tfstate-${local.account_id}-${var.region}-${local.repo_name}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json
}

resource "aws_dynamodb_table" "locks" {
  name         = "tfstate-locks-${local.repo_name}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ---------------------------------------------------------------------------
# GitHub OIDC
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # not used for validation by AWS since 2023, but still required by the API
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only this repository's PRs, main branch and production environment.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:pull_request",
        "repo:${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_repo}:environment:production",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "gh-${local.repo_name}"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

# PowerUserAccess covers every service except IAM ...
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# ... and IAM is limited to roles carrying this project's prefix.
data "aws_iam_policy_document" "scoped_iam" {
  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.resource_prefix}-*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "scoped_iam" {
  name   = "scoped-iam"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.scoped_iam.json
}

output "state_bucket" {
  description = "Remote state bucket (TF_STATE_BUCKET repo variable)."
  value       = aws_s3_bucket.state.bucket
}

output "lock_table" {
  description = "DynamoDB lock table (TF_LOCK_TABLE repo variable)."
  value       = aws_dynamodb_table.locks.name
}

output "deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN GitHub secret."
  value       = aws_iam_role.deploy.arn
}
