# FreeRDP 3.31 光标形态同步 + 文件打开重定向 补齐交付文档

> 基线：3.31.1-dev0 升级已完成（见 `FreeRDP-3.31-升级评估.md`、`entry-libs-清理清单.md`）。
> 本次在其上补齐两项历史缺失能力，全部新增逻辑受宏/选项守卫，**不影响已验证的 7 项适配与老功能**。

---

## 一、功能概述

| 能力 | 链路 | 现状 |
|---|---|---|
| **光标形态同步** | Windows 指针位图(xor/and mask) → `harmonyos_Pointer_New` 解码为 RGBA8888 → `Pointer_Set` 事件(位图+热点+类型, 带去抖) → NAPI TSFN → `LibFreeRDP.setOnCursorShapeChanged` → SessionPage 叠加层 Image(热点对齐、跟随触点、随视口缩放) | 已实现并构建通过 |
| **文件打开重定向** | 远端 Explorer 双击重定向盘文件 → drive 通道 `drive_process_irp_create` 观测钩子(纯观测, IRP 正常完成) → wrapper dlsym 注册的回调 → NAPI TSFN → `LibFreeRDP.setOnFileOpen` → SessionPage toast + 尽力 `startAbility(viewData)` | 已实现并构建通过 |

设计要点：
- **光标**：复用 FreeRDP 标准客户端扩展机制（参照 Android 客户端 `androidPointer`）：`pointer.size = sizeof(harmonyosPointer)`，回调里把 `rdpPointer*` 强转回扩展结构。解码用官方 `freerdp_image_copy_from_pointer_data()`（X11/Wayland/SDL/Android 同款），目标格式 `PIXEL_FORMAT_ABGR32` = 内存字节序 R,G,B,A，与 ArkTS `image.PixelMapFormat.RGBA_8888` 一致。解码失败/超界(>384)/OOM 均降级为"仅类型事件"，**不破坏会话**。
- **去抖**：wrapper 侧 memcmp 上次已发位图（Windows 频繁重复 Set 同一缓存指针）；drive 侧同路径 3s 去抖 + 元文件过滤（desktop.ini/thumbs.db/~$ 前缀）+ 只报 `FILE_OPEN`、非目录、无写意图的 IRP。
- **兼容**：旧的 `OnCursorTypeChanged` 类型事件**原样保留**，两事件并存；`SetNull/SetDefault` 发 `length=0` 的清空事件。
- **文件打开钩子为观测式**：只在 IRP 成功创建后回调，不改任何返回值/数据，远端行为零变化。
- **解耦**：wrapper 用 `dlsym(RTLD_DEFAULT, "ohos_freerdp_set_file_open_callback")` 动态注册，FreeRDP 树用 `WITH_OHOS_FILE_OPEN=OFF` 构建时 wrapper 照常工作（事件静默不触发，仅打一条 WARN）。

---

## 二、修改文件清单（前后对照）

### 1. FreeRDP 树（3 处，全部受宏/选项守卫）

#### `entry/libs/FreeRDP/cmake/ConfigOptions.cmake`
在 `WITH_OHOS_AUDIO` 块之后新增：
```cmake
option(WITH_OHOS_FILE_OPEN "notify wrapper on server-side file open in drive channel" OFF)
```

#### `entry/libs/FreeRDP/include/config/config.h.in`
在 `#cmakedefine WITH_OHOS_AUDIO` 之后新增：
```c
#cmakedefine WITH_OHOS_FILE_OPEN
```

