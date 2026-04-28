# Screenpipe → Skill: operational status

**Last updated:** 2026-04-28
**Companion:** [`WINDOWS.md`](WINDOWS.md) — install/build pain points and fixes.

This doc captures **what's running, what works, what doesn't,** and the commands you need day-to-day. When something is fixed or upgraded, update the relevant table here.

---

## TL;DR

Screen activity → Screenpipe records to `~/.screenpipe/db.sqlite` and serves an HTTP API on `127.0.0.1:3030`. The pipeline pulls the last N minutes of OCR + frames (and optionally audio + a11y), sends them to Gemini, and writes a `SKILL.md` to `skills/export/<slug>/`. Push to `main` on the upstream pipeline repo auto-publishes the skill to `badass-skills`.

---

## Architecture

```
 desktop activity
       │
       ▼
┌──────────────────┐   port 3030   ┌──────────────────────┐
│  screenpipe.exe  │───/health,    │ live-to-skill.js     │
│  (Rust engine)   │   /search,    │ (5-pass pipeline)    │
│  records OCR +   │   /frames     │                      │
│  audio + a11y    │──────────────▶│  → Gemini analysis   │
└──────────────────┘               │  → MiniMax compile   │
       │                           │  → SKILL.md          │
       ▼                           └──────────────────────┘
 ~/.screenpipe/db.sqlite                    │
                                            ▼
                                  skills/export/<slug>/
                                  (auto-published on push)
```

---

## Pipeline (5 passes)

Defined in `tools/openclaw-video-skill-pipeline/screenpipe/live-to-skill.js`.

| Pass | Input | Tool | Output |
|------|-------|------|--------|
| 1 | Last N min audio | OpenAI Whisper | Time-stamped transcript (skipped if `--disable-audio`) |
| 2 | Last N min frames | Screenpipe `/search` + `/frames` | OCR snapshots + 1 keyframe / 2s |
| 3 | OCR + frames + a11y inventory | Gemini (`gemini-3-flash-preview`) | Workflow JSON: title, summary, steps, decision points |
| 4 | Each step + closest keyframe | Gemini (same model) | Grounded selectors (`find role button --name "X"`) + visual ref |
| 5 | Workflow JSON | Template engine | `SKILL.md` with frontmatter, Setup, Steps, Decision Points |

Followed by a separate **MiniMax compile** pass (`run-screenpipe-compile.js`) that produces a normalized workflow manifest for cross-skill reuse.

---

## Current state (this machine)

| Component | Value | Notes |
|-----------|-------|-------|
| Screenpipe binary | `C:\_sp\target\release\screenpipe.exe` | Built from source via `setup-screenpipe.ps1` |
| Screenpipe version | **0.3.296** | Latest: `0.3.303` on npm. Upgrade path below |
| Default Gemini model | **`gemini-3-flash-preview`** | Bumped from `gemini-2.5-flash` (run 1 → run 2: 0/6 → 3/6 grounded) |
| Audio capture | **disabled** (`--disable-audio`) | Whisper Pass 1 skipped; "Why" lines are inferred |
| UIA / a11y capture | **not active** | `/health` doesn't return `ui_status`; 0 UI snapshots in every run |
| OCR grounding | working | ~50% of action steps grounded via OCR text match |
| Auto-publish workflow | active on push to `main` of `sergiocoding96/openclaw-video-skill-pipeline` | Per commit `1f0653d` in that repo |

---

## Commands

All commands assume **CWD = repo root** (`hermes-multi-agent/`).

### Start Screenpipe (leave running)

```powershell
# Wrapper (sets ONNX DLL path):
.\scripts\screenpipe\start-screenpipe.ps1

# Or direct, with extra debug:
& C:\_sp\target\release\screenpipe.exe record --port 3030 --disable-audio --debug
```

### Verify it's healthy

```powershell
curl.exe http://127.0.0.1:3030/health
```

Expect `status: healthy` + `frame_status: ok`. If the response includes `ui_status`, UIA capture is on; absence of the field means it's off.

### Run the e2e pipeline

```powershell
# Full path (records → Gemini → MiniMax → copy export back into this repo):
.\scripts\screenpipe\run-e2e.ps1 -Minutes 3

# Skip MiniMax compile:
.\scripts\screenpipe\run-e2e.ps1 -Minutes 3 -NoCompile
```

The wrapper:
1. Clones/pulls `tools/openclaw-video-skill-pipeline/` from upstream
2. Runs `npm install` via Git Bash (needed for `sh` postinstall)
3. Invokes `node scripts/e2e-screenpipe-skill.js --minutes <N>`
4. Copies the latest export into `skills/export/<slug>/` of **this** repo

### Run the e2e pipeline directly (faster, skips clone/pull)

```bash
cd tools/openclaw-video-skill-pipeline
npm run e2e:screenpipe -- --minutes 3
```

Output: `tools/openclaw-video-skill-pipeline/skills/export/<slug>/`. **Note:** committing this folder on the openclaw repo's `main` branch triggers auto-publish.

### Build / rebuild Screenpipe from source

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\openclaw-video-skill-pipeline\scripts\setup-screenpipe.ps1 `
  -InstallDeps -RunProbe
```

