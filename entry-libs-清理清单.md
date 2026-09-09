# entry/libs 清理清单（FreeRDP 3.31 升级完成后）

> 更新日期：2026-09-07
> **状态：升级已实施完毕。** `entry/libs` 已整体切换到 FreeRDP **3.31.1-dev0**（master 快照），
> 包含 7 处鸿蒙适配（全部条件编译隔离），HAP 构建通过（BUILD SUCCESSFUL）。
> 上层 NAPI / XComponent 业务代码 **0 改动**（`git status` 确认 `entry/src` 无任何修改）。
> 本清单只做梳理，**不做任何删除**，请按"处置"列自行手动操作。

---

## 〇、当前状态速览

| 项 | 3.10.3（升级前） | 3.31.1-dev0（当前） |
|---|---|---|
| 源码树 | `entry/libs/FreeRDP-3.10.3/`（13 个补丁文件） | `entry/libs/FreeRDP/`（7 处适配，全部条件隔离） |
| 运行时库 | libfreerdp3.so.3.10.3 等 | **libfreerdp3.so.3.31.1** 等（SONAME 仍为 `lib*.so.3`） |
| 头文件 | 254 个（含错误的顺序编号 settings_keys.h，已修复） | **262 个**，来自 3.31 install，整体替换、无混用 |
| 音频后端 | rdpsnd-ohos（OpenSLES 补丁 6 个 + OHAudio 后端） | **rdpsnd-ohos（纯 OHAudio，OpenSLES 全部关闭，零补丁）** |
| 通道集合 | 17 个（默认全开） | **8 个**（cliprdr/rdpsnd/rdpdr/drdynvc/disp/rdpgfx/rdpei/drive） |
| 构建脚本 | `scripts/rebuild-ohos-native.ps1` | **`scripts/rebuild-ohos-native-3.31.ps1`** |
| HAP | — | 已重编 + 签名通过，包含全部 3.31.1 库 |

---

## 一、清理清单

### 1.1 立即可删（不影响任何构建）

| 条目 | 大小 | git 状态 | 处置 | 原因 |
|---|---:|---|---|---|
| `entry/libs/temp_freerdp/` | 目录已空（原 8.9 MB） | 1053 个删除待提交 | **可删目录本身** | 早期解包残留；内容已被手动清空，提交删除即可 |
| `entry/libs/freerdp-3.10.3.zip` | 11.4 MB | 已跟踪 | **可删** | 上游 3.10.3 原版 zip，仅作 diff 基准用，升级已完成（需考古时从 git 历史找回） |
| `native-install/freerdp-3.31-noohos/` | 66.5 MB | 未跟踪 | **可删** | `WITH_OHOS_AUDIO=OFF` 验证构建产物，验证已通过（见 §5.2），保留无意义 |

**立即可释放：约 78 MB**

### 1.2 回归通过后可删

| 条目 | 大小 | git 状态 | 处置 | 原因 |
|---|---:|---|---|---|
| `entry/libs/FreeRDP-3.10.3/` | 65.7 MB | 已跟踪（2713 个文件） | **真机回归通过后删** | 旧源码树。rdpsnd-ohos 后端已移植到新树；回退走 git（见 §7），不依赖此目录 |
| `native-install/freerdp/` | 67 MB | 未跟踪 | **真机回归通过后删** | 3.10.3 install 产物（含旧头文件），仅作回退期对照 |

**回归通过后可再释放：约 133 MB**

### 1.3 保留（勿删）

