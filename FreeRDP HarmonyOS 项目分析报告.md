# FreeRDP HarmonyOS 项目分析报告

> 分析日期：2026-09-03
> 项目路径：E:\HarmonyOs\Worker\ProjectFiles\freerdp-harmonyos

---

## 一、项目概述

本项目是 FreeRDP 3.10.3 的 HarmonyOS 移植版，通过 N-API 将 C 层的 FreeRDP 客户端库暴露给 ArkTS 层，实现远程桌面（RDP）连接功能。

### 项目结构

```
entry/src/main/
├── cpp/
│   ├── harmonyos_freerdp.cpp    # FreeRDP 核心实现（连接、渲染、事件循环）
│   ├── harmonyos_freerdp.h      # 原生头文件
│   ├── harmonyos_napi.cpp       # N-API 绑定层
│   └── freerdp_client_compat.h  # FreeRDP 兼容层
├── ets/
│   ├── services/
│   │   ├── LibFreeRDP.ets       # ArkTS 封装（对应 Android LibFreeRDP.java）
│   │   ├── NetworkManager.ets   # 网络状态监控 & 自动重连
│   │   ├── RdpSessionManager.ets # 会话生命周期管理
│   │   ├── RdpBackgroundService.ets # 后台服务（保持音频）
│   │   └── AudioFocusManager.ets # 音频焦点管理
│   ├── pages/
│   │   ├── Index.ets            # 主页（快速连接）
│   │   ├── SessionPage.ets      # 远程桌面会话页
│   │   ├── BookmarkPage.ets     # 书签管理
│   │   ├── SettingsPage.ets     # 设置页
│   │   └── AboutPage.ets        # 关于页
│   ├── components/
│   │   ├── SessionView.ets      # 远程桌面渲染组件
│   │   ├── TouchPointerView.ets # 触控指针
│   │   └── VirtualKeyboard.ets  # 虚拟键盘
│   └── model/
│       ├── BookmarkBase.ets     # 书签数据模型
│       └── SessionState.ets     # 会话状态
└── libs/
    └── FreeRDP-3.10.3/         # FreeRDP 官方库源码（未修改）
```

---

## 二、安全审计结果

### 审计范围

- 全部自定义源码：`harmonyos_freerdp.cpp`, `harmonyos_napi.cpp`, `harmonyos_freerdp.h`, 全部 `.ets` 文件
- FreeRDP 库版本验证：3.10.3 官方版本

### 审计结论：未发现后门

| 检查项 | 结果 | 说明 |
|--------|------|------|
| 外部网络请求 | 无异常 | 仅有 MPL 许可证 URL 和 FreeRDP 官网展示链接 |
| 硬编码凭证/密钥 | 未发现 | 无硬编码密码、Token、API Key |
| 隐藏文件操作 | 未发现 | 无 fopen/fwrite 到外部路径 |
| 动态代码执行 | 未发现 | 无 system()/popen()/exec() 调用 |
| 数据外泄通道 | 未发现 | 无隐藏数据发送逻辑 |
| setenv 调用 | 正常 | 仅用于 OpenSSL 配置（HOME, OPENSSL_CONF 等） |
| FreeRDP 库完整性 | 正常 | 官方 3.10.3 版本，未发现篡改 |

### 安全建议

1. **证书验证被硬编码忽略**（`harmonyos_freerdp.cpp:1051`）：
   ```cpp
   freerdp_settings_set_bool(inst->context->settings, FreeRDP_IgnoreCertificate, TRUE);
   ```
   调试阶段可以接受，**生产环境必须改为用户可配置**，否则易受中间人攻击。

2. **密码日志保护**：`parse_arguments` 中已正确过滤 `/p:` 参数不打印明文，此项无问题。

3. **`.signing/` 目录**：项目根目录存在 `.signing/` 文件夹和大量签名相关文档，集成到自己的项目时建议清理，避免签名材料泄露。

---

## 三、连接失败根因分析

### 用户报告的问题

连接局域网 Windows 远程桌面失败，相关错误日志：

```
Failed to check FreeRDP file descriptor
ErrorCode=0x2000D Msg=The connection transport layer failed.
```

### 发现的 4 个关键问题

#### 问题1（致命）：`harmonyos_post_connect` 跳过了 ArkTS 回调

**位置**：`harmonyos_freerdp.cpp:497-506`