#### `entry/libs/FreeRDP/channels/drive/client/drive_main.c`
- `DRIVE_DEVICE` 结构体尾部新增守卫字段（去抖状态）：
```c
#if defined(WITH_OHOS_FILE_OPEN)
	/* Debounce state for the OHOS file-open observation hook */
	UINT64 ohosLastFileOpenTick;
	char ohosLastFileOpenPath[4096];
#endif
```
- 结构体定义之后新增 `#if defined(WITH_OHOS_FILE_OPEN)` 钩子块：
  - `typedef void (*ohos_freerdp_file_open_cb)(int64_t instance, const char* fullpath, const char* filename);`
  - `static ohos_freerdp_file_open_cb g_ohosFileOpenCallback` + **`FREERDP_API void ohos_freerdp_set_file_open_callback(cb)`**（default visibility，供 dlsym）
  - `OHOS_FILE_OPEN_DEBOUNCE_MS 3000`
  - `ohos_is_meta_file_name()`：过滤 desktop.ini / thumbs.db / `~$` 前缀
  - `ohos_notify_file_open(drive, file)`：`ConvertWCharToUtf8Alloc` 转路径 → 目录过滤 → 3s 同路径去抖 → `strrchr` 取文件名 → 回调
- `drive_process_irp_create` 文件成功创建分支末尾（`allocationSize` 处理之后）新增守卫调用：
```c
#if defined(WITH_OHOS_FILE_OPEN)
		/* [OHOS adaptation] Observe plain read-only FILE_OPEN requests
		 * (e.g. Explorer double-click) and notify the wrapper so it can
		 * open the file locally. Directory opens, write intent and
		 * create/overwrite dispositions are not "open a document" events.
		 * Purely observational: the IRP completes normally below. */
		if ((CreateDisposition == FILE_OPEN) && !(CreateOptions & FILE_DIRECTORY_FILE) &&
		    !(DesiredAccess & (GENERIC_WRITE | FILE_WRITE_DATA | FILE_APPEND_DATA)))
		{
			ohos_notify_file_open(drive, file);
		}
#endif
```

> ⚠ 注意：钩子块必须在 `DRIVE_DEVICE` 定义**之后**（3.31 的该结构体为匿名 typedef，无法前向声明）——首次实现放在文件头部导致 ON 构建报 `unknown type name 'DRIVE_DEVICE'`，已修正。

### 2. Wrapper（4 个文件）

#### `entry/src/main/cpp/harmonyos_freerdp.h`
- 新增回调 typedef（`OnCursorTypeChangedCallback` 之后）：
```c
/* Cursor shape event: full pointer bitmap decoded to RGBA8888 (byte order R,G,B,A).
 * rgbaData/length are only valid during the callback; receivers must copy.
 * length == 0 means "no custom shape" (SetNull/SetDefault): hide the overlay. */
typedef void (*OnCursorShapeChangedCallback)(int64_t instance, int cursorType, int width,
                                             int height, int hotspotX, int hotspotY,
                                             const uint8_t* rgbaData, int length);
/* File-open redirection event: server issued a plain read-only FILE_OPEN
 * against the redirected drive (e.g. Explorer double-click). fullPath is the
 * local filesystem path of the file; both strings are only valid during the
 * callback. */
typedef void (*OnFileOpenCallback)(int64_t instance, const char* fullPath, const char* filename);
```
- setter 声明区新增：
```c
void harmonyos_set_cursor_shape_changed_callback(OnCursorShapeChangedCallback callback);
void harmonyos_set_file_open_callback(OnFileOpenCallback callback);
```

#### `entry/src/main/cpp/harmonyos_freerdp.cpp`
- include 区新增 `<vector>`、`<dlfcn.h>`、`<freerdp/codec/color.h>`。
- 全局回调区新增 `g_onCursorShapeChanged` / `g_onFileOpen`。
- 新增 setter：
  - `harmonyos_set_cursor_shape_changed_callback()`：直接存全局。
  - `harmonyos_set_file_open_callback()`：存全局 + `dlsym(RTLD_DEFAULT, "ohos_freerdp_set_file_open_callback")` 动态注册蹦床 `harmonyos_file_open_trampoline`（符号缺失仅 LOGW，不失败）。
