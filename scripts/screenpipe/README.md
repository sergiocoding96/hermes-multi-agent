# Screenpipe → Skill (wrapper)

This repo does **not** implement the Screenpipe video/trace → SKILL.md pipeline directly.
Instead, it **vendors the workflow** by driving the proven pipeline repo:
`sergiocoding96/openclaw-video-skill-pipeline`.

Goal: run one command, then get a **stable, versioned skill folder** inside *this* repo at:

- `skills/export/<slug>/SKILL.md`

## Prerequisites (Windows)

- **Node.js** >= 18
- **ffmpeg** on PATH
- **Git for Windows (Git Bash)** (required so `npm install` can run upstream `postinstall.sh`)
- **Screenpipe** running and recording (local API default: `http://127.0.0.1:3030`)
- A clone path you can write to: `tools/openclaw-video-skill-pipeline/` (this wrapper creates it)
- **Native build deps (Windows)** (only if you build Screenpipe from source):
  - **CMake** (`cmake.exe` on PATH)
  - **LLVM/Clang** (`libclang.dll` available; often `C:\Program Files\LLVM\bin`)
  - **OpenBLAS headers** (must provide `cblas.h`)

## Environment variables

The upstream pipeline expects a `.env` in its own repo. This wrapper will create it if missing.

Typical keys:

- `GEMINI_API_KEY`
- `OPENAI_API_KEY` (for Whisper transcription in video mode)
- `MINIMAX_API_KEY` (optional unless you want the “compile” phase)
- `SCREENPIPE_URL` (optional; default `http://127.0.0.1:3030`)

## Run (recommended)

From this repo root (PowerShell):

### 0) (If needed) Build Screenpipe from source on Windows

If `npx screenpipe@latest record` doesn’t work on your machine, the upstream pipeline vendors Screenpipe and can build it.

Install missing native deps:

```powershell
winget install -e --id Kitware.CMake --accept-package-agreements --accept-source-agreements
winget install -e --id LLVM.LLVM --accept-package-agreements --accept-source-agreements
```

Install OpenBLAS via `vcpkg` (recommended):

```powershell
git clone https://github.com/microsoft/vcpkg.git $env:USERPROFILE\vcpkg
cd $env:USERPROFILE\vcpkg
.\bootstrap-vcpkg.bat
.\vcpkg.exe install openblas:x64-windows
```

Then in the same terminal:

```powershell
$env:LIBCLANG_PATH = "C:\Program Files\LLVM\bin"
$env:OPENBLAS_ROOT = "$env:USERPROFILE\vcpkg\installed\x64-windows"
```

Now run the upstream build/probe:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\openclaw-video-skill-pipeline\scripts\setup-screenpipe.ps1 -RunProbe
```

### 0) Start Screenpipe (in its own terminal)

```powershell
.\scripts\screenpipe\start-screenpipe.ps1
```

Verify it responds:

```powershell
curl.exe http://127.0.0.1:3030/health
```

### 1) Generate a skill from the last N minutes

```powershell
.\scripts\screenpipe\run-e2e.ps1 -Minutes 5 -NoCompile
```

Outputs:

- Copied skill folder: `skills/export/<slug>/`
- Artifacts (copied): `skills/export/<slug>/artifacts/*`

## Notes

- The upstream pipeline’s end-to-end entry point is:
  - `scripts/e2e-screenpipe-skill.js`
- If you want to run upstream directly, see:
  - `https://github.com/sergiocoding96/openclaw-video-skill-pipeline`

## Windows build + troubleshooting notes

If you need the full Windows “requirements + problems/fixes” writeup for future setups, see:

- `docs/screenpipe/WINDOWS.md`

