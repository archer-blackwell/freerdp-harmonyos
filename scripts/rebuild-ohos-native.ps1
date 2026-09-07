param(
  [string]$NdkRoot = $env:OHOS_NDK_HOME,
  [string]$Arch = "arm64-v8a",
  [string]$BuildType = "Release",
  [string]$OpenSslRoot = "",
  [string]$ZlibRoot = "",
  [string]$CJsonRoot = "",
  [switch]$WithFFmpeg,
  [switch]$Clean,
  [switch]$SkipWrapper
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

  $candidates += @(
    "C:\huawei\Sdk",
    "C:\Users\Administrator\AppData\Local\Huawei\Sdk"
  )

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

# 必须用 NDK 自带 cmake/ninja：系统 PATH 可能捡到 Cygwin 版（路径被改写成 /cygdrive/...）
$cmakeExe = Join-Path $NdkRoot "build-tools\cmake\bin\cmake.exe"
$ninjaExe = Join-Path $NdkRoot "build-tools\cmake\bin\ninja.exe"
if (-not (Test-Path $cmakeExe)) {
  throw "未找到 NDK cmake: $cmakeExe"
}
if (-not (Test-Path $ninjaExe)) {
  throw "未找到 NDK ninja: $ninjaExe"
}

$freerdpSrc = Join-Path $root "entry\libs\FreeRDP-3.10.3"
if (-not (Test-Path $freerdpSrc)) {
  throw "未找到 FreeRDP 源码目录: $freerdpSrc"
}

$buildRoot = Join-Path $root "native-build"
$installRoot = Join-Path $root "native-install"
$freerdpBuild = Join-Path $buildRoot "freerdp\$Arch"
$freerdpInstall = Join-Path $installRoot "freerdp\$Arch"
$wrapperBuild = Join-Path $buildRoot "wrapper\$Arch"
$depsInstall = Join-Path $installRoot "deps\$Arch"

if ($Clean) {
  Remove-Item -Recurse -Force $buildRoot, $installRoot -ErrorAction SilentlyContinue
}

if (-not $OpenSslRoot) {
  $defaultOpenSsl = Join-Path $depsInstall "openssl"
  if (Test-Path $defaultOpenSsl) {
    $OpenSslRoot = $defaultOpenSsl
  }
}

if (-not $OpenSslRoot) {
  throw "未设置 OpenSSL 路径。请先编译依赖并设置 -OpenSslRoot 或确保 $depsInstall\\openssl 存在。"
}

if (-not (Test-Path (Join-Path $OpenSslRoot "include"))) {
  throw "OpenSSL include 目录不存在: $OpenSslRoot\\include"
}

if (-not $ZlibRoot) {
  $defaultZlib = Join-Path $depsInstall "zlib"
  if (Test-Path $defaultZlib) {
    $ZlibRoot = $defaultZlib
  }
}

if (-not $CJsonRoot) {
  $defaultCJson = Join-Path $depsInstall "cjson"
  if (Test-Path $defaultCJson) {
    $CJsonRoot = $defaultCJson
  }
}

New-Item -ItemType Directory -Path $freerdpBuild, $freerdpInstall, $wrapperBuild -Force | Out-Null

Write-Host "=== 构建 FreeRDP ($Arch, $BuildType) ===" -ForegroundColor Cyan

$freerdpArgs = @(
  "-S", $freerdpSrc,
  "-B", $freerdpBuild,
  "-G", "Ninja",
  "-DCMAKE_MAKE_PROGRAM=$ninjaExe",
  "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
  "-DOHOS_ARCH=$Arch",
  "-DCMAKE_BUILD_TYPE=$BuildType",
  "-DCMAKE_INSTALL_PREFIX=$freerdpInstall",
  "-DBUILD_SHARED_LIBS=ON",
  "-DWITH_CLIENT=ON",
  "-DWITH_CLIENT_COMMON=ON",
  "-DWITH_SERVER=OFF",
  "-DWITH_SAMPLE=OFF",
  "-DWITH_CUPS=OFF",
  "-DWITH_PULSE=OFF",
  "-DWITH_ALSA=OFF",
  "-DWITH_KRB5=OFF",
  # OHOS sysroot 只有合并版 libicu.so（无组件库），且原版 libwinpr3 NEEDED 仅 libc.so，
  # 说明原构建使用内嵌 Unicode 表（与 Android 构建同理），保持一致
  "-DWITH_UNICODE_BUILTIN=ON",
  # 原版 libfreerdp3 NEEDED 仅 libwinpr3+libc（无 libswscale/libcairo），缩放由应用层 viewport 完成
  "-DWITH_SWSCALE=OFF",
  # 音频后端：OHAudio（AudioKit C-API，回调拉取式）替代 OpenSLES。
  # WITH_OHOS_AUDIO 定义在 ConfigOptions.cmake（通用），rdpsnd/ohos 插件链 libohaudio.so（系统库）。
  # WITH_OPENSLES 关闭（ConfigOptionsAndroid.cmake 中默认 ON，此处显式覆盖）
  "-DWITH_OPENSLES=OFF",
  "-DWITH_OHOS_AUDIO=ON",
  # ThinLTO 在 OHOS lld 上会把 vectorize remark 升级为错误（--fatal-warnings），原版行为不可考，关闭
  "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF",
  "-DWITH_FUSE=OFF",                       # 剪贴板 FUSE 文件拷贝（需要 pkg-config+fuse3）
  "-DWITH_CLIENT_SDL=OFF",                 # SDL 客户端可执行文件（只需 libfreerdp-client3）
  "-DWITH_CCACHE=OFF",
  "-DWITH_MANPAGES=OFF",
  # 桌面专属通道（需要 ffmpeg/v4l2/libusb）
  "-DCHANNEL_RDPECAM_CLIENT=OFF",          # 摄像头重定向
  "-DCHANNEL_URBDRC=OFF",                  # USB 设备重定向（通道共享代码也需 libusb 头文件）
  "-DWITH_X11=OFF",
  "-DWITH_WAYLAND=OFF",
  "-DWITH_GSTREAMER_0_10=OFF",
  "-DWITH_GSTREAMER_1_0=OFF",
  "-DWITH_FFMPEG=" + ($(if ($WithFFmpeg) { "ON" } else { "OFF" })),
  "-DWITH_OPENSSL=ON",
  # 对齐原版 libwinpr3 导出符号（winpr_MD4_* / winpr_MD5_* / winpr_int_rc4_*）：
  # OHOS 上静态链 OpenSSL 3.x 无 legacy provider，EVP_get_digestbyname("MD4")/RC4 不可用，
  # NLA(CredSSP/NTLM) 计算会失败导致连接断开（transport layer failed）。
  # 原版构建以 WITH_INTERNAL_MD4/MD5/RC4=ON 内置这些算法，必须保持一致
  "-DWITH_INTERNAL_MD4=ON",
  "-DWITH_INTERNAL_MD5=ON",
  "-DWITH_INTERNAL_RC4=ON",
  "-DOPENSSL_ROOT_DIR=$OpenSslRoot",
  # OHOS 工具链 CMAKE_FIND_ROOT_PATH_MODE=ONLY 会拦截 sysroot 外的搜索，
  # 显式传入缓存变量绕过 FindOpenSSL/FindZLIB 的搜索逻辑
  "-DOPENSSL_INCLUDE_DIR=$OpenSslRoot\include",
  "-DOPENSSL_SSL_LIBRARY=$OpenSslRoot\lib\libssl.a",
  "-DOPENSSL_CRYPTO_LIBRARY=$OpenSslRoot\lib\libcrypto.a"
)

if ($ZlibRoot) {
  $freerdpArgs += @(
    "-DZLIB_ROOT=$ZlibRoot",
    "-DZLIB_INCLUDE_DIR=$ZlibRoot\include",
    "-DZLIB_LIBRARY=$ZlibRoot\lib\libz.a"
  )
}
if ($CJsonRoot) {
  $freerdpArgs += "-DcJSON_DIR=$CJsonRoot"
}

& $cmakeExe @freerdpArgs
if ($LASTEXITCODE -ne 0) { throw "FreeRDP cmake 配置失败（exit $LASTEXITCODE）" }
& $cmakeExe --build $freerdpBuild --parallel
if ($LASTEXITCODE -ne 0) { throw "FreeRDP 编译失败（exit $LASTEXITCODE）" }
& $cmakeExe --install $freerdpBuild
if ($LASTEXITCODE -ne 0) { throw "FreeRDP 安装失败（exit $LASTEXITCODE）" }

if (-not $SkipWrapper) {
  Write-Host "=== 构建 NAPI Wrapper ($Arch, $BuildType) ===" -ForegroundColor Cyan

  $wrapperSrc = Join-Path $root "entry\src\main\cpp"
  $wrapperArgs = @(
    "-S", $wrapperSrc,
    "-B", $wrapperBuild,
    "-G", "Ninja",
    "-DCMAKE_MAKE_PROGRAM=$ninjaExe",
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
    "-DOHOS_ARCH=$Arch",
    "-DCMAKE_BUILD_TYPE=$BuildType",
    "-DFREERDP_DIR=$freerdpInstall",
    "-DFREERDP_LIB_DIR=$freerdpInstall\lib",
    "-DOPENSSL_DIR=$OpenSslRoot"
  )

  & $cmakeExe @wrapperArgs
  & $cmakeExe --build $wrapperBuild --parallel
} else {
  Write-Host "跳过 NAPI Wrapper 构建（-SkipWrapper），wrapper 由 DevEco 构建生成" -ForegroundColor Yellow
}

Write-Host "=== 同步库到 entry/libs/$Arch ===" -ForegroundColor Cyan

# 构建产物完整性校验：全部关键库存在才清理+同步，失败时保留 entry/libs 原状
$freerdpLibDir = Join-Path $freerdpInstall "lib"
$requiredLibs = @("libfreerdp3.so.3", "libfreerdp-client3.so.3", "libwinpr3.so.3")
foreach ($lib in $requiredLibs) {
  if (-not (Test-Path (Join-Path $freerdpLibDir $lib))) {
    throw "构建产物缺失: $freerdpLibDir\$lib，跳过 entry/libs 同步（原库保留）"
  }
}

$targetLibDir = Join-Path $root "entry\libs\$Arch"
New-Item -ItemType Directory -Path $targetLibDir -Force | Out-Null

# 只清理 FreeRDP 官方库（libfreerdp_harmonyos.so 是 DevEco 构建产物，保留）
$removePatterns = @(
  "libfreerdp3.so*",
  "libfreerdp-client3.so*",
  "libwinpr3.so*",
  "libwinpr-tools3.so*"
)
if ($WithFFmpeg) {
  $removePatterns += "libav*.so*"
}

foreach ($pattern in $removePatterns) {
  Get-ChildItem -Path $targetLibDir -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
    for ($i = 1; $i -le 3; $i++) {
      try {
        Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
        break
      } catch {
        Write-Warning "第 $i 次删除失败（文件可能被占用）: $($_.Name)"
        if ($i -eq 3) { throw "无法删除旧库 $($_.Name)（请关闭 DevEco/hvigor 进程后重试）" }
        Start-Sleep -Seconds 1
      }
    }
  }
}

