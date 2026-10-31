# git_push.ps1 - commit the working tree and push to GitHub, the safe way.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool\git_push.ps1 -Message "feat: ..."
#   powershell -ExecutionPolicy Bypass -File tool\git_push.ps1 -Message "..." -DryRun
#
# WHY THIS SCRIPT EXISTS (local traps it hides)
#   1) git may not be on PATH. Prefer the standalone git (2.47+) at
#      C:\ttsbuild\git\cmd\git.exe. Flutter's mingit is only 2.15 and does NOT
#      support http.curloptResolve, which we need below - it is a last resort.
#   2) DNS for github.com often resolves to 20.205.243.166, which is NOT reachable
#      from this host (connect times out after ~21s). Other GitHub IPs do work.
#      So we probe candidate IPs and push with http.curloptResolve to a good one.
#      NOTE: this bypasses the local accelerator entirely, so the real GitHub
#      certificate is used and the Windows (schannel) trust store validates it.
#      That is why we do NOT need build\local-ca.pem any more - the old
#      GIT_SSL_CAINFO approach failed with UNABLE_TO_GET_ISSUER_CERT_LOCALLY
#      because the accelerator's CA did not match the served chain.
#   3) The token must never stay in .git\config. This script pushes to an explicit
#      token URL and then restores origin to its clean form, so a later
#      `git remote -v` never prints the secret.
#
# Verified 2026-10-31: e15cf4a..2dd6f06 pushed successfully with this approach.
#
# This file is ASCII-only on purpose: Windows PowerShell 5.1 parses non-ASCII .ps1
# files as ANSI unless they carry a BOM, which silently mangles CJK text.
#
# Related: HANDOFF.md section 11.8 (publish flow) and tool\gh_release_asset.js
# (binary APK goes to Releases, never into the git tree).
param(
  [Parameter(Mandatory = $true)][string]$Message,
  [switch]$DryRun,
  # Skip the IP probe and go straight to DNS. Use when GitHub is reachable normally.
  [switch]$NoResolveOverride
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# Prefer the modern git. mingit (2.15) cannot do http.curloptResolve.
$gitCandidates = @(
  'C:\ttsbuild\git\cmd\git.exe',
  'C:\ttsbuild\flutter\bin\mingit\cmd\git.exe'
)
$git = $null
foreach ($c in $gitCandidates) {
  if (Test-Path $c) { $git = $c; break }
}
if (-not $git) { throw 'git not found (tried: ' + ($gitCandidates -join '; ') + ')' }
$gitVersion = (& $git --version)
Write-Host "git: $git  ($gitVersion)"

$tokenPath = 'C:\Users\user\.dsh\dsh_wechat\logs\gh-token.txt'
if (-not (Test-Path $tokenPath)) { throw "token not found: $tokenPath" }
$token = (Get-Content $tokenPath -Raw).Trim()
if (-not $token) { throw "token file is empty: $tokenPath" }

$repoUrl = 'https://github.com/lzhtt23/tts_reader.git'
$tokenUrl = "https://x-access-token:$token@github.com/lzhtt23/tts_reader.git"

# Candidate GitHub IPs. Order matters: put known-good ones first.
# 20.205.243.166 is deliberately last - it is the one DNS usually returns here
# and it is unreachable, but keep it as a fallback in case routing changes.
$candidateIps = @(
  '140.82.121.3',
  '20.27.177.113',
  '20.205.243.166'
)

# Common git options for a flaky network.
$netOpts = @(
  '-c', 'http.sslBackend=schannel',
  '-c', 'http.postBuffer=524288000',
  '-c', 'http.lowSpeedLimit=0',
  '-c', 'http.lowSpeedTime=999'
)

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

  # Pick a reachable endpoint. `ls-remote` is the cheapest real check: it needs
  # TLS + auth to succeed, so a pass means push will almost certainly work.
  $resolvedIp = $null
  $probeOk = $false
  if ($NoResolveOverride) {
    Write-Host 'probe skipped (-NoResolveOverride); using DNS'
    $probeOk = $true
  } else {
    foreach ($ip in $candidateIps) {
      Write-Host "probing $ip ..."
      & $git @netOpts -c "http.curloptResolve=github.com:443:$ip" `
        ls-remote $tokenUrl HEAD 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Host "  ok: $ip"
        $resolvedIp = $ip
        $probeOk = $true
        break
      }
      Write-Host "  fail: $ip"
    }
  }

  if (-not $probeOk) {
    # Last resort: plain DNS. Usually fails on this host, but try once so the
    # error message reflects the real problem instead of "no candidate".
    Write-Host 'no candidate IP worked; trying plain DNS'
    & $git @netOpts push $tokenUrl HEAD:main
    if ($LASTEXITCODE -ne 0) {
      throw "push failed ($LASTEXITCODE). Network issue: run 'curl.exe -sI --max-time 10 --resolve github.com:443:<ip> https://github.com' to find a reachable IP, then add it to `$candidateIps."
    }
  } else {
    $pushArgs = @($netOpts)
    if ($resolvedIp) { $pushArgs += @('-c', "http.curloptResolve=github.com:443:$resolvedIp") }
    $pushArgs += @('push', $tokenUrl, 'HEAD:main')
    if ($resolvedIp) { Write-Host "pushing via $resolvedIp ..." }
    else { Write-Host 'pushing via DNS ...' }
    & $git @pushArgs
    if ($LASTEXITCODE -ne 0) { throw "push failed ($LASTEXITCODE)" }
  }

  # Never leave the secret sitting in .git\config.
  & $git remote set-url origin $repoUrl
  Write-Host 'pushed; origin URL restored (no token stored)'
} finally {
  Pop-Location
}