```cpp
/*
 * CRITICAL: Temporarily bypass ArkTS callbacks to isolate the crash.
 * The crash occurs immediately after "Update callbacks set" when calling
 * either g_onSettingsChanged or g_onConnectionSuccess.
 *
 * TODO: Debug TSFN implementation or callback parameters.
 */
LOGI("harmonyos_post_connect: Skipping ArkTS callbacks to test connection stability");

LOGI("harmonyos_post_connect: EXIT - connection established (UI not notified)");
return TRUE;
```

**影响**：
- `g_onConnectionSuccess` 永远不会被调用
- ArkTS 层的 `SessionPage.OnConnectionSuccess` 永远不会触发
- UI 永远停在"正在连接..."状态
- `pixelMap` 永远不会被创建和更新，屏幕黑屏
- 作者为了调试 TSFN 崩溃问题故意禁用了这些回调，但忘记恢复

#### 问题2（致命）：`harmonyos_end_paint` 跳过了图形更新回调

**位置**：`harmonyos_freerdp.cpp:282-290`

```cpp
/*
 * TODO: Re-enable g_onGraphicsUpdate once we implement Android-style
 * graphics copy in ArkTS layer (using a dedicated N-API getter function)
 */
// if (g_onGraphicsUpdate) {
//     g_onGraphicsUpdate((int64_t)(uintptr_t)context->instance, x1, y1, x2 - x1, y2 - y1);
// }

LOGD("harmonyos_end_paint: Graphics update region calculated, memcpy skipped (Android-style)");
```

**影响**：
- 即使连接成功，画面也不会渲染到 UI
- `freerdp_harmonyos_update_graphics()` 函数存在但从未被 ArkTS 层调用
- 远程桌面画面无法显示

#### 问题3：重复连接（双实例竞争）

**日志时间线**：

| 时间 | 事件 | instance |
|------|------|----------|
| 13:37:25.154 | 用户点击连接，创建实例1 | 388951718400 |
| 13:37:25.157 | 实例1开始连接 | 388951718400 |
| 13:37:25.170 | NetworkManager 检测到 netAvailable | - |
| 13:37:25.178 | **错误触发重连**，创建实例2 | - |
| 13:37:26.183 | 实例2创建 | 388951237248 |
| 13:37:26.265 | 实例1连接成功（但UI未通知） | 388951718400 |
| 13:37:27.144 | 实例2也连接成功 | 388951237248 |
| 13:37:46.737 | 实例1被服务器踢掉（0x10001） | 388951718400 |
| 13:38:01.942 | 实例2也被踢掉（0x1000C） | 388951237248 |

**根因**：`NetworkManager.ets:80-83` 在 `netAvailable` 回调中无条件触发 `startReconnect()`：

```typescript
netConnection.on('netAvailable', (netHandle: connection.NetHandle) => {
    // ...
    // Trigger reconnect if we have a session to reconnect
    if (currentSession && !isReconnecting) {
        NetworkManager.startReconnect();  // 即使当前连接正常也触发！
    }
});
```

当用户首次连接时，网络可用事件被触发，NetworkManager 误以为需要重连，创建了第二个实例连接到同一台 Windows，导致第一个连接被服务器踢掉。

#### 问题4：首连接的 0x2000D 错误

```
Failed to check FreeRDP file descriptor
ErrorCode=0x2000D Msg=The connection transport layer failed.
```

**位置**：`harmonyos_freerdp.cpp:661-665`

```cpp
if (!freerdp_check_event_handles(context)) {
    LOGE("Failed to check FreeRDP file descriptor");
    status = GetLastError();
    break;
}
```

这是运行循环中 `freerdp_check_event_handles` 返回 FALSE 导致的，可能原因：
- 双实例竞争导致 fd 异常
- HarmonyOS/musl 的 select/poll 行为与 Linux 有差异
- WaitForMultipleObjects 在 HarmonyOS 上的兼容性问题

---

## 四、修复建议

### 修复1：恢复 `harmonyos_post_connect` 中的 ArkTS 回调（最关键）

**文件**：`entry/src/main/cpp/harmonyos_freerdp.cpp`

将 `harmonyos_post_connect` 函数中被禁用的回调恢复：

```cpp
static BOOL harmonyos_post_connect(freerdp* instance) {
    // ... 前面的代码保持不变 ...

    LOGI("harmonyos_post_connect: Update callbacks set");

    // 恢复 SettingsChanged 回调
    if (g_onSettingsChanged) {
        g_onSettingsChanged((int64_t)(uintptr_t)instance,
            freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
            freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight),
            freerdp_settings_get_uint32(settings, FreeRDP_ColorDepth));
    }

    // 恢复 ConnectionSuccess 回调
    if (g_onConnectionSuccess) {
        g_onConnectionSuccess((int64_t)(uintptr_t)instance);
    }

    LOGI("harmonyos_post_connect: EXIT - connection established");
    return TRUE;
}
```