| 条目 | 大小 | 处置 | 原因 |
|---|---:|---|---|
| `entry/libs/FreeRDP/` | 68.8 MB | **保留，建议尽快 `git add` 入库** | 当前唯一构建源码树（3.31.1-dev0 + 7 处适配），目前未跟踪——不入库则升级成果不受版本控制保护 |
| `entry/libs/arm64-v8a/` | 50.1 MB | **保留** | HAP 打包运行时库：libfreerdp3 / libfreerdp-client3 / libwinpr3（各 3 个文件名变体）+ libfreerdp_harmonyos.so |
| `entry/libs/include/` | 2.1 MB | **保留** | wrapper 编译头文件（262 个，3.31 全量替换），**必须与 arm64-v8a 的 .so 同源，禁止混入旧头** |
| `native-install/freerdp-3.31/` | 66.6 MB | **保留** | 3.31 install 产物：头文件替换来源 + wrapper 独立构建（`-DFREERDP_DIR`）基准 |
| `native-install/deps/` | 24 MB | **保留** | OpenSSL 3.0.15 / zlib 静态库，3.31 构建复用（`WITH_INTERNAL_MD4/MD5/RC4` 同样依赖） |
| `scripts/rebuild-ohos-native-3.31.ps1` | — | **保留** | 当前构建脚本（用法见 §4） |
| `scripts/rebuild-ohos-native.ps1` | — | 保留 | 3.10.3 构建配方；回归通过且删除 FreeRDP-3.10.3 后可一并删除 |

### 1.4 可选清理（磁盘紧张时）

| 条目 | 大小 | 处置 | 原因 |
|---|---:|---|---|
| `native-build/` | 237.1 MB | **可整体删** | 纯构建缓存（3.10.3 + 3.31 两个构建树 + wrapper）。删除后下次构建为全量重编（约多花几分钟） |
| `native-build/freerdp-3.31-noohos/` | （包含在上行） | 优先删这个 | OFF 验证构建缓存，已完成使命 |

---

## 二、3.31 升级修改记录（7 处适配，全部条件隔离 / 纯追加）

> 全部位于 `entry/libs/FreeRDP/`（未跟踪新树）。核心原则：**上游原生逻辑零覆盖、零删除**，
> 鸿蒙逻辑一律用 `#if` / CMake `if()` 隔离，关闭开关即恢复上游行为。

### 适配 1：线程兼容（musl 无 pthread_cancel）

**文件：`winpr/libwinpr/thread/thread.c`（TerminateThread 函数内）**

修改前（上游）：
```c
#ifndef ANDROID
	pthread_cancel(thread->thread);
#else
	WLog_ERR(TAG, "Function not supported on this platform!");
#endif
```

修改后：
```c
/* OHOS musl does not provide pthread_cancel, the same applies to ANDROID.
 * Guard with __MUSL__ so all other platforms keep the original behavior. */
#if !defined(ANDROID) && !defined(__MUSL__)      /* ← 隔离点：__MUSL__ */
	pthread_cancel(thread->thread);
#else
	WLog_ERR(TAG, "Function not supported on this platform!");
#endif
```
- 仅扩大 `#if` 排除条件，`#else` 分支与上游逐字一致；非 OHOS 平台行为不变。

### 适配 2：新增 CMake 开关 `WITH_OHOS_AUDIO`（默认 OFF）

**文件：`cmake/ConfigOptions.cmake`（UNIX 音频选项块之后，纯追加）**
```cmake
# OpenHarmony OHAudio (AudioKit C API) sound backend, used by the rdpsnd client
# channel. Only meaningful when building against an OpenHarmony NDK sysroot
# (libohaudio.so). Default OFF, does not affect any other platform.
option(WITH_OHOS_AUDIO "use OpenHarmony OHAudio for sound" OFF)
```

### 适配 3：config.h.in 同步宏定义

**文件：`include/config/config.h.in`（`WITH_OPENSLES` 之后追加一行）**
```c
#cmakedefine WITH_OPENSLES
#cmakedefine WITH_OHOS_AUDIO      /* ← 新增 */
```

### 适配 4：rdpsnd 客户端 CMake 条件加载 ohos 子系统

**文件：`channels/rdpsnd/client/CMakeLists.txt`（opensles 块之后，纯追加）**
```cmake
if(WITH_OHOS_AUDIO)                                        /* ← 隔离点 */
  add_channel_client_subsystem(${MODULE_PREFIX} ${CHANNEL_NAME} "ohos" "")
endif()
```

