# TODO — Hermes Multi-Agent System

## Phase 1: Infrastructure (Current)
- [x] Research skills created (research-coordinator, social-media, code, academic, market-intelligence, hn-research, web-research)
- [x] Firecrawl configured (localhost:3002, NUM_WORKERS=4)
- [x] Hermes FIRECRAWL_API_URL set
- [x] MemOS architecture decisions finalized (TreeText+Fine everywhere)
- [x] PROJECT-STATE recovery document created
- [ ] Write MemOS provisioning script (`setup-memos-agents.py`) — users, cubes, CEO shares
- [ ] Configure MemOS `.env` for MiniMax (embedder, MEMRADER, chat model)
- [ ] Start MemOS server and verify add/search work
- [ ] Verify Neo4j (bolt://localhost:7687) and Qdrant (localhost:6333) are healthy

## Phase 2: Agent Implementation
- [ ] Install `hermes-paperclip-adapter` in Paperclip adapter registry
- [ ] Write CEO SOUL.md with feedback loop logic (soft + hard)
- [ ] Add `quality_score` self-eval to `research-coordinator` SKILL.md
- [ ] Add MemOS dual-write (POST /product/add) to research-coordinator output step
- [ ] Create `email-marketing-plusvibe` Hermes skill (plusvibe.ai email marketing)
- [ ] Add MemOS dual-write to email-marketing skill

## Phase 3: Testing & Self-Improvement
- [ ] Test MemOS infrastructure end-to-end (write, search, cross-cube CEO search)
- [ ] Test research agent with MemOS dual-write
- [ ] Test email-marketing agent end-to-end
- [ ] Run hard feedback loop: score research output, auto-patch if below threshold
- [ ] Run soft feedback loop: user feedback → CEO skill patch
- [ ] Verify skill self-improvement: confirm skill_manage(patch) works with MiniMax M2.7

## Phase 4: Production Readiness
- [ ] Add error handling to MemOS writes (retry on 500, timeout on sync)
- [ ] Add MemOS health check to CEO HEARTBEAT
- [ ] Monitor Qdrant/Neo4j resource usage under sustained agent load
- [ ] Document runbook for starting full stack (Neo4j → Qdrant → MemOS → Firecrawl → Hermes → Paperclip)
