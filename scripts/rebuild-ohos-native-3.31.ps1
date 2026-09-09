# ============================================================================
# FreeRDP 3.31 (entry/libs/FreeRDP, master 快照 3.31.1-dev0) OHOS arm64 构建
#
# 与 3.10.3 的 rebuild-ohos-native.ps1 完全隔离：
#   构建   native-build\freerdp-3.31\<arch>
#   安装   native-install\freerdp-3.31\<arch>
#
# 用法：
#   正式构建（含 entry/libs 同步）:  .\rebuild-ohos-native-3.31.ps1
#   验证 WITH_OHOS_AUDIO=OFF 编译:   .\rebuild-ohos-native-3.31.ps1 -OhosAudioOff -SkipSync -SkipWrapper
#   验证 WITH_OHOS_FILE_OPEN=OFF 编译: .\rebuild-ohos-native-3.31.ps1 -OhosFileOpenOff -SkipSync -SkipWrapper
#   全新重来:                        .\rebuild-ohos-native-3.31.ps1 -Clean
#
# ⚠ 绝对禁止向 CMake 传 WITHOUT_FREERDP_3x_DEPRECATED：
#   wrapper 依赖的 Authenticate / GatewayAuthenticate 等接口在 3.31 中标记废弃，
#   由该宏守卫，一旦定义会导致 wrapper 编译失败。废弃接口只需容忍编译告警。
# ============================================================================
param(
  [string]$NdkRoot = $env:OHOS_NDK_HOME,
  [string]$Arch = "arm64-v8a",
  [string]$BuildType = "Release",
  [string]$OpenSslRoot = "",
  [string]$ZlibRoot = "",
  [switch]$OhosAudioOff,   # WITH_OHOS_AUDIO=OFF 验证构建（配合 -SkipSync）
  [switch]$OhosFileOpenOff, # WITH_OHOS_FILE_OPEN=OFF 验证构建（配合 -SkipSync）
  [switch]$Clean,
  [switch]$SkipWrapper,
  [switch]$SkipSync        # 只构建+install，不改动 entry/libs（验证构建用）
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
if (-not (Test-Path $cmakeExe)) { throw "未找到 NDK cmake: $cmakeExe" }
if (-not (Test-Path $ninjaExe)) { throw "未找到 NDK ninja: $ninjaExe" }

$freerdpSrc = Join-Path $root "entry\libs\FreeRDP"
if (-not (Test-Path $freerdpSrc)) { throw "未找到 FreeRDP 源码目录: $freerdpSrc" }

# 独立构建/安装目录，与 3.10.3 产物（native-build\freerdp、native-install\freerdp）隔离
$buildRoot = Join-Path $root "native-build"
$installRoot = Join-Path $root "native-install"
$tag = if ($OhosAudioOff) { "freerdp-3.31-noohos" } else { "freerdp-3.31" }
$freerdpBuild = Join-Path $buildRoot "$tag\$Arch"
$freerdpInstall = Join-Path $installRoot "$tag\$Arch"
$wrapperBuild = Join-Path $buildRoot "wrapper-3.31\$Arch"
$depsInstall = Join-Path $installRoot "deps\$Arch"

if ($Clean) {
  Remove-Item -Recurse -Force $freerdpBuild, $freerdpInstall, $wrapperBuild -ErrorAction SilentlyContinue
}

if (-not $OpenSslRoot) {
  $defaultOpenSsl = Join-Path $depsInstall "openssl"
  if (Test-Path $defaultOpenSsl) { $OpenSslRoot = $defaultOpenSsl }
}
if (-not $OpenSslRoot) {
  throw "未设置 OpenSSL 路径。请先编译依赖并设置 -OpenSslRoot 或确保 $depsInstall\openssl 存在。"
}
if (-not (Test-Path (Join-Path $OpenSslRoot "include"))) {
  throw "OpenSSL include 目录不存在: $OpenSslRoot\include"
}
if (-not $ZlibRoot) {
  $defaultZlib = Join-Path $depsInstall "zlib"
  if (Test-Path $defaultZlib) { $ZlibRoot = $defaultZlib }
}

New-Item -ItemType Directory -Path $freerdpBuild, $freerdpInstall, $wrapperBuild -Force | Out-Null

$withOhosAudio = if ($OhosAudioOff) { "OFF" } else { "ON" }
$withOhosFileOpen = if ($OhosFileOpenOff) { "OFF" } else { "ON" }
Write-Host "=== 构建 FreeRDP 3.31 ($Arch, $BuildType, WITH_OHOS_AUDIO=$withOhosAudio, WITH_OHOS_FILE_OPEN=$withOhosFileOpen) ===" -ForegroundColor Cyan

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
  # ---- 可执行程序 / server / 示例 / 测试：全部关闭，只产出三个共享库 ----
  "-DWITH_CLIENT=ON",                 # client 库目标（不生成 sdl 可执行文件）
  "-DWITH_CLIENT_COMMON=ON",          # libfreerdp-client3.so
  "-DWITH_CLIENT_SDL=OFF",            # SDL 客户端可执行文件
  "-DWITH_SERVER=OFF",                # 服务端
  "-DWITH_SERVER_CHANNELS=OFF",       # 服务端通道
  "-DWITH_SAMPLE=OFF",                # 示例程序
  "-DBUILD_TESTING=OFF",              # 单元测试
  "-DWITH_MANPAGES=OFF",
  # ---- 版本与第三方 ----
  "-DUSE_VERSION_FROM_GIT_TAG=OFF",   # 源码目录无 git 元数据；使用内置版本 3.31.1-dev0
  "-DWITH_THIRD_PARTY=OFF",
  "-DWITH_JSON_DISABLED=ON",          # 离线构建禁用 JSON 探测（不需要 cjson/json-c/jansson）
  "-DWITH_FUSE=OFF",                  # ★ 3.31 新默认 ON，OHOS 无 fuse3 依赖
  "-DWITH_CCACHE=OFF",
  "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF",  # OHOS lld ThinLTO 会把 remark 升级为错误
  # ---- 平台依赖裁剪（与 3.10.3 构建保持一致）----
  "-DWITH_UNICODE_BUILTIN=ON",        # OHOS sysroot 只有合并版 libicu.so
  "-DWITH_SWSCALE=OFF",               # 缩放由应用层 viewport 完成
  "-DWITH_KRB5=OFF",
  "-DWITH_CUPS=OFF",
  "-DWITH_X11=OFF",
  "-DWITH_WAYLAND=OFF",
  "-DWITH_FFMPEG=OFF",
  "-DWITH_PULSE=OFF",
  "-DWITH_ALSA=OFF",
  # ---- 音频后端：OHAudio（AudioKit C-API，pull 回调 + 环形缓冲）----
  # 跳过 OpenSLES 全部逻辑（3.10.3 树的 6 个 opensles 补丁无需移植）
  "-DWITH_OPENSLES=OFF",
  "-DWITH_OHOS_AUDIO=$withOhosAudio",
  # ---- rdpdr 文件打开重定向（drive 通道观测钩子，wrapper 侧 dlsym 动态注册）----
  "-DWITH_OHOS_FILE_OPEN=$withOhosFileOpen",
  # 注意：此处绝不传 WITHOUT_FREERDP_3x_DEPRECATED（见文件头警告）
  # ---- OpenSSL / zlib：复用 deps 静态库 ----
  "-DWITH_OPENSSL=ON",
  # OHOS 静态链 OpenSSL 3.x 无 legacy provider，MD4/RC4 不可用；
  # NLA(CredSSP/NTLM) 依赖它们，必须内置（与 3.10.3 构建一致）
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

# ---- RDP 通道裁剪：8 开 23 关（共 31 个通道，见 channels/*/ChannelOptions.cmake）----
# 开启：剪贴板 / 音频输出 / 设备重定向 / 动态虚拟通道 / 显示更新 / 图形管线 / 触摸输入 / 磁盘重定向
# audin 无可用后端（OpenSLES/OHAudio 均不提供录音），关闭；其余通道业务未使用，全部关闭
$channelsOn = @("CLIPRDR", "RDPSND", "RDPDR", "DRDYNVC", "DISP", "RDPGFX", "RDPEI", "DRIVE")
$channelsOff = @(
  "AINPUT", "AUDIN", "ECHO", "ENCOMSP", "GEOMETRY", "GFXREDIR", "LOCATION",
  "PARALLEL", "PRINTER", "RAIL", "RDP2TCP", "RDPEAR", "RDPECAM", "RDPEMSC",
  "RDPEWA", "REMDESK", "SERIAL", "SMARTCARD", "SSHAGENT", "TELEMETRY",
  "TSMF", "URBDRC", "VIDEO"
)
$freerdpArgs += "-DWITH_CHANNELS=ON"
$freerdpArgs += "-DWITH_CLIENT_CHANNELS=ON"
foreach ($c in $channelsOn) { $freerdpArgs += "-DCHANNEL_$c=ON" }
foreach ($c in $channelsOff) { $freerdpArgs += "-DCHANNEL_$c=OFF" }

& $cmakeExe @freerdpArgs
if ($LASTEXITCODE -ne 0) { throw "FreeRDP cmake 配置失败（exit $LASTEXITCODE）" }
& $cmakeExe --build $freerdpBuild --parallel
if ($LASTEXITCODE -ne 0) { throw "FreeRDP 编译失败（exit $LASTEXITCODE）" }
& $cmakeExe --install $freerdpBuild
if ($LASTEXITCODE -ne 0) { throw "FreeRDP 安装失败（exit $LASTEXITCODE）" }

Write-Host "install 完成: $freerdpInstall" -ForegroundColor Green

if ($SkipSync) {
  Write-Host "验证构建完成，未改动 entry/libs（-SkipSync）。" -ForegroundColor Green
  exit 0
}

# ============================================================================
# 产物完整性校验：关键库全部存在才允许清理+同步，失败时保留 entry/libs 原状
# ============================================================================
$freerdpLibDir = Join-Path $freerdpInstall "lib"
$requiredLibs = @("libfreerdp3.so.3", "libfreerdp-client3.so.3", "libwinpr3.so.3")
foreach ($lib in $requiredLibs) {
  if (-not (Test-Path (Join-Path $freerdpLibDir $lib))) {
    throw "构建产物缺失: $freerdpLibDir\$lib，跳过 entry/libs 同步（原库保留）"
  }
}

$targetLibDir = Join-Path $root "entry\libs\$Arch"
New-Item -ItemType Directory -Path $targetLibDir -Force | Out-Null

# ---- 同步 .so：先删旧 3.10.3 全部文件名变体，再复制 3.31 产物 ----
# （libfreerdp_harmonyos.so 是 DevEco/wrapper 构建产物，不在清理范围）
$removePatterns = @(
  "libfreerdp3.so*",
  "libfreerdp-client3.so*",
  "libwinpr3.so*",
  "libwinpr-tools3.so*"
)
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

$allowPatterns = @("libfreerdp3.so*", "libfreerdp-client3.so*", "libwinpr3.so*")
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

# ============================================================================
# 头文件完整覆盖 entry\libs\include —— 禁止新旧混用！
# 3.31 的 settings_keys.h 枚举值与 3.10.3 完全不同，混用会静默写错配置
# （历史教训：0x20001 连接失败）。必须整目录删除后全量复制。
# ============================================================================
$installInclude = Join-Path $freerdpInstall "include"
$entryInclude = Join-Path $root "entry\libs\include"
New-Item -ItemType Directory -Path $entryInclude -Force | Out-Null

foreach ($d in @("freerdp3", "winpr3")) {
  $srcDir = Join-Path $installInclude $d
  if (-not (Test-Path $srcDir)) { throw "install include 缺少 $d，中止头文件同步" }
  $dstDir = Join-Path $entryInclude $d
  if (Test-Path $dstDir) { Remove-Item -Recurse -Force $dstDir }
  Copy-Item -Recurse $srcDir $dstDir
}

# install include 若出现其它顶层内容则提示人工确认（当前上游只有 freerdp3/winpr3）
Get-ChildItem -Path $installInclude | Where-Object { $_.Name -ne "freerdp3" -and $_.Name -ne "winpr3" } | ForEach-Object {
  Write-Warning "install include 存在未同步的顶层条目: $($_.Name)（请人工确认是否需要）"
}

Write-Host ".so 与头文件已同步到 entry\libs。" -ForegroundColor Green

# ---- NAPI Wrapper（可选；hvigor 构建 HAP 时也会重编 wrapper）----
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
  if ($LASTEXITCODE -ne 0) { throw "Wrapper cmake 配置失败（exit $LASTEXITCODE）" }
  & $cmakeExe --build $wrapperBuild --parallel
  if ($LASTEXITCODE -ne 0) { throw "Wrapper 编译失败（exit $LASTEXITCODE）" }
} else {
  Write-Host "跳过 NAPI Wrapper 构建（-SkipWrapper），wrapper 由 DevEco/hvigor 构建生成" -ForegroundColor Yellow
}

Write-Host "完成。请重新构建 HAP 并真机回归测试。" -ForegroundColor Green
