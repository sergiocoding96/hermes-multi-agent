# Screenpipe → Skill on Windows (Hermes repo notes)

This document is the **“everything we learned”** writeup for getting the **vendored Screenpipe build** working on Windows and unblocking the **Screenpipe → Skill** pipeline in `hermes-multi-agent`.

## Goal / success criteria

- **Screenpipe API is reachable** locally:
  - `curl.exe http://127.0.0.1:3030/health` → HTTP `200`
- Run the pipeline from this repo:
  - `.\scripts\screenpipe\run-e2e.ps1 -Minutes 5 -NoCompile`
- Expected output in this repo:
  - `skills/export/<slug>/SKILL.md`

## How the pieces connect (repo wiring)

- **Vendored pipeline** (Node):
  - `tools/openclaw-video-skill-pipeline/`
- **Vendored Screenpipe source** (Rust, built locally on Windows):
  - `tools/openclaw-video-skill-pipeline/vendor/screenpipe/`
- **Hermes repo wrappers** (PowerShell):
  - `scripts/screenpipe/start-screenpipe.ps1` starts Screenpipe recording + HTTP API (port `3030`)
  - `scripts/screenpipe/run-e2e.ps1` runs the upstream pipeline and copies the exported skill back into this repo

## What Screenpipe captures (in this flow)

- **Frames / screen events** are captured and stored locally by Screenpipe while it is running in `record` mode.
- The pipeline queries Screenpipe’s local API for the **last N minutes** and uses an LLM step to produce a **Hermes skill** (`SKILL.md`) plus artifacts.
- Audio capture can be enabled/disabled depending on Screenpipe config; the `/health` payload exposes capture status.

## Requirements (Windows)

### Runtime requirements

- **Node.js** ≥ 18
- **ffmpeg** on `PATH`
- **Git for Windows** (Git Bash is needed so upstream `npm install` can run `postinstall.sh`)

### Build requirements (only if building Screenpipe from source)

Rust + native deps are required because Screenpipe vendors C/C++ libraries and uses CMake + bindgen:

- **Rust toolchain**
  - `cargo` / `rustc` installed (via `rustup`)
- **Visual Studio 2022 Build Tools**
  - MSVC toolchain + Windows SDK (`cl.exe`, `link.exe`, `kernel32.lib`, headers)
- **CMake**
  - required by multiple `*-sys` crates
- **LLVM/Clang**
  - required for `bindgen` via `libclang.dll`
  - `LIBCLANG_PATH` must point to the LLVM `bin` folder
- **OpenBLAS** (via `vcpkg` recommended)
  - provides `cblas.h` headers and `openblas.lib` / `openblas.dll`

## Common failures and the fixes we applied

### 1) `npm install` fails with: `sh is not recognized`

**Cause**
- Upstream repo uses a `postinstall.sh`. Windows `cmd`/PowerShell can’t run `sh` by default.

**Fix**
- `scripts/screenpipe/run-e2e.ps1` runs `npm install` via Git Bash when available.

### 2) Rust build fails because MSVC environment is missing

Symptoms include:
- `link.exe not found`
- missing SDK headers (`stdint.h`, `stdbool.h`)
- `kernel32.lib` not found

**Fix**
- `tools/openclaw-video-skill-pipeline/scripts/setup-screenpipe.ps1` activates the VS dev environment via `VsDevCmd.bat` in-process, so `INCLUDE/LIB/PATH` are populated.

### 3) bindgen fails: `Unable to find libclang`

**Fix**
- Install LLVM and set `LIBCLANG_PATH` to the LLVM `bin` folder (script auto-detects common install paths).

### 4) `antirez-asr-sys` fails: `fatal error C1083: cblas.h`

**Fix**
- Install OpenBLAS via `vcpkg` (`openblas:x64-windows`)
- Ensure `OPENBLAS_ROOT`, `INCLUDE`, and `LIB` are populated (script auto-wires this).

### 5) Linker expects `libopenblas.lib` but vcpkg provides `openblas.lib`

**Fix**
- Script creates a local alias:
  - copies `openblas.lib` → `libopenblas.lib` in the OpenBLAS `lib` directory (if missing).

### 6) Build requires `unzip.exe` (ONNX Runtime extraction) on Windows

**Cause**
- Screenpipe’s `screenpipe-audio` build downloads ONNX Runtime zip and attempted to use `unzip.exe`.

**Fix**
- Patched vendored `vendor/screenpipe/crates/screenpipe-audio/build.rs` to fall back to Windows built-in `tar -xf` if `unzip` is not found.

### 7) Windows path-length / CMake scratch issues

**Fix**
- Use a short build output path:
  - `CARGO_TARGET_DIR=C:\_sp\target`
- Script sets this automatically for the build session.

### 8) Screenpipe builds but won’t start (missing runtime DLLs)

Typical crash: `0xc0000135` (missing DLL), or silent failure.

**Fix**
- Copy runtime DLLs next to the built exe:
  - `onnxruntime.dll`
  - `openblas.dll`
- Also prepend ONNX Runtime folder to `PATH` before launch.

## How to run (Windows)

### 1) Build Screenpipe (vendored) and validate

From repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\openclaw-video-skill-pipeline\scripts\setup-screenpipe.ps1 -RunProbe
```

Expected:
- build completes
- `C:\_sp\target\release\screenpipe.exe` exists

### 2) Start Screenpipe (leave running)

```powershell
.\scripts\screenpipe\start-screenpipe.ps1
```

Verify:

```powershell
curl.exe -v http://127.0.0.1:3030/health
```

### 3) Generate a skill

```powershell
.\scripts\screenpipe\run-e2e.ps1 -Minutes 5 -NoCompile
```

Output:
- `skills/export/<slug>/SKILL.md`

## Logs / artifacts

- `tools/openclaw-video-skill-pipeline/scripts/setup-screenpipe.ps1` writes Screenpipe logs during `-RunProbe` to:
  - `screenpipe-logs/screenpipe.stdout.log`
  - `screenpipe-logs/screenpipe.stderr.log`
- `screenpipe-logs/` is ignored by `.gitignore`.

