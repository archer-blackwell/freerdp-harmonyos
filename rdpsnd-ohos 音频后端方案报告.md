# rdpsnd-ohos 音频后端方案报告

> 日期：2026-09-04
> 任务：放弃 OpenSLES 路线，基于 OpenHarmony OHAudio（AudioKit C-API）为 FreeRDP 3.10.3 新建 rdpsnd-ohos 音频输出后端，集成到 HarmonyOS 应用构建链。

---

## 一、背景

- 项目此前的音频后端为 OpenSLES（rdpsnd/audin 各一套），依赖 Android 式 `SLES/OpenSLES_Android.h` 扩展接口，虽已通过标准 `SLBufferQueueItf` 适配编译通过，但按决策放弃该路线。
- 实测本机 OHOS NDK sysroot **没有 C++ 层 AudioRenderer**（无 `audio/` 目录、无 `libnative_media_audio.so`），实际可用的是 **OHAudio C-API**（`sysroot/usr/include/ohaudio/` + 系统库 `libohaudio.so`）。
- 项目 `build-profile.json5` 的 `targetSdkVersion/compatibleSdkVersion` 均为 **5.0.0(12)**，约束了可选 API 集合：**只能使用 @since ≤ 12 的接口**。

## 二、方案设计

### 2.1 API 选型（全部 @since ≤ 12）

| 类别 | API | @since |
|---|---|---|
| Builder | `OH_AudioStreamBuilder_Create` / `Destroy` | 10 |
| Builder | `SetSamplingRate` / `SetChannelCount` / `SetSampleFormat` / `SetEncodingType` / `SetLatencyMode` / `SetRendererInfo` / `GenerateRenderer` | 10 |
| Builder | `SetRendererWriteDataCallback` | 12 |
| Renderer | `Start` / `Stop` / `Flush` / `Release` / `GetFrameSizeInCallback` / `GetSamplingRate` / `GetChannelCount` | 10 |
| Renderer | `SetVolume` / `GetUnderflowCount` | 12 |

选型说明：
- 新版 `OH_AudioStreamInfo` 结构体 API（@since 19）在本 SDK 的 builder 头文件中**没有对应 setter**，且超出 targetSdkVersion 12，故弃用；采用旧版分立 setter。
- 本 SDK 的 OHAudio **没有推送式 `OH_AudioRenderer_Write` 接口**，唯一写入方式是**回调拉取式**：音频服务线程主动回调 `OH_AudioRenderer_OnWriteDataCallback(renderer, userData, audioData, audioDataSize)`，要求应用在回调内填满整块缓冲，返回 `AUDIO_DATA_CALLBACK_RESULT_VALID`。

### 2.2 数据通路与环形缓冲

rdpsnd 通道线程（推送端）与音频服务线程（拉取端）解耦于一个 **128 KiB 环形缓冲**（≈341ms @ 48kHz/stereo/S16LE）：

```
rdpsnd 通道线程                    音频服务线程
Play(data,size) ──写──▶ [Ring 128KB] ──读──▶ OnWriteDataCallback → 扬声器
     (锁内)                (CRITICAL_SECTION)        (锁内)
```

- **缓冲不足**：回调用已有数据填充，剩余补静音（标准欠载行为，`DEBUG_SND` 记录）；
- **缓冲已满**：丢弃最旧数据腾位（保实时性，`overflow` 计数）；
- **整块超容量**：仅保留最新尾部。

### 2.3 线程模型（防死锁设计）

- `CRITICAL_SECTION` **只保护环形缓冲**；读写两侧均在锁内完成 memcpy，锁粒度小且不阻塞。
- `renderer/builder` 指针**仅由 rdpsnd 通道线程访问**（open/play/close/free 均在该线程），无跨线程竞争。
- **`Stop/Release` 绝不在持锁状态下调用**：若音频回调线程正阻塞在锁上、而 Release 内部又等待回调线程退出，会形成死锁。因此 `rdpsnd_ohos_destroy_renderer()` 为"通道线程 + 无锁"专用。

### 2.4 关键策略