- 指针处理器整体重写（原桩 → 完整实现）：
  - 扩展结构：
    ```c
    typedef struct {
        rdpPointer pointer;
        uint8_t* rgba;     /* width*height*4 bytes, byte order R,G,B,A; NULL = undecodable */
        uint32_t rgbaLen;
    } harmonyosPointer;
    ```
  - 去快照 `g_lastCursorRgba/Len/W/H/HX/HY/Type`。
  - `harmonyos_Pointer_New`：0/超界(>384)直接返回 TRUE（类型兜底）；`calloc` 失败返回 TRUE（OOM 兜底）；`freerdp_image_copy_from_pointer_data(rgba, PIXEL_FORMAT_ABGR32, ..., &context->gdi->palette)` 解码，失败释放并降级。
  - `harmonyos_Pointer_Free`：释放 rgba。
  - `harmonyos_Pointer_Set`：① 旧类型事件（不变）；② 新 shape 事件：与快照逐项比对 + memcmp，**变更才发**，发后深拷贝刷新快照。
  - `harmonyos_Pointer_SetNull/SetDefault`：旧类型事件 + `harmonyos_clear_cursor_shape()`（清快照 + 发 length=0 清空事件）。
  - `harmonyos_register_pointer`：`harmonyosPointer pointer; ... pointer.pointer.size = sizeof(pointer);`（框架按扩展大小分配缓存条目）。

#### `entry/src/main/cpp/harmonyos_napi.cpp`
- 新增 TSFN：`g_tsfnCursorShapeChanged` / `g_tsfnFileOpen`。
- 新增数据结构：
```cpp
struct CursorShapeData {
    int64_t instance;
    int32_t cursorType = 0;
    int32_t width = 0;
    int32_t height = 0;
    int32_t hotspotX = 0;
    int32_t hotspotY = 0;
    uint8_t* rgbaData = nullptr; /* heap deep-copy, byte order R,G,B,A */
    int32_t length = 0;          /* 0 = clear overlay */
};
struct FileOpenData {
    int64_t instance;
    std::string fullPath;
    std::string filename;
};
```
- 新增 CallJS：`CallJS_CursorShape`（8 参，rgba 包成 **external ArrayBuffer** 零拷贝 + finalizer 释放；length=0/失败发空 buffer）、`CallJS_FileOpen`（3 参，字符串）。
- 新增 Impl：`OnCursorShapeChangedImpl`（**回调内深拷贝** rgba，缓冲只在回调期间有效）、`OnFileOpenImpl`（字符串拷贝）。
- 新增 setter + desc 注册：`setOnCursorShapeChanged`、`setOnFileOpen`。

### 3. ArkTS（2 个文件）

#### `entry/src/main/ets/services/LibFreeRDP.ets`
- `FreerdpNative` 接口新增两方法（`setOnGraphicsResize` 之后）：
```ts
setOnCursorShapeChanged(callback: (instance: number, cursorType: number, width: number, height: number,
  hotspotX: number, hotspotY: number, rgba: ArrayBuffer, length: number) => void): void;
setOnFileOpen(callback: (instance: number, fullPath: string, filename: string) => void): void;
```
- 模块级回调变量 + `initCallbacks()` 内注册分发（仿 `settingsChangedCallback` 模式）+ 静态 `setOnCursorShapeChanged/clearOnCursorShapeChanged/setOnFileOpen/clearOnFileOpen`。
- 修复历史缺口：`setOnCursorTypeChanged` 原生侧早已存在但 ETS 从未注册——本次 `initCallbacks` 一并接通（类型事件分发到 `UIEventListener.OnCursorTypeChanged`，保持向后兼容，业务层原未消费不受影响）。