Sets `CARGO_TARGET_DIR=C:\_sp\target` (short path to dodge CMake path-length failures).

---

## Required env vars

In `tools/openclaw-video-skill-pipeline/.env` (gitignored):

| Key | Required for | Notes |
|-----|--------------|-------|
| `GEMINI_API_KEY` | Gemini analysis Pass 3 + 4 | Verify validity by listing models endpoint |
| `OPENAI_API_KEY` | Whisper Pass 1 | Only needed when audio is enabled |
| `MINIMAX_API_KEY` | MiniMax compile pass | Skip with `--no-compile` if unused |
| `SCREENPIPE_API_KEY` | `--api-auth` mode (Bearer token) | Optional; only if you set `--api-auth` on screenpipe |

---

## Recent fixes (this session)

| Commit | Repo | Fix |
|--------|------|-----|
| `017be2b` | `sergiocoding96/openclaw-video-skill-pipeline` | Default Gemini model → `gemini-3-flash-preview`. README's benchmark-recommended; produces clean role-based selectors. Lifted run 2 from 0/6 to 3/6 grounded. |
| `0695598` | (same) | `buildSelector` handles `action_type === 'navigate'` explicitly, emitting `openclaw browser open "<url>"` instead of falling through to a bogus `find role textbox --name "<url>" fill ""`. |

---

## Known issues / weaknesses

### a11y / UIA capture is not firing
- `/health` returns no `ui_status` field on v0.3.296
- Every run reports `0 UI snapshots`
- The `record` subcommand has **no `--enable-ui-monitoring` flag** in this version (verified via `record --help`)
- Latest source on `main` (~v0.3.303) hardcodes `enable_accessibility: true` as a default in `RecordingSettings`, but the field is marked `#[allow(deprecated)]` — uncertain whether it actually triggers UIA capture or is a vestigial field
- **Result:** all grounding is OCR-only. Selectors fall back to `find text "..."` for elements without role hints. Ceiling per upstream README is ~70%.

### Skill template assumes browser
- `live-to-skill.js` always emits `allowed-tools: browser(*)` and `openclaw browser ...` commands
- Fine for browser tasks; nonsensical for Win32 desktop tasks (a Notepad capture would emit unreachable selectors)
- No `desktop:` codepath exists in the renderer

### Audio narration is missing
- `--disable-audio` skips Whisper Pass 1, so Gemini gets no narration to anchor "why" notes
- "Why" lines are model-inferred from screenshots only — usually plausible, occasionally wrong

### Setup vs Step 1 redundancy on navigate steps
- The Setup block already opens the URL; Step 1 (NAVIGATE) opens it again
- Cosmetic, not blocking — Step 1 still emits valid `browser open "<url>"` after the `0695598` fix

---

## Upgrade path: v0.3.296 → v0.3.303

Goal: see if the deprecated `enable_accessibility: true` actually surfaces UIA snapshots in `/health` and `/search` responses.

**Prebuilt binary path** (recommended, no rebuild):

1. Stop the running Screenpipe (Ctrl+C)
2. Back up the current binary:
   ```powershell
   mv C:\_sp\target\release\screenpipe.exe C:\_sp\target\release\screenpipe-0.3.296.exe
   ```
3. Download + extract the npm tarball:
   ```bash
   curl -o /tmp/sp.tgz https://registry.npmjs.org/@screenpipe/cli-win32-x64/-/cli-win32-x64-0.3.303.tgz
   tar -xzf /tmp/sp.tgz -C /tmp/sp-unpack
   cp /tmp/sp-unpack/package/bin/screenpipe.exe C:\_sp\target\release\screenpipe.exe
   ```
4. Restart with the same command
5. Hit `/health` — if it returns a `ui_status` field, UIA is on. If not, the deprecated field is a no-op and we'd need to investigate further.

**Rollback:**
```powershell
mv C:\_sp\target\release\screenpipe-0.3.296.exe C:\_sp\target\release\screenpipe.exe
```

Build-from-source path: `git pull` in `tools/openclaw-video-skill-pipeline/vendor/screenpipe/`, then re-run `setup-screenpipe.ps1`. Slower (15-30 min) but predictable. Currently the vendor source dir doesn't exist on disk — would need re-cloning first.

---

## Tested workflows

| Date | Task | Skill | Result |
|------|------|-------|--------|
| 2026-04-28 | Notepad: open .env, Ctrl+N, type "test" repeatedly | `populating-notepad-with-repetitive-text` | Broken: 0 grounded, browser-tool template applied to desktop task. Not published. |
| 2026-04-28 | Browser: open onlinenotepad.org, dismiss ad, paste, select all, backspace, type | `testing-text-input-and-word-count-on-online-notepad` | Decent: 3/6 grounded, real selectors for ad-close + textbox, Decision Points block correctly notes the Vignette ad. Published via auto-workflow. |

---

## Reference

- Pipeline repo (upstream): `https://github.com/sergiocoding96/openclaw-video-skill-pipeline`
- Screenpipe repo: `https://github.com/screenpipe/screenpipe`
- Screenpipe npm: `https://www.npmjs.com/package/screenpipe`
- Skill library (auto-publish target): `https://github.com/sergiocoding96/badass-skills`