### 适配 5：rdpsnd_main.c 后端注册表追加 ohos 条目

**文件：`channels/rdpsnd/client/rdpsnd_main.c`（rdpsnd_process_connect 的 backends[]）**
```c
#if defined(WITH_OPENSLES)
		{ "opensles", "" },
#endif
#if defined(WITH_OHOS_AUDIO)       /* ← 隔离点 */
		{ "ohos", "" },
#endif
```
- 与上游 ios/opensles/pulse/…/fake 条目同构；未定义宏时零影响。

### 适配 6：新建 `channels/rdpsnd/client/ohos/` 音频后端（完全隔离）

**新文件 1：`channels/rdpsnd/client/ohos/CMakeLists.txt`**（仿上游 opensles 子系统模式）
```cmake
define_channel_client_subsystem("rdpsnd" "ohos" "")

# libohaudio.so and the ohaudio/*.h headers are part of the OpenHarmony NDK
# sysroot, so plain 'ohaudio' resolves to -lohaudio when the OHOS toolchain
# file is used.
set(${MODULE_PREFIX}_SRCS rdpsnd_ohos.c)

set(${MODULE_PREFIX}_LIBS winpr freerdp ohaudio)

include_directories(..)

add_channel_client_subsystem_library(${MODULE_PREFIX} ${MODULE_NAME} ${CHANNEL_NAME} "" TRUE "")
```

**新文件 2：`channels/rdpsnd/client/ohos/rdpsnd_ohos.c`**（492 行，自 3.10.3 树移植，接口已逐一核对兼容）
- 机制：OHAudio C-API（`OH_AudioStreamBuilder_*` / `OH_AudioRenderer_*`）**pull 回调模式**，
  音频服务线程回调 `rdpsnd_ohos_write_cb` 从 **128 KiB 环形缓冲**拉数据，欠载时补静音；
- 线程模型：builder/renderer 指针仅通道线程访问；临界区只护环形缓冲；Stop/Release 不持锁（防回调死锁）；
- 延迟启动：首帧真实数据到达才 `OH_AudioRenderer_Start`（避免持续静音流被系统节流）；
- 仅使用 `@since 10/12` API（兼容 targetSdk 5.0.0(12)）；RDP 音量（0xFFFF=100%）映射 `OH_AudioRenderer_SetVolume`；
- 插件接口：`Open/FormatSupported/DefaultFormat/GetVolume/SetVolume/Start/Play/Close/Free`
  与新树 `rdpsndDevicePlugin`（`include/freerdp/client/rdpsnd.h`）完全匹配；
- 整个目录只在 `WITH_OHOS_AUDIO=ON` 时被适配 4 的 CMake 块引入，**不污染任何其它平台**。

### OpenSLES：零修改（跳过全部补丁）

3.10.3 树的 6 个 opensles 修复补丁**全部不再需要**：新树构建显式 `WITH_OPENSLES=OFF`，
opensles 子系统不参与编译（OFF 验证产物 0 个 opensles 符号，见 §5.2）。

---

## 三、完整 CMake 参数配置（脚本实际传参）

`scripts/rebuild-ohos-native-3.31.ps1` 传给 cmake 的全部关键参数：

