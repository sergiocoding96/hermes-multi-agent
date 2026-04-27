param(
  [Parameter(Mandatory = $false)]
  [string]$ScreenpipeUrl = "http://127.0.0.1:3030"
)

$ErrorActionPreference = "Stop"

function Assert-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing dependency: '$name' is not on PATH."
  }
}

Assert-Command "node"

Write-Host ""
Write-Host "============================================================"
Write-Host " Start Screenpipe (local recorder + HTTP API)"
Write-Host "============================================================"
Write-Host " Expected health endpoint: $ScreenpipeUrl/health"
Write-Host ""
Write-Host "Starting:"
Write-Host "  (built) screenpipe.exe record --port 3030"
Write-Host ""
Write-Host "Leave this running. In another terminal, verify:"
Write-Host "  curl.exe $ScreenpipeUrl/health"
Write-Host ""

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) # .../scripts
$repoRoot = Split-Path -Parent $repoRoot                                       # repo root
$upstream = Join-Path $repoRoot "tools\\openclaw-video-skill-pipeline\\vendor\\screenpipe"
$exe = "C:\\_sp\\target\\release\\screenpipe.exe"
$ortDllDir = Join-Path $upstream "apps\\screenpipe-app-tauri\\src-tauri\\onnxruntime-win-x64-1.19.2\\lib"

if (-not (Test-Path $exe)) {
  throw "Missing built Screenpipe exe at: $exe. Build it first: tools/openclaw-video-skill-pipeline/scripts/setup-screenpipe.ps1 -RunProbe"
}

# Ensure ONNX Runtime DLL is discoverable at runtime.
$env:Path = "$ortDllDir;$env:Path"

& $exe record --port 3030