| 策略 | 说明 |
|---|---|
| 延迟启动 | `Open()` 创建 renderer 但不 `Start()`；首次 `Play()` 到达才启动拉取。避免通道空闲期持续输出静音回调——OHAudio 头文件明确警告该行为会被系统省电管控。 |
| 格式自适应 | 支持 **44100/48000 Hz、16bit、单声道/立体声**（`FormatSupported` 严格校验 PCM/S16LE）；`DefaultFormat` 兜底 44100/2/16。格式协商变化时 rdpsnd 主通道会重新调用 `Open(format)`，插件销毁旧 renderer 按新参数重建。 |
| 音量映射 | rdpsnd 音量为 DWORD（低 16 位左声道 / 高 16 位右声道，0xFFFF=100%）；OHAudio `SetVolume` 为 float 0.0–1.0。取**左声道**驱动（与 opensles 后端一致），完整 DWORD 缓存于 `GetVolume` 回报。renderer 重建时重放缓存音量。 |
| 欠载/过载统计 | `close()` 时输出 `underflowCount`（OHAudio 原生计数）与 `overflowDrops`（本插件丢弃计数）。 |
| 无 C 层 assert | 所有 OHAudio 返回值均检查并走日志分支，不使用 `WINPR_ASSERT`，避免异常路径 abort。 |

### 2.5 插件接口实现

完整实现 `rdpsndDevicePlugin`（`include/freerdp/client/rdpsnd.h`）生命周期：

```
Open → 按 format 创建 builder/renderer（配置 7 项参数 + 写回调）
FormatSupported / DefaultFormat → 格式协商
GetVolume / SetVolume → 音量
Start → 幂等启动（内部处理延迟启动）
Play → 确保启动 + 写环形缓冲
Close → Stop/Flush + 统计日志 + 清空缓冲（renderer 保留复用）
Free → 销毁 renderer/builder + 删除临界区 + 释放内存
```

入口符号（addin 加载机制按 `{subsystem}_freerdp_rdpsnd_client_subsystem_entry` 拼接）：

```c
FREERDP_ENTRY_POINT(UINT VCAPITYPE ohos_freerdp_rdpsnd_client_subsystem_entry(
    PFREERDP_RDPSND_DEVICE_ENTRY_POINTS pEntryPoints))
```

## 三、修改点清单

### 3.1 新增文件

| # | 路径 | 说明 |
|---|---|---|
| 1 | `entry\libs\FreeRDP-3.10.3\channels\rdpsnd\client\ohos\rdpsnd_ohos.c` | rdpsnd-ohos 插件完整实现（纯 C，约 530 行） |
| 2 | `entry\libs\FreeRDP-3.10.3\channels\rdpsnd\client\ohos\CMakeLists.txt` | 子系统构建脚本：`define_channel_client_subsystem("rdpsnd" "ohos" "")`，OBJECT 库链 `winpr freerdp ohaudio` |

### 3.2 修改文件

| # | 路径 | 改动 |
|---|---|---|
| 3 | `entry\libs\FreeRDP-3.10.3\channels\rdpsnd\client\CMakeLists.txt` | 新增 `if(WITH_OHOS_AUDIO) add_channel_client_subsystem(... "ohos" "")` 分支 |
| 4 | `entry\libs\FreeRDP-3.10.3\channels\rdpsnd\client\rdpsnd_main.c` | `backends[]` 数组**首位**插入 `#if defined(WITH_OHOS_AUDIO) { "ohos", "" }`（优先于其他后端；"fake" 兜底保留） |
| 5 | `entry\libs\FreeRDP-3.10.3\include\config\config.h.in` | 新增 `#cmakedefine WITH_OHOS_AUDIO`（生成到 `freerdp/config.h`） |
| 6 | `entry\libs\FreeRDP-3.10.3\cmake\ConfigOptions.cmake` | 新增 `option(WITH_OHOS_AUDIO "Enable sound redirection using OpenHarmony OHAudio" OFF)` |
| 7 | `scripts\rebuild-ohos-native.ps1` | ① `-DWITH_OPENSLES=OFF`、`-DWITH_OHOS_AUDIO=ON`；② 改用 **NDK 自带 cmake/ninja 全路径**（`build-tools\cmake\bin\`），修复系统 PATH 捡到 Cygwin cmake 导致路径被改写为 `/cygdrive/...` 的构建失败；③ wrapper 产物校验逻辑适配（wrapper 由其 CMakeLists 直接输出到 `entry\libs\<arch>`） |

### 3.3 构建链传导

```
ConfigOptions.cmake: option(WITH_OHOS_AUDIO)          (cmake 配置期)
        ↓
