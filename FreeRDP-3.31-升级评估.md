# FreeRDP 3.10.3 → 3.31.1-dev0 升级评估（鸿蒙适配）

> ✅ **本评估已实施完成（2026-09-07）**：7 处适配全部落地，双构建（OHOS_AUDIO ON/OFF）通过，
> HAP 构建成功。实施记录、实测数据、回归清单与回退操作见《entry-libs-清理清单.md》。

> 评估日期：2026-09-07
> 升级目标：`entry/libs/FreeRDP`（最新拉取的 master 快照，3.31.1-dev0）
> 评估范围：**仅 FreeRDP 第三方库构建逻辑**，不涉及上层 NAPI 业务代码改动

---

## 1. 版本对比

| | 现状 | 升级目标 |
|---|---|---|
| 版本 | FreeRDP 3.10.3（release，本地树带 13 个文件的鸿蒙补丁） | FreeRDP **3.31.1-dev0**（master 快照，2026-09-07 拉取，无 git 元数据） |
| 预编译库 | libfreerdp3.so.3.10.3 / libfreerdp-client3.so.3.10.3 / libwinpr3.so.3.10.3（arm64-v8a，50.8 MB） | 待构建（SONAME 将变为 .so.3.31） |
| 音频后端 | rdpsnd-ohos（自研 OHAudio，commit 5368df9 加入） | 需移植补丁 |
| wrapper 依赖 | client3 的 7 个符号 + core 的一批 API（见 3.1） | 全部核对存活 |

**版本选择建议**：3.31.1-dev0 是开发版快照，上游无稳定性承诺。若条件允许，建议改用最新 **stable tag**（如 3.31.0）替代 master 快照，其余步骤不变。若坚持当前快照，应立即将其 `git add` 锁定，避免上游漂移。

---

## 2. 必须移植的鸿蒙补丁（完整清单）

本地 3.10.3 树相对上游的全部差异已由项目仓库 commit `5368df9` 完整记录，提取方式：

```powershell
git show 5368df9 -- entry/libs/FreeRDP-3.10.3 > harmonyos-3.10.3.patch
```

逐项移植到 `entry/libs/FreeRDP`：

| # | 旧树文件 | 新树对应位置 | 移植难度 | 说明 |
|---|---|---|---|---|
| 1 | `winpr/libwinpr/thread/thread.c` | 同路径（新树 1049 行处） | 低（1 行） | `#ifndef ANDROID` → `#if !defined(ANDROID) && !defined(__MUSL__)`（OHOS musl 无 pthread_cancel） |
| 2 | `cmake/ConfigOptions.cmake` | 同路径 | 低（2 行） | `option(WITH_OHOS_AUDIO "Enable sound redirection using OpenHarmony OHAudio" OFF)` |
| 3 | `include/config/config.h.in` | 同路径 | 低（1 行） | `#cmakedefine WITH_OHOS_AUDIO` |
| 4 | `channels/rdpsnd/client/CMakeLists.txt` | 同路径（结构未变） | 低（4 行） | `if(WITH_OHOS_AUDIO) add_channel_client_subsystem(... "ohos" "") endif()` |
| 5 | `channels/rdpsnd/client/rdpsnd_main.c` | 同路径（backends[] 结构未变，新树 1036 行起） | 低（3 行） | backends[] 首位插入 `{ "ohos", "" }`（`#if defined(WITH_OHOS_AUDIO)` 守卫） |
| 6 | `channels/rdpsnd/client/ohos/CMakeLists.txt` | 新目录 | **整目录复制** | 新增文件 |
| 7 | `channels/rdpsnd/client/ohos/rdpsnd_ohos.c` | 同上 | **整目录复制**（492 行） | OHAudio 后端：pull 模式回调 + 128KB 环形缓冲，仅用 @since 10/12 API，链系统 `libohaudio.so` |
| 8–13 | `channels/{rdpsnd,audin}/client/opensles/*` 共 6 文件 | — | **可不移植** | 新构建 `WITH_OPENSLES=OFF` 不编译 OpenSLES；仅当将来重新启用 OpenSLES 时才需要（内容：设备关闭时序修复、去 WINPR_ASSERT、头文件适配） |

> 补丁 #1–#7 均为机械移植，无上下文冲突风险（已核对新树对应位置的代码结构未变）。

