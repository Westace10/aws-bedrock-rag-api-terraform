"""S3 ObjectCreated -> chunk -> embed with Bedrock -> store in DynamoDB."""

from __future__ import annotations

import json
import logging
import os
import urllib.parse

from boto3.dynamodb.conditions import Key

import clients
from rag import chunk_text, pack_vector

log = logging.getLogger()
log.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

MAX_CHUNKS_PER_DOC = int(os.environ.get("MAX_CHUNKS_PER_DOC", "200"))  # cost guard


def _delete_existing(doc_id: str) -> None:
    """Re-ingesting a document replaces its chunks rather than duplicating them."""
    resp = clients.table.query(KeyConditionExpression=Key("doc_id").eq(doc_id), ProjectionExpression="doc_id, chunk_id")
    with clients.table.batch_writer() as batch:
        for item in resp.get("Items", []):
            batch.delete_item(Key={"doc_id": item["doc_id"], "chunk_id": item["chunk_id"]})


def lambda_handler(event, _context):
    processed = []
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        body = clients.s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8", errors="replace")
        chunks = chunk_text(body)[:MAX_CHUNKS_PER_DOC]

        _delete_existing(key)
        with clients.table.batch_writer() as batch:
            for i, chunk in enumerate(chunks):
                batch.put_item(
                    Item={
                        "doc_id": key,
                        "chunk_id": f"{i:05d}",
                        "text": chunk,
                        "embedding": pack_vector(clients.embed(chunk)),
                    }
                )

        log.info(json.dumps({"event": "ingested", "doc_id": key, "chunks": len(chunks)}))
        processed.append({"doc_id": key, "chunks": len(chunks)})

    return {"processed": processed}