$allowPatterns = @(
  "libfreerdp3.so*",
  "libfreerdp-client3.so*",
  "libwinpr3.so*"
)
if ($WithFFmpeg) {
  $allowPatterns += "libav*.so*"
}

foreach ($pattern in $allowPatterns) {
  Get-ChildItem -Path $freerdpLibDir -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
    for ($i = 1; $i -le 3; $i++) {
      try {
        Copy-Item $_.FullName $targetLibDir -Force -ErrorAction Stop
        break
      } catch {
        Write-Warning "第 $i 次复制失败（文件可能被占用）: $($_.Name)"
        if ($i -eq 3) { throw "无法同步 $($_.Name)（请关闭 DevEco/hvigor 进程后重试）" }
        Start-Sleep -Seconds 1
      }
    }
  }
}

# wrapper 的 CMakeLists 直接输出到 entry\libs\$Arch（CMAKE_LIBRARY_OUTPUT_DIRECTORY），
# native-build 下无产物；若两处都没有则告警
$wrapperOut = Join-Path $wrapperBuild "libfreerdp_harmonyos.so"
$wrapperFinal = Join-Path $targetLibDir "libfreerdp_harmonyos.so"
if (Test-Path $wrapperOut) {
  Copy-Item $wrapperOut $targetLibDir -Force
} elseif (-not (Test-Path $wrapperFinal)) {
  Write-Warning "未找到 wrapper 输出: $wrapperOut"
} else {
  Write-Host "wrapper 已由 CMake 直接输出到 $wrapperFinal"
}

Write-Host "完成。请重新构建 HAP 并测试连接。" -ForegroundColor Green
