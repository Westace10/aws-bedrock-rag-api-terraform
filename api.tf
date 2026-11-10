# REST API with an API key and usage plan: per-key throttling and a monthly quota
# put a hard ceiling on how many paid model calls the endpoint can make.

resource "aws_api_gateway_rest_api" "this" {
  name        = "${local.name}-api"
  description = "Retrieval-augmented question answering over uploaded documents"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "ask" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "ask"
}

resource "aws_api_gateway_model" "ask" {
  rest_api_id  = aws_api_gateway_rest_api.this.id
  name         = "AskRequest"
  content_type = "application/json"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    type      = "object"
    required  = ["question"]
    properties = {
      question = { type = "string", minLength = 1, maxLength = 1000 }
      top_k    = { type = "integer", minimum = 1, maximum = 8 }
    }
    additionalProperties = false
  })
}

resource "aws_api_gateway_request_validator" "body" {
  rest_api_id           = aws_api_gateway_rest_api.this.id
  name                  = "validate-body"
  validate_request_body = true
}

resource "aws_api_gateway_method" "ask_post" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = aws_api_gateway_resource.ask.id
  http_method          = "POST"
  authorization        = "NONE"
  api_key_required     = true
  request_validator_id = aws_api_gateway_request_validator.body.id

  request_models = {
    "application/json" = aws_api_gateway_model.ask.name
  }
}

resource "aws_api_gateway_integration" "ask_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.ask.id
  http_method             = aws_api_gateway_method.ask_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.query.invoke_arn
}

resource "aws_lambda_permission" "apigw_invoke_query" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/ask"
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.ask.id,
      aws_api_gateway_method.ask_post.id,
      aws_api_gateway_integration.ask_post.id,
      aws_api_gateway_model.ask.schema,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Account-level setting that lets API Gateway write access logs to CloudWatch.
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_logs" {
  name               = "${local.name}-apigw-logs"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
}

resource "aws_iam_role_policy_attachment" "apigw_logs" {
  role       = aws_iam_role.apigw_logs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.apigw_logs.arn
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name}-api/access"
  retention_in_days = var.log_retention_days
}

resource "aws_api_gateway_stage" "v1" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  deployment_id        = aws_api_gateway_deployment.this.id
  stage_name           = "v1"
  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      apiKeyId       = "$context.identity.apiKeyId"
      method         = "$context.httpMethod"
      path           = "$context.resourcePath"
      status         = "$context.status"
      latencyMs      = "$context.responseLatency"
      integrationErr = "$context.integration.error"
    })
  }

  depends_on = [aws_api_gateway_account.this]
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.v1.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "ERROR"
    throttling_rate_limit  = 20
    throttling_burst_limit = 40
  }
}

resource "aws_api_gateway_usage_plan" "default" {
  name = "${local.name}-default"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.v1.stage_name
  }

  throttle_settings {
    rate_limit  = var.api_rate_limit
    burst_limit = var.api_rate_limit * 2
  }

  quota_settings {
    limit  = var.api_monthly_quota
    period = "MONTH"
  }
}

resource "aws_api_gateway_api_key" "demo" {
  name = "${local.name}-demo-key"
}

resource "aws_api_gateway_usage_plan_key" "demo" {
  key_id        = aws_api_gateway_api_key.demo.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.default.id
}
