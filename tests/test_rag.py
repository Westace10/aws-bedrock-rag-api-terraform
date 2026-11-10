import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from rag import (
    build_prompt,
    chunk_text,
    cosine_similarity,
    pack_vector,
    top_k,
    unpack_vector,
    validate_request,
)


def test_chunk_text_respects_size_and_overlap():
    text = ("Sentence number one. " * 200).strip()
    chunks = chunk_text(text, chunk_size=300, overlap=50)
    assert len(chunks) > 1
    assert all(len(c) <= 300 for c in chunks)
    # consecutive chunks overlap
    assert chunks[0][-20:] in chunks[1] or chunks[1][:20] in chunks[0]


def test_chunk_text_empty_and_short():
    assert chunk_text("   ") == []
    assert chunk_text("hello") == ["hello"]


def test_chunk_text_rejects_bad_overlap():
    with pytest.raises(ValueError):
        chunk_text("abc", chunk_size=10, overlap=10)


def test_cosine_similarity():
    assert cosine_similarity([1, 0], [1, 0]) == pytest.approx(1.0)
    assert cosine_similarity([1, 0], [0, 1]) == pytest.approx(0.0)
    assert cosine_similarity([0, 0], [1, 1]) == 0.0


def test_top_k_orders_by_score():
    items = [
        {"id": "a", "embedding": [0, 1]},
        {"id": "b", "embedding": [1, 0]},
        {"id": "c", "embedding": [0.7, 0.7]},
    ]
    result = top_k([1, 0], items, 2)
    assert [r["id"] for r in result] == ["b", "c"]


def test_vector_round_trip():
    vec = [0.25, -0.5, 1.0]
    assert unpack_vector(pack_vector(vec)) == pytest.approx(vec)


@pytest.mark.parametrize(
    "body",
    [{}, {"question": ""}, {"question": "x" * 1001}, {"question": "ok", "top_k": 0}, {"question": "ok", "top_k": "3"}],
)
def test_validate_request_rejects(body):
    with pytest.raises(ValueError):
        validate_request(body)


def test_validate_request_defaults():
    assert validate_request({"question": "  What is X?  "}) == ("What is X?", 4)


def test_build_prompt_numbers_passages():
    prompt = build_prompt("Q?", [{"doc_id": "d", "chunk_id": "00000", "text": "alpha"}])
    assert "[1] (source: d, chunk 00000)" in prompt
    assert prompt.endswith("Question: Q?")