| 分组 | 参数 | 说明 |
|---|---|---|
| 工具链 | `-DCMAKE_TOOLCHAIN_FILE=ohos.toolchain.cmake -DOHOS_ARCH=arm64-v8a -G Ninja` | NDK 自带 cmake/ninja |
| 产物 | `-DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=native-install/freerdp-3.31/arm64-v8a` | 独立安装目录，与 3.10.3 隔离 |
| 关可执行/服务端/示例/测试 | `-DWITH_CLIENT_SDL=OFF -DWITH_SERVER=OFF -DWITH_SERVER_CHANNELS=OFF -DWITH_SAMPLE=OFF -DBUILD_TESTING=OFF -DWITH_MANPAGES=OFF` | 只产出三个 .so |
| 客户端库 | `-DWITH_CLIENT=ON -DWITH_CLIENT_COMMON=ON` | libfreerdp-client3.so 必需 |
| 版本/第三方 | `-DUSE_VERSION_FROM_GIT_TAG=OFF -DWITH_THIRD_PARTY=OFF -DWITH_JSON_DISABLED=ON -DWITH_CCACHE=OFF -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF` | 源码目录无 git 元数据；离线禁 JSON 探测 |
| ★ 新默认值修正 | **`-DWITH_FUSE=OFF`** | 3.31 新默认 ON，OHOS 无 fuse3 |
| 平台裁剪 | `-DWITH_UNICODE_BUILTIN=ON -DWITH_SWSCALE=OFF -DWITH_KRB5=OFF -DWITH_CUPS=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_FFMPEG=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF` | 与 3.10.3 构建对齐 |
| 音频后端 | **`-DWITH_OHOS_AUDIO=ON -DWITH_OPENSLES=OFF`** | OpenSLES 全部跳过 |
| OpenSSL/zlib | `-DWITH_OPENSSL=ON -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON -DOPENSSL_ROOT_DIR=… -DOPENSSL_SSL_LIBRARY=libssl.a -DOPENSSL_CRYPTO_LIBRARY=libcrypto.a -DZLIB_LIBRARY=libz.a` | 复用 `native-install/deps` 静态库；内置 MD4/MD5/RC4 保障 NLA |
| 通道 | `-DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON`；**ON×8**：`CHANNEL_CLIPRDR / RDPSND / RDPDR / DRDYNVC / DISP / RDPGFX / RDPEI / DRIVE`；**OFF×23**：`CHANNEL_AINPUT / AUDIN / ECHO / ENCOMSP / GEOMETRY / GFXREDIR / LOCATION / PARALLEL / PRINTER / RAIL / RDP2TCP / RDPEAR / RDPECAM / RDPEMSC / RDPEWA / REMDESK / SERIAL / SMARTCARD / SSHAGENT / TELEMETRY / TSMF / URBDRC / VIDEO` | 上游通道逻辑零改动，只裁是否编译 |

**⚠ 绝对禁传：`WITHOUT_FREERDP_3x_DEPRECATED`**
3.31 中 `Authenticate / GatewayAuthenticate` 等接口标记废弃并由该宏守卫
（`include/freerdp/freerdp.h` 等多处 `#if !defined(WITHOUT_FREERDP_3x_DEPRECATED)`）。
wrapper 依赖这些回调签名，一旦定义此宏将导致 wrapper 编译失败。当前构建**未定义**该宏，
废弃接口正常参与编译，仅产生 `-Wdeprecated-declarations` 告警（预期行为）。

---

## 四、PowerShell 编译脚本

**`scripts/rebuild-ohos-native-3.31.ps1`**（UTF-8 BOM，PowerShell 5.1 可直接运行）

```powershell
# 正式构建：编译 + install + 同步 .so/头文件到 entry/libs + 预编 wrapper
powershell -ExecutionPolicy Bypass -File scripts\rebuild-ohos-native-3.31.ps1 `
  -NdkRoot "E:\HarmonyOs\DevelopTools\huawei\commandline-tools\command-line-tools\sdk\default\openharmony\native"

# 验证构建：WITH_OHOS_AUDIO=OFF（不改动 entry/libs）
powershell -ExecutionPolicy Bypass -File scripts\rebuild-ohos-native-3.31.ps1 `
  -NdkRoot "<同上>" -OhosAudioOff -SkipSync -SkipWrapper

# 全新重来（清 3.31 构建缓存）
powershell -ExecutionPolicy Bypass -File scripts\rebuild-ohos-native-3.31.ps1 -NdkRoot "<同上>" -Clean
```