> **注意**：原始代码注释提到调用这两个回调会导致崩溃（TSFN 问题）。如果恢复后崩溃，需要排查 N-API ThreadSafeFunction 的初始化时序，确保 TSFN 在回调触发前已创建完毕。

### 修复2：恢复 `harmonyos_end_paint` 中的图形更新回调

**文件**：`entry/src/main/cpp/harmonyos_freerdp.cpp`

```cpp
static BOOL harmonyos_end_paint(rdpContext* context) {
    // ... 前面的计算代码保持不变 ...

    // 恢复图形更新回调
    if (g_onGraphicsUpdate) {
        g_onGraphicsUpdate((int64_t)(uintptr_t)context->instance, x1, y1, x2 - x1, y2 - y1);
    }

    hwnd->invalid->null = TRUE;
    hwnd->ninvalid = 0;
    return TRUE;
}
```

### 修复3：修复 NetworkManager 的错误重连触发

**文件**：`entry/src/main/ets/services/NetworkManager.ets`

在 `netAvailable` 回调中增加判断，只在当前实例确实已断开时才重连：

```typescript
netConnection.on('netAvailable', (netHandle: connection.NetHandle) => {
    console.info(`${TAG}: Network available: netId=${netHandle.netId}`);
    isNetworkAvailable = true;

    if (onNetworkAvailableCallback) {
        onNetworkAvailableCallback();
    }

    // 仅在当前实例已断开且有会话信息时才触发重连
    if (currentSession && !isReconnecting) {
        const isStillConnected = currentSession.instance !== 0 &&
            LibFreeRDP.isInstanceConnected(currentSession.instance);
        if (!isStillConnected) {
            NetworkManager.startReconnect();
        }
    }
});
```

### 修复4：生产环境移除证书忽略硬编码

**文件**：`entry/src/main/cpp/harmonyos_freerdp.cpp`

将 `IgnoreCertificate=TRUE` 改为可配置：

```cpp
// 建议改为通过参数传入，或仅在调试模式启用
#ifdef DEBUG_BUILD
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_IgnoreCertificate, TRUE);
#else
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_IgnoreCertificate, FALSE);
#endif
```

### 修复5：SessionPage 中实现图形渲染逻辑

**文件**：`entry/src/main/ets/pages/SessionPage.ets`

当前 `SessionPage` 虽然有 `pixelMap` 状态变量，但缺少将 GDI 缓冲区数据写入 PixelMap 的逻辑。需要：

1. 在 `OnGraphicsUpdate` 回调中获取 GDI 缓冲区数据
2. 使用 `image.createPixelMap` 或增量更新将帧数据写入 PixelMap
3. 更新 UI 显示

建议参考 Android 版 FreeRDP 的 `BitmapUpdateHandler` 实现方式。

---

## 五、问题优先级

| 优先级 | 问题 | 影响 |
|--------|------|------|
| P0 | post_connect 跳过 ArkTS 回调 | 连接成功但 UI 无响应，黑屏 |
| P0 | end_paint 跳过图形回调 | 远程桌面画面无法显示 |
| P1 | NetworkManager 错误重连 | 双实例竞争导致连接被踢 |
| P2 | 证书验证硬编码忽略 | 安全风险（中间人攻击） |
| P2 | 图形渲染逻辑缺失 | 即使回调恢复也需实现 PixelMap 更新 |

---

## 六、总结

1. **安全性**：项目代码未发现后门或恶意逻辑，FreeRDP 库为官方版本。主要安全风险是证书验证被硬编码忽略。

2. **连接失败根因**：作者在调试 TSFN 崩溃问题时，故意禁用了 `harmonyos_post_connect` 中的 ArkTS 回调和 `harmonyos_end_paint` 中的图形更新回调，导致连接成功后 UI 层无法感知，画面无法渲染。同时 NetworkManager 在首次连接时错误触发重连，创建双实例竞争，进一步导致连接被 Windows 服务器踢掉。

3. **修复路径**：按优先级依次恢复被禁用的回调、修复 NetworkManager 重连逻辑、实现 PixelMap 渲染、移除证书忽略硬编码。如果恢复回调后出现 TSFN 崩溃，需要排查 N-API ThreadSafeFunction 初始化时序问题。