---

## 3. API 变更风险点（wrapper 编译面逐一核对）

wrapper（`harmonyos_freerdp.cpp` / `freerdp_client_compat.c` / `harmonyos_cliprdr.c`）的全部外部依赖已枚举并逐项比对新树头文件/源码。

### 3.1 硬依赖核对结果：**全部存活，签名不变**

**libfreerdp-client3 的 7 个导入符号**（llvm-nm 从 libfreerdp_harmonyos.so 提取的动态未定义符号 ∩ client3 导出表）：

| 符号 | 新树位置 | 结论 |
|---|---|---|
| `freerdp_client_context_new` / `_free` | client/common/client.c | 存在 |
| `freerdp_client_settings_parse_command_line`（不带 `_arguments` 的简写） | client/common/client.c（包一层调 `..._ex`） | **存在且签名不变**（注意：头文件只声明 `_arguments` 版本，简写版是 ABI 保留的导出函数，3.31 仍在） |
| `freerdp_client_start` / `freerdp_client_stop` | client/common/client.c | 存在 |
| `freerdp_client_OnChannelConnectedEventHandler` / `OnChannelDisconnectedEventHandler` | client/common/client.c | 存在 |

**libfreerdp3 的 core API**：freerdp_connect/disconnect/reconnect/abort_connect_context/free、freerdp_check_event_handles/get_event_handles、freerdp_settings_get_bool/get_uint32/set_bool/set_uint32/set_string、freerdp_input_send_{mouse,keyboard,unicode_keyboard,synchronize}_event、freerdp_image_copy、freerdp_get_last_error{,_category,_string}、freerdp_get_version_string、freerdp_is_active_state、freerdp_shall_disconnect_context —— 全部存在，签名比对：
- `freerdp_input_send_*`：3.10.3 已是 `BOOL` 返回，**无变化**；
- `freerdp_image_copy`：参数列表一致（新增 `WINPR_RESTRICT` 编译注解，无 ABI 影响）。

**30 个 settings 键**（wrapper/compat 实际使用的全部命名常量）：AudioCapture、AudioPlayback、AutoReconnectionEnabled、AutoReconnectMaxRetries、ColorDepth、CompressionEnabled、ConfigPath、ConnectionType、DeactivateClientDecoding、DesktopHeight、DesktopWidth、FastPathOutput、IgnoreCertificate、NegotiateSecurityLayer、NlaSecurity、RdpSecurity、RemoteConsoleAudio、RequestedProtocols、SupportDynamicChannels、SupportGraphicsPipeline、SupportMonitorLayoutPdu、SupportStatusInfoPdu、SuppressOutput、SynchronousDynamicChannels、SynchronousStaticChannels、TcpKeepAlive(+Delay/Interval/Retries)、TlsSecurity —— **全部存活**（settings_keys.h 由构建时生成，枚举**值**会变，见 3.3-R1）。

**结构体与回调**：
- `rdpGdi`：`primary_buffer`、`stride`、`width`、`height` 字段仍在（新树 gdi.h 498/508 行附近）；`gdi_resize(rdpGdi*, UINT32, UINT32)` 签名不变（wrapper 旋转修复依赖它，升级后继续有效）；
- `DispClientContext->SendMonitorLayout`：签名不变（仅加 NODISCARD）；
- cliprdr 全套回调（`UINT (*)(CliprdrClientContext*, const CLIPRDR_*)`）：签名不变（仅加 NODISCARD），harmonyos_cliprdr.c 的 6 个回调注册无需改动；
- update 回调 `BeginPaint/EndPaint/DesktopResize`：typedef 不变（仅加 NODISCARD）。

### 3.2 已发生变更、需要注意的项

