# TASK: feat/fast-mode-chunking — chunk long content in fast mode

## Goal
`async_mode=sync, mode=fast` with long content should produce multiple chunked memory items (one per ~500-token chunk) rather than a single giant-embedding memory.

## Context
From [blind-audit-report.md § 5a](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/tests/blind-audit-report.md):
> Fast mode stores the entire content as a SINGLE memory regardless of length. No chunking. For very long texts this means semantic search quality degrades since the whole document is one embedding.

CLAUDE.md already instructs skills to chunk to ≤500 words before POSTing — but that's a client-side hack. The server should handle this itself. Fast mode is supposed to be "raw mode" for speed; chunking doesn't require an LLM, so it stays cheap.

Fine mode is not in scope here — it already does per-fact extraction via DeepSeek and is correctly handled.

## Files
- `src/memos/api/handlers/add_handler.py` — the fast-mode path

## Acceptance
- [ ] Content ≤ ~1000 tokens: single memory (unchanged behavior).
- [ ] Content > ~1000 tokens: split into overlapping chunks of ~500 tokens with ~50-token overlap. Each chunk becomes its own `TextualMemoryItem`.
- [ ] Chunks preserve order: attach `chunk_index` and `chunk_total` to each memory's metadata/info so they can be reassembled.
- [ ] Timestamp prefix (`user: [HH:MM on DD Month, YYYY]:`) appears on the FIRST chunk only (or a consistent scheme — document the choice in code).
- [ ] Write-time dedup still works: writing the same long doc twice should produce 0 new memories (dedup catches every chunk).
- [ ] Semantic search over a 5000-word doc can retrieve the chunk containing a specific sentence near the end (previously impossible — single embedding washed out late content).
- [ ] Chunk size is env-configurable: `MOS_FAST_CHUNK_TOKENS` (default 500), `MOS_FAST_CHUNK_OVERLAP_TOKENS` (default 50).

## Approach
Use a tiny tokenizer for chunking. Options:
1. `tiktoken` (if already imported elsewhere for the embedder) — fast, accurate for OpenAI-style tokens.
2. Plain character-based proxy (1 token ≈ 4 chars for English). Cheaper, "good enough" for fast mode.

Pick one, document why. Split on paragraph boundaries first, fall back to sentence, finally by token count.

## Test plan (isolated)
```bash
USER=audit-chunking-user
CUBE=audit-chunking-cube
KEY=<key>

# 1. Short content — expect 1 memory:
curl -sS -X POST http://localhost:8001/product/add \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER\",\"writable_cube_ids\":[\"$CUBE\"],\"messages\":[{\"role\":\"user\",\"content\":\"Short note about Paris.\"}],\"async_mode\":\"sync\",\"mode\":\"fast\"}" \
  | jq '.data | length'
# expect: 1

# 2. Long content — expect multiple memories:
LONG=$(python3 -c "print(' '.join(['para-$i The quick brown fox jumps over the lazy dog.'] * 300))")
curl -sS -X POST http://localhost:8001/product/add \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER\",\"writable_cube_ids\":[\"$CUBE\"],\"messages\":[{\"role\":\"user\",\"content\":\"$LONG\"}],\"async_mode\":\"sync\",\"mode\":\"fast\"}" \
  | jq '.data | length, (.[0] | {chunk_index, chunk_total})'
# expect: count > 1, chunk_index/chunk_total present

# 3. Retrieval of late content:
# Compose a doc where a unique needle sits near the end (e.g. word "SPECIAL-MARKER-XYZ").
# Write it in fast mode. Search for "SPECIAL-MARKER-XYZ" — must find it.
```

## Out of scope
- Don't chunk in fine mode. Fine mode is already per-fact extraction.
- Don't implement semantic paragraph chunking with NLP. Simple token-based is enough for fast mode.

## Commit / PR
Branch: `feat/fast-mode-chunking`
PR title suggestion: `feat(add): chunk long content in fast mode (~500 token chunks, 50 overlap)`