构建树 include/freerdp/config.h: #define WITH_OHOS_AUDIO
        ↓
channels/rdpsnd/client/CMakeLists.txt: add_channel_client_subsystem("ohos")
        ↓
rdpsnd-client-ohos OBJECT 库（PUBLIC winpr freerdp ohaudio）→ 并入 libfreerdp-client3.so
        ↓
rdpsnd_main.c backends[]（#if defined(WITH_OHOS_AUDIO)）→ 运行期按序加载，符号
ohos_freerdp_rdpsnd_client_subsystem_entry
```

## 四、构建与验证结果

| 验证项 | 结果 |
|---|---|
| native 重建（arm64-v8a，NDK clang 15） | 全部编译通过，无 error |
| 动态符号 | `ohos_freerdp_rdpsnd_client_subsystem_entry` 存在；`opensles` 符号消失，`fake` 兜底保留 |
| `libfreerdp-client3.so.3` NEEDED | `libc.so`、`libfreerdp3.so.3`、`libohaudio.so`、`libwinpr3.so.3`（**libOpenSLES.so 已移除**） |
| 生成的 `config.h` | `#define WITH_OHOS_AUDIO`；`WITH_OPENSLES` 已注释 |
| HAP（hvigor assembleHap） | **BUILD SUCCESSFUL**，`libfreerdp-client3.so.3`（strip 后 600264B）入包；`libohaudio.so` 为系统库**不打包** |
| 产物位置 | `entry\build\default\outputs\default\entry-default-signed.hap` |

## 五、权限说明

**音频播放无需新增任何权限**，`entry\src\main\module.json5` 无需改动：

- OHAudio AudioRenderer 播放：不需要权限（需要权限的是录音 `ohos.permission.MICROPHONE`，本次不涉及）；
- `libohaudio.so` 为系统库，随系统发布，仅参与链接、不打包进 HAP；
- 应用已有 `ohos.permission.INTERNET` 满足 RDP 连接需求。

## 六、调试日志（装机后 hilog 可见）

| 级别 | 内容 |
|---|---|
| INFO | `rdpsnd-ohos: open rate=%u channels=%u bits=%u latency=%u` |
| INFO | `rdpsnd-ohos: renderer created, requested rate=%d channels=%d, actual rate=%d channels=%d`（请求 vs 设备实际） |
| INFO | `rdpsnd-ohos: frameSizeInCallback=%d bytes`（每次回调帧大小） |
| INFO | `rdpsnd-ohos: close, underflowCount=%u overflowDrops=%u` |
| DEBUG_SND（需 `WITH_DEBUG_SND`） | 每次 `play` 字节数与 ring 占用、欠载静音填充量 |

## 七、已知边界与后续建议

1. **未注册音频中断回调**：音频焦点被抢占（如来电）时系统会暂停渲染，当前版本不感知焦点事件，表现为暂停后不再出声直至断开重连。后续可用 `SetRendererInterruptCallback`（需评估 @since 版本）补充焦点恢复逻辑。
2. **audin（麦克风）无后端**：`WITH_OPENSLES=OFF` 同时关闭了 audin 的 opensles 子系统；wrapper 未启用 audin 通道，无实际影响。若未来需要麦克风重定向，可参照本插件用 `OH_AudioCapturer` 另建后端。
3. **音量单值映射**：OHAudio 仅支持标量音量，双声道独立音量暂以左声道近似。
4. **装机实测待执行**：`hdc -t <设备号> install -r entry\build\default\outputs\default\entry-default-signed.hap` 后验证：连接 → 远程端播放音频 → 出声且无卡顿 → 断开连接无 SIGABRT（同时覆盖此前崩溃修复的回归验证）。
