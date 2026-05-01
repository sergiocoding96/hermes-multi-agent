# MemOS v1 Hermes Plugin Integration Audit — 2026-04-30

**Scope.** End-to-end audit of the `memos-toolset` Hermes plugin
(`~/.hermes/plugins/memos-toolset/`, v1.0.3) and its boundary with the MemOS
HTTP API at `http://localhost:8001`. The plugin is the *only* path agents
have to MemOS — there is no direct HTTP from agent prompts.

**Marker.** `V1-PI-1777660611` — every memory, cube, and user created
during this audit carries this token.

**Bootstrap.** Two throwaway profiles provisioned under
`/tmp/hermes-v1-pi-1777660611/profiles/{alpha,beta}/.env` (chmod 600), each
backed by a freshly-issued bcrypt-hashed agent key in the running server's
`agents-auth.json`. The audit-prescribed `setup-memos-agents.py` did not
match the documented `--output / --agents` interface, so I provisioned
directly via `memos.mem_user.user_manager.UserManager` (see "Auxiliary
findings"). System teardown (`DELETE FROM users / cubes WHERE … LIKE
'audit-v1-pi%' / 'V1-PI-%'`) is queued for after the report lands.

---

## Summary

| Area | Score | Key finding |
|------|-----:|-------------|
| Tool surface (no admin / no escalation) | 10 | Schema exposes only `content/mode/tags` and `query/top_k`. Override args silently dropped. |
| Identity-from-env enforcement | 10 | `_get_config()` reads env per call; LLM-supplied `user_id` / `cube_id` / `api_key` ignored. |
| Auth header propagation + redaction | 8 | `Authorization: Bearer <raw-key>` over plain HTTP. Bad-key error doesn't echo the client's key back to LLM; no `ak_…` strings found in plugin logs. |
| Agent ↔ MemOS round-trip correctness | 9 | Round-trip works. **Plugin drops `cube_id` from formatted search results** — caller can't verify which cube a memory came from. |
| Auto-capture (v1.0.3) reliability | 8 | Length, `[no-capture]` sentinel, 3-window dedup, durable SQLite retry queue, drain-on-success. Filter for system/tool boilerplate is content-agnostic; relies entirely on the assistant turn being long-form prose. |
| Concurrent-agent isolation | 10 | 20 parallel writes (10 alpha + 10 beta). Server enforces 403 on cross-cube read/write and on `user_id` spoofing under a different bcrypt-authenticated key. |
| CompositeCubeView (CEO) read-only | 6 | Not implemented in *this* plugin (CEO uses Paperclip, not Hermes). Server enforces per-cube ACL, but the plugin never tags returned memories with `cube_id`, so a CEO consuming this plugin's response shape would lose the cube provenance the CompositeCubeView contract requires. |
| Endpoint discovery + URL allowlist | **3** | **No allowlist, no scheme/host validation.** `MEMOS_API_URL=http://attacker:port` causes the plugin to send the raw bearer key to the attacker host. Confirmed by intercepting traffic on a local socket. |
| Plugin reload behaviour | 5 | Module loaded once at `register()`; mid-session edits to `handlers.py` / `auto_capture.py` are not picked up. `.env` *is* re-read per call (good for rotation, bad as an in-process privilege boundary). No documented reload path. |
| Plugin-side logging + secret redaction | 8 | Plugin never `logger`-references `api_key`; the only paths the secret takes are the env, the `Authorization` header, and (transitively) wherever `MEMOS_API_URL` points. |

**Overall plugin-integration score (MIN of the above): 3 / 10.**

The score is dominated by the URL-allowlist gap (PI-001). The rest of the
plugin is well-built: identity is read from env on every call, the LLM
literally has no schema slot for impersonation, and server-side ACL
enforcement is strict (403 on every cross-cube and cross-user attempt).
The demo agents (research-agent, email-marketing-agent, CEO) get correct
and isolated memory access *as long as the profile env is trusted*. They
do not get fully observable access — the plugin's response shape strips
`cube_id`, which weakens any composite view downstream.

---

## Findings

### PI-001 — No `MEMOS_API_URL` allowlist; bearer key exfiltrable to attacker URL  
**Class:** unredacted-secret / discovery-failure (defense-in-depth).  
**Severity:** Medium (file-level write to a profile `.env` is the
prerequisite, but the audit prompt explicitly calls out scheme/host
validation as a needed control).

**Reproducer (T11 in `/tmp/v1-pi-probe.py`).** Listen on an ephemeral
local port, set `MEMOS_API_URL=http://127.0.0.1:<port>` in the alpha
profile env, call `handlers.memos_store({"content": "..."})`. The
plugin sends:

```
POST /product/add HTTP/1.1
Host: 127.0.0.1:<port>
Content-Type: application/json
Authorization: Bearer ak_bb1c4e3a1cc769f6977929d12b252222
…body…
```

The captured request contains the **raw, pre-bcrypt agent key**. The
plugin's `handlers._post()` (`handlers.py:30-53`) accepts any URL via
`MEMOS_API_URL` and calls `urllib.request.urlopen(req, …)` with no host
or scheme validation.

**Impact.** Any process with write access to `~/.hermes/profiles/<agent>/.env`
(or any precursor that sets the env var in the agent's process) can
redirect the bearer to a host of its choosing on the first subsequent
plugin call. The bcrypt-hashed-at-rest design is undone in flight.

**Remediation.** In `handlers._get_config()`, validate `api_url` against
an allowlist (e.g. `{"http://localhost:8001", "http://127.0.0.1:8001"}`)
or at minimum require `urllib.parse.urlparse(url).hostname` ∈
{`localhost`, `127.0.0.1`, configured production host}. Reject mismatches
with a `{"error":"endpoint_not_allowlisted"}` instead of issuing the
request.

---

### PI-002 — `cube_id` stripped from search results returned to LLM  
**Class:** observability gap (silent-coercion-adjacent).  
**Severity:** Low (correctness intact; provenance lost).

**Reproducer (T3, search response from `handlers.memos_search`).**
`MemOS /product/search` returns each memory under a `text_mem[i].cube_id`
bucket and per-memory `metadata.user_id`. The plugin in
`handlers.py:127-149` flattens results into `{rank, content, relevance,
tags, created_at}` and **drops `cube_id` and `metadata.user_id`**.

**Impact.** A CEO orchestrator consuming this plugin's output cannot
honor the project's stated `CompositeCubeView` contract ("results tagged
with `cube_id`"). Any downstream skill that needs to attribute a memory
to its source cube must re-query.

**Remediation.** Include `cube_id` (from the bucket) and
`metadata.user_id` in each formatted entry in
`handlers.memos_search`. ~6 LOC change.

---

### PI-003 — Provisioning script + audit prompt drifted apart  
**Class:** silent-coercion / discovery-failure (operational).  
**Severity:** Low.

The audit prompt (and the plugin's `requires_env` triplet) presupposes a
`deploy/scripts/setup-memos-agents.py` that takes `--output` and
`--agents` flags. The actual script in tree is
`deploy/scripts/setup-memos-agents.py.archived` and:
1. has no CLI flags (it hardcodes `ceo` / `research-agent` /
   `email-marketing-agent`),
2. is marked `.archived` and the plugin ships a `DEPRECATED.md`
   claiming v1.0.3 was archived during a Sprint 2 migration on
   2026-04-20.

Yet `plugin.yaml` is still `version: "1.0.3"`, the plugin is registered
at `~/.hermes/plugins/memos-toolset/`, and the live server is happily
serving requests against it. This is mixed signalling, not a runtime
bug, but anyone reading the audit prompt at face value is going to
write the wrong shell.

**Remediation.** Either un-archive the script and add the prescribed
flags, or update the audit doc and `DEPRECATED.md` to reflect the v1
plugin is the audited surface for the 2026-04-30 re-audit.

---

### PI-004 — Auto-capture filter is content-agnostic past length + sentinel + dedup  
**Class:** capture-loss-adjacent (false-positive direction).  
**Severity:** Low.

`auto_capture.AutoCapture._filter_reason()` (`auto_capture.py:138-152`)
skips only on:
- `< _MIN_CHARS` (50) combined,
- `[no-capture]` (case-insensitive) anywhere in the assistant message,
- exact-content duplicate of the last 3 captures from the same session.

There is no filtering for tool-call boilerplate (`memos_search` results,
shell stdout, etc.) or for system-prompt echo. With the audit's `T2`-style
turns, this is harmless. With a skill that surfaces large tool outputs
into the assistant text, the cube fills up with low-signal noise.

**Remediation.** Document the filter contract in the SKILL.md so skill
authors include `[no-capture]` when they emit boilerplate, or add a
content-shape filter (e.g. skip turns whose assistant text is >X% JSON).

---

### PI-005 — Mid-session env mutation IS picked up; no in-process identity pinning  
**Class:** silent-coercion (configuration).  
**Severity:** Low (acceptable design, but worth flagging).

`handlers._get_config()` reads `os.environ` on every call. Running
alpha → mutating env → running beta in the same Python process flips
the cube boundary on the next call. This is *fine* for a long-lived
agent process whose env never changes — but if a future feature
populates env from less-trusted state, the plugin will follow it without
complaint.

**Remediation.** None required today. If the hub-sync / multi-profile
roadmap ever shares a process across profiles, pin identity at hook /
tool registration time and refuse to re-bind without an explicit
`logout / login`.

---

### PI-006 — Plugin code itself does not hot-reload  
**Class:** discovery-failure (operational).  
**Severity:** Info.

Editing `handlers.py` mid-session leaves the running agent on the
already-imported module (Hermes' loader uses `spec.loader.exec_module`
once at register). Combined with the env-is-re-read-per-call behaviour
above, this is the correct asymmetry for security (you can't swap code
into a running process via filesystem write), but it should be
documented so operators don't expect a deploy to land without a
`hermes restart`.

---

### PI-007 — Shared retry queue across profiles  
**Class:** cross-profile-leak-adjacent.  
**Severity:** Low.

`capture_queue.CaptureQueue._resolve_queue_path()` defaults to
`~/.hermes/plugins/memos-toolset/queue/captures.db` — a single SQLite
file shared across all profiles on the host. Rows are keyed by
`(user_id, cube_id)`, so drains are scoped, but `list_user_cubes()`
returns all distinct pairs, leaking the membership set of profiles to
any caller of the queue API. If two agents on the same host run as the
same OS user (normal), they both have read access.

**Remediation.** Set `MEMOS_QUEUE_PATH` per profile (already supported)
and document it as a *required* setting alongside `MEMOS_API_KEY` in
SOUL.md / the deployment README.

---

## Probe matrix — what was run and what came back

All probe scripts wrote to `/tmp/v1-pi-*.py` (created this session).
Where the script targeted the live MemOS at `localhost:8001`, every
mutation carries the marker `V1-PI-1777660611` and is scoped to
`audit-v1-pi-{alpha,beta}-1777660611` users + `V1-PI-{A,B}-1777660611`
cubes.

| ID | Probe | Result |
|---:|-------|--------|
| T1 | `memos_store(content, user_id=BETA, cube_id=BETA, api_key=BETA)` from alpha env | Stored to **alpha** cube; override args silently dropped (only `content/mode/tags` make it past schema). ✅ |
| T2 | Alpha basic round-trip store | `{"status":"stored","cube":"V1-PI-A-…"}`. ✅ |
| T3 | Alpha search for marker | 3 memories, all alpha. ✅ |
| T4 | Beta search for marker | `count: 0`. ✅ |
| T5 | Beta `memos_store` with override args targeting alpha cube | Stored to **beta** cube; alpha cube untouched (T6 confirms). ✅ |
| T6 | Alpha search after T5 | T5 content not present. ✅ |
| T7 | Bad `MEMOS_API_KEY` | `{"status":"error","error":"HTTP 401","detail":"Invalid or unknown agent key."}`. The bad key string itself is NOT echoed back. ✅ |
| T8 | Drop `MEMOS_API_KEY` / `_USER_ID` / `_CUBE_ID` from env | `{"error":"Missing environment variable: 'MEMOS_API_KEY'"}` (var name, not value). ✅ |
| T9 | `top_k=9999` and `top_k=-5` | Both clamped to `[1,50]` per `handlers.py:105`. ✅ |
| T10 | `MEMOS_API_URL=http://wrong-host-no-such.invalid:8001` | Errors fast (50 ms) with `connection_failed`. ✅ |
| T11 | `MEMOS_API_URL=http://127.0.0.1:<my-listener>` | **Plugin sends raw bearer key to attacker socket. See PI-001.** ❌ |
| AC1 | `post_llm_call(user_message="hi", assistant_response="hello")` | Skipped (`< 50` chars). ✅ |
| AC2 | Normal turn | Captured. ✅ |
| AC3 | Assistant message contains `[no-capture]` | Skipped. ✅ |
| AC4 | Same turn submitted twice | Second skipped (dedup ring of 3 per session). ✅ |
| AC5 | `MEMOS_API_URL=http://127.0.0.1:1` (refused), then restore | Capture enqueued (`size()==1`); next successful capture drains it (`size()==0`). ✅ |
| AC6 | After AC2/AC5, search alpha | Capture present, tagged `auto-capture`. ✅ |
| AC7 | `post_llm_call(…, cube_id=BETA, user_id=BETA)` (caller kwargs) | Hook ignores extra kwargs; identity from env (alpha). ✅ |
| Concurrent | 10 alpha + 10 beta `memos_store` from two subprocesses with disjoint env | All 20 stored; alpha-search returns alpha-only, beta-search returns beta-only (modulo MemReader extracting the word "beta" from alpha's *content*; cube_id provenance via direct DB confirms isolation). ✅ |
| Direct HTTP, alpha key, `readable_cube_ids=[BETA]` | 403 `Access denied: user 'audit-v1-pi-alpha-…' cannot read cube 'V1-PI-B-…'`. ✅ |
| Direct HTTP, alpha key, `writable_cube_ids=[BETA]` | 403 `cannot write to cube 'V1-PI-B-…'`. ✅ |
| Direct HTTP, alpha key, claim `user_id=BETA` | 403 `Key authenticated as 'audit-v1-pi-alpha-…' but request claims user_id='audit-v1-pi-beta-…'. Spoofing not allowed.` ✅ |

---

## Auxiliary findings (not part of probe matrix but worth recording)

- The plugin's `__init__.py:_memos_available()` registers tools only when
  all three env vars are present. An agent without a valid profile
  cleanly degrades to "no memos tools available" rather than hanging or
  exposing a misconfigured surface. ✅
- `register()` instantiates `AutoCapture` once per process and binds it
  via `ctx.register_hook("post_llm_call", …)`. There is no
  `pre_llm_call` or other lifecycle hook — auto-capture is post-only,
  meaning a turn that throws before completing the LLM call doesn't get
  captured. Acceptable.
- The `memos.api.exceptions` server log redacts what looks like
  phone-number patterns, which over-redacts the audit user IDs into
  `audit-v1-pi-alpha-[REDACTED:phone]`. Cosmetic noise; doesn't affect
  the probe.
- `agents-auth.json` is a checked-in file under
  `/home/openclaw/Coding/Hermes/`; bcrypt-hashed keys at rest with
  `key_prefix` for diagnostics. Adding the two audit users
  appended-and-saved with no mutation of existing entries.

---

## Final judgement

The `memos-toolset` plugin enforces the v1 boundary correctly **at the
LLM-input surface** — the schema doesn't expose identity knobs, and the
handlers re-read identity from env on every call. The boundary is also
enforced at the **server-input surface** — bcrypt-keyed authentication,
per-cube ACL, and refusal-to-spoof on `user_id`. All cross-profile
read/write attempts fail with 403, and concurrent isolation holds.

What it doesn't enforce is the **outbound URL boundary**. With a
single env-var flip, the same agent that the rest of the stack
considers identity-pinned will dump its bearer key to whatever URL it
finds in `MEMOS_API_URL`. That's the gap that drags the score from a
solid 8 to a 3 under MIN-aggregation.

The auto-capture path is the right shape: lifecycle hook, env-pinned
identity, durable retry queue, drain-on-success. Its filter is rough
(length + sentinel + dedup), and it relies on skill authors knowing
when to emit `[no-capture]` for boilerplate.

For the demo agents specifically:
- **research-agent** — gets correct, isolated, observable memory
  access *if* `MEMOS_API_URL` is locked down (today: not validated).
- **email-marketing-agent** — same.
- **CEO orchestrator** — does not consume this plugin (Paperclip path).
  The plugin's stripped `cube_id` in search responses would weaken any
  CompositeCubeView consumer that did consume it.

Recommended order of fixes: PI-001 (URL allowlist) → PI-002 (re-include
`cube_id` in search results) → PI-003 (un-archive or rewrite the
provisioning script) → the rest as housekeeping.

---

## Teardown

```
DELETE FROM users  WHERE user_id LIKE 'audit-v1-pi%-1777660611';
DELETE FROM cubes  WHERE cube_id LIKE 'V1-PI-%-1777660611';
DELETE FROM user_cube_association WHERE user_id LIKE 'audit-v1-pi%-1777660611';
rm -rf /tmp/memos-v1-pi-audit-1777660611 /tmp/hermes-v1-pi-1777660611 /tmp/v1-pi-*.py /tmp/v1-pi-queue-1777660611.db
# remove the two audit entries from /home/openclaw/Coding/Hermes/agents-auth.json (audit-v1-pi-alpha/beta-1777660611)
```

(Teardown runs after the report lands; report is the durable artefact.)
