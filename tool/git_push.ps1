# git_push.ps1 - commit the working tree and push to GitHub, the safe way.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool\git_push.ps1 -Message "feat: ..."
#   powershell -ExecutionPolicy Bypass -File tool\git_push.ps1 -Message "..." -DryRun
#
# WHY THIS SCRIPT EXISTS (three local traps it hides)
#   1) git is NOT on PATH here. It ships inside Flutter: flutter\bin\mingit.
#   2) A local GitHub accelerator signs github.com with a private CA, so git must
#      be told to trust build\local-ca.pem via GIT_SSL_CAINFO, otherwise fetch/push
#      fails with UNABLE_TO_GET_ISSUER_CERT_LOCALLY.
#   3) The token must never stay in .git\config. This script pushes to an explicit
#      token URL and then restores origin to its clean form, so a later
#      `git remote -v` never prints the secret.
#
# This file is ASCII-only on purpose: Windows PowerShell 5.1 parses non-ASCII .ps1
# files as ANSI unless they carry a BOM, which silently mangles CJK text.
#
# Related: HANDOFF.md section 11.8 (publish flow) and tool\gh_release_asset.js
# (binary APK goes to Releases, never into the git tree).
param(
  [Parameter(Mandatory = $true)][string]$Message,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$git = 'C:\ttsbuild\flutter\bin\mingit\cmd\git.exe'
if (-not (Test-Path $git)) { throw "git not found: $git  (Flutter mingit)" }

$tokenPath = 'C:\Users\user\.dsh\dsh_wechat\logs\gh-token.txt'
if (-not (Test-Path $tokenPath)) { throw "token not found: $tokenPath" }
$token = (Get-Content $tokenPath -Raw).Trim()
if (-not $token) { throw "token file is empty: $tokenPath" }

$ca = Join-Path $root 'build\local-ca.pem'
if (-not (Test-Path $ca)) {
  throw "CA not found: $ca  (run tool\export_local_ca.ps1 first)"
}

Push-Location $root
try {
  & $git add -A
  if ($LASTEXITCODE -ne 0) { throw "git add failed ($LASTEXITCODE)" }

  $staged = @(& $git diff --cached --name-only)
  if ($staged.Count -eq 0) {
    Write-Host 'nothing to commit'
  } else {
    Write-Host "staged $($staged.Count) file(s)"
    & $git -c core.autocrlf=false commit -m $Message
    if ($LASTEXITCODE -ne 0) { throw "commit failed ($LASTEXITCODE)" }
  }

  if ($DryRun) {
    Write-Host '[dry-run] commit kept, push skipped'
    return
  }

  $env:GIT_SSL_CAINFO = $ca
  $url = "https://x-access-token:$token@github.com/lzhtt23/tts_reader.git"
  & $git push $url HEAD:main
  if ($LASTEXITCODE -ne 0) { throw "push failed ($LASTEXITCODE)" }

  # Never leave the secret sitting in .git\config.
  & $git remote set-url origin https://github.com/lzhtt23/tts_reader.git
  Write-Host 'pushed; origin URL restored (no token stored)'
} finally {
  Pop-Location
}
