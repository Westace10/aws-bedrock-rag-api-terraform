data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/lambda.zip"
  excludes    = ["__pycache__"]
}

locals {
  bedrock_model_arns = {
    embedding  = "arn:aws:bedrock:${var.region}::foundation-model/${var.embedding_model_id}"
    generation = "arn:aws:bedrock:${var.region}::foundation-model/${var.generation_model_id}"
  }

  common_env = {
    TABLE_NAME           = aws_dynamodb_table.chunks.name
    EMBEDDING_MODEL_ID   = var.embedding_model_id
    GENERATION_MODEL_ID  = var.generation_model_id
    EMBEDDING_DIMENSIONS = tostring(var.embedding_dimensions)
    MAX_OUTPUT_TOKENS    = tostring(var.max_output_tokens)
    LOG_LEVEL            = "INFO"
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Ingest function: one role, only what it needs
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "ingest_dlq" {
  name                      = "${local.name}-ingest-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_iam_role" "ingest" {
  name               = "${local.name}-ingest"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "ingest" {
  statement {
    sid       = "ReadDocs"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.docs.arn}/docs/*"]
  }

  statement {
    sid       = "Embed"
    actions   = ["bedrock:InvokeModel"]
    resources = [local.bedrock_model_arns.embedding]
  }

  statement {
    sid       = "WriteChunks"
    actions   = ["dynamodb:Query", "dynamodb:BatchWriteItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.chunks.arn]
  }

  statement {
    sid       = "DeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ingest_dlq.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingest.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "ingest"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${local.name}-ingest"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "ingest" {
  function_name                  = "${local.name}-ingest"
  role                           = aws_iam_role.ingest.arn
  runtime                        = "python3.12"
  architectures                  = ["arm64"]
  handler                        = "ingest.lambda_handler"
  filename                       = data.archive_file.lambda.output_path
  source_code_hash               = data.archive_file.lambda.output_base64sha256
  timeout                        = 300
  memory_size                    = 512
  reserved_concurrent_executions = var.ingest_reserved_concurrency

  environment {
    variables = local.common_env
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.ingest_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.ingest, aws_iam_role_policy.ingest]
}

resource "aws_lambda_permission" "s3_invoke_ingest" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ingest.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.docs.arn
  source_account = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Query function
# ---------------------------------------------------------------------------

resource "aws_iam_role" "query" {
  name               = "${local.name}-query"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "query" {
  statement {
    sid       = "EmbedAndGenerate"
    actions   = ["bedrock:InvokeModel"]
    resources = values(local.bedrock_model_arns)
  }

  statement {
    sid       = "ReadChunks"
    actions   = ["dynamodb:Scan", "dynamodb:Query", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.chunks.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.query.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "query" {
  name   = "query"
  role   = aws_iam_role.query.id
  policy = data.aws_iam_policy_document.query.json
}

resource "aws_cloudwatch_log_group" "query" {
  name              = "/aws/lambda/${local.name}-query"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "query" {
  function_name                  = "${local.name}-query"
  role                           = aws_iam_role.query.arn
  runtime                        = "python3.12"
  architectures                  = ["arm64"]
  handler                        = "query.lambda_handler"
  filename                       = data.archive_file.lambda.output_path
  source_code_hash               = data.archive_file.lambda.output_base64sha256
  timeout                        = 29 # just under the API Gateway integration limit
  memory_size                    = 512
  reserved_concurrent_executions = var.query_reserved_concurrency

  environment {
    variables = local.common_env
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.query, aws_iam_role_policy.query]
}
