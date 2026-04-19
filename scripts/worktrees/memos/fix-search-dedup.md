# TASK: fix/search-dedup — make dedup modes actually dedup

## Goal
`POST /product/search` with `dedup: "no" | "sim" | "mmr"` should produce materially different result sets on a near-duplicate corpus.

## Context
From [blind-audit-report.md § 3f + Bug 4](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/tests/blind-audit-report.md):
> All 4 modes (null, no, sim, mmr) returned identical result counts and identical results. The search-time dedup modes appear non-functional.

Write-time dedup (cosine ≥ 0.90) already works and is tuned via `MOS_MMR_TEXT_THRESHOLD=0.85` / `MOS_MMR_PENALTY_THRESHOLD=0.70` (see [PATCHES.md](https://github.com/sergiocoding96/MemOS/blob/main/PATCHES.md)). But the **search-time** dedup parameter is documented, accepted, and does nothing.

## Files
- `src/memos/api/handlers/search_handler.py`

## Acceptance
- [ ] `dedup="no"` returns raw top-K without filtering (baseline).
- [ ] `dedup="sim"` filters pairwise: skip candidate if cosine similarity ≥ `MOS_MMR_TEXT_THRESHOLD` to any already-selected result.
- [ ] `dedup="mmr"` uses Maximal Marginal Relevance: score each candidate by `λ * rel(q) - (1-λ) * max_sim(selected)`, default λ=0.7. Apply exponential penalty when max_sim > `MOS_MMR_PENALTY_THRESHOLD`.
- [ ] On a corpus with 5 near-identical sentences + 5 distinct sentences (top_k=10, threshold=0.85):
  - `no` → 10 results including all 5 near-dupes
  - `sim` → ≤6 results (at most 1 from the dupe cluster)
  - `mmr` → ≤7 results, with MMR ordering visibly different from `sim`
- [ ] Default behavior (no `dedup` param) unchanged — whatever it is today, stays.
- [ ] Deterministic: two identical requests return identical ordering.

## Approach
The expansion factor `MOS_SEARCH_TOP_K_FACTOR=5` already overfetches before MMR. The problem is the dedup step is probably a no-op stub. Find the stub, implement the three branches.

For `sim`: simple set filter using embeddings already in the search pipeline.
For `mmr`: standard MMR loop.
Both use the cosine similarity function already in the vec_dbs layer — don't re-implement.

## Test plan (isolated)
```bash
USER=audit-dedup-user
CUBE=audit-dedup-cube
KEY=<key>

# 1. Seed the cube:
NEAR_DUPES=(
  "The Pacific Ocean covers about 46% of Earth's water surface."
  "The Pacific Ocean covers approximately 46% of Earth's water surface."
  "The Pacific Ocean covers roughly 46% of the Earth's surface water."
  "About 46% of Earth's water is the Pacific Ocean."
  "The Pacific is 46% of Earth's ocean water."
)
DISTINCT=(
  "Mount Everest is 8848 meters tall."
  "Python was created by Guido van Rossum."
  "The French Revolution began in 1789."
  "Whales are mammals, not fish."
  "The speed of light is about 300000 km/s."
)
for s in "${NEAR_DUPES[@]}" "${DISTINCT[@]}"; do
  curl -sS -X POST http://localhost:8001/product/add \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"$USER\",\"writable_cube_ids\":[\"$CUBE\"],\"messages\":[{\"role\":\"user\",\"content\":\"$s\"}],\"async_mode\":\"sync\",\"mode\":\"fast\"}" > /dev/null
done

# IMPORTANT: write-time dedup will eat some near-dupes. Lower MOS_MMR_TEXT_THRESHOLD temporarily
# or use slightly less similar seed sentences so all 10 land in the cube first.

# 2. Query each mode:
for mode in no sim mmr; do
  echo "=== dedup=$mode ==="
  curl -sS -X POST http://localhost:8001/product/search \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"query\":\"Pacific ocean\",\"user_id\":\"$USER\",\"top_k\":10,\"dedup\":\"$mode\"}" \
    | jq '.data | length, (.[] | .content[:60])'
done
```

Expected: `no` returns 10 results, `sim` ≤6, `mmr` ≤7 with different ordering than `sim`.

## Out of scope
- Don't touch write-time dedup (`single_cube.py`). That works.
- Don't change default thresholds — they're already tuned via env vars.

## Commit / PR
Branch: `fix/search-dedup`
PR title suggestion: `fix(search): implement sim and mmr dedup modes (were no-op)`