脚本内置安全逻辑：
1. **产物完整性校验**：install 后先验证 `libfreerdp3.so.3 / libfreerdp-client3.so.3 / libwinpr3.so.3` 全部存在，失败则**保留 entry/libs 原状**并中止；
2. **.so 同步**：先删 `entry/libs/arm64-v8a` 下三个库的全部旧文件名变体（含 3.10.3），再复制 3.31 产物（`libfreerdp_harmonyos.so` 不动）；
3. **头文件铁律**：`entry/libs/include` 的 `freerdp3/`、`winpr3/` **整目录删除后全量复制** install 头文件（禁止新旧混用——3.31 的 `settings_keys.h` 枚举与 3.10.3 不同，混用会静默写错配置，历史教训：0x20001 连接失败）；
4. 文件被占用时重试 3 次，仍失败则报错中止。

构建完成后执行 HAP 构建：
```powershell
& "E:\HarmonyOs\DevelopTools\huawei\devecostudio\application\DevEco Studio\tools\hvigor\bin\hvigorw.bat" `
  --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap `
  --analyze=false --parallel --incremental --daemon=false
```

---

## 五、llvm 产物校验（命令 + 本次实测结果）

工具链前缀：`E:\HarmonyOs\DevelopTools\huawei\commandline-tools\command-line-tools\sdk\default\openharmony\native\llvm\bin\`
（下述命令在项目根目录执行；`$llvm` 为上述 bin 目录）

### 5.1 正式构建（WITH_OHOS_AUDIO=ON）实测 ✅

```powershell
# SONAME 与动态依赖
& "$llvm\llvm-readelf.exe" -d entry\libs\arm64-v8a\libfreerdp-client3.so.3 | Where-Object { $_ -match "NEEDED|SONAME" }
& "$llvm\llvm-readelf.exe" -d entry\libs\arm64-v8a\libfreerdp3.so.3     | Where-Object { $_ -match "NEEDED|SONAME" }
& "$llvm\llvm-readelf.exe" -d entry\libs\arm64-v8a\libwinpr3.so.3       | Where-Object { $_ -match "NEEDED|SONAME" }
```
实测结果：
| 库 | SONAME | NEEDED |
|---|---|---|
| libfreerdp-client3.so.3 | libfreerdp-client3.so.3 | libfreerdp3.so.3, **libwinpr3.so.3, libohaudio.so**, libc.so |
| libfreerdp3.so.3 | libfreerdp3.so.3 | libwinpr3.so.3, libc.so |
| libwinpr3.so.3 | libwinpr3.so.3 | **仅 libc.so** |

→ client3 链上系统 **libohaudio.so** ✓；**无 libssl/libcrypto**（OpenSSL 静态链入）✓

```powershell
# ohos 音频后端符号（新库带 symtab，用完整符号表）
& "$llvm\llvm-nm.exe" entry\libs\arm64-v8a\libfreerdp-client3.so.3 | Select-String "ohos"
```
实测：`ohos_freerdp_rdpsnd_client_subsystem_entry` + `rdpsnd_ohos_{open,play,close,free,write_cb,…}` 全部在库内，
与上游 `fake_freerdp_rdpsnd_client_subsystem_entry` **同级同构**（本地符号，由静态 addin 表内部解析）。

```powershell
# 静态 addin 注册表（构建目录生成物）
Select-String -Path native-build\freerdp-3.31\arm64-v8a\channels\client\tables.c -Pattern "ohos|subsystem_entry"
```
实测：`{ "ohos", "", ohos_freerdp_rdpsnd_client_subsystem_entry }` 与 `{ "fake", … }` 并列注册 ✓；
通道表恰好 8 个：cliprdr / rdpsnd(静态+动态) / rdpdr / drdynvc / disp / rdpgfx / rdpei / drive(DeviceServiceEntry) ✓

```powershell
# musl 修复生效验证（期望 0）
(& "$llvm\llvm-nm.exe" -D --undefined-only entry\libs\arm64-v8a\libwinpr3.so.3 | Select-String "pthread_cancel").Count
```
实测：**0** ✓（TerminateThread 不再引用 pthread_cancel，musl 可链接）

```powershell
# wrapper 导入符号核对（8 个，全部应 OK）
& "$llvm\llvm-nm.exe" -D --undefined-only entry\libs\arm64-v8a\libfreerdp_harmonyos.so | Select-String "freerdp_client_|freerdp_get_version"
```
实测：`freerdp_client_{context_new,context_free,settings_parse_command_line,start,stop,OnChannelConnectedEventHandler,OnChannelDisconnectedEventHandler}` + `freerdp_get_version_string` 共 8 个导入，与升级前一致，且新库全部导出（逐个 OK）✓

头文件版本核对：
```powershell
Select-String entry\libs\include\freerdp3\freerdp\version.h -Pattern "VERSION_MAJOR|VERSION_MINOR|VERSION_REVISION"
```
实测：`3 / 31 / 1` ✓；include 共 262 个 .h（3.10.3 为 254），含 `buildflags.h`、`utils/channel_pdu_tracker.h`、`winpr/assert-api.h` 等新头，旧 `config/` 子目录已随全量替换移除——**无新旧混用** ✓

HAP 打包核对：`entry-default-signed.hap` 内 `libs/arm64-v8a/` 含
`libfreerdp3.so.3.31.1 / libfreerdp-client3.so.3.31.1 / libwinpr3.so.3.31.1 / libfreerdp_harmonyos.so / libc++_shared.so`（各 3 个名字变体，strip 后 7.7 MB / 437 KB / 6.6 MB / 137 KB）✓

### 5.2 回归校验重点 ①：WITH_OHOS_AUDIO=OFF 可正常编译链接 ✅

```powershell
powershell -ExecutionPolicy Bypass -File scripts\rebuild-ohos-native-3.31.ps1 `
  -NdkRoot "<NDK>" -OhosAudioOff -SkipSync -SkipWrapper
# 之后核对：
& "$llvm\llvm-nm.exe" -D native-install\freerdp-3.31-noohos\arm64-v8a\lib\libfreerdp-client3.so.3 | Select-String "ohos|opensles"
```
实测（2026-09-07）：**全库编译+链接成功**；client3 动态符号中 ohos/opensles 匹配数 **0**；
NEEDED 仅 `libfreerdp3.so.3 / libwinpr3.so.3 / libc.so`（无 libohaudio）——
关闭开关后库结构与上游原生构建完全一致，rdpsnd 自动回落 fake 后端。验证产物 `native-install/freerdp-3.31-noohos/` 可删。