#### `entry/src/main/ets/pages/SessionPage.ets`
- import 新增：`Want`（`@kit.AbilityKit`）、`fileUri`（`@kit.CoreFileKit`）、`image`（`@ohos.multimedia.image`）。
- 新增 `@State`：`cursorPixelMap/cursorVisible/cursorW/cursorH/cursorViewX/cursorViewY` + 私有 `cursorHotspotX/Y`、`lastTouchX/Y`。
- `aboutToAppear`：注册 `LibFreeRDP.setOnCursorShapeChanged` / `setOnFileOpen`（按 instance 过滤）；`aboutToDisappear`：`clearOnCursorShapeChanged/clearOnFileOpen` + 释放 PixelMap。
- `onCursorShapeChanged()`：`length<=0` → 隐藏叠加层；否则 `image.createPixelMap(rgba, {size, RGBA_8888})` → 替换 PixelMap（旧的 release）→ `repositionCursorOverlay()`。
- `cursorOverlayScale()`：`viewScale / density`（桌面 px → 屏幕 vp）；`repositionCursorOverlay()`：叠加层左上角 = 最近触点 − 热点 × scale。
- `onSessionTouch()`：Down/Move/Up 更新 `lastTouchX/Y` 并重放叠加层位置（远端光标位置由己方触控驱动）。
- `onRemoteFileOpen()`：`promptAction.showToast` + `fileUri.getUriFromPath` → `startAbility({action:'ohos.want.action.viewData', uri, type:MIME})`，全部 try/catch（沙箱文件跨应用可见性受限，失败仅告警）。
- `guessMimeType()`：txt/log/md/pdf/图片/视频/音频 → octet-stream 兜底。
- `build()`：XComponent 与方向按钮之间新增叠加层：
```ts
if (this.cursorVisible && this.cursorPixelMap) {
  Image(this.cursorPixelMap)
    .width(this.cursorW * this.cursorOverlayScale())
    .height(this.cursorH * this.cursorOverlayScale())
    .position({ x: this.cursorViewX, y: this.cursorViewY })
    .draggable(false)
    .hitTestBehavior(HitTestMode.None)   // 不拦截触控
}
```

### 4. 构建脚本

#### `scripts/rebuild-ohos-native-3.31.ps1`
- 新增参数 `[switch]$OhosFileOpenOff`。
- CMake 参数新增 `"-DWITH_OHOS_FILE_OPEN=$withOhosFileOpen"`（默认 ON）。
- 用法示例（文件头注释同步更新）：
```powershell
# 验证 WITH_OHOS_FILE_OPEN=OFF 编译:
.\rebuild-ohos-native-3.31.ps1 -OhosFileOpenOff -SkipSync -SkipWrapper
```

---

## 三、NAPI 接口定义（完整）

| JS 方法 | 回调签名 | 说明 |
|---|---|---|
| `setOnCursorShapeChanged(cb)` | `(instance: number, cursorType: number, width: number, height: number, hotspotX: number, hotspotY: number, rgba: ArrayBuffer, length: number) => void` | rgba 为 RGBA_8888 字节序；`length === 0` 表示清除自定义光标叠加层 |
| `setOnFileOpen(cb)` | `(instance: number, fullPath: string, filename: string) => void` | fullPath 为本地沙箱绝对路径；UTF-8 |

事件常量（既有导出，未变）：`CURSOR_TYPE_UNKNOWN=0/DEFAULT=1/HAND=2/IBEAM=3/SIZE_NS=4/SIZE_WE=5/SIZE_NWSE=6/SIZE_NESW=7/CROSS=8/WAIT=9`。

线程模型：FreeRDP 线程回调 → `g_tsfnMutex` 下深拷贝入队 → ArkTS 事件循环 CallJS → 外部 ArrayBuffer(finalizer 释放) / 字符串。**无跨线程裸指针。**

---

## 四、构建与产物验证（本次实测）

