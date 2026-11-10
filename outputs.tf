output "api_url" {
  description = "POST {\"question\": \"...\"} to this URL with the x-api-key header."
  value       = "${aws_api_gateway_stage.v1.invoke_url}/ask"
}

output "api_key_id" {
  description = "Read the key value with: aws apigateway get-api-key --api-key <id> --include-value"
  value       = aws_api_gateway_api_key.demo.id
}

output "docs_bucket" {
  description = "Upload .txt or .md files under docs/ to ingest them."
  value       = aws_s3_bucket.docs.bucket
}

output "chunks_table" {
  description = "DynamoDB table holding chunks and embeddings."
  value       = aws_dynamodb_table.chunks.name
}