### 5.3 回归校验重点 ②③：上游逻辑保留 & 废弃接口仅告警 ✅

- **上游逻辑保留**：7 处适配全部为"追加块 / 扩大 #if 条件"，无一行上游代码被删除或改写
  （thread.c 仅把 `#ifndef ANDROID` 改为 `#if !defined(ANDROID) && !defined(__MUSL__)`，`#else` 分支原样保留；
  其余均为新增 `if(WITH_OHOS_AUDIO)` 块、`#if defined(WITH_OHOS_AUDIO)` 守卫、新目录）。
  关闭 `WITH_OHOS_AUDIO` 后除 thread.c 单点外与上游零差异（见 5.2 实测）。
- **废弃接口仅告警**：wrapper 对 3.31 头文件全量重编，`-Wdeprecated-declarations` 告警出现
  （如 `SEC_WINPR_KERBEROS_SETTINGS [since 3.31.0] use ..._V2`），**无任何编译错误**；
  `Authenticate / GatewayAuthenticate` 等回调链正常参与编译与链接（未定义 `WITHOUT_FREERDP_3x_DEPRECATED`）。

---

## 六、真机回归测试清单

> 前置：DevEco 签名正常，`hvigorw assembleHap` 后安装 `entry-default-signed.hap`。
> 建议顺序执行，任一项失败即停止并按 §7 回退。