| 步骤 | 命令 | 结果 |
|---|---|---|
| OFF 验证构建 | `.\rebuild-ohos-native-3.31.ps1 -OhosFileOpenOff -SkipSync -SkipWrapper -NdkRoot <NDK>` | ✅ `llvm-nm -D libfreerdp-client3.so` 无任何 ohos file-open 符号 |
| ON 全量构建 | `.\rebuild-ohos-native-3.31.ps1 -NdkRoot <NDK>` | ✅ install + entry/libs 同步 + wrapper 链接成功 |
| client3 符号 | `llvm-nm -D entry\libs\arm64-v8a\libfreerdp-client3.so` | ✅ `T ohos_freerdp_set_file_open_callback` |
| wrapper 符号 | `llvm-nm -D entry\libs\arm64-v8a\libfreerdp_harmonyos.so` | ✅ `T harmonyos_set_cursor_shape_changed_callback` / `T harmonyos_set_file_open_callback` |
| config.h 同步 | `entry\libs\include\freerdp3\freerdp\config.h` | ✅ `#define WITH_OHOS_AUDIO` + `#define WITH_OHOS_FILE_OPEN` |
| ArkTS 静态检查 | arkts_check（LibFreeRDP.ets、SessionPage.ets） | ✅ 0 error |
| HAP | `hvigorw.bat --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap ...` | ✅ `entry-default-signed.hap`（18:10） |

> NDK：`E:\HarmonyOs\DevelopTools\huawei\commandline-tools\command-line-tools\sdk\default\openharmony\native`
> ⚠ 本机 `PATH` 中 DevEco 自带 Node 18 优先于 nvm，`build_project` 工具会因 string-width 的 `v` 正则标志失败；HAP 用上述 hvigorw 命令构建（与清理清单文档一致）。

---

## 五、真机回归用例

前置：真机安装 `entry-default-signed.hap`，准备一台 Windows 测试机（建议 Win10/11），书签开启 **重定向 SD 卡**（`/drive:sdcard,/data/storage`）。

### 5.1 老功能回归（防破坏）

| # | 用例 | 步骤 | 预期 |
|---|---|---|---|
| R1 | 基本连接 | 书签连接测试机 | 正常进入桌面，渲染/键鼠/音频/剪贴板与升级前一致 |
| R2 | 磁盘重定向 | 远端资源管理器打开"此电脑"上的重定向盘，浏览目录、复制文件进出 | 目录可浏览、文件可读写（钩子为纯观测，不改变 IRP 行为） |
| R3 | 分辨率/旋转 | 旋转设备、切换 FIT/FILL | Display Control resize 正常，黑边兜底正常 |
| R4 | 后台保活 | Home 键退后台再回前台 | 会话保持，心跳正常 |

### 5.2 光标形态同步

| # | 用例 | 步骤 | 预期 |
|---|---|---|---|
| C1 | 文本 I 型 | 触控移动到远端记事本/浏览器地址栏 | 叠加层显示 I 型光标位图，热点在竖线中上部 |
| C2 | 手型 | 悬停在浏览器链接上（先触摸移动过去） | 手型光标 |
| C3 | 等待/忙碌 | 双击远端大型程序（如 Excel 大表） | 等待光标（转圈/沙漏），程序就绪后恢复箭头 |
| C4 | 调整大小 | 移到远端窗口边缘 | 双向箭头（NS/WE/NWSE/NESW） |
| C5 | 自定义光标 | 远端设置非默认鼠标方案（如黑色大指针） | 叠加层显示服务器实际下发位图（位图级精确） |
| C6 | 消隐 | 关闭远端窗口使光标消失（SetNull），或 `Ctrl+Alt+End` 等触发系统光标重置（SetDefault） | 叠加层隐藏；SetDefault 后下次移动重现 |
| C7 | 跟随与缩放 | 双指缩放视口后触摸拖动 | 叠加层跟随触点、大小随 viewScale/density 缩放、不拦截触控 |
| C8 | 降级 | （可选）连接 8bpp 会话 | 位图事件正常（解码支持 1/8/16/24/32bpp xor） |

