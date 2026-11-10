"""Thin wrappers around the AWS SDK so handlers stay small and testable."""

from __future__ import annotations

import json
import os

import boto3
from botocore.config import Config

_cfg = Config(retries={"max_attempts": 5, "mode": "adaptive"})
bedrock = boto3.client("bedrock-runtime", config=_cfg)
s3 = boto3.client("s3", config=_cfg)
table = boto3.resource("dynamodb").Table(os.environ.get("TABLE_NAME", "unset"))

EMBEDDING_MODEL_ID = os.environ.get("EMBEDDING_MODEL_ID", "amazon.titan-embed-text-v2:0")
GENERATION_MODEL_ID = os.environ.get("GENERATION_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")
EMBEDDING_DIMENSIONS = int(os.environ.get("EMBEDDING_DIMENSIONS", "256"))
MAX_OUTPUT_TOKENS = int(os.environ.get("MAX_OUTPUT_TOKENS", "512"))


def embed(text: str) -> list[float]:
    response = bedrock.invoke_model(
        modelId=EMBEDDING_MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=json.dumps({"inputText": text, "dimensions": EMBEDDING_DIMENSIONS, "normalize": True}),
    )
    return json.loads(response["body"].read())["embedding"]


def generate(system_prompt: str, user_prompt: str) -> tuple[str, dict]:
    """Call the model through the Converse API, which works across Bedrock model families."""
    response = bedrock.converse(
        modelId=GENERATION_MODEL_ID,
        system=[{"text": system_prompt}],
        messages=[{"role": "user", "content": [{"text": user_prompt}]}],
        inferenceConfig={"maxTokens": MAX_OUTPUT_TOKENS, "temperature": 0.2},
    )
    text = response["output"]["message"]["content"][0]["text"]
    return text, response.get("usage", {})