### A. 原有业务功能（全量覆盖）

| # | 用例 | 操作与预期 |
|---|---|---|
| 1 | NLA 连接 | `/sec:nla` + 账号密码登录 Windows 10/11，进入桌面（重点：settings 枚举新值生效，不出现 0x20001） |
| 2 | TLS / RDP 安全模式 | `/sec:tls`、`sec:rdp` 各连一次成功 |
| 3 | 域账户 | `/d:域名 /u:user /p:pwd` 登录域机 |
| 4 | 网关 | `/gateway:g:<gw>` 经 RD Gateway 连接内网机 |
| 5 | gdi 软件渲染 | `/gdi:sw` 默认路径，桌面色彩/文字正常，无花屏撕裂 |
| 6 | 横竖屏切换 | 设备旋转：桌面随动、无半屏/黑边；竖→横→竖 3 轮，画面与输入正常（重点回归：gdi_resize 修复仍生效） |
| 7 | 动态分辨率 | `/dynamic-resolution` + 服务端改分辨率，画面自适应 |
| 8 | RemoteFX / GFX | `/rfx`、`/gfx`、`/gfx:AVC444` 各连一次（AVC444 需服务端支持），渲染正常 |
| 9 | 音频播放（rdpsnd-ohos） | `/sound:latency:150,quality:medium`，远端播放音乐/视频：有声、无爆音、延迟可接受；`/audio-mode:2`（本机播放）验证 |
| 10 | 音量控制 | 远端音量滑条 ↔ 本端音量联动（SetVolume 映射） |
| 11 | 剪贴板：文本下行 | 远端复制 → 本端粘贴，中文/emoji 正确 |
| 12 | 剪贴板：文本上行 | 本端复制 → 远端粘贴 |
| 13 | 剪贴板：文件 | 远端↔本端文件复制粘贴（如业务启用） |
| 14 | 磁盘重定向 | `/drive:sdcard,/data/storage`：远端资源管理器可见共享盘，读写文件正常（重点回归：CHANNEL_DRIVE 裁剪后仍在） |
| 15 | 键鼠输入 | 物理键盘、软键盘、鼠标/触摸板点击、拖拽、右键、滚轮 |
| 16 | 触摸 rdpei | 触屏手势（点击、拖动、双指缩放）作用于远端 |
| 17 | 自动重连 | 连接中关闭 Wi-Fi/飞行模式 10s 再恢复：自动重连成功且画面恢复（compat 层 freerdp_client_auto_reconnect） |
| 18 | TCP keepalive | 保持连接空闲 30 分钟以上不断开 |
| 19 | 会话保持 | `/admin` 管理会话登录一次验证 |
| 20 | 断开清理 | 正常断开连接：无残留进程/音频线程，连续连接-断开 5 次无泄漏（close 路径销毁 renderer） |
| 21 | 后台/前台切换 | 应用切后台再回前台：会话保持、画面刷新正常（compat 层 enter_background_mode） |
| 22 | 并发通道 | 剪贴板 + 磁盘 + 音频 + disp 同时工作（连接期间复制文件+播放音乐+旋转屏幕） |

### B. 升级专项确认

| # | 用例 | 预期 |
|---|---|---|
| B1 | `WITH_OHOS_AUDIO=OFF` 构建 | 已实测通过（§5.2）；如需复验：`-OhosAudioOff -SkipSync -SkipWrapper` |
| B2 | 上游新版本特性未被破坏 | 对照 A 组全过即证明：上游 3.11→3.31 的连接/渲染/通道修复均在生效路径上 |
| B3 | 废弃接口仅告警 | 已实测（§5.3）；HAP 构建日志仅 `-Wdeprecated-declarations`，无错误 |

### C. 上游新版本行为抽样（3.11~3.31 变化点）

