<#
.SYNOPSIS
  Install the modernization security review skills.

.DESCRIPTION
  Copies the three skill folders into a Claude Code skills directory. There is nothing to build and
  nothing to fetch - the skills are Markdown and static assets. This script only copies files.

.PARAMETER Scope
  user    ~/.claude/skills          available in every project on this machine (default)
  project <target>/.claude/skills   available in one project only

.PARAMETER Target
  The project directory, when -Scope project. Defaults to the current directory.

.PARAMETER Force
  Overwrite an existing installation without asking.

.EXAMPLE
  .\install.ps1
  .\install.ps1 -Scope project -Target C:\src\acme
  .\install.ps1 -Force
#>
[CmdletBinding()]
param(
  [ValidateSet('user', 'project')] [string] $Scope  = 'user',
  [string] $Target = (Get-Location).Path,
  [switch] $Force
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$skills = @('security-audit', 'security-audit-compare', 'security-code-review')

# Verify the source tree is complete before touching the destination, so a partial copy is not
# possible: a half-installed skill fails in ways that are much harder to diagnose than a refusal.
foreach ($s in $skills) {
  $src = Join-Path $here $s
  if (-not (Test-Path $src)) { throw "Source folder not found: $src" }
  if (-not (Test-Path (Join-Path $src 'SKILL.md'))) { throw "Not a skill folder (no SKILL.md): $src" }
}

$dest = if ($Scope -eq 'user') {
  Join-Path $HOME '.claude\skills'
} else {
  Join-Path (Resolve-Path $Target).Path '.claude\skills'
}

Write-Host "Installing to $dest" -ForegroundColor Cyan
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }

foreach ($s in $skills) {
  $to = Join-Path $dest $s
  if ((Test-Path $to) -and -not $Force) {
    $answer = Read-Host "  $s already exists. Overwrite? [y/N]"
    if ($answer -notmatch '^[Yy]') { Write-Host "  skipped $s" -ForegroundColor Yellow; continue }
  }
  if (Test-Path $to) { Remove-Item -Recurse -Force $to }
  Copy-Item -Recurse (Join-Path $here $s) $to
  Write-Host "  installed $s" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Start a new Claude Code session, then run:" -ForegroundColor Cyan
Write-Host "  /security-code-review"
Write-Host ""
Write-Host "The three skills must stay siblings - security-audit-compare reads" -ForegroundColor DarkGray
Write-Host "security-audit's cost collectors by relative path." -ForegroundColor DarkGray