| 变更 | 影响 | 对策 |
|---|---|---|
| `freerdp` 实例结构布局调整：`Authenticate`/`GatewayAuthenticate`（offset 50/56）标记 deprecated（since 3.25），移入 `!WITHOUT_FREERDP_3x_DEPRECATED` 守卫；`reserved[2]` 移除；`pSendChannelPacket` 字段移除 | wrapper 第 1002/1003 行仍在赋值这两个回调 | **构建新库时绝不能传 `-DWITHOUT_FREERDP_3x_DEPRECATED=ON`**（默认不定义即可，仅产生编译告警）；中期迁移到 `AuthenticateEx` |
| 大量 API 加 `WINPR_ATTR_NODISCARD` | wrapper 若忽略返回值且开 `-Wunused-result`/`-Werror` 会报错 | wrapper 当前未开 `-Werror`，暂无影响；建议顺手处理编译告警 |
| `pSaveSessionInfo` 参数 `void*` → `const void*` | wrapper 未注册该回调 | 无 |
| 移除：`freerdp_get_param_*` 旧式参数接口、`freerdp_device_equal`、`AUTH_SMARTCARD_PIN` 枚举值 | wrapper/compat 未使用 | 无 |
| `freerdp_client_settings_parse_command_line_ex` 的回调参数改为 `freerdp_command_line_handle_option_t` 类型别名 | wrapper 只用简写版 | 无 |
| `settings.h` 头文件大规模重构（+263/-110 行，多为文档与拆分） | 编译期 | wrapper 重编译时自动适配 |

### 3.3 风险分级

| 级别 | 风险 | 说明 |
|---|---|---|
| **高（已有既定防护）** | R1：settings_keys 枚举值在新版本重排 | 唯一正确做法：**新库 install 输出的头文件整体替换 `entry/libs/include`，wrapper 全量重编译**。历史上"顺序枚举假头文件"曾导致连接 0x20001 静默失败，严禁新旧混用 |
| **高（已有既定防护）** | R2：wrapper 直接访问结构体内部字段（`context->gdi->primary_buffer`、`gdi->width/height/stride`） | 新版本字段布局有变（freerdp 实例结构 offset 重排）。C 编译器按新头文件重算 offset，只要**头/库同源**即安全；跨 .so 无内联导出，无额外风险 |
| 中 | R3：OpenSSL 版本 | 新树 CI 参考版本为 **openssl-4.0.1**（`cmake/DepVersions.cmake`，仅 CI 下载用，无最低版本强校验）。本地 3.0.15 静态库预计可编译（FreeRDP 使用稳定 EVP API），**需实测**；若报废弃接口错误，再评估升级 OpenSSL（连带 rebuild-ohos-deps）。注意保持 `WITH_INTERNAL_MD4/MD5/RC4=ON`（无 legacy provider 时 NLA 必需，3.31 同样适用） |
| 中 | R4：master 快照不稳定 | 3.31.1-dev0 非发布版，上游仍在变动 | 建议（1）锁定快照入库；或（2）改用 stable tag |
| 低 | R5：`WITH_FUSE` 新默认 ON | OHOS 非 ANDROID 会命中默认值 → configure 阶段 pkg-config 找 fuse3 失败 | 显式 `-DWITH_FUSE=OFF` |
| 低 | R6：JSON 依赖探测 | `JsonDetect.cmake` 找不到 cjson/json-c/jansson 时自动降级"无 JSON 支持"（当前 3.10.3 构建即如此，功能无损） | 可显式 `-DWITH_JSON_DISABLED=ON` 锁定行为 |
| 低 | R7：`WITH_CWALK` 默认 OFF | 开启才会 FetchContent 联网拉取 cwalk | 保持 OFF，离线构建无忧 |
| 低 | R8：版本号探测 | 源码目录无 git 元数据，`USE_VERSION_FROM_GIT_TAG` 默认 ON 时探测结果不可控 | 显式 `-DUSE_VERSION_FROM_GIT_TAG=OFF`，固定为 3.31.1-dev0 |

### 3.4 通道需求（由 ETS 侧实参推导，LibFreeRDP.ets:465-580）

| 命令行参数 | 依赖通道 | 结论 |
|---|---|---|
| `/clipboard` | cliprdr | **保留** |
| `/dynamic-resolution` | disp（经 drdynvc） | **保留** |
| `/gfx`、`/gfx:AVC444` | rdpgfx + drdynvc（AVC444 解码需 FFMPEG，当前关闭则自动降级） | **保留 rdpgfx/drdynvc** |
| `/sound`、`/audio-mode` | rdpsnd（ohos 后端） | **保留** |
| `/microphone`（UI 可选） | audin | **注意**：`WITH_OPENSLES=OFF` 后 audin 无任何可用后端，该功能实际不可用（与当前 3.10.3+ohos 构建行为一致）。建议 `CHANNEL_AUDIN=OFF` 并在 UI 禁用麦克风开关；若保留编译也只是徒增体积 |
| `/drive:sdcard`（UI 可选） | rdpdr + drive | **保留** |
| `/rfx`、`/sec:*`、`/gateway:g:*`、`/kbd:unicode:on`、`/cert:ignore`、`/network:auto` | core / gateway（libfreerdp3 内） | 不涉通道裁剪 |

