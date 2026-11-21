# 给 pub 缓存里的 pdfrx 打本机补丁（Windows 符号链接 → 目录复制）
#
# ## 为什么需要这个补丁
#
# pdfrx 1.0.101 的 Android 构建走 CMake，其中有一段：
#
# ```cmake
# file(REMOVE ${PDFIUM_LATEST_DIR})
# file(CREATE_LINK ${PDFIUM_LIBS_DIR} ${PDFIUM_LATEST_DIR} SYMBOLIC)
# ```
#
# 在 Windows 上建**符号链接**需要管理员权限或开启「开发者模式」。
# 本机两者都没有，于是 configure 阶段直接失败：
#
# ```
# CMake Error at CMakeLists.txt:68 (file):
#   file failed to create symbolic link
# ```
#
# 补丁把这两行换成「把目录复制过去」（几 MB，无特权要求）。
#
# ## 还有一件事：PDFium 二进制的下载
#
# 同一个 CMakeLists 会从 GitHub 下载预编译的 libpdfium.so：
#
# ```
# https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F6555/pdfium-android-<abi>.tgz
# ```
#
# 本机直连 GitHub 会**间歇性 502**（实测重试第 2 次才成功）。下载失败时
# CMake 不会报「下载失败」，而是留下一个 **0 字节的 .tgz**，然后在解压时报
# “Configuring incomplete” —— 排查时容易误判成别的问题。
# 本脚本会把四个 ABI 的 .so 直接铺到 pdfrx 期望的缓存位置
# （`android/.lib/chromium%2F6555/<abi>/libpdfium.so`），
# 于是 CMake 走「Use existing precompiled PDFium」分支，不再联网。
#
# ## 什么时候要重跑
#
# - `flutter pub cache repair` / 清空 pub-cache 之后（补丁与缓存都会丢）；
# - 换 pdfrx 版本之后；
# - 构建报 “file failed to create symbolic link” 或 “Could not obtain PDFium binary” 时。
#
# 用法：
#   pwsh -File tool\patch_pdfrx_symlink.ps1
#   pwsh -File tool\patch_pdfrx_symlink.ps1 -Check     # 只看状态，不改
param(
  [switch]$Check
)

$ErrorActionPreference = 'Stop'

# 与本工程 Flutter 3.24.5 / Dart 3.5.4 兼容的最后一个 pdfrx 版本
# （1.2+ 起要求 Flutter >= 3.29，装不上）
$PdfrxVersion = '1.0.101'
$PdfiumRelease = 'chromium%2F6555'
$Abis = @{
  'arm64-v8a'   = 'pdfium-android-arm64'
  'armeabi-v7a' = 'pdfium-android-arm'
  'x86'         = 'pdfium-android-x86'
  'x86_64'      = 'pdfium-android-x64'
}

$pubCacheRoots = @(
  'C:\ttsbuild\pub-cache\hosted\pub.flutter-io.cn',
  # v1.22.76：构建实际读取的是 ttsbuild 下的 pub.dev 目录（不是 flutter-io.cn）。
  # 少了这一条就会出现「脚本说打好了、build 仍报 create symbolic link 失败」。
  'C:\ttsbuild\pub-cache\hosted\pub.dev',
  "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev"
)
# ⚠️ 本机有**两份** pub 缓存，构建实际用哪一份取决于 PUB_CACHE / 环境，
# 每个根之间不共享。v1.21.35 出包时踩过：脚本只补了第一份（ttsbuild），
# 而 flutter build 用的是 %LOCALAPPDATA% 那份 → 依然报
# "file failed to create symbolic link"。所以**存在几份就补几份**。
$packages = @()
foreach ($root in $pubCacheRoots) {
  $candidate = Join-Path $root "pdfrx-$PdfrxVersion"
  if (Test-Path $candidate) { $packages += $candidate }
}
if ($packages.Count -eq 0) { throw "找不到 pdfrx-$PdfrxVersion（找过：$($pubCacheRoots -join '; ')）" }

