param(
  [Parameter(Mandatory = $false)]
  [int]$Minutes = 5,

  [Parameter(Mandatory = $false)]
  [string]$ExportSlug = "",

  [Parameter(Mandatory = $false)]
  [switch]$NoCompile,

  [Parameter(Mandatory = $false)]
  [string]$PipelineDir = "tools/openclaw-video-skill-pipeline"
)

$ErrorActionPreference = "Stop"

$ScriptVersion = "2026-04-26.3"

function Assert-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing dependency: '$name' is not on PATH."
  }
}

function Find-GitBash {
  $candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe",
    "$env:ProgramFiles(x86)\Git\bin\bash.exe",
    "$env:ProgramFiles(x86)\Git\usr\bin\bash.exe"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  $cmd = Get-Command bash -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Ensure-Dir($p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) # .../scripts
$RepoRoot = Split-Path -Parent $RepoRoot                                       # repo root

Write-Host ""
Write-Host "============================================================"
Write-Host " E2E Screenpipe -> SKILL.md (via openclaw-video-skill-pipeline)"
Write-Host "============================================================"
Write-Host " Script ver:  $ScriptVersion"
Write-Host " Repo root:   $RepoRoot"
Write-Host " Minutes:     $Minutes"
Write-Host " ExportSlug:  $ExportSlug"
Write-Host " NoCompile:   $NoCompile"
Write-Host " PipelineDir: $PipelineDir"
Write-Host ""

Assert-Command "git"
Assert-Command "node"
Assert-Command "npm"
Assert-Command "ffmpeg"

$PipelinePath = Join-Path $RepoRoot $PipelineDir
Ensure-Dir (Split-Path -Parent $PipelinePath)

if (-not (Test-Path (Join-Path $PipelinePath "package.json"))) {
  Write-Host "Cloning pipeline repo into $PipelinePath ..."
  git clone https://github.com/sergiocoding96/openclaw-video-skill-pipeline.git $PipelinePath
} else {
  Write-Host "Updating pipeline repo (git pull) ..."
  Push-Location $PipelinePath
  try { git pull } finally { Pop-Location }
}

# Ensure upstream .env exists (but do not overwrite; user must fill keys)
$UpstreamEnv = Join-Path $PipelinePath ".env"
$UpstreamEnvExample = Join-Path $PipelinePath ".env.example"
if (-not (Test-Path $UpstreamEnv)) {
  if (-not (Test-Path $UpstreamEnvExample)) {
    throw "Upstream .env.example missing at $UpstreamEnvExample"
  }
  Copy-Item $UpstreamEnvExample $UpstreamEnv
  Write-Host ""
  Write-Host "Created upstream .env from .env.example:"
  Write-Host "  $UpstreamEnv"
  Write-Host "Fill GEMINI_API_KEY (and MINIMAX_API_KEY if compiling), then re-run."
  throw "Missing API keys in upstream .env (created template)."
}

Write-Host "Installing pipeline dependencies (npm install) ..."
# On Windows, the upstream dependency `screenpipe` runs a `postinstall.sh`.
# If `sh` isn't available, plain `npm install` fails. Prefer running install via Git Bash.
$bash = Find-GitBash
if ($bash) {
  Write-Host "Using bash for npm install: $bash"
  # Avoid PowerShell quoting pitfalls by passing the path via env var.
  $pipelineUnix = ($PipelinePath -replace '\\','/')
  $old = $env:PIPELINE_DIR
  $env:PIPELINE_DIR = $pipelineUnix
  try {
    & $bash -lc 'cd "$PIPELINE_DIR" && npm install'
    if ($LASTEXITCODE -ne 0) { throw "npm install failed (bash) with exit code $LASTEXITCODE" }
  } finally {
    if ($null -ne $old) { $env:PIPELINE_DIR = $old } else { Remove-Item Env:PIPELINE_DIR -ErrorAction SilentlyContinue }
  }
  if ($LASTEXITCODE -ne 0) { throw "npm install failed (bash) with exit code $LASTEXITCODE" }
} else {
  Write-Host ""
  Write-Host "ERROR: Git Bash (bash.exe) not found, and upstream needs 'sh' for npm postinstall."
  Write-Host "Fix options:"
  Write-Host "  - Install Git for Windows (includes Git Bash): https://git-scm.com/download/win"
  Write-Host "  - OR run this flow inside WSL where bash/sh exists"
  Write-Host ""
  throw "Cannot run npm install: missing bash/sh environment."
}

$Args = @("scripts/e2e-screenpipe-skill.js", "--minutes", "$Minutes")
if ($NoCompile) { $Args += "--no-compile" }
if ($ExportSlug -and $ExportSlug.Trim().Length -gt 0) { $Args += @("--export-slug", $ExportSlug.Trim()) }

Write-Host ""
Write-Host "Running upstream E2E pipeline:"
Write-Host "  node $($Args -join ' ')"
Write-Host ""

Push-Location $PipelinePath
try {
  & node @Args
  if ($LASTEXITCODE -ne 0) { throw "Upstream pipeline failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}

# Copy exported skill folder from upstream -> this repo
$UpstreamExportRoot = Join-Path $PipelinePath "skills/export"
if (-not (Test-Path $UpstreamExportRoot)) {
  throw "Upstream export root missing: $UpstreamExportRoot"
}

$ExportDirs = Get-ChildItem -Path $UpstreamExportRoot -Directory | Sort-Object LastWriteTime -Descending
if ($ExportDirs.Count -eq 0) {
  throw "No exported skill directories found under: $UpstreamExportRoot"
}

$Latest = $ExportDirs[0].FullName
$Slug = Split-Path -Leaf $Latest
$DestRoot = Join-Path $RepoRoot "skills/export"
$Dest = Join-Path $DestRoot $Slug
Ensure-Dir $DestRoot

Write-Host ""
Write-Host "Copying exported skill into this repo:"
Write-Host "  From: $Latest"
Write-Host "  To:   $Dest"

if (Test-Path $Dest) {
  Write-Host "  Destination already exists; removing it first to avoid stale files."
  Remove-Item -Recurse -Force $Dest
}

Copy-Item -Recurse -Force $Latest $Dest

$SkillMd = Join-Path $Dest "SKILL.md"
if (-not (Test-Path $SkillMd)) {
  throw "Copied skill missing SKILL.md at: $SkillMd"
}

Write-Host ""
Write-Host "DONE."
Write-Host "Skill is now in this repo at:"
Write-Host "  skills/export/$Slug"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  - Review SKILL.md"
Write-Host "  - git add skills/export/$Slug"
Write-Host "  - git commit -m \"add screenpipe skill: $Slug\""