- 连接 Windows Server 2022/2025 与 Win11 24H2（新版服务端协商路径）；
- 长路径/特殊字符剪贴板文件（上游 clipboard 若干修复）；
- `/kbd:unicode:on` 中文输入法远端输入（键盘 unicode 路径）；
- `/cert:ignore` 与自签名证书链（证书错误处理上游有更新）；
- 弱网（限速 1Mbps）下 `/network:auto` 自动降级。

---

## 七、git 回退操作（快速切回 3.10.3）

> 旧版完整基线：提交 `5368df9` "feat: 鸿蒙兼容层开发"（含 3.10.3 补丁树 + 旧 .so + 旧 include）。

### 场景 0（强烈建议先做）：升级成果入库

当前升级改动尚未提交（`entry/libs/FreeRDP/`、新脚本、3.31 .so/头文件等均为未跟踪/修改状态）。
**先提交，升级才受版本保护**：
```powershell
git add -A
git commit -m "feat: 升级 FreeRDP 至 3.31.1-dev0（OHAudio 音频后端移植，通道裁剪 8 开 23 关）"
```
（注：`entry/libs/temp_freerdp/` 的 1053 个删除为用户此前手动清理，将随本次提交一并入库。）

### 场景 1：升级已提交 → 回退

```powershell
# 整树切回旧提交（最干净，新提交里新增的文件不会残留）
git checkout -b rollback-freerdp-3.10.3 5368df9

# 然后重编 HAP（旧 .so/旧头已随 checkout 恢复）
& "E:\HarmonyOs\DevelopTools\huawei\devecostudio\application\DevEco Studio\tools\hvigor\bin\hvigorw.bat" `
  --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap `
  --analyze=false --parallel --incremental --daemon=false
```
或者不切分支，仅还原库与头文件（保留 3.31 源码树在盘）：
```powershell
git checkout 5368df9 -- entry/libs/arm64-v8a entry/libs/include
git clean -fd entry/libs/arm64-v8a entry/libs/include   # 清掉 3.31.1 后缀文件与新头
# 再执行上面的 hvigorw 命令
```

### 场景 2：升级未提交（当前状态）→ 回退

```powershell
# 还原被替换的跟踪文件（旧 .so、旧 include）
git checkout -- entry/libs/arm64-v8a entry/libs/include entry/libs/temp_freerdp
# 清掉全部新增未跟踪产物（3.31 源码树、脚本、.so.3.31.1、新头、install 目录）
git clean -fd entry/libs/FreeRDP scripts/rebuild-ohos-native-3.31.ps1
# 重编 HAP（同场景 1 的 hvigorw 命令）
```
（`temp_freerdp` 视需要选择是否还原——它是已确认可删的残留。）

### 回退后验证

- `llvm-readelf -d entry\libs\arm64-v8a\libfreerdp3.so.3` 应无 NEEDED（旧版 soname 命名不同属正常）；
- HAP 构建通过后按 §6.A 抽测 #1/#6/#9/#14 四项即可确认回退成功。

---

## 附：与《FreeRDP-3.31-升级评估.md》的对应关系

评估文档（升级前撰写）中的 R1~R8 风险项实施结果：
- R1 settings 枚举值重排 → 已按"install 头文件全量覆盖"铁律规避（§4 脚本步骤 3），wrapper 全量重编；
- R2 结构体布局 → wrapper 8 个导入符号 + 回调签名逐一核对，实测无变化；
- R3 OpenSSL 4.0.1 上游参考 → 实测本地 OpenSSL 3.0.15 + INTERNAL_MD4/MD5/RC4 编译链接通过；
- R4 master 快照 → 已按评估建议实施 7 处适配并验证；建议尽快 git 提交锁定（§7 场景 0）；
- R5 WITH_FUSE 默认 ON → 已显式 OFF，构建通过；
- R6-R8 → 均未发生（JsonDetect 已用 WITH_JSON_DISABLED=ON 显式关闭；通道名已按新树 ChannelOptions.cmake 逐一核实）。