---

## 4. 鸿蒙适配 CMake 配置（完整参数表）

基于 `scripts/rebuild-ohos-native.ps1` 现有配方改造，改动点已用 `★` 标注：

```powershell
$freerdpArgs = @(
  "-S", "<entry\libs\FreeRDP>",                  # ★ 源码切到新树
  "-B", "<native-build\freerdp-3.31\arm64-v8a>", # ★ 独立构建目录，保留 3.10.3 现场
  "-G", "Ninja",
  "-DCMAKE_MAKE_PROGRAM=$ninjaExe",
  "-DCMAKE_TOOLCHAIN_FILE=$toolchain",           # OHOS NDK ohos.toolchain.cmake
  "-DOHOS_ARCH=arm64-v8a",
  "-DCMAKE_BUILD_TYPE=Release",
  "-DCMAKE_INSTALL_PREFIX=<native-install\freerdp-3.31\arm64-v8a>",   # ★ 独立安装目录
  # ---------- 目标形态：只出三个 so ----------
  "-DBUILD_SHARED_LIBS=ON",
  "-DWITH_CLIENT_COMMON=ON",                     # libfreerdp-client3（wrapper 依赖）
  "-DWITH_CLIENT=OFF",                           # ★ 不编任何客户端可执行程序
  "-DWITH_CLIENT_SDL=OFF",
  "-DWITH_SAMPLE=OFF",
  "-DWITH_SERVER=OFF",
  "-DWITH_SERVER_CHANNELS=OFF",                  # ★ 新树默认 ON，白编 server 侧通道对象
  # ---------- 音频 ----------
  "-DWITH_OHOS_AUDIO=ON",                        # 自研 OHAudio 后端（补丁 #2/#4/#5/#6/#7）
  "-DWITH_OPENSLES=OFF",
  # ---------- 平台适配（沿用 3.10.3 验证过的组合） ----------
  "-DWITH_UNICODE_BUILTIN=ON",
  "-DWITH_SWSCALE=OFF",
  "-DWITH_CAIRO=OFF",
  "-DWITH_INTERNAL_MD4=ON",                      # OHOS 静态链 OpenSSL 3.x 无 legacy provider，
  "-DWITH_INTERNAL_MD5=ON",                      # NLA(CredSSP/NTLM) 依赖这三个内置实现
  "-DWITH_INTERNAL_RC4=ON",
  "-DWITH_FUSE=OFF",                             # ★ 新默认 ON，必须显式关
  "-DWITH_X11=OFF", "-DWITH_WAYLAND=OFF",
  "-DWITH_KRB5=OFF", "-DWITH_PULSE=OFF", "-DWITH_ALSA=OFF", "-DWITH_CUPS=OFF",
  "-DWITH_FFMPEG=OFF",
  "-DWITH_CCACHE=OFF", "-DWITH_MANPAGES=OFF",
  "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF",    # OHOS lld ThinLTO remark 当错误，关闭
  # ---------- 新增确定性开关 ----------
  "-DUSE_VERSION_FROM_GIT_TAG=OFF",              # ★ 固定 3.31.1-dev0
  "-DWITH_JSON_DISABLED=ON",                     # ★ 锁定无 JSON（当前行为一致）
  # 注意：不要传 WITHOUT_FREERDP_3x_DEPRECATED（wrapper 仍用 Authenticate/GatewayAuthenticate）
  # ---------- 通道裁剪 ----------
  "-DCHANNEL_CLIPRDR=ON", "-DCHANNEL_RDPDR=ON", "-DCHANNEL_RDPSND=ON",
  "-DCHANNEL_DRDYNVC=ON", "-DCHANNEL_DISP=ON", "-DCHANNEL_RDPGFX=ON", "-DCHANNEL_RDPEI=ON",
  "-DCHANNEL_AUDIN=OFF",                         # ★ 无后端可用（见 3.4）
  "-DCHANNEL_DRIVE=ON",                          # /drive:sdcard 重定向需要（rdpdr 的设备子系统）
  "-DCHANNEL_AINPUT=OFF",
  "-DCHANNEL_ECHO=OFF", "-DCHANNEL_ENCOMSP=OFF", "-DCHANNEL_GEOMETRY=OFF",
  "-DCHANNEL_LOCATION=OFF", "-DCHANNEL_RAIL=OFF", "-DCHANNEL_RDP2TCP=OFF",
  "-DCHANNEL_GFXREDIR=OFF",
  "-DCHANNEL_RDPEAR=OFF", "-DCHANNEL_RDPECAM=OFF",
  "-DCHANNEL_RDPEMSC=OFF", "-DCHANNEL_RDPEWA=OFF",
  "-DCHANNEL_REMDESK=OFF", "-DCHANNEL_SERIAL=OFF", "-DCHANNEL_PARALLEL=OFF",
  "-DCHANNEL_PRINTER=OFF", "-DCHANNEL_SMARTCARD=OFF",
  "-DCHANNEL_SSHAGENT=OFF", "-DCHANNEL_TELEMETRY=OFF",
  "-DCHANNEL_TSMF=OFF", "-DCHANNEL_URBDRC=OFF", "-DCHANNEL_VIDEO=OFF",
  "-DCHANNEL_GFXREDIR=OFF",
  # ---------- 依赖（复用 native-install/deps） ----------
  "-DWITH_OPENSSL=ON",
  "-DOPENSSL_ROOT_DIR=<deps\openssl>",
  "-DOPENSSL_INCLUDE_DIR=<deps\openssl\include>",
  "-DOPENSSL_SSL_LIBRARY=<deps\openssl\lib\libssl.a>",
  "-DOPENSSL_CRYPTO_LIBRARY=<deps\openssl\lib\libcrypto.a>",
  "-DZLIB_ROOT=<deps\zlib>",
  "-DZLIB_INCLUDE_DIR=<deps\zlib\include>",
  "-DZLIB_LIBRARY=<deps\zlib\lib\libz.a>"
)
```

