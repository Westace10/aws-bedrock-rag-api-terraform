"""Pure helpers for chunking, similarity search and prompt building.

Kept free of AWS calls so they can be unit tested without credentials.
"""

from __future__ import annotations

import math
import re
import struct
from collections.abc import Iterable, Sequence

MAX_QUESTION_CHARS = 1000
MAX_TOP_K = 8


def chunk_text(text: str, chunk_size: int = 1000, overlap: int = 150) -> list[str]:
    """Split text into overlapping chunks, preferring paragraph and sentence boundaries."""
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")
    if not 0 <= overlap < chunk_size:
        raise ValueError("overlap must be >= 0 and smaller than chunk_size")

    text = re.sub(r"[ \t]+", " ", text).strip()
    if not text:
        return []

    chunks: list[str] = []
    start = 0
    while start < len(text):
        end = min(start + chunk_size, len(text))
        if end < len(text):
            # Back off to the last paragraph or sentence break inside the window.
            window = text[start:end]
            cut = max(window.rfind("\n\n"), window.rfind(". "))
            if cut > chunk_size // 2:
                end = start + cut + 1
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= len(text):
            break
        start = max(end - overlap, start + 1)
    return chunks


def cosine_similarity(a: Sequence[float], b: Sequence[float]) -> float:
    if len(a) != len(b):
        raise ValueError("vectors must have the same length")
    dot = sum(x * y for x, y in zip(a, b, strict=True))
    norm = math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b))
    return 0.0 if norm == 0 else dot / norm


def top_k(query: Sequence[float], items: Iterable[dict], k: int) -> list[dict]:
    """Return the k items whose 'embedding' is most similar to query, with a 'score' added."""
    scored = [{**item, "score": cosine_similarity(query, item["embedding"])} for item in items]
    scored.sort(key=lambda i: i["score"], reverse=True)
    return scored[:k]


def pack_vector(vec: Sequence[float]) -> bytes:
    """Store embeddings as float32 bytes: 4 bytes per dimension instead of a JSON list."""
    return struct.pack(f"<{len(vec)}f", *vec)


def unpack_vector(blob: bytes) -> list[float]:
    return list(struct.unpack(f"<{len(blob) // 4}f", blob))


def validate_request(body: dict) -> tuple[str, int]:
    """Validate the /ask payload and return (question, top_k)."""
    question = body.get("question")
    if not isinstance(question, str) or not question.strip():
        raise ValueError("'question' must be a non-empty string")
    if len(question) > MAX_QUESTION_CHARS:
        raise ValueError(f"'question' must be at most {MAX_QUESTION_CHARS} characters")
    k = body.get("top_k", 4)
    if not isinstance(k, int) or not 1 <= k <= MAX_TOP_K:
        raise ValueError(f"'top_k' must be an integer between 1 and {MAX_TOP_K}")
    return question.strip(), k


SYSTEM_PROMPT = (
    "You answer questions using only the context passages provided. "
    "Cite the passages you used as [1], [2] and so on. "
    "If the context does not contain the answer, say you don't know. Do not invent facts."
)


def build_prompt(question: str, passages: list[dict]) -> str:
    context = "\n\n".join(
        f"[{i}] (source: {p['doc_id']}, chunk {p['chunk_id']})\n{p['text']}"
        for i, p in enumerate(passages, start=1)
    )
    return f"Context passages:\n\n{context}\n\nQuestion: {question}"
