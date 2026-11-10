resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name = "${var.project}-${var.environment}"
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Document bucket: upload .txt / .md files under docs/ to ingest them
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "docs" {
  bucket        = "${local.name}-docs-${random_id.suffix.hex}"
  force_destroy = true # lab convenience
}

resource "aws_s3_bucket_versioning" "docs" {
  bucket = aws_s3_bucket.docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "docs_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.docs.arn, "${aws_s3_bucket.docs.arn}/*"]
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

resource "aws_s3_bucket_policy" "docs" {
  bucket = aws_s3_bucket.docs.id
  policy = data.aws_iam_policy_document.docs_tls_only.json
}

resource "aws_s3_bucket_notification" "docs" {
  bucket = aws_s3_bucket.docs.id

  dynamic "lambda_function" {
    for_each = [".txt", ".md"]
    content {
      lambda_function_arn = aws_lambda_function.ingest.arn
      events              = ["s3:ObjectCreated:*"]
      filter_prefix       = "docs/"
      filter_suffix       = lambda_function.value
    }
  }

  depends_on = [aws_lambda_permission.s3_invoke_ingest]
}

# ---------------------------------------------------------------------------
# Chunk and embedding store
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "chunks" {
  name         = "${local.name}-chunks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "doc_id"
  range_key    = "chunk_id"

  attribute {
    name = "doc_id"
    type = "S"
  }

  attribute {
    name = "chunk_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }
}
