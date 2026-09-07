param(
  [string]$NdkRoot = $env:OHOS_NDK_HOME,
  [string]$Arch = "arm64-v8a",
  [string]$BuildType = "Release",
  [string]$OpenSslVersion = "3.0.15",
  [string]$ZlibVersion = "1.3.1",
  [switch]$Clean
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Resolve-NdkRoot {
  param([string]$Provided)
  if ($Provided) { return $Provided }

  $candidates = @()
  if ($env:OHOS_NDK_HOME) { $candidates += $env:OHOS_NDK_HOME }

  $devEcoConfig = Join-Path $env:APPDATA "Huawei\DevEcoStudio6.0\options\other.xml"
  if (Test-Path $devEcoConfig) {
    $content = Get-Content $devEcoConfig -Raw
    if ($content -match 'arkuix\.sdk\.location":\s*"([^"]+)"') {
      $sdkPath = $Matches[1] -replace '\\\\','\'
      $candidates += $sdkPath
    }
  }

  foreach ($base in $candidates) {
    if (-not (Test-Path $base)) { continue }
    $toolchain = Get-ChildItem -Path $base -Filter "ohos.toolchain.cmake" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($toolchain) {
      $cmakeDir = Split-Path $toolchain.FullName -Parent
      $buildDir = Split-Path $cmakeDir -Parent
      $ndkRoot = Split-Path $buildDir -Parent
      return $ndkRoot
    }
  }
  return $null
}

$NdkRoot = Resolve-NdkRoot $NdkRoot
if (-not $NdkRoot) {
  throw "未指定 OHOS NDK 路径。请设置 OHOS_NDK_HOME 或传入 -NdkRoot。"
}

$toolchain = Join-Path $NdkRoot "build\cmake\ohos.toolchain.cmake"
if (-not (Test-Path $toolchain)) {
  throw "未找到 ohos.toolchain.cmake: $toolchain"
}

$srcRoot = Join-Path $root "native-src"
$buildRoot = Join-Path $root "native-build"
$installRoot = Join-Path $root "native-install\deps\$Arch"

if ($Clean) {
  Remove-Item -Recurse -Force $srcRoot, $buildRoot, $installRoot -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $srcRoot, $buildRoot, $installRoot -Force | Out-Null

function Download-IfMissing {
  param([string]$Url, [string]$OutFile)
  if (-not (Test-Path $OutFile)) {
    Write-Host "下载 $Url" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
  }
}

function Expand-Tar {
  param([string]$Archive, [string]$Dest)
  if (-not (Test-Path $Dest)) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    tar -xf $Archive -C $Dest --strip-components=1
  }
}

Write-Host "=== 构建 zlib ===" -ForegroundColor Cyan
$zlibArchive = Join-Path $srcRoot "zlib-$ZlibVersion.tar.gz"
$zlibSrc = Join-Path $srcRoot "zlib-$ZlibVersion"
Download-IfMissing "https://zlib.net/fossils/zlib-$ZlibVersion.tar.gz" $zlibArchive
Expand-Tar $zlibArchive $zlibSrc

$zlibBuild = Join-Path $buildRoot "zlib\$Arch"
New-Item -ItemType Directory -Path $zlibBuild -Force | Out-Null
$zlibArgs = @(
  "-S", $zlibSrc,
  "-B", $zlibBuild,
  "-G", "Ninja",
  "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
  "-DOHOS_ARCH=$Arch",
  "-DCMAKE_BUILD_TYPE=$BuildType",
  "-DCMAKE_INSTALL_PREFIX=$installRoot\zlib"
)
cmake @zlibArgs
cmake --build $zlibBuild --parallel
cmake --install $zlibBuild

Write-Host "=== 构建 OpenSSL ===" -ForegroundColor Cyan
if (-not (Get-Command perl -ErrorAction SilentlyContinue)) {
  throw "未找到 perl。OpenSSL 构建需要 Perl（建议安装 Strawberry Perl 或使用 WSL）。"
}
if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
  throw "未找到 make。建议在 WSL/Linux 环境构建 OpenSSL。"
}

$opensslArchive = Join-Path $srcRoot "openssl-$OpenSslVersion.tar.gz"
$opensslSrc = Join-Path $srcRoot "openssl-$OpenSslVersion"
Download-IfMissing "https://deb.debian.org/debian/pool/main/o/openssl/openssl-$OpenSslVersion.orig.tar.gz" $opensslArchive
Expand-Tar $opensslArchive $opensslSrc

$opensslInstall = Join-Path $installRoot "openssl"

# Cygwin make/sh 无法执行含空格/反斜杠的 Windows 路径（"DevEco Studio"），
# 建立无空格 junction 别名，并用 POSIX 路径调用 NDK 工具链
$ndkDrive = (Get-Item $NdkRoot).PSDrive.Name
$ndkJunction = "$($ndkDrive):\ohos_ndk"
if (-not (Test-Path $ndkJunction)) {
  New-Item -ItemType Junction -Path $ndkJunction -Target $NdkRoot | Out-Null
  Write-Host "已创建 NDK junction: $ndkJunction -> $NdkRoot"
}
$ndkPosix = "/cygdrive/$($ndkDrive.ToLower())/ohos_ndk"
$ndkFwd = $ndkJunction -replace '\\', '/'

Push-Location $opensslSrc
try {
  $env:CC = "$ndkPosix/llvm/bin/clang.exe"
  $env:AR = "$ndkPosix/llvm/bin/llvm-ar.exe"
  $env:RANLIB = "$ndkPosix/llvm/bin/llvm-ranlib.exe"
  $env:CFLAGS = "--target=aarch64-linux-ohos --sysroot=$ndkFwd/sysroot -fPIC"
  $env:LDFLAGS = "--target=aarch64-linux-ohos --sysroot=$ndkFwd/sysroot"

  $opensslInstallFwd = $opensslInstall -replace '\\', '/'
  perl Configure linux-aarch64 "--prefix=$opensslInstallFwd" no-tests no-shared
  make -j
  make install_sw
} finally {
  Pop-Location
}

Write-Host "依赖构建完成：$installRoot" -ForegroundColor Green
