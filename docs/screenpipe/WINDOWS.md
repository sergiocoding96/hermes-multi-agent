# Screenpipe → Skill on Windows (repo knowledge base)

This doc collects the **requirements, failure modes, and fixes** needed to keep the Screenpipe → Skill pipeline working on Windows in this repo.

## Success criteria

- Screenpipe API healthy:
  - `curl.exe http://127.0.0.1:3030/health` → `200`
- Generate a skill:
  - `.\scripts\screenpipe\run-e2e.ps1 -Minutes 5 -NoCompile`
- Output:
  - `skills/export/<slug>/SKILL.md`

## How it connects to this repo

- Vendored pipeline repo (Node): `tools/openclaw-video-skill-pipeline/`
- Vendored Screenpipe source (Rust): `tools/openclaw-video-skill-pipeline/vendor/screenpipe/`
- Hermes wrappers:
  - `scripts/screenpipe/start-screenpipe.ps1` (starts Screenpipe for Windows)
  - `scripts/screenpipe/run-e2e.ps1` (runs pipeline + copies exported skill back into this repo)

## What Screenpipe captures

- Runs in **record mode** and captures screen activity as frames/events.
- Persists captured data locally and exposes an HTTP API (`127.0.0.1:3030`) so the pipeline can query the last N minutes and synthesize a Hermes skill.
- `/health` includes details like monitors, frames captured/db-written, last timestamps, and whether audio capture is enabled.

## Windows requirements

### Runtime (always needed)
- Node.js ≥ 18
- ffmpeg on PATH
- Git for Windows (Git Bash is required so upstream `npm install` can run `postinstall.sh`)

### Build (only if building Screenpipe from source)
- Rust (cargo/rustc via rustup)
- Visual Studio 2022 Build Tools (MSVC + Windows SDK)
- CMake
- LLVM/Clang (for bindgen: `libclang.dll`, set `LIBCLANG_PATH`)
- OpenBLAS (via vcpkg recommended)

## Problems we hit and the fixes

### A) `npm install` fails: `sh` is not recognized
**Fix**: Run `npm install` via Git Bash (handled by `scripts/screenpipe/run-e2e.ps1`).

### B) `link.exe` / Windows SDK libs missing (`kernel32.lib`, headers)
**Fix**: Activate VS dev environment via `VsDevCmd.bat` (handled by `tools/openclaw-video-skill-pipeline/scripts/setup-screenpipe.ps1`).

### C) bindgen can’t find `libclang`
**Fix**: Install LLVM and set `LIBCLANG_PATH` to the LLVM `bin` directory (script auto-detects common paths).

### D) OpenBLAS headers missing (`cblas.h`) or libs not found
**Fix**: Install OpenBLAS with vcpkg and wire `OPENBLAS_ROOT`, `INCLUDE`, `LIB` (script auto-wires this).

### E) Linker expects `libopenblas.lib` but vcpkg ships `openblas.lib`
**Fix**: Script creates an alias copy: `openblas.lib` → `libopenblas.lib` (if missing).

### F) `unzip.exe` missing for ONNX Runtime extraction
**Fix**: Vendored `screenpipe-audio` build uses `tar -xf` fallback when `unzip` is not available.

### G) Windows path-length issues during cmake builds
**Fix**: Use a short cargo target dir:
- `CARGO_TARGET_DIR=C:\_sp\target` (set by setup script)

### H) Screenpipe builds but won’t start (missing runtime DLLs)
**Fix**: Copy runtime DLLs next to `screenpipe.exe`:
- `onnxruntime.dll`
- `openblas.dll`

## How to run (Windows)

### 1) Build + validate Screenpipe (vendored)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\openclaw-video-skill-pipeline\scripts\setup-screenpipe.ps1 -RunProbe
```

### 2) Start Screenpipe (leave running)

```powershell
.\scripts\screenpipe\start-screenpipe.ps1
```

Verify:

```powershell
curl.exe http://127.0.0.1:3030/health
```

### 3) Generate a skill

```powershell
.\scripts\screenpipe\run-e2e.ps1 -Minutes 5 -NoCompile
```