> 通道名以新树 `channels/*/ChannelOptions.cmake` 实际定义为准（共 31 个通道，`CHANNEL_<NAME>` 全大写：ainput, audin, cliprdr, disp, drdynvc, drive, echo, encomsp, geometry, gfxredir, location, parallel, printer, rail, rdp2tcp, rdpdr, rdpear, rdpecam, rdpei, rdpemsc, rdpewa, rdpgfx, rdpsnd, remdesk, serial, smartcard, sshagent, telemetry, tsmf, urbdrc, video）。configure 输出的 "Adding xxx channel" 日志可最终确认生效集合。若担心首版裁剪引入回归，可先只关确知无用的大块（audin/rdpecam/urbdrc/rdpear/rdpewa/sshagent/telemetry/tsmf/video/printer/smartcard/serial/parallel/rail/rdp2tcp/remdesk/location/geometry/echo/encomsp/ainput/gfxredir/rdpemsc），与当前 3.10.3 库内通道集合对齐后再逐步收紧。

### 产物预期

| 文件 | 说明 |
|---|---|
| libwinpr3.so.3(.31) | 无 OpenSSL 动态依赖（静态链） |
| libfreerdp3.so.3(.31) | NEEDED libwinpr3.so.3 |
| libfreerdp-client3.so.3(.31) | NEEDED libfreerdp3 + libwinpr3 + **libohaudio.so**（ohos 音频后端）；内含 cliprdr/rdpsnd(+ohos)/disp/drdynvc/rdpgfx/rdpei/rdpdr 通道客户端与 7 个 wrapper 依赖符号 |

---

## 5. 编译步骤

### 第 1 步：移植补丁
按第 2 节清单将 #1–#7 打入 `entry/libs/FreeRDP`（#8–#13 跳过）。以 `git show 5368df9 -- entry/libs/FreeRDP-3.10.3` 的 diff 为准。

### 第 2 步：建升级版构建脚本
复制 `scripts/rebuild-ohos-native.ps1` 为 `scripts/rebuild-ohos-native-3.31.ps1`：
- `$freerdpSrc` 指向 `entry\libs\FreeRDP`
- 构建目录 `native-build\freerdp-3.31\<arch>`、安装目录 `native-install\freerdp-3.31\<arch>`（与 3.10.3 现场隔离）
- 按第 4 节参数表增改 `-D` 开关
- **同步逻辑保持"先校验产物完整性，再清理 entry/libs/arm64-v8a"**（脚本已有）