foreach ($pkg in $packages) {
$cmake = Join-Path $pkg 'android\CMakeLists.txt'
$libDir = Join-Path $pkg "android\.lib\$PdfiumRelease"
$latest = Join-Path $pkg 'android\.lib\latest'
if (-not (Test-Path $cmake)) { throw "找不到 $cmake" }

# ---- 1) 检查 / 铺好四个 ABI 的 libpdfium.so ----
$missing = @()
foreach ($abi in $Abis.Keys) {
  if (-not (Test-Path (Join-Path $libDir "$abi\libpdfium.so"))) { $missing += $abi }
}
Write-Host "pdfrx 包：$pkg"
Write-Host "缺少 PDFium 的 ABI：$(if ($missing.Count -eq 0) { '无' } else { $missing -join ', ' })"

if ($Check) {
  # 用「还在真的建链接吗」判断，而不是找 CREATE_LINK 字样 ——
  # 补丁后的文件里注释也提到 CREATE_LINK，会误判成没打补丁。
  $stillLinks = Select-String -Path $cmake -Pattern '^\s*file\(CREATE_LINK' -Quiet
  Write-Host "CMakeLists 是否已打补丁：$(-not $stillLinks)"
  Write-Host "staging 目录是否存在：$(Test-Path (Join-Path $latest 'arm64-v8a\libpdfium.so'))"
  continue  # 下一个缓存根（原来是 exit 0，多根循环下会跳过收尾代码）
}

if ($missing.Count -gt 0) {
  $tmp = Join-Path $env:TEMP 'pdfium-seed'
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $base = "https://github.com/bblanchon/pdfium-binaries/releases/download/$PdfiumRelease"
  foreach ($abi in $missing) {
    $name = $Abis[$abi]
    $tgz = Join-Path $tmp "$name.tgz"
    $ok = $false
    # GitHub 会间歇性 502，必须重试
    foreach ($try in 1..5) {
      try {
        Write-Host "  下载 $name.tgz（第 $try 次）…"
        Invoke-WebRequest -Uri "$base/$name.tgz" -OutFile $tgz -TimeoutSec 300 -UseBasicParsing
        if ((Get-Item $tgz).Length -gt 1MB) { $ok = $true; break }
      } catch { Start-Sleep -Seconds 4 }
    }
    if (-not $ok) { throw "下载失败：$name.tgz（GitHub 502，稍后重试）" }
    $ex = Join-Path $tmp $name
    Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $ex -Force | Out-Null
    tar -xzf $tgz -C $ex
    $so = Join-Path $ex 'lib\libpdfium.so'
    if (-not (Test-Path $so)) { throw "解压后找不到 lib/libpdfium.so：$name" }
    $dest = Join-Path $libDir $abi
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item $so (Join-Path $dest 'libpdfium.so') -Force
    if (-not (Test-Path (Join-Path $libDir 'include'))) {
      Copy-Item (Join-Path $ex 'include') $libDir -Recurse -Force
    }
    Write-Host "  已放置 $abi/libpdfium.so"
  }
}

# ---- 2) 打 CMakeLists 补丁 ----
$content = [System.IO.File]::ReadAllText($cmake, [System.Text.UTF8Encoding]::new($false))
# ⚠️ 判据必须是「真的还有 CREATE_LINK 语句」，不能用 `-match 'CREATE_LINK'`：
# 打过补丁的文件里**注释也提到 CREATE_LINK**，那样会误判成没打补丁，
# 然后在下面校验 `$old` 时抛"内容与预期不一致"（v1.21.35 出包时踩过）。
if ($content -match '(?m)^\s*file\(CREATE_LINK') {
  $old = "file(REMOVE `${PDFIUM_LATEST_DIR})`nfile(CREATE_LINK `${PDFIUM_LIBS_DIR} `${PDFIUM_LATEST_DIR} SYMBOLIC)"
  $new = @'
# [本机补丁] 原实现给 .lib/latest 建符号链接，Windows 无管理员/开发者模式下
# 会报 "file failed to create symbolic link"。改成复制目录（见
# tool/patch_pdfrx_symlink.ps1 的说明）。
if (EXISTS ${PDFIUM_LATEST_DIR}/arm64-v8a/${PDFIUM_LIB_FILENAME})
    message(STATUS "Use existing PDFium staging dir (local patch).")
else()
    file(REMOVE ${PDFIUM_LATEST_DIR})
    file(COPY ${PDFIUM_LIBS_DIR} DESTINATION ${PDFIUM_LATEST_DIR})
endif()
'@
  $new = $new -replace "`r`n", "`n"
  if (-not $content.Contains($old)) {
    # 兼容 CRLF
    $old = $old -replace "`n", "`r`n"
    $new = $new -replace "`n", "`r`n"
  }
  if (-not $content.Contains($old)) {
    throw "CMakeLists 内容与预期不一致，没找到要替换的两行。请手工检查：$cmake"
  }
  [System.IO.File]::WriteAllText($cmake, $content.Replace($old, $new),
    [System.Text.UTF8Encoding]::new($false))
  Write-Host "已给 CMakeLists 打补丁（CREATE_LINK → COPY）"
} else {
  Write-Host "CMakeLists 已经是补丁后的版本，跳过"
}

# ---- 3) 预建 staging 目录（省一次复制，也让首次 configure 就命中缓存）----
$stagingSo = Join-Path $latest 'arm64-v8a\libpdfium.so'
if (-not (Test-Path $stagingSo)) {
  Remove-Item $latest -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $latest -Force | Out-Null
  Copy-Item (Join-Path $libDir 'include') $latest -Recurse -Force
  foreach ($abi in $Abis.Keys) {
    $dest = Join-Path $latest $abi
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item (Join-Path $libDir "$abi\libpdfium.so") (Join-Path $dest 'libpdfium.so') -Force
  }
  Write-Host "已预建 .lib/latest"
} else {
  Write-Host ".lib/latest 已存在，跳过"
}

# 清掉可能残留的失败 CMake 缓存（0 字节 tar 会让后续 configure 直接失败）
$cxx = Join-Path $pkg 'android\.cxx'
if (Test-Path $cxx) {
  Remove-Item $cxx -Recurse -Force
  Write-Host "已清掉 .cxx 缓存（强制重新 configure）"
}

}  # foreach ($pkg in $packages)

Write-Host "完成。现在可以 flutter build apk / flutter test integration_test/。" -ForegroundColor Green
