# pack_release.ps1 - build the GitHub release bundle for this project.
#
#   Usage:  powershell -ExecutionPolicy Bypass -File tool\pack_release.ps1 -Version 1.15.0
#
# Output (all inside release\):
#   tts_reader-<Version>/                  clean source tree  (drag this into the GitHub web UI)
#   tts_reader-<Version>-source.zip        the same tree, zipped
#   tts_reader-v<Version>-release.apk      copied from dist\
#   SHA256SUMS.txt                         checksums of the two files above
#
# WHY A WHITELIST: the project root also collects scratch files from development
# sessions (dev1.log, devall.txt, t1.log, viewer.txt ...). A blacklist silently
# let one of them through once, so now only the entries listed in
# $PublishEntries are copied - anything else at the root is reported and skipped.
#
# LOCAL-ONLY files that must never be published:
#   HANDOFF.md            - deep engineering notes (local toolchain, T2S analysis)
#   docs\*.md             - internal handoff notes
# Both are enforced below and verified by the sanity check at the end.
#
# Note: this file is intentionally ASCII-only. Windows PowerShell 5.1 parses
# non-ASCII .ps1 files as ANSI unless they carry a BOM, which silently mangles
# Chinese text in scripts.

param(
  [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$release = Join-Path $root 'release'
$stageName = "tts_reader-$Version"
$stage = Join-Path $release $stageName
$apkSource = Join-Path $root "dist\tts_reader-v$Version-release.apk"
$zip = Join-Path $release "tts_reader-$Version-source.zip"

if (-not (Test-Path $apkSource)) {
  throw "APK not found: $apkSource  (run 'flutter build apk --release' first)"
}

# --- what gets published (whitelist of top-level entries) ------------------
$PublishEntries = @(
  '.gitignore',
  'analysis_options.yaml',
  'pubspec.yaml',
  'pubspec.lock',
  'README.md',
  'CHANGELOG.md',
  'LICENSE',
  # NOTE 2026-10-27: assets/icons/ is declared in pubspec.yaml (settings page icon
  # previews) and is REQUIRED to build. It was missing from this whitelist, so every
  # published tree could not be built by `flutter build apk`. Added here and committed
  # to git the same day.
  'assets',
  'lib',
  'android',
  'test',
  'integration_test',
  'tool',
  'docs'
)

# --- never copied, even inside the entries above --------------------------
$ExcludeDirs = @('.dart_tool', 'build', 'dist', 'release', '.gradle', '.idea', '.vscode')
$ExcludeFiles = @('*.iml', 'local.properties', '.flutter-plugins', '.flutter-plugins-dependencies',
                  '*.jks', '*.keystore', '*.log',
                  # NOTE 2026-10-21: a 2.1 GB JVM heap dump (java_pidNNNN.hprof) landed in
                  # android\ after a Gradle OOM and got copied into the publish tree, making
                  # the source zip 190 MB. Heap dumps are never source; exclude them.
                  '*.hprof')
# NOTE 2026-10-18: gradle-wrapper.jar was in this exclude list until it silently
# deleted the file from the GitHub repo (the v1.21.53 incident, again). The jar is
# tracked by git (`.gitignore` does not ignore it), so it MUST be published.
# CHANGELOG.md / LICENSE had never been whitelisted and were deleted the same way.
# docs\ is published for its images; every markdown file in it is an internal note
$DropDocsMarkdown = $true

Write-Host "[1/4] staging source tree -> $stage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$skipped = @()
foreach ($item in Get-ChildItem $root -Force) {
  if ($item.Name -eq $stageName -and $item.DirectoryName -eq $release) { continue }
  if ($PublishEntries -notcontains $item.Name) { $skipped += $item.Name; continue }
  $target = Join-Path $stage $item.Name
  if ($item.PSIsContainer) {
    $rcArgs = @($item.FullName, $target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1',
                '/XD') + $ExcludeDirs + @('/XF') + $ExcludeFiles
    robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "robocopy failed for $($item.Name) with exit code $LASTEXITCODE" }
  } else {
    # single file: robocopy rejects a file source with /E, plain copy is enough
    Copy-Item $item.FullName $target -Force
  }
}

if ($DropDocsMarkdown) {
  Get-ChildItem (Join-Path $stage 'docs') -Filter *.md -File -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force; Write-Host "      dropped docs\$($_.Name) (internal)" }
}

if ($skipped.Count -gt 0) {
  Write-Host "      skipped (not in the publish whitelist):"
  $skipped | Sort-Object | ForEach-Object { Write-Host "        $_" }
}

Write-Host "[2/4] zipping"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
Start-Sleep -Seconds 2   # let the writer flush before hashing

Write-Host "[3/4] copying APK"
Copy-Item $apkSource (Join-Path $release "tts_reader-v$Version-release.apk") -Force

Write-Host "[4/4] checksums"
$lines = @()
Get-ChildItem $release -File | Where-Object { $_.Name -match '\.(apk|zip)$' } |
  Sort-Object Name | ForEach-Object {
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    $lines += "$hash  $($_.Name)"
    Write-Host ("      {0}  {1,12:N0} bytes  {2}" -f $_.Name, $_.Length, $hash)
  }
[System.IO.File]::WriteAllLines((Join-Path $release 'SHA256SUMS.txt'), $lines,
  (New-Object System.Text.UTF8Encoding($false)))

# --- sanity check: nothing internal slipped in ----------------------------
Write-Host ""
Write-Host "sanity check (must all be empty):"
$leaks = Get-ChildItem $stage -Recurse -File -Force | Where-Object {
  $_.Name -eq 'HANDOFF.md' -or
  ($_.Extension -eq '.md' -and $_.DirectoryName -match '\\docs$') -or
  $_.Name -match '\.(jks|keystore)$' -or
  $_.Name -eq 'local.properties' -or
  $_.FullName -match '\\\.dart_tool\\|\\build\\|\\\.gradle\\'
}
if ($leaks) {
  $leaks | ForEach-Object { Write-Host "  LEAK: $($_.FullName.Replace($stage, ''))" }
  throw "internal files would be published - fix the whitelist / exclusion list"
}
Write-Host "  ok - no internal docs, no keystores, no local.properties, no build output"

# --- GitHub web upload plan (100 files per upload) ------------------------
$count = { param($p) @(Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue).Count }
$rootFiles = @(Get-ChildItem $stage -File -Force).Count
$libCount = & $count (Join-Path $stage 'lib')
$androidCount = & $count (Join-Path $stage 'android')
$restCount = (& $count $stage) - $rootFiles - $libCount - $androidCount
$total = & $count $stage

Write-Host ""
Write-Host "GitHub upload plan ($total files total, limit 100 per upload):"
Write-Host ("  batch 1: root files        {0,4}" -f $rootFiles)
Write-Host ("  batch 2: lib\              {0,4}" -f $libCount)
Write-Host ("  batch 3: android\          {0,4}" -f $androidCount)
Write-Host ("  batch 4: test\ integration_test\ tool\ docs\  {0,4}" -f $restCount)
Write-Host "  then add .gitignore by hand - browsers do not drag hidden files,"
Write-Host "  and Android Studio / VS Code hide it from the folder view."
Write-Host ""
Write-Host "done: $release"
