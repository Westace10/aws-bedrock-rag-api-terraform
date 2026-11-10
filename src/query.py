"""POST /ask {"question": "...", "top_k": 4} -> grounded answer with cited sources."""

from __future__ import annotations

import json
import logging
import os
import time

import clients
from rag import SYSTEM_PROMPT, build_prompt, top_k, unpack_vector, validate_request

log = logging.getLogger()
log.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

MAX_ITEMS_SCANNED = int(os.environ.get("MAX_ITEMS_SCANNED", "5000"))


def _load_chunks():
    """Demo-scale retrieval: scan the table and rank in memory.

    Fine for a few thousand chunks. For production volumes, swap this for a vector
    store (OpenSearch Serverless, Aurora pgvector or S3 Vectors) behind the same interface.
    """
    items, kwargs = [], {}
    while len(items) < MAX_ITEMS_SCANNED:
        page = clients.table.scan(**kwargs)
        for it in page.get("Items", []):
            items.append(
                {
                    "doc_id": it["doc_id"],
                    "chunk_id": it["chunk_id"],
                    "text": it["text"],
                    "embedding": unpack_vector(bytes(it["embedding"])),
                }
            )
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
    return items


def _response(status: int, body: dict):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, _context):
    started = time.time()
    try:
        payload = json.loads(event.get("body") or "{}")
        question, k = validate_request(payload)
    except (ValueError, json.JSONDecodeError) as exc:
        return _response(400, {"error": str(exc)})

    query_vec = clients.embed(question)
    passages = top_k(query_vec, _load_chunks(), k)
    if not passages:
        return _response(200, {"answer": "No documents have been ingested yet.", "sources": []})

    answer, usage = clients.generate(SYSTEM_PROMPT, build_prompt(question, passages))

    log.info(
        json.dumps(
            {
                "event": "answered",
                "latency_ms": int((time.time() - started) * 1000),
                "input_tokens": usage.get("inputTokens"),
                "output_tokens": usage.get("outputTokens"),
                "top_score": round(passages[0]["score"], 4),
            }
        )
    )

    return _response(
        200,
        {
            "answer": answer,
            "sources": [
                {"ref": i, "doc_id": p["doc_id"], "chunk_id": p["chunk_id"], "score": round(p["score"], 4)}
                for i, p in enumerate(passages, start=1)
            ],
        },
    )