### 第 3 步：构建
```powershell
# 依赖复用（已存在于 native-install/deps/arm64-v8a）
powershell -File scripts\rebuild-ohos-deps.ps1        # 仅在 deps 缺失时执行

powershell -File scripts\rebuild-ohos-native-3.31.ps1
```

### 第 4 步：整体替换头文件（关键！）
```powershell
Remove-Item -Recurse -Force entry\libs\include\freerdp3, entry\libs\include\winpr3
Copy-Item -Recurse native-install\freerdp-3.31\arm64-v8a\include\freerdp3 entry\libs\include\
Copy-Item -Recurse native-install\freerdp-3.31\arm64-v8a\include\winpr3  entry\libs\include\
```
> install 布局以实际输出为准。**严禁**与旧头文件混合；settings_keys.h 枚举值必须与新 .so 同源（风险 R1）。

### 第 5 步：重建 HAP
删除 `entry/.cxx`（或 `build/`）缓存后：
```powershell
& "E:\HarmonyOs\DevelopTools\huawei\devecostudio\application\DevEco Studio\tools\hvigor\bin\hvigorw.bat" `
  --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap `
  --analyze=false --parallel --incremental --daemon=false
```
wrapper 编译告警（NODISCARD、Authenticate deprecated）可正常出现，不应有 error。

### 第 6 步：构建后验证
```powershell
$llvm = "E:\...\native\llvm\bin"
# 1) SONAME 已是 3.31
& "$llvm\llvm-readelf.exe" -d entry\libs\arm64-v8a\libfreerdp3.so | Select-String "SONAME"
# 2) 7 个 client3 符号 + ohos 后端
& "$llvm\llvm-nm.exe" --defined-only --dynamic entry\libs\arm64-v8a\libfreerdp-client3.so |
  Select-String "freerdp_client_context_new|ohos_freerdp_rdpsnd_client_subsystem_entry"
# 3) 动态依赖：无 libssl/libcrypto；client3 有 libohaudio.so
# 4) settings 枚举同源抽查：反汇编 wrapper 中任一 freerdp_settings_set_bool 调用点，
#    mov 立即数应等于新头文件中该键的值（如 SynchronousStaticChannels 的新值）
```

### 第 7 步：真机回归清单
- [ ] 标准连接（NLA/TLS/RDP 三种 /sec 模式）
- [ ] 横竖屏切换：Display Control resize 生效、无半屏/花屏（gdi_resize 路径）
- [ ] 声音播放（rdpsnd-ohos 后端，含 latency/quality 参数）
- [ ] 双向剪贴板（harmonyos_cliprdr：文本收发）
- [ ] /drive:sdcard 重定向（若启用）
- [ ] 网关连接（/gateway:g:）
- [ ] 断线自动重连（compat 层 auto_reconnect）
- [ ] 后台/锁屏模式（enter/exit_background_mode）
- [ ] TCP keepalive（setTcpKeepalive）

### 回滚方案
升级期间 `entry/libs/arm64-v8a` 与 `entry/libs/include` 的旧内容均在 git（commit `5368df9`）中：
```powershell
git checkout 5368df9 -- entry/libs/arm64-v8a entry/libs/include
```
native-build/native-install 的 3.10.3 目录（未被脚本 -Clean 清除时）也可直接复用。

---

## 6. CI 工作流同步改造要点（.github/workflows/build-freerdp-harmonyos.yml）

1. 源码路径 `FreeRDP-3.10.3` → `FreeRDP`（或改为拉取固定 tag）
2. 移除针对旧树的 in-CI sed 补丁（thread.c、OpenSLES include、client/common SHARED 修复）——补丁已直接打入新树
3. 增补：`-DWITH_FUSE=OFF`、`-DWITH_SERVER_CHANNELS=OFF`、`-DUSE_VERSION_FROM_GIT_TAG=OFF`、`-DWITH_JSON_DISABLED=ON`、通道裁剪参数
4. 产物同步逻辑保持"完整性校验 → 清理 → 同步"，并同步 install 头文件供 entry/libs/include 替换
