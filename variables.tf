variable "region" {
  description = "AWS region. Both Bedrock models must be enabled in this region."
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Project name (also the prefix of the IAM roles the pipeline may manage)."
  type        = string
  default     = "rag"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "alert_email" {
  description = "Email for alarms. Leave null to skip the subscription."
  type        = string
  default     = null
}

variable "embedding_model_id" {
  description = "Bedrock embedding model."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "generation_model_id" {
  description = "Bedrock text model used through the Converse API."
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

variable "embedding_dimensions" {
  description = "Titan v2 output size: 256, 512 or 1024."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024], var.embedding_dimensions)
    error_message = "embedding_dimensions must be 256, 512 or 1024."
  }
}

variable "max_output_tokens" {
  description = "Cap on generated tokens per answer (cost control)."
  type        = number
  default     = 512
}

variable "api_monthly_quota" {
  description = "Requests per month allowed per API key."
  type        = number
  default     = 1000
}

variable "api_rate_limit" {
  description = "Steady-state requests per second per API key."
  type        = number
  default     = 5
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
  default     = 14
}

# New AWS accounts often have an account concurrency limit of 10, which leaves no room
# to reserve. Set these (e.g. 2 and 5) once your limit is raised, to cap Bedrock spend.
variable "ingest_reserved_concurrency" {
  description = "Reserved concurrency for the ingest function (-1 = unreserved)."
  type        = number
  default     = -1
}

variable "query_reserved_concurrency" {
  description = "Reserved concurrency for the query function (-1 = unreserved)."
  type        = number
  default     = -1
}