### 5.3 文件打开重定向

| # | 用例 | 步骤 | 预期 |
|---|---|---|---|
| F1 | 双击打开 | 重定向盘放 `test.txt`/`test.pdf`/`test.png`，远端 Explorer 双击 | 本机 toast「远端打开了文件：xxx」；有对应系统应用时弹打开（txt/pdf/图片） |
| F2 | 去抖 | 快速连续双击同一文件 | 3s 内只 toast 一次（远端重复 IRP 被去抖） |
| F3 | 元文件过滤 | 浏览含 desktop.ini 的目录、打开 Office 文档产生 `~$` 锁文件 | 不弹 toast |
| F4 | 写操作不报 | 远端对重定向盘文件右键"编辑"、另存为、重命名 | 不弹 toast（非 FILE_OPEN / 有写意图） |
| F5 | 目录不报 | 远端双击重定向盘内文件夹 | 不弹 toast（is_dir 过滤） |
| F6 | 无处理器兜底 | 双击无应用可打开的类型（如 .xyz） | toast 正常，startAbility 失败仅记日志，无崩溃 |
| F7 | 沙箱受限 | 双击 app 沙箱内文件（/data/storage/...） | toast 正常；若目标应用无权限则打开失败，仅告警（已知边界，不崩溃） |

### 5.4 开关回退验证（可选）

- `rebuild-ohos-native-3.31.ps1 -OhosFileOpenOff` 重新构建 + HAP：文件打开事件静默（wrapper LOGW 一条），其余功能不受影响。

---

## 六、回退方案

| 粒度 | 操作 | 影响 |
|---|---|---|
| **关闭文件打开**（推荐） | 构建加 `-OhosFileOpenOff`；或仅不调 `LibFreeRDP.setOnFileOpen`（ArkTS 侧一行） | 文件打开事件消失，其余全部保留 |
| **关闭光标叠加层** | SessionPage `aboutToAppear` 注释掉 `LibFreeRDP.setOnCursorShapeChanged(...)` 注册 | 回到"无叠加层"旧观感；类型事件链路仍在 |
| **整体回退本次改动** | `git checkout <本次提交前的 commit> -- entry/libs/FreeRDP entry/src/main/cpp entry/src/main/ets/services/LibFreeRDP.ets entry/src/main/ets/pages/SessionPage.ets scripts/rebuild-ohos-native-3.31.ps1` 后重跑 `rebuild-ohos-native-3.31.ps1` + HAP | 回到 3.31 升级完成态（升级本身不受影响） |
| **回到 3.10.3** | 见 `entry-libs-清理清单.md` 回退章节（git 5368df9） | 最后手段 |

---

## 七、已知边界与后续优化

1. **跨应用打开沙箱文件**：`/drive:sdcard` 映射的是应用沙箱目录，其他应用通过 `viewData` 读取可能受限（需要应用自行申请或走 `fileUri` 临时授权）。当前实现为尽力而为（toast 必达，打开失败仅告警）。后续可考虑：复制到公共媒体库后再打开，或引导用户。
2. **光标位置**：触屏设备无真实鼠标，叠加层跟随最近触点（远端光标实际由触控驱动）。如需"服务器驱动的位置同步"需处理 `Pointer_SetPosition` + pointer position update 通道，当前按计划忽略。
3. **并发 PixelMap 替换**：native 侧已按内容去抖，快速连续不同形状理论上可能在 `createPixelMap` 异步间隙交错；实际触发概率极低，如出现可加序号丢弃旧帧。
4. **大面积自定义光标**：>384×384 直接降级为类型事件（large-pointer 极端场景）。

---

*文档生成于 2026-09-07，对应构建：FreeRDP 3.31.1-dev0 + WITH_OHOS_AUDIO=ON + WITH_OHOS_FILE_OPEN=ON，HAP `entry-default-signed.hap`。*
