resource "aws_sns_topic" "alarms" {
  name              = "${local.name}-alarms"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  lambda_functions = {
    ingest = aws_lambda_function.ingest.function_name
    query  = aws_lambda_function.query.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.lambda_functions

  alarm_name          = "${local.name}-${each.key}-errors"
  alarm_description   = "${each.key} function errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    FunctionName = each.value
  }
}

resource "aws_cloudwatch_metric_alarm" "ingest_dlq" {
  alarm_name          = "${local.name}-ingest-dlq-not-empty"
  alarm_description   = "Documents failed ingestion and landed in the dead-letter queue"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    QueueName = aws_sqs_queue.ingest_dlq.name
  }
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name}-api-5xx"
  alarm_description   = "API returned 5xx responses"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    ApiName = aws_api_gateway_rest_api.this.name
    Stage   = aws_api_gateway_stage.v1.stage_name
  }
}
