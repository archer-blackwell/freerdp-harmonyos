/*
 * HarmonyOS FreeRDP Native Implementation
 * 
 * Copyright 2026 FreeRDP HarmonyOS Port
 * Based on Android FreeRDP implementation
 * 
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
 * If a copy of the MPL was not distributed with this file, You can obtain one at
 * http://mozilla.org/MPL/2.0/.
 */

#include "harmonyos_freerdp.h"
#include "freerdp_client_compat.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <locale.h>
#include <mutex>
#include <vector>
#include <dlfcn.h>
#include <sys/mman.h>
#include <poll.h>
#include <unistd.h>

#ifdef OHOS_PLATFORM
#include <hilog/log.h>
#include <time.h>
#include <winpr/sysinfo.h>
#include <winpr/wlog.h>
#include <freerdp/client/disp.h>
#include <native_window/external_window.h>
#ifdef LOG_TAG
#undef LOG_TAG
#endif
#define LOG_TAG "FreeRDP"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGW(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)
#define LOGD(...) OH_LOG_DEBUG(LOG_APP, __VA_ARGS__)

/* 全局缓冲区和互斥锁 */
static uint8_t* g_external_buffer = nullptr;
static size_t g_external_buffer_size = 0;
static std::mutex g_external_buffer_mutex;

/* XComponent NativeWindow 渲染相关 */
static OHNativeWindow* g_nativeWindow = nullptr;
static std::mutex g_nativeWindow_mutex;
static void* g_mappedAddr = nullptr;
static size_t g_mappedSize = 0;

/* Viewport transform: scale + top-left offset (px) applied to RDP framebuffer */
static float g_viewportScale = 1.0f;
static float g_viewportOffsetX = 0.0f;
static float g_viewportOffsetY = 0.0f;

/* Display mode: FIT (aspect-fit letterbox) or FILL (stretch to full screen, default) */
static int g_displayMode = HARMONYOS_DISPLAY_MODE_FILL;

/* Display Control (disp) dynamic channel context for desktop resize on rotation.
 * g_dispOwner 记录该上下文归属的 freerdp 实例：旧实例 teardown 未完成时新实例
 * 已连接的场景下，拒绝陈旧实例的请求，避免跨实例使用已释放的通道上下文。 */
static DispClientContext* g_dispContext = NULL;
static freerdp* g_dispOwner = NULL;

/* Active render context for on-demand redraw (gesture/rotation) */
static rdpContext* g_activeContext = nullptr;

/* OHOS/musl 兼容: GetTickCount64 替代实现 */
#if !defined(_WIN32)
static inline UINT64 GetTickCount64_compat(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        return (UINT64)ts.tv_sec * 1000ULL + (UINT64)ts.tv_nsec / 1000000ULL;
    }
    return 0;
}
#ifndef GetTickCount64
#define GetTickCount64 GetTickCount64_compat
#endif
#endif

#else
#define LOGI(...) printf(__VA_ARGS__)
#define LOGW(...) printf(__VA_ARGS__)
#define LOGE(...) printf(__VA_ARGS__)
#define LOGD(...) printf(__VA_ARGS__)
#endif

#define TAG "FreeRDP.HarmonyOS"

#include <freerdp/codec/color.h>

/* Forward declarations for internal functions defined later in this file */
static bool freerdp_harmonyos_render_to_surface(rdpContext* context, int x1, int y1, int width, int height);
static bool freerdp_harmonyos_render_to_surface_unlocked(rdpContext* context);
static void freerdp_harmonyos_release_surface_unlocked(void);

/* Global callback pointers */
static OnConnectionSuccessCallback g_onConnectionSuccess = nullptr;
static OnConnectionFailureCallback g_onConnectionFailure = nullptr;
static OnPreConnectCallback g_onPreConnect = nullptr;
static OnDisconnectingCallback g_onDisconnecting = nullptr;
static OnDisconnectedCallback g_onDisconnected = nullptr;
static OnSettingsChangedCallback g_onSettingsChanged = nullptr;
static OnGraphicsUpdateCallback g_onGraphicsUpdate = nullptr;
static OnGraphicsResizeCallback g_onGraphicsResize = nullptr;
static OnRemoteClipboardChangedCallback g_onRemoteClipboardChanged = nullptr;
static OnCursorTypeChangedCallback g_onCursorTypeChanged = nullptr;
static OnCursorShapeChangedCallback g_onCursorShapeChanged = nullptr;
static OnFileOpenCallback g_onFileOpen = nullptr;
static OnAuthenticateCallback g_onAuthenticate = nullptr;
static OnVerifyCertificateCallback g_onVerifyCertificate = nullptr;

/* Callback registration implementations */
void harmonyos_set_connection_success_callback(OnConnectionSuccessCallback callback) {
    g_onConnectionSuccess = callback;
}

void harmonyos_set_connection_failure_callback(OnConnectionFailureCallback callback) {
    g_onConnectionFailure = callback;
}

void harmonyos_set_pre_connect_callback(OnPreConnectCallback callback) {
    g_onPreConnect = callback;
}

void harmonyos_set_disconnecting_callback(OnDisconnectingCallback callback) {
    g_onDisconnecting = callback;
}

void harmonyos_set_disconnected_callback(OnDisconnectedCallback callback) {
    g_onDisconnected = callback;
}

void harmonyos_set_settings_changed_callback(OnSettingsChangedCallback callback) {
    g_onSettingsChanged = callback;
}

void harmonyos_set_graphics_update_callback(OnGraphicsUpdateCallback callback) {
    g_onGraphicsUpdate = callback;
}

void harmonyos_set_graphics_resize_callback(OnGraphicsResizeCallback callback) {
    g_onGraphicsResize = callback;
}

void harmonyos_set_remote_clipboard_changed_callback(OnRemoteClipboardChangedCallback callback) {
    g_onRemoteClipboardChanged = callback;
}

void harmonyos_set_cursor_type_changed_callback(OnCursorTypeChangedCallback callback) {
    g_onCursorTypeChanged = callback;
}

void harmonyos_set_cursor_shape_changed_callback(OnCursorShapeChangedCallback callback) {
    g_onCursorShapeChanged = callback;
}

/* ==================== File-open redirection (rdpdr observation hook) ====================
 *
 * The drive channel in libfreerdp-client3 exports
 * ohos_freerdp_set_file_open_callback() only when built WITH
 * WITH_OHOS_FILE_OPEN=ON. Resolve it with dlsym at registration time so this
 * wrapper keeps working against builds with the option OFF (event simply
 * never fires). */

typedef void (*ohos_file_open_register_fn)(void (*)(int64_t, const char*, const char*));

static void harmonyos_file_open_trampoline(int64_t instance, const char* fullPath,
                                           const char* filename) {
    if (g_onFileOpen)
        g_onFileOpen(instance, fullPath, filename);
}

void harmonyos_set_file_open_callback(OnFileOpenCallback callback) {
    g_onFileOpen = callback;

    if (!callback)
        return;

    ohos_file_open_register_fn register_fn =
        (ohos_file_open_register_fn)(uintptr_t)dlsym(RTLD_DEFAULT,
                                                     "ohos_freerdp_set_file_open_callback");
    if (!register_fn) {
        LOGW("ohos_freerdp_set_file_open_callback not found "
             "(libfreerdp-client3 built without WITH_OHOS_FILE_OPEN)");
        return;
    }
    register_fn(harmonyos_file_open_trampoline);
    LOGI("file-open redirection hook registered");
}

void harmonyos_set_authenticate_callback(OnAuthenticateCallback callback) {
    g_onAuthenticate = callback;
}

void harmonyos_set_verify_certificate_callback(OnVerifyCertificateCallback callback) {
    g_onVerifyCertificate = callback;
}

/*
 * [Cursor shape sync] Extended rdpPointer carrying the decoded RGBA bitmap.
 * Uses the standard client extension mechanism (cf. androidPointer in the
 * Android client): harmonyos_register_pointer() sets pointer.size =
 * sizeof(harmonyosPointer), so the framework allocates the extended struct
 * for every pointer cache entry and casts it back in the callbacks.
 */
typedef struct {
    rdpPointer pointer;
    uint8_t* rgba;     /* width*height*4 bytes, byte order R,G,B,A; NULL = undecodable */
    uint32_t rgbaLen;
} harmonyosPointer;

/* [IME heuristic] Visible-pixel count in one bitmap row (alpha >= 0x80).
 * The decoded bitmap is ABGR32, i.e. bytes R,G,B,A per pixel. The 0x80
 * threshold excludes the Windows cursor drop shadow (alpha ~50-100),
 * which would otherwise inflate the bbox and row widths and break the
 * serif-ratio classification below. */
static UINT32 cursor_row_occupancy(const uint8_t* rgba, UINT32 width, UINT32 y) {
    UINT32 count = 0;
    for (UINT32 x = 0; x < width; x++) {
        if (rgba[(y * width + x) * 4 + 3] >= 0x80)
            count++;
    }
    return count;
}

/*
 * [IME heuristic] Content-based classification for full-size cursor bitmaps.
 * Windows sends its standard cursors as 32x32 images with a centered hotspot,
 * so the geometry-only rules in identify_cursor_type() cannot tell IBEAM from
 * WAIT/CROSS/SIZE there and everything falls into the CROSS/WAIT catch-alls.
 * The UI layer relies on a reliable CURSOR_TYPE_IBEAM to auto-popup the soft
 * keyboard when a text field is tapped, so classify by content instead:
 *  - narrow & tall, widest rows at BOTH extremes -> IBEAM (serifs top+bottom;
 *    serif rows only need >= 50% of the widest row: small/faint I-beams have
 *    anti-aliased serifs barely half the widest row, while real resize
 *    arrows have narrow tip rows (<50%) at the extremes and never match)
 *  - narrow & tall, widest rows in the MIDDLE     -> UNKNOWN (mouse arrow)
 *  - narrow & tall otherwise                     -> SIZE_NS
 *  - wide & short                                -> SIZE_WE
 */
static int identify_cursor_content(harmonyosPointer* ptr) {
    const UINT32 width = ptr->pointer.width;
    const UINT32 height = ptr->pointer.height;
    const uint8_t* rgba = ptr->rgba;

    if (!rgba || ptr->rgbaLen < width * height * 4)
        return CURSOR_TYPE_UNKNOWN;

    UINT32 minX = width, minY = height, maxX = 0, maxY = 0;
    for (UINT32 y = 0; y < height; y++) {
        for (UINT32 x = 0; x < width; x++) {
            if (rgba[(y * width + x) * 4 + 3] >= 0x80) {
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }
        }
    }
    if (minX > maxX || minY > maxY)
        return CURSOR_TYPE_UNKNOWN; /* fully transparent */

    const UINT32 bboxW = maxX - minX + 1;
    const UINT32 bboxH = maxY - minY + 1;
    if (bboxW < 2 || bboxH < 4)
        return CURSOR_TYPE_UNKNOWN;

    UINT32 maxRow = 0, topRow = 0, bottomRow = 0;
    for (UINT32 y = minY; y <= maxY; y++) {
        const UINT32 occ = cursor_row_occupancy(rgba, width, y);
        if (occ > maxRow) maxRow = occ;
        if (y <= minY + 2 && occ > topRow) topRow = occ;
        if (y + 2 >= maxY && occ > bottomRow) bottomRow = occ;
    }
    const UINT32 midRow = cursor_row_occupancy(rgba, width, (minY + maxY) / 2);

    int result = CURSOR_TYPE_UNKNOWN;

    /* narrow & tall: aspect ratio >= 1.6 and width <= half the canvas */
    if (bboxH * 10 >= bboxW * 16 && bboxW * 2 <= width) {
        const BOOL serifTop = (midRow * 2 <= topRow) && (topRow * 2 >= maxRow);
        const BOOL serifBottom = (midRow * 2 <= bottomRow) && (bottomRow * 2 >= maxRow);
        if (serifTop && serifBottom)
            result = CURSOR_TYPE_IBEAM;
        else if (midRow * 2 > topRow && midRow * 2 > bottomRow)
            /* widest rows in the middle, narrow at both extremes: classic
             * mouse-arrow profile (e.g. non-32x32 arrow variants on high-DPI
             * remotes that the geometry rules cannot classify). NOT a resize
             * handle - reporting SIZE_NS here misclassified the plain arrow. */
            result = CURSOR_TYPE_UNKNOWN;
        else
            result = CURSOR_TYPE_SIZE_NS;
    }
    /* wide & short */
    else if (bboxW * 10 >= bboxH * 16 && bboxH * 2 <= height)
        result = CURSOR_TYPE_SIZE_WE;

    static int lastLoggedContent = -1;
    if (result != lastLoggedContent) {
        lastLoggedContent = result;
        LOGI("cursor content: bbox=%{public}ux%{public}u max=%{public}u top=%{public}u mid=%{public}u bot=%{public}u -> %{public}d",
             bboxW, bboxH, maxRow, topRow, midRow, bottomRow, result);
    }
    return result;
}

/* Identify cursor type based on pointer properties */
static int identify_cursor_type(rdpPointer* pointer) {
    if (!pointer)
        return CURSOR_TYPE_UNKNOWN;
    
    UINT32 width = pointer->width;
    UINT32 height = pointer->height;
    UINT32 xPos = pointer->xPos;
    UINT32 yPos = pointer->yPos;
    
    if (width == 32 && height == 32 && xPos < 5 && yPos < 5)
        return CURSOR_TYPE_DEFAULT;
    
    if (width == 32 && height == 32 && xPos >= 10 && xPos <= 16 && yPos >= 5 && yPos <= 10)
        return CURSOR_TYPE_HAND;
    
    if (width <= 12 && height >= 16 && xPos <= 6)
        return CURSOR_TYPE_IBEAM;
    
    if (width <= 20 && height >= 24 && xPos >= width/2 - 3 && xPos <= width/2 + 3) {
        if (height > width * 1.2)
            return CURSOR_TYPE_SIZE_NS;
    }
    
    if (height <= 20 && width >= 24 && yPos >= height/2 - 3 && yPos <= height/2 + 3) {
        if (width > height * 1.2)
            return CURSOR_TYPE_SIZE_WE;
    }

    /* Full-size cursors (Windows standard cursors are 32x32 with centered
     * hotspots): the geometry rules above cannot classify those, refine by
     * bitmap content. Must run BEFORE the CROSS/WAIT catch-alls which would
     * otherwise swallow IBEAM and break the soft-keyboard heuristic. */
    {
        const int content = identify_cursor_content((harmonyosPointer*)pointer);
        if (content != CURSOR_TYPE_UNKNOWN)
            return content;
    }

    if (width >= 24 && height >= 24 && 
        xPos >= width/2 - 4 && xPos <= width/2 + 4 &&
        yPos >= height/2 - 4 && yPos <= height/2 + 4)
        return CURSOR_TYPE_CROSS;
    
    if (width == 32 && height == 32)
        return CURSOR_TYPE_WAIT;
    
    return CURSOR_TYPE_UNKNOWN;
}

/* Channel event handlers */
static void harmonyos_OnChannelConnectedEventHandler(void* context, const ChannelConnectedEventArgs* e) {
    harmonyosContext* afc;

    if (!context || !e) {
        LOGE("(context=%p, EventArgs=%p)", context, (void*)e);
        return;
    }

    afc = (harmonyosContext*)context;
    // settings = afc->common.context.settings; // Unused

    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        // TODO: Initialize clipboard
        LOGI("Clipboard channel connected");
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        g_dispContext = (DispClientContext*)e->pInterface;
        g_dispOwner = ((rdpContext*)context)->instance;
        LOGI("DisplayControl channel connected: %p (owner=%p)",
             (void*)g_dispContext, (void*)g_dispOwner);
    } else {
        freerdp_client_OnChannelConnectedEventHandler(context, e);
    }
}

static void harmonyos_OnChannelDisconnectedEventHandler(void* context, const ChannelDisconnectedEventArgs* e) {
    harmonyosContext* afc;

    if (!context || !e) {
        LOGE("(context=%p, EventArgs=%p)", context, (void*)e);
        return;
    }

    afc = (harmonyosContext*)context;
    // settings = afc->common.context.settings; // Unused

    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        // TODO: Uninitialize clipboard
        LOGI("Clipboard channel disconnected");
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        LOGI("DisplayControl channel disconnected");
        /* 仅当断开者与当前归属一致时清理，避免旧实例迟到的事件清掉新实例的上下文 */
        if (g_dispOwner == ((rdpContext*)context)->instance) {
            g_dispContext = NULL;
            g_dispOwner = NULL;
        }
    } else {
        freerdp_client_OnChannelDisconnectedEventHandler(context, e);
    }
}

/* Paint handlers */
static BOOL harmonyos_begin_paint(rdpContext* context) {
    (void)context;
    return TRUE;
}

bool freerdp_harmonyos_update_graphics_buffer(int64_t instance, uint8_t* buffer, size_t buffer_size) {
    std::lock_guard<std::mutex> lock(g_external_buffer_mutex);
    g_external_buffer = buffer;
    g_external_buffer_size = buffer_size;
    LOGI("freerdp_harmonyos_update_graphics_buffer: buffer=%p, size=%zu", buffer, buffer_size);
    return true;
}

static BOOL harmonyos_end_paint(rdpContext* context) {
    HGDI_WND hwnd;
    int ninvalid;
    rdpGdi* gdi;
    HGDI_RGN cinvalid;
    int x1, y1, x2, y2;
    harmonyosContext* ctx = (harmonyosContext*)context;
    rdpSettings* settings;

    if (!ctx || !context->instance)
        return FALSE;

    settings = context->settings;
    if (!settings)
        return FALSE;

    gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc)
        return FALSE;

    hwnd = ctx->common.context.gdi->primary->hdc->hwnd;
    if (!hwnd)
        return FALSE;

    ninvalid = hwnd->ninvalid;
    if (ninvalid < 1)
        return TRUE;

    cinvalid = hwnd->cinvalid;
    if (!cinvalid)
        return FALSE;

    x1 = cinvalid[0].x;
    y1 = cinvalid[0].y;
    x2 = cinvalid[0].x + cinvalid[0].w;
    y2 = cinvalid[0].y + cinvalid[0].h;

    for (int i = 0; i < ninvalid; i++) {
        x1 = MIN(x1, cinvalid[i].x);
        y1 = MIN(y1, cinvalid[i].y);
        x2 = MAX(x2, cinvalid[i].x + cinvalid[i].w);
        y2 = MAX(y2, cinvalid[i].y + cinvalid[i].h);
    }

    /* 
     * RENDERING STRATEGY:
     * 1. If NativeWindow (XComponent surface) is available, render directly to it.
     *    This is the fastest path - no data copy to ArkTS, no PixelMap overhead.
     * 2. If no NativeWindow, fall back to ArkTS callback (g_onGraphicsUpdate).
     *    ArkTS will call getFrameBuffer() to copy data to PixelMap.
     */
    
    static int frameCount = 0;
    if (frameCount < 5) {
        LOGI("harmonyos_end_paint: frame=%d, region=[%d,%d,%d,%d], gdi=%dx%d", 
             frameCount, x1, y1, x2-x1, y2-y1, gdi->width, gdi->height);
        frameCount++;
    }
    
    /* Try direct NativeWindow rendering first */
    g_activeContext = context;
    bool rendered = freerdp_harmonyos_render_to_surface(context, x1, y1, x2 - x1, y2 - y1);
    
    /* Fall back to ArkTS callback if NativeWindow not available */
    if (!rendered && g_onGraphicsUpdate) {
        g_onGraphicsUpdate((int64_t)(uintptr_t)context->instance, x1, y1, x2 - x1, y2 - y1);
    }

    hwnd->invalid->null = TRUE;
    hwnd->ninvalid = 0;
    return TRUE;
}

static BOOL harmonyos_desktop_resize(rdpContext* context) {
    rdpSettings* settings;

    /* 安全检查 - 不使用 WINPR_ASSERT 避免 abort */
    if (!context || !context->instance) {
        LOGE("harmonyos_desktop_resize: invalid context");
        return FALSE;
    }

    /* [闪退修复] settings 指针单次读取后再判空使用：teardown 竞态下 context
     * 内存可能被并发释放/清零，若先检查 context->settings 再通过 context 重复
     * 取址（TOCTOU），相邻两次读取之间被置空会让 freerdp_settings_get_uint32
     * 命中 WINPR_ASSERT(settings) 直接 abort。 */
    settings = context->settings;
    if (!settings) {
        LOGE("harmonyos_desktop_resize: settings is NULL");
        return FALSE;
    }

    /*
     * [画面修复] GDI 帧缓冲必须跟随服务器分辨率重建（对齐 X11 客户端
     * xf_sw_desktop_resize 的标准做法）。此前只上报回调不重建 GDI，
     * gdi->primary_buffer 仍是旧尺寸：横屏 2776x1130 的帧被裁剪进
     * 1224x2776 的缓冲，导致只显示左半边画面。
     * 持有渲染互斥锁执行：gdi_resize 会释放旧 primary_buffer，而 UI 线程
     * （set_viewport → render_to_surface）可能并发读取该缓冲，不加锁会
     * 读到已释放内存（UAF）。render 回调与本回调同线程顺序执行，无死锁。
     */
    rdpGdi* gdi = context->gdi;
    if (gdi) {
        const UINT32 newWidth = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
        const UINT32 newHeight = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
        {
            std::lock_guard<std::mutex> lock(g_nativeWindow_mutex);
            if (!gdi_resize(gdi, newWidth, newHeight)) {
                LOGE("harmonyos_desktop_resize: gdi_resize to %ux%u failed",
                     (unsigned)newWidth, (unsigned)newHeight);
                return FALSE;
            }
            /* 新缓冲清零：服务器整屏重绘到达前避免闪现旧内容/未初始化数据 */
            if (gdi->primary_buffer && gdi->stride > 0 && gdi->height > 0) {
                memset(gdi->primary_buffer, 0, (size_t)gdi->stride * (size_t)gdi->height);
            }
        }
        LOGI("harmonyos_desktop_resize: gdi buffer resized to %ux%u",
             (unsigned)newWidth, (unsigned)newHeight);
    }

    if (g_onGraphicsResize) {
        g_onGraphicsResize((int64_t)(uintptr_t)context->instance,
            freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
            freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight),
            freerdp_settings_get_uint32(settings, FreeRDP_ColorDepth));
    }
    return TRUE;
}

/* Pre-connect callback */
static BOOL harmonyos_pre_connect(freerdp* instance) {
    int rc;
    rdpSettings* settings;
    rdpContext* context;

    LOGI("harmonyos_pre_connect: ENTER");

    /* 安全检查 - 不使用 WINPR_ASSERT 避免 abort */
    if (!instance) {
        LOGE("harmonyos_pre_connect: instance is NULL");
        return FALSE;
    }
    
    context = instance->context;
    if (!context) {
        LOGE("harmonyos_pre_connect: context is NULL");
        return FALSE;
    }

    settings = context->settings;
    if (!settings) {
        LOGE("harmonyos_pre_connect: settings is NULL");
        return FALSE;
    }

    LOGI("harmonyos_pre_connect: Settings validated, proceeding...");

    /*
     * 注意：移除了对 settings 字符串的手动提取和打印。
     * 在某些 FreeRDP 版本中，如果在 pre_connect 阶段 settings 尚未完全同步，
     * 访问这些字段可能导致不稳定的行为甚至崩溃。
     */

    /*
     * [闪退修复] 强制同步静态/动态通道。
     * 崩溃栈（SIGABRT @ drdynvc_virtual_channel_client_thread）表明 drdynvc 以
     * 异步模式运行：其 terminated 处理不 join 工作线程，若 context/gdi 在线程
     * 仍处理迟到 PDU（/dynamic-resolution 的 ResetGraphics）时释放，会以悬空
     * context 调用 update->DesktopResize → getter 断言 abort。
     * 同步模式下 PDU 全部在客户端主线程内联处理，teardown 时序由
     * freerdp_disconnect 保证。pre_connect 是通道加载（utils_reload_channels）
     * 之前最后的设置点，此处兜底重设并记录运行时实际值。
     */
    if (!freerdp_settings_set_bool(settings, FreeRDP_SynchronousStaticChannels, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_SynchronousDynamicChannels, TRUE)) {
        LOGE("harmonyos_pre_connect: failed to enforce synchronous channels");
        return FALSE;
    }
    LOGI("harmonyos_pre_connect: sync channels enforced (static=%d dyn=%d)",
         freerdp_settings_get_bool(settings, FreeRDP_SynchronousStaticChannels),
         freerdp_settings_get_bool(settings, FreeRDP_SynchronousDynamicChannels));

    rc = PubSub_SubscribeChannelConnected(context->pubSub,
                                          harmonyos_OnChannelConnectedEventHandler);
    if (rc != CHANNEL_RC_OK) {
        LOGE("Could not subscribe to connect event handler [%{public}08X]", rc);
        /* 不直接返回 FALSE，尝试继续 */
    } else {
        LOGI("harmonyos_pre_connect: ChannelConnected subscribed");
    }

    rc = PubSub_SubscribeChannelDisconnected(context->pubSub,
                                             harmonyos_OnChannelDisconnectedEventHandler);
    if (rc != CHANNEL_RC_OK) {
        LOGE("Could not subscribe to disconnect event handler [%{public}08X]", rc);
    } else {
        LOGI("harmonyos_pre_connect: ChannelDisconnected subscribed");
    }

    if (g_onPreConnect) {
        g_onPreConnect((int64_t)(uintptr_t)instance);
    }
    
    LOGI("harmonyos_pre_connect: returning TRUE");
    return TRUE;
}

/* Pointer handlers */
/* (harmonyosPointer is defined next to identify_cursor_type above) */

/* Last-delivered cursor shape (dedup: Windows re-Sets the same cached
 * pointer constantly, e.g. when moving between windows) */
static uint8_t* g_lastCursorRgba = nullptr;
static uint32_t g_lastCursorLen = 0;
static uint32_t g_lastCursorW = 0;
static uint32_t g_lastCursorH = 0;
static uint32_t g_lastCursorHX = 0;
static uint32_t g_lastCursorHY = 0;
static int g_lastCursorType = -1;
/* Last cursor type already written to the device log (log dedup only) */
static int g_lastLoggedCursorType = -1;

static BOOL harmonyos_Pointer_New(rdpContext* context, rdpPointer* pointer) {
    /* 安全检查 */
    if (!context || !pointer || !context->gdi)
        return FALSE;

    harmonyosPointer* ptr = (harmonyosPointer*)pointer;
    ptr->rgba = NULL;
    ptr->rgbaLen = 0;

    /* Sanity bounds: standard pointers are 32x32, large-pointer capability
     * allows up to 384x384. Out-of-range shapes keep the type-only fallback. */
    if (pointer->width == 0 || pointer->height == 0 ||
        pointer->width > 384 || pointer->height > 384)
        return TRUE;

    const uint32_t len = pointer->width * pointer->height * 4;
    ptr->rgba = (uint8_t*)calloc(len, 1);
    if (!ptr->rgba)
        return TRUE; /* OOM: type-only fallback, do not break the session */

    /*
     * Pixel-perfect conversion of xor/and masks (handles 1/8/16/24/32 bpp
     * xor data, transparency + inverted pixels, bottom-up rows) - same
     * utility the X11/Wayland/SDL/Android clients use.
     * PIXEL_FORMAT_ABGR32 yields byte order R,G,B,A which matches
     * ArkTS image.PixelMapFormat.RGBA_8888.
     */
    if (!freerdp_image_copy_from_pointer_data(
            ptr->rgba, PIXEL_FORMAT_ABGR32, 0, 0, 0, pointer->width, pointer->height,
            pointer->xorMaskData, pointer->lengthXorMask, pointer->andMaskData,
            pointer->lengthAndMask, pointer->xorBpp, &context->gdi->palette)) {
        LOGW("cursor decode failed (%ux%u xorBpp=%u), fallback to type-only",
             pointer->width, pointer->height, pointer->xorBpp);
        free(ptr->rgba);
        ptr->rgba = NULL;
        return TRUE;
    }
    ptr->rgbaLen = len;
    return TRUE;
}

static void harmonyos_Pointer_Free(rdpContext* context, rdpPointer* pointer) {
    WINPR_UNUSED(context);
    if (pointer) {
        harmonyosPointer* ptr = (harmonyosPointer*)pointer;
        free(ptr->rgba);
        ptr->rgba = NULL;
        ptr->rgbaLen = 0;
    }
}

/* Send a "shape cleared" event (SetNull/SetDefault) and reset dedup state */
static void harmonyos_clear_cursor_shape(freerdp* instance, int cursorType) {
    free(g_lastCursorRgba);
    g_lastCursorRgba = nullptr;
    g_lastCursorLen = 0;
    g_lastCursorType = cursorType;
    g_lastCursorW = g_lastCursorH = g_lastCursorHX = g_lastCursorHY = 0;
    if (instance && g_onCursorShapeChanged) {
        g_onCursorShapeChanged((int64_t)(uintptr_t)instance, cursorType, 0, 0, 0, 0, NULL, 0);
    }
}

static BOOL harmonyos_Pointer_Set(rdpContext* context, rdpPointer* pointer) {
    /* 安全检查 */
    if (!context || !pointer)
        return FALSE;

    int cursorType = identify_cursor_type(pointer);

    /* Type transitions only (device-log diagnostics for the IME heuristic) */
    if (cursorType != g_lastLoggedCursorType) {
        g_lastLoggedCursorType = cursorType;
        LOGI("Pointer_Set: cursor type=%{public}d size=%{public}ux%{public}u hotspot=(%{public}u,%{public}u)", cursorType,
             pointer->width, pointer->height, pointer->xPos, pointer->yPos);
    }

    freerdp* instance = context->instance;

    /* Legacy type-only event (unchanged behaviour) */
    if (instance && g_onCursorTypeChanged) {
        g_onCursorTypeChanged((int64_t)(uintptr_t)instance, cursorType);
    }

    /* New shape event: type + bitmap + hotspot */
    if (instance && g_onCursorShapeChanged) {
        harmonyosPointer* ptr = (harmonyosPointer*)pointer;
        const uint8_t* rgba = ptr->rgba;
        const uint32_t len = ptr->rgbaLen;

        bool changed = (len != g_lastCursorLen) || (cursorType != g_lastCursorType) ||
                       (pointer->width != g_lastCursorW) || (pointer->height != g_lastCursorH) ||
                       (pointer->xPos != g_lastCursorHX) || (pointer->yPos != g_lastCursorHY);
        if (!changed && len > 0)
            changed = (memcmp(rgba, g_lastCursorRgba, len) != 0);

        if (changed) {
            g_onCursorShapeChanged((int64_t)(uintptr_t)instance, cursorType,
                                   (int)pointer->width, (int)pointer->height,
                                   (int)pointer->xPos, (int)pointer->yPos, rgba, (int)len);

            /* Refresh dedup snapshot (deep copy: the cache entry may be
             * freed anytime after this callback returns) */
            free(g_lastCursorRgba);
            g_lastCursorRgba = nullptr;
            if (len > 0) {
                g_lastCursorRgba = (uint8_t*)malloc(len);
                if (g_lastCursorRgba)
                    memcpy(g_lastCursorRgba, rgba, len);
            }
            g_lastCursorLen = len;
            g_lastCursorType = cursorType;
            g_lastCursorW = pointer->width;
            g_lastCursorH = pointer->height;
            g_lastCursorHX = pointer->xPos;
            g_lastCursorHY = pointer->yPos;
        }
    }

    return TRUE;
}

static BOOL harmonyos_Pointer_SetPosition(rdpContext* context, UINT32 x, UINT32 y) {
    if (!context)
        return FALSE;
    LOGD("Pointer SetPosition: x=%u, y=%u", x, y);
    return TRUE;
}

static BOOL harmonyos_Pointer_SetNull(rdpContext* context) {
    if (!context)
        return FALSE;
    LOGD("Pointer_SetNull");
    
    freerdp* instance = context->instance;
    if (instance && g_onCursorTypeChanged) {
        g_onCursorTypeChanged((int64_t)(uintptr_t)instance, CURSOR_TYPE_UNKNOWN);
    }
    harmonyos_clear_cursor_shape(instance, CURSOR_TYPE_UNKNOWN);
    return TRUE;
}

static BOOL harmonyos_Pointer_SetDefault(rdpContext* context) {
    if (!context)
        return FALSE;
    LOGD("Pointer_SetDefault");
    
    freerdp* instance = context->instance;
    if (instance && g_onCursorTypeChanged) {
        g_onCursorTypeChanged((int64_t)(uintptr_t)instance, CURSOR_TYPE_DEFAULT);
    }
    harmonyos_clear_cursor_shape(instance, CURSOR_TYPE_DEFAULT);
    return TRUE;
}

static BOOL harmonyos_register_pointer(rdpGraphics* graphics) {
    harmonyosPointer pointer;
    memset(&pointer, 0, sizeof(harmonyosPointer));

    if (!graphics)
        return FALSE;

    /* Tell the framework to allocate the extended struct for every cache
     * entry so the callbacks can cast rdpPointer* back to harmonyosPointer* */
    pointer.pointer.size = sizeof(pointer);
    pointer.pointer.New = harmonyos_Pointer_New;
    pointer.pointer.Free = harmonyos_Pointer_Free;
    pointer.pointer.Set = harmonyos_Pointer_Set;
    pointer.pointer.SetNull = harmonyos_Pointer_SetNull;
    pointer.pointer.SetDefault = harmonyos_Pointer_SetDefault;
    pointer.pointer.SetPosition = harmonyos_Pointer_SetPosition;
    graphics_register_pointer(graphics, &pointer.pointer);
    return TRUE;
}

/* Post-connect callback */
static BOOL harmonyos_post_connect(freerdp* instance) {
    rdpSettings* settings;
    rdpUpdate* update;

    LOGI("harmonyos_post_connect: ENTER");

    /* 安全检查 - 不使用 WINPR_ASSERT 避免 abort */
    if (!instance) {
        LOGE("harmonyos_post_connect: instance is NULL");
        return FALSE;
    }
    if (!instance->context) {
        LOGE("harmonyos_post_connect: context is NULL");
        return FALSE;
    }

    update = instance->context->update;
    if (!update) {
        LOGE("harmonyos_post_connect: update is NULL");
        return FALSE;
    }

    settings = instance->context->settings;
    if (!settings) {
        LOGE("harmonyos_post_connect: settings is NULL");
        return FALSE;
    }

    /* 能力协商后检查：服务端 input caps 会覆写 FreeRDP_UnicodeInput，
     * 若为 0 则 input.c 会静默丢弃全部 Unicode 键事件（IME 输入落空的头号嫌疑） */
    LOGI("harmonyos_post_connect: negotiated UnicodeInput=%{public}d",
         freerdp_settings_get_bool(settings, FreeRDP_UnicodeInput) ? 1 : 0);

    LOGI("harmonyos_post_connect: Calling gdi_init...");
    if (!gdi_init(instance, PIXEL_FORMAT_RGBX32)) {
        LOGE("harmonyos_post_connect: gdi_init failed");
        return FALSE;
    }
    LOGI("harmonyos_post_connect: gdi_init succeeded");

    if (!harmonyos_register_pointer(instance->context->graphics)) {
        LOGE("harmonyos_post_connect: register_pointer failed");
        return FALSE;
    }
    LOGI("harmonyos_post_connect: register_pointer succeeded");

    LOGI("harmonyos_post_connect: Setting update callbacks...");
    update->BeginPaint = harmonyos_begin_paint;
    update->EndPaint = harmonyos_end_paint;
    update->DesktopResize = harmonyos_desktop_resize;
    LOGI("harmonyos_post_connect: Update callbacks set");

    if (g_onSettingsChanged) {
        g_onSettingsChanged((int64_t)(uintptr_t)instance,
                            (int)settings->DesktopWidth,
                            (int)settings->DesktopHeight,
                            (int)settings->ColorDepth);
        LOGI("harmonyos_post_connect: SettingsChanged callback called");
    }

    if (g_onConnectionSuccess) {
        g_onConnectionSuccess((int64_t)(uintptr_t)instance);
        LOGI("harmonyos_post_connect: ConnectionSuccess callback called");
    }

    LOGI("harmonyos_post_connect: EXIT - connection established");
    return TRUE;
}

/* Post-disconnect callback */
static void harmonyos_post_disconnect(freerdp* instance) {
    LOGI("harmonyos_post_disconnect: ENTER");
    
    /* 尝试获取更多断开原因的信息 */
    if (instance && instance->context) {
        UINT32 errorCode = freerdp_get_last_error(instance->context);
        const char* errorString = freerdp_get_last_error_string(errorCode);
        LOGI("harmonyos_post_disconnect: ErrorCode=0x%{public}X Msg=%{public}s", 
             (unsigned int)errorCode, errorString ? errorString : "NULL");
    }
    
    if (g_onDisconnecting) {
        g_onDisconnecting((int64_t)(uintptr_t)instance);
    }
    gdi_free(instance);
    
    LOGI("harmonyos_post_disconnect: EXIT");
}

/* Authentication callback */
static BOOL harmonyos_authenticate(freerdp* instance, char** username, char** password, char** domain) {
    if (g_onAuthenticate) {
        return g_onAuthenticate((int64_t)(uintptr_t)instance, username, domain, password);
    }
    return FALSE;
}

static BOOL harmonyos_gw_authenticate(freerdp* instance, char** username, char** password, char** domain) {
    return harmonyos_authenticate(instance, username, password, domain);
}

/* Certificate verification callback */
static DWORD harmonyos_verify_certificate_ex(freerdp* instance, const char* host, UINT16 port,
                                             const char* common_name, const char* subject,
                                             const char* issuer, const char* fingerprint, DWORD flags) {
    LOGD("Certificate details [%s:%u]:", host, port);
    LOGD("\tSubject: %s", subject);
    LOGD("\tIssuer: %s", issuer);
    LOGD("\tThumbprint: %s", fingerprint);

    if (g_onVerifyCertificate) {
        return g_onVerifyCertificate((int64_t)(uintptr_t)instance, host, port,
                                     common_name, subject, issuer, fingerprint, flags);
    }
    
    // Default: accept certificate
    return 1;
}

static DWORD harmonyos_verify_changed_certificate_ex(freerdp* instance, const char* host, UINT16 port,
                                                     const char* common_name, const char* subject,
                                                     const char* issuer, const char* new_fingerprint,
                                                     const char* old_subject, const char* old_issuer,
                                                     const char* old_fingerprint, DWORD flags) {
    (void)old_subject;
    (void)old_issuer;
    (void)old_fingerprint;
    return harmonyos_verify_certificate_ex(instance, host, port, common_name, subject,
                                           issuer, new_fingerprint, flags);
}

/* Background mode state tracking */
static volatile BOOL g_isInBackgroundMode = FALSE;
static volatile UINT64 g_lastNetworkActivityTime = 0;
static const DWORD BACKGROUND_KEEPALIVE_INTERVAL_MS = 30000; /* 30 seconds */
static const DWORD NETWORK_TIMEOUT_MS = 60000; /* 60 seconds without activity = timeout */

/* Update network activity timestamp */
static void update_network_activity(void) {
    g_lastNetworkActivityTime = GetTickCount64();
}

/* Check if network is still alive based on activity */
static BOOL is_network_alive(void) {
    if (g_lastNetworkActivityTime == 0)
        return TRUE; /* Not initialized yet */
    
    UINT64 elapsed = GetTickCount64() - g_lastNetworkActivityTime;
    return elapsed < NETWORK_TIMEOUT_MS;
}

/* Main run loop with background mode support */
static int harmonyos_freerdp_run(freerdp* instance) {
    DWORD count;
    DWORD status = WAIT_FAILED;
    HANDLE handles[MAXIMUM_WAIT_OBJECTS];
    HANDLE inputEvent = NULL;
    rdpContext* context = instance->context;
    DWORD waitTimeout;
    DWORD consecutiveTimeouts = 0;
    const DWORD MAX_CONSECUTIVE_TIMEOUTS = 10;

    inputEvent = harmonyos_get_handle(instance);
    update_network_activity(); /* Initialize activity timestamp */

    while (!freerdp_shall_disconnect_context(instance->context)) {
        DWORD tmp;
        count = 0;

        handles[count++] = inputEvent;

        tmp = freerdp_get_event_handles(context, &handles[count], 64 - count);
        if (tmp == 0) {
            LOGE("freerdp_get_event_handles failed");
            break;
        }

        count += tmp;
        
        /* In background mode, use timeout to periodically check connection health */
        if (g_isInBackgroundMode) {
            waitTimeout = BACKGROUND_KEEPALIVE_INTERVAL_MS;
        } else {
            waitTimeout = INFINITE;
        }
        
        status = WaitForMultipleObjects(count, handles, FALSE, waitTimeout);

        if (status == WAIT_FAILED) {
            LOGE("WaitForMultipleObjects failed with %u [%08X]", status, (unsigned int)GetLastError());
            break;
        }
        
        if (status == WAIT_TIMEOUT) {
            /* Timeout in background mode - check connection health */
            if (g_isInBackgroundMode) {
                consecutiveTimeouts++;
                LOGD("Background keepalive check (%d/%d)", consecutiveTimeouts, MAX_CONSECUTIVE_TIMEOUTS);
                
                /* Check if network is still alive */
                if (!is_network_alive()) {
                    LOGW("Network timeout detected in background mode");
                    break;
                }
                
                /* Too many consecutive timeouts might indicate connection issue */
                if (consecutiveTimeouts >= MAX_CONSECUTIVE_TIMEOUTS) {
                    LOGW("Too many consecutive timeouts, checking connection...");
                    /* Reset counter but don't break - let FreeRDP handle it */
                    consecutiveTimeouts = 0;
                }
                
                continue; /* Continue waiting */
            }
        } else {
            /* Reset timeout counter on activity */
            consecutiveTimeouts = 0;
            update_network_activity();
        }

        if (!freerdp_check_event_handles(context)) {
            DWORD checkErr = GetLastError();
            LOGW("freerdp_check_event_handles failed (error=0x%08X), retrying...", checkErr);
            
            int retries = 0;
            const int MAX_EVENT_RETRIES = 3;
            BOOL eventOk = FALSE;
            while (retries < MAX_EVENT_RETRIES) {
                retries++;
                Sleep(50);
                eventOk = freerdp_check_event_handles(context);
                if (eventOk) {
                    LOGI("freerdp_check_event_handles recovered on retry %d", retries);
                    break;
                }
            }
            
            if (!eventOk) {
                LOGE("freerdp_check_event_handles failed after %d retries, disconnecting", MAX_EVENT_RETRIES);
                status = checkErr;
                break;
            }
        }

        if (freerdp_shall_disconnect_context(instance->context))
            break;

        if (harmonyos_check_handle(instance) != TRUE) {
            LOGW("harmonyos_check_handle failed, retrying...");
            Sleep(50);
            if (harmonyos_check_handle(instance) != TRUE) {
                LOGE("harmonyos_check_handle failed after retry, disconnecting");
                status = GetLastError();
                break;
            }
        }
    }

    LOGI("Prepare shutdown...");
    return status;
}

/* Auto-reconnect callback for logging */
static void internal_on_reconnecting(void* ctx, int attempt, int maxAttempts) {
    LOGI("Auto-reconnect attempt %d/%d", attempt, maxAttempts);
}

/* Thread function with auto-reconnect support */
static DWORD WINAPI harmonyos_thread_func(LPVOID param) {
    DWORD status = ERROR_BAD_ARGUMENTS;
    freerdp* instance = (freerdp*)param;
    rdpContext* context = NULL;
    BOOL shouldReconnect = FALSE;
    BOOL connectResult = FALSE;
    int reconnectAttempts = 0;
    const int MAX_RECONNECT_ATTEMPTS = 5;
    UINT64 connectStartTime = 0;
    UINT64 connectEndTime = 0;
    UINT64 connectDuration = 0;
    int savedErrno = 0;
    
    LOGD("Start...");

    /* 安全检查 - 不使用 WINPR_ASSERT 避免 abort */
    if (!instance) {
        LOGE("harmonyos_thread_func: instance is NULL");
        goto fail;
    }
    if (!instance->context) {
        LOGE("harmonyos_thread_func: context is NULL");
        goto fail;
    }
    
    context = instance->context;

    if (freerdp_client_start(context) != CHANNEL_RC_OK) {
        LOGE("freerdp_client_start failed");
        goto fail;
    }

    LOGI("Connect... (attempt 1)");
    LOGI("Checking instance validity...");
    
    if (!instance) {
        LOGE("instance became NULL!");
        goto fail;
    }
    
    LOGI("instance=%{public}p", (void*)instance);
    LOGI("context=%{public}p", (void*)instance->context);
    
    if (!instance->context) {
        LOGE("context is NULL before connect!");
        goto fail;
    }
    
    if (!instance->context->settings) {
        LOGE("settings is NULL before connect!");
        goto fail;
    }
    
    LOGI("PreConnect callback=%{public}p", (void*)instance->PreConnect);
    LOGI("PostConnect callback=%{public}p", (void*)instance->PostConnect);
    
    LOGI("Calling freerdp_connect NOW...");

    /* 清除 errno 以便准确捕获连接错误 */
    errno = 0;
    
    /* 记录连接开始时间 */
    connectStartTime = GetTickCount64();
    
    connectResult = freerdp_connect(instance);
    
    /* 立即保存 errno，避免被后续调用覆盖 */
    savedErrno = errno;
    
    /* 计算连接耗时 */
    connectEndTime = GetTickCount64();
    connectDuration = connectEndTime - connectStartTime;
    
    LOGI("freerdp_connect returned: %{public}s (took %{public}llu ms)", 
         connectResult ? "TRUE" : "FALSE", (unsigned long long)connectDuration);
    
    /* 如果失败，打印 errno */
    if (!connectResult) {
        LOGE("errno=%{public}d (%{public}s)", savedErrno, 
             savedErrno ? strerror(savedErrno) : "No error");
        
        /* 如果连接时间很短（<100ms），说明可能是配置或初始化错误 */
        if (connectDuration < 100) {
            LOGE("Connection failed very quickly - likely config/init error, not network");
        }
    }
    
    if (!connectResult) {
        status = GetLastError();
        
        /* 获取详细错误信息 */
        UINT32 errorCode = freerdp_get_last_error(context);
        const char* errorString = freerdp_get_last_error_string(errorCode);
        const char* errorCategory = freerdp_get_last_error_category(errorCode);
        
        /* 使用 {public} 标记避免隐私过滤 */
        LOGE("Connection failed! GetLastError=0x%{public}08X", status);
        LOGE("FreeRDP ErrorCode=0x%{public}08X", errorCode);
        LOGE("FreeRDP Category=%{public}s", errorCategory ? errorCategory : "Unknown");
        LOGE("FreeRDP Message=%{public}s", errorString ? errorString : "No error message");
        
        /* 分类错误类型 */
        const char* errorType = "UNKNOWN";
        UINT32 errorType_id = errorCode & 0xFFFF;
        
        if (errorCode == 0) {
            errorType = "INTERNAL_ERROR";
            LOGE("Error Type: %{public}s - Internal error", errorType);
        } else if (errorType_id >= 0x0005 && errorType_id <= 0x0007) {
            errorType = "NETWORK_ERROR";
            LOGE("Error Type: %{public}s - Check host address and port", errorType);
        } else if (errorType_id == 0x0009 || errorType_id == 0x000F || 
                   (errorType_id >= 0x0010 && errorType_id <= 0x001F)) {
            errorType = "AUTH_ERROR";
            LOGE("Error Type: %{public}s - Check username and password", errorType);
        } else if (errorType_id == 0x0008 || errorType_id == 0x000B || errorType_id == 0x000D) {
            errorType = "SECURITY_ERROR";
            LOGE("Error Type: %{public}s - Check security settings (RDP/TLS/NLA)", errorType);
        } else {
            errorType = "CONNECTION_ERROR";
            LOGE("Error Type: %{public}s - General connection failure", errorType);
        }
        
        /* 
         * 关键修复：禁用 Native 层重连。
         * 让 ArkTS 层统一处理连接生命周期，避免多个实例抢占会话。
         */
        LOGI("Native reconnection disabled. Reporting failure to ArkTS.");
        goto fail;
    } else {
        /* Connection successful */
        freerdp_client_set_connected(context, TRUE);
        
        status = harmonyos_freerdp_run(instance);
        LOGD("Run loop exited with status: %08X", status);
        
        freerdp_client_set_connected(context, FALSE);

        if (!freerdp_disconnect(instance)) {
            LOGE("Disconnect failed");
        }
        
        /* 连接丢失后也直接返回，由上层重连 */
        LOGI("Session ended. Reporting to ArkTS.");
    }

    LOGD("Stop...");

    if (freerdp_client_stop(context) != CHANNEL_RC_OK)
        goto fail;

fail:
    LOGD("Session ended with %08X", status);

    if (status == CHANNEL_RC_OK || reconnectAttempts == 0) {
        if (g_onDisconnected) {
            g_onDisconnected((int64_t)(uintptr_t)instance);
        }
    } else {
        if (g_onConnectionFailure) {
            g_onConnectionFailure((int64_t)(uintptr_t)instance);
        }
    }

    LOGD("Quit.");
    ExitThread(status);
    return status;
}

/* Client new/free */
static BOOL harmonyos_client_new(freerdp* instance, rdpContext* context) {
    /* 安全检查 - 不使用 WINPR_ASSERT 避免 abort */
    if (!instance) {
        LOGE("harmonyos_client_new: instance is NULL");
        return FALSE;
    }
    if (!context) {
        LOGE("harmonyos_client_new: context is NULL");
        return FALSE;
    }

    if (!harmonyos_event_queue_init(instance)) {
        LOGE("harmonyos_client_new: event_queue_init failed");
        return FALSE;
    }

    instance->PreConnect = harmonyos_pre_connect;
    instance->PostConnect = harmonyos_post_connect;
    instance->PostDisconnect = harmonyos_post_disconnect;
    instance->Authenticate = harmonyos_authenticate;
    instance->GatewayAuthenticate = harmonyos_gw_authenticate;
    instance->VerifyCertificateEx = harmonyos_verify_certificate_ex;
    instance->VerifyChangedCertificateEx = harmonyos_verify_changed_certificate_ex;
    instance->LogonErrorInfo = NULL;
    return TRUE;
}

static void harmonyos_client_free(freerdp* instance, rdpContext* context) {
    if (!context)
        return;

    harmonyos_event_queue_uninit(instance);
}

static int RdpClientEntry(RDP_CLIENT_ENTRY_POINTS* pEntryPoints) {
    /* 安全检查 - 不使用 WINPR_ASSERT 避免 abort */
    if (!pEntryPoints) {
        LOGE("RdpClientEntry: pEntryPoints is NULL");
        return -1;
    }

    ZeroMemory(pEntryPoints, sizeof(RDP_CLIENT_ENTRY_POINTS));

    pEntryPoints->Version = RDP_CLIENT_INTERFACE_VERSION;
    pEntryPoints->Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    pEntryPoints->GlobalInit = NULL;
    pEntryPoints->GlobalUninit = NULL;
    pEntryPoints->ContextSize = sizeof(harmonyosContext);
    pEntryPoints->ClientNew = harmonyos_client_new;
    pEntryPoints->ClientFree = harmonyos_client_free;
    pEntryPoints->ClientStart = NULL;
    pEntryPoints->ClientStop = NULL;
    return 0;
}

/* ==================== Public API Implementation ==================== */

/* 全局 SSL 初始化标志 */
static BOOL g_sslInitialized = FALSE;

int64_t freerdp_harmonyos_new(void) {
    RDP_CLIENT_ENTRY_POINTS clientEntryPoints;
    rdpContext* ctx;

    setlocale(LC_ALL, "");

    /* 调试期：开启 WinPR/FreeRDP 内部 DEBUG 日志（transport/TLS/NLA 层诊断信息进 hilog） */
    WLog_SetLogLevel(WLog_Get(""), WLOG_DEBUG);
    
    /* 初始化 OpenSSL（只需要做一次） */
    if (!g_sslInitialized) {
        LOGI("freerdp_harmonyos_new: Initializing SSL...");
        
        /* 
         * 针对 HarmonyOS 的重要修复：
         * 1. 设置 HOME 环境变量到应用沙箱目录，防止 FreeRDP 尝试在沙箱外创建配置目录。
         * 2. 显式清除 OpenSSL 模块路径环境变量，防止其尝试访问编译机路径 (/home/runner/work/...)
         */
        setenv("HOME", "/data/storage/el2/base/files", 1);
        unsetenv("OPENSSL_MODULES");
        unsetenv("OPENSSL_CONF");
        unsetenv("OPENSSL_ENGINES");
        
        /* 使用 winpr 的 SSL 初始化函数 */
        if (winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT)) {
            LOGI("freerdp_harmonyos_new: SSL initialized successfully");
        } else {
            LOGW("freerdp_harmonyos_new: SSL initialization returned FALSE (proceeding anyway)");
        }
        g_sslInitialized = TRUE;
    }

    RdpClientEntry(&clientEntryPoints);
    ctx = freerdp_client_context_new(&clientEntryPoints);

    if (!ctx)
        return 0;

    return (int64_t)(uintptr_t)ctx->instance;
}

void freerdp_harmonyos_free(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    LOGI("freerdp_harmonyos_free: instance=%p", (void*)inst);

    if (!inst) {
        return;
    }

    /* 置空全局缓冲区关联 */
    {
        std::lock_guard<std::mutex> lock(g_external_buffer_mutex);
        g_external_buffer = nullptr;
        g_external_buffer_size = 0;
    }

    if (inst->context) {
        harmonyosContext* ctx = (harmonyosContext*)inst->context;

        /*
         * 断开闪退修复：freerdp_client_context_free 之前必须等待客户端线程退出，
         * 否则线程 teardown（freerdp_disconnect / 通道释放 / rdpsnd 关闭）会与
         * context 释放产生 use-after-free。正常流程中 ArkTS 层在 onDisconnected
         * 回调后才调用 free，线程此刻基本已退出，此等待只是兜底（超时 3 秒）。
         */
        if (ctx->thread) {
            freerdp_abort_connect_context(inst->context);
            DWORD waitResult = WaitForSingleObject(ctx->thread, 3000);
            if (waitResult != WAIT_OBJECT_0) {
                LOGE("freerdp_harmonyos_free: client thread not exited in time (0x%08X)", waitResult);
            }
            CloseHandle(ctx->thread);
            ctx->thread = NULL;
        }
    }

    {
        std::lock_guard<std::mutex> lock(g_nativeWindow_mutex);
        g_activeContext = nullptr;
    }

    /* [闪退修复] 若释放的实例拥有 disp 通道上下文，同步清理防止悬空 */
    if (g_dispOwner == inst) {
        g_dispContext = NULL;
        g_dispOwner = NULL;
    }

    if (inst->context) {
        LOGI("freerdp_harmonyos_free: freeing client context and instance");
        /* 
         * CRITICAL: 在 FreeRDP 中，freerdp_client_context_free 
         * 会释放 context 及其关联的 instance (如果它是所有者)。
         */
        freerdp_client_context_free(inst->context);
    } else {
        LOGI("freerdp_harmonyos_free: freeing instance only");
        freerdp_free(inst);
    }
}

bool freerdp_harmonyos_parse_arguments(int64_t instance, const char** args, int argc) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    DWORD status;

    LOGI("parse_arguments: ENTER instance=0x%llx argc=%d", (unsigned long long)instance, argc);

    if (!inst) {
        LOGE("parse_arguments: inst is NULL");
        return false;
    }
    
    LOGI("parse_arguments: inst=%p", (void*)inst);
    
    if (!inst->context) {
        LOGE("parse_arguments: context is NULL");
        return false;
    }
    
    LOGI("parse_arguments: context=%p", (void*)inst->context);
    
    if (!inst->context->settings) {
        LOGE("parse_arguments: Settings is NULL");
        return false;
    }
    
    LOGI("parse_arguments: settings=%p - All checks passed!", (void*)inst->context->settings);

    char** argv = (char**)malloc(argc * sizeof(char*));
    if (!argv) {
        LOGE("parse_arguments: Failed to allocate argv");
        return false;
    }
    
    LOGI("parse_arguments: argv allocated, copying args...");

    for (int i = 0; i < argc; i++) {
        argv[i] = strdup(args[i]);
        if (argv[i]) {
            /* 不打印密码 */
            if (strncmp(argv[i], "/p:", 3) == 0) {
                LOGI("parse_arguments: argv[%d]=/p:****", i);
            } else {
                LOGI("parse_arguments: argv[%d]=%s", i, argv[i]);
            }
        } else {
            LOGE("parse_arguments: strdup failed for arg %d", i);
        }
    }

    /* 
     * 设置默认配置以增强稳定性
     */
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_RemoteConsoleAudio, FALSE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_AudioPlayback, TRUE);
    /*
     * 断开闪退修复：启用同步静态/动态通道处理。
     * rdpsnd 默认启用 async（rdpsnd_main.c 中 async=TRUE 会创建 play_thread），
     * 断开时主线程 teardown 与 play_thread 处理音频 PDU 存在竞态。
     * 同步处理后 rdpsnd 在主线程内联执行，消除该竞态。
     */
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_SynchronousStaticChannels, TRUE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_SynchronousDynamicChannels, TRUE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_CompressionEnabled, TRUE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_FastPathOutput, TRUE);
    
    /* 
     * 针对连接 0x0002000D 错误的修复：
     * 1. 默认启用多种安全协议协商 (RDP + TLS + NLA)，以提高服务器兼容性。
     * 2. 显式启用各种安全层。
     * 3. 忽略证书验证错误，防止因 UI 缺失导致的验证失败或崩溃。
     */
    freerdp_settings_set_uint32(inst->context->settings, FreeRDP_RequestedProtocols, 
                                0x00000001 | 0x00000002 | 0x00000004);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_NlaSecurity, TRUE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_RdpSecurity, TRUE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_IgnoreCertificate, TRUE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_NegotiateSecurityLayer, TRUE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_SupportStatusInfoPdu, TRUE);
    
    /* 额外的稳定连接设置 */
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_SupportMonitorLayoutPdu, FALSE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(inst->context->settings, FreeRDP_SupportDynamicChannels, TRUE);
    freerdp_settings_set_string(inst->context->settings, FreeRDP_ConfigPath, ".");
    
    LOGI("parse_arguments: Security protocols set - RDP|TLS|NLA, IgnoreCertificate=TRUE");
    
    LOGI("parse_arguments: Calling freerdp_client_settings_parse_command_line...");
    status = freerdp_client_settings_parse_command_line(inst->context->settings, argc, argv, FALSE);
    LOGI("parse_arguments: freerdp_client_settings_parse_command_line returned %u", (unsigned int)status);

    for (int i = 0; i < argc; i++)
        free(argv[i]);
    free(argv);

    return (status == 0);
}

bool freerdp_harmonyos_connect(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    harmonyosContext* ctx;

    if (!inst || !inst->context) {
        LOGE("Invalid instance");
        return false;
    }

    ctx = (harmonyosContext*)inst->context;

    if (!(ctx->thread = CreateThread(NULL, 0, harmonyos_thread_func, inst, 0, NULL))) {
        return false;
    }

    return true;
}

bool freerdp_harmonyos_disconnect(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    HARMONYOS_EVENT* event;

    if (!inst || !inst->context) {
        LOGE("Invalid instance");
        return false;
    }

    event = (HARMONYOS_EVENT*)harmonyos_event_disconnect_new();

    if (!event)
        return false;

    if (!harmonyos_push_event(inst, event)) {
        harmonyos_event_free(event);
        return false;
    }

    if (!freerdp_abort_connect_context(inst->context))
        return false;

    return true;
}

bool freerdp_harmonyos_update_graphics(int64_t instance, uint8_t* buffer, int x, int y, int width, int height) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    rdpGdi* gdi;

    if (!inst || !inst->context)
        return false;

    gdi = inst->context->gdi;
    if (!gdi || !gdi->primary_buffer)
        return false;

    // Copy from GDI buffer to output buffer
    UINT32 DstFormat = PIXEL_FORMAT_RGBX32;
    return freerdp_image_copy(buffer, DstFormat, width * 4, 0, 0, width, height,
                              gdi->primary_buffer, gdi->dstFormat, gdi->stride, x, y,
                              &gdi->palette, FREERDP_FLIP_NONE);
}

bool freerdp_harmonyos_send_cursor_event(int64_t instance, int x, int y, int flags) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    HARMONYOS_EVENT* event;

    if (!inst || !inst->context) {
        LOGE("Invalid instance");
        return false;
    }

    event = (HARMONYOS_EVENT*)harmonyos_event_cursor_new(flags, x, y);
    if (!event)
        return false;

    if (!harmonyos_push_event(inst, event)) {
        harmonyos_event_free(event);
        return false;
    }

    return true;
}

bool freerdp_harmonyos_send_key_event(int64_t instance, int keycode, bool down) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    HARMONYOS_EVENT* event;
    DWORD scancode;

    if (!inst)
        return false;

    scancode = GetVirtualScanCodeFromVirtualKeyCode(keycode, 4);
    int flags = down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    flags |= (scancode & KBDEXT) ? KBD_FLAGS_EXTENDED : 0;

    event = (HARMONYOS_EVENT*)harmonyos_event_key_new(flags, scancode & 0xFF);
    if (!event)
        return false;

    if (!harmonyos_push_event(inst, event)) {
        harmonyos_event_free(event);
        return false;
    }

    return true;
}

bool freerdp_harmonyos_send_unicodekey_event(int64_t instance, int keycode, bool down) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    HARMONYOS_EVENT* event;

    if (!inst)
        return false;

    UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;
    event = (HARMONYOS_EVENT*)harmonyos_event_unicodekey_new(flags, keycode);

    if (!event)
        return false;

    if (!harmonyos_push_event(inst, event)) {
        harmonyos_event_free(event);
        return false;
    }

    return true;
}

bool freerdp_harmonyos_set_tcp_keepalive(int64_t instance, bool enabled, int delay, int interval, int retries) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;

    if (!inst || !inst->context) {
        LOGE("freerdp_set_tcp_keepalive: Invalid instance");
        return false;
    }

    rdpSettings* settings = inst->context->settings;
    if (!settings) {
        LOGE("freerdp_set_tcp_keepalive: Invalid settings");
        return false;
    }

    if (!freerdp_settings_set_bool(settings, FreeRDP_TcpKeepAlive, enabled ? TRUE : FALSE)) {
        LOGW("Failed to set TcpKeepAlive=%d (possibly unsupported by this build)", enabled);
        /* 不返回 false，因为这不一定是致命错误 */
    }

    if (enabled) {
        freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveDelay, (UINT32)delay);
        freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveInterval, (UINT32)interval);
        freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveRetries, (UINT32)retries);
        LOGI("TCP Keepalive configured: delay=%ds, interval=%ds, retries=%d", delay, interval, retries);
    }

    return true;
}

bool freerdp_harmonyos_send_synchronize_event(int64_t instance, int flags) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;

    if (!inst || !inst->context) {
        LOGE("freerdp_send_synchronize_event: Invalid instance");
        return false;
    }

    rdpInput* input = inst->context->input;
    if (!input) {
        LOGE("freerdp_send_synchronize_event: Invalid input");
        return false;
    }

    return freerdp_input_send_synchronize_event(input, (UINT32)flags);
}

bool freerdp_harmonyos_send_clipboard_data(int64_t instance, const char* data) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    HARMONYOS_EVENT* event;

    if (!inst)
        return false;

    size_t length = data ? strlen(data) : 0;
    event = (HARMONYOS_EVENT*)harmonyos_event_clipboard_new(data, length);

    if (!event)
        return false;

    if (!harmonyos_push_event(inst, event)) {
        harmonyos_event_free(event);
        return false;
    }

    return true;
}

int freerdp_harmonyos_set_client_decoding(int64_t instance, bool enable) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;

    if (!inst || !inst->context)
        return -1;

    rdpContext* context = inst->context;
    
    /* 
     * 关键安全检查：必须检查连接是否已经建立。
     * 1. 检查 GDI 是否初始化（只有在 post_connect 后才会初始化）
     * 2. 检查是否正在断开
     */
    rdpGdi* gdi = context->gdi;
    if (!gdi || !gdi->primary) {
        LOGW("set_client_decoding: GDI not initialized, connection not established yet");
        return -8;
    }
    
    if (freerdp_shall_disconnect_context(context)) {
        LOGW("set_client_decoding: session disconnecting, skipping PDU");
        return -9;
    }

    rdpSettings* settings = context->settings;
    if (!settings)
        return -2;

    rdpUpdate* update = context->update;
    if (!update)
        return -3;

    /* 
     * FreeRDP 3.x 核心库中可能没有 FreeRDP_DeactivateClientDecoding 这个自定义键。
     * 我们改用标准键 FreeRDP_SuppressOutput。
     */
    BOOL suppress = enable ? FALSE : TRUE;
    freerdp_settings_set_bool(settings, FreeRDP_SuppressOutput, suppress);

    BOOL allowDisplayUpdates = enable ? TRUE : FALSE;
    
    RECTANGLE_16 rect = { 0, 0, 0, 0 };
    rect.left = 0;
    rect.top = 0;
    rect.right = (UINT16)freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    rect.bottom = (UINT16)freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);

    if (update->SuppressOutput) {
        if (!update->SuppressOutput(context, allowDisplayUpdates, &rect)) {
            LOGE("SuppressOutput PDU failed");
            return -6;
        }
        
        LOGI("Client decoding %s, SuppressOutput sent (allowDisplayUpdates=%d)",
             enable ? "enabled" : "disabled", allowDisplayUpdates);
        return 0;
    } else {
        LOGW("SuppressOutput callback not available");
        return -7;
    }
}

const char* freerdp_harmonyos_get_last_error_string(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;

    if (!inst || !inst->context)
        return "";

    return freerdp_get_last_error_string(freerdp_get_last_error(inst->context));
}

const char* freerdp_harmonyos_get_version(void) {
    return freerdp_get_version_string();
}

bool freerdp_harmonyos_has_h264(void) {
    H264_CONTEXT* ctx = h264_context_new(FALSE);
    if (!ctx)
        return false;
    h264_context_free(ctx);
    return true;
}

bool freerdp_harmonyos_is_connected(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context)
        return false;
    
    /* FreeRDP 3.x doesn't have freerdp_is_connected, check via shall_disconnect */
    return !freerdp_shall_disconnect_context(inst->context);
}

/* ==================== Background Mode & Audio Priority ==================== */

bool freerdp_harmonyos_enter_background_mode(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context) {
        LOGE("enter_background_mode: Invalid instance");
        return false;
    }
    
    rdpContext* context = inst->context;
    rdpSettings* settings = context->settings;
    rdpUpdate* update = context->update;
    
    if (!settings || !update) {
        LOGE("enter_background_mode: Invalid settings or update");
        return false;
    }
    
    LOGI("Entering background mode - audio only");
    
    /* Set background mode flag for run loop */
    g_isInBackgroundMode = TRUE;
    
    /* Disable graphics decoding to save CPU/bandwidth */
    freerdp_settings_set_bool(settings, FreeRDP_DeactivateClientDecoding, TRUE);
    
    /* Send SuppressOutput PDU to tell server to stop sending graphics */
    RECTANGLE_16 rect = { 0, 0, 0, 0 };
    rect.left = 0;
    rect.top = 0;
    rect.right = (UINT16)freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    rect.bottom = (UINT16)freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    
    if (update->SuppressOutput) {
        /* FALSE = suppress display updates (only audio continues) */
        if (!update->SuppressOutput(context, FALSE, &rect)) {
            LOGW("SuppressOutput PDU failed, but continuing");
        }
    }
    
    LOGI("Background mode active - graphics suppressed, audio continues, keepalive enabled");
    return true;
}

bool freerdp_harmonyos_exit_background_mode(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context) {
        LOGE("exit_background_mode: Invalid instance");
        return false;
    }
    
    rdpContext* context = inst->context;
    rdpSettings* settings = context->settings;
    rdpUpdate* update = context->update;
    
    if (!settings || !update) {
        LOGE("exit_background_mode: Invalid settings or update");
        return false;
    }
    
    LOGI("Exiting background mode - resuming graphics with full refresh");
    
    /* Clear background mode flag FIRST */
    g_isInBackgroundMode = FALSE;
    
    /* Re-enable graphics decoding */
    freerdp_settings_set_bool(settings, FreeRDP_DeactivateClientDecoding, FALSE);
    
    /* Get full screen dimensions */
    UINT32 width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    UINT32 height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    
    RECTANGLE_16 rect = { 0, 0, 0, 0 };
    rect.left = 0;
    rect.top = 0;
    rect.right = (UINT16)width;
    rect.bottom = (UINT16)height;
    
    /* Step 1: Send SuppressOutput PDU to tell server to resume graphics */
    if (update->SuppressOutput) {
        /* TRUE = allow display updates */
        if (!update->SuppressOutput(context, TRUE, &rect)) {
            LOGW("SuppressOutput resume PDU failed");
        }
    }
    
    /* Step 2: Request full screen refresh using RefreshRect PDU */
    if (update->RefreshRect) {
        /* RefreshRect tells the server to re-send the specified area */
        if (!update->RefreshRect(context, 1, &rect)) {
            LOGW("RefreshRect PDU failed");
        } else {
            LOGI("RefreshRect sent for full screen (%ux%u)", width, height);
        }
    } else {
        LOGW("RefreshRect callback not available");
    }
    
    /* Step 3: Mark entire GDI surface as invalid to force redraw */
    rdpGdi* gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd) {
        HGDI_WND hwnd = gdi->primary->hdc->hwnd;
        
        /* Create a full-screen invalid region */
        GDI_RGN invalidRegion;
        invalidRegion.x = 0;
        invalidRegion.y = 0;
        invalidRegion.w = (INT32)width;
        invalidRegion.h = (INT32)height;
        
        /* Add to invalid regions - this will trigger redraw on next update cycle */
        if (hwnd->invalid) {
            hwnd->invalid->null = FALSE;
            hwnd->invalid->x = 0;
            hwnd->invalid->y = 0;
            hwnd->invalid->w = (INT32)width;
            hwnd->invalid->h = (INT32)height;
        }
        
        /* Also expand cinvalid array if needed */
        if (hwnd->cinvalid && hwnd->count > 0) {
            hwnd->cinvalid[0] = invalidRegion;
            hwnd->ninvalid = 1;
        }
        
        LOGI("GDI surface marked as invalid for full redraw");
    }
    
    /* Step 4: Notify application that graphics update is coming */
    if (g_onGraphicsUpdate) {
        /* Trigger an immediate update callback for the full screen */
        g_onGraphicsUpdate((int64_t)(uintptr_t)inst, 0, 0, (int)width, (int)height);
        LOGI("Graphics update callback triggered");
    }
    
    LOGI("Background mode exited - full screen refresh requested");
    return true;
}

bool freerdp_harmonyos_configure_audio(int64_t instance, bool playback, bool capture, int quality) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context) {
        LOGE("configure_audio: Invalid instance");
        return false;
    }
    
    rdpSettings* settings = inst->context->settings;
    if (!settings) {
        LOGE("configure_audio: Invalid settings");
        return false;
    }
    
    /* Enable audio playback */
    if (playback) {
        freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, TRUE);
        LOGI("Audio playback enabled");
    }
    
    /* Enable audio capture (microphone) */
    if (capture) {
        freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, TRUE);
        LOGI("Audio capture enabled");
    }
    
    /* Set quality based on connection type */
    switch (quality) {
        case 0: /* Dynamic */
            freerdp_settings_set_uint32(settings, FreeRDP_ConnectionType, CONNECTION_TYPE_AUTODETECT);
            LOGI("Audio quality: Dynamic");
            break;
        case 1: /* Medium */
            freerdp_settings_set_uint32(settings, FreeRDP_ConnectionType, CONNECTION_TYPE_BROADBAND_LOW);
            LOGI("Audio quality: Medium");
            break;
        case 2: /* High */
            freerdp_settings_set_uint32(settings, FreeRDP_ConnectionType, CONNECTION_TYPE_LAN);
            LOGI("Audio quality: High");
            break;
        default:
            LOGW("Unknown audio quality mode: %d", quality);
            break;
    }
    
    return true;
}

bool freerdp_harmonyos_set_auto_reconnect(int64_t instance, bool enabled, int maxRetries, int delayMs) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context) {
        LOGE("set_auto_reconnect: Invalid instance");
        return false;
    }
    
    rdpSettings* settings = inst->context->settings;
    if (!settings) {
        LOGE("set_auto_reconnect: Invalid settings");
        return false;
    }
    
    /* Configure FreeRDP auto-reconnect settings */
    freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, enabled);
    
    if (enabled && maxRetries > 0) {
        freerdp_settings_set_uint32(settings, FreeRDP_AutoReconnectMaxRetries, (UINT32)maxRetries);
        LOGI("Auto-reconnect enabled: maxRetries=%d, delayMs=%d", maxRetries, delayMs);
    } else {
        LOGI("Auto-reconnect disabled");
    }
    
    return true;
}

/* Get connection health status */
int freerdp_harmonyos_get_connection_health(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context)
        return -1; /* Invalid */
    
    if (freerdp_shall_disconnect_context(inst->context))
        return 0; /* Disconnected */
    
    /* Check if we can get event handles - indicates healthy connection */
    HANDLE handles[8];
    DWORD count = freerdp_get_event_handles(inst->context, handles, 8);
    
    if (count == 0)
        return 1; /* Connected but degraded */
    
    return 2; /* Healthy */
}

/* Force immediate full screen refresh - use after unlock/foreground */
bool freerdp_harmonyos_request_refresh(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context) {
        LOGE("request_refresh: Invalid instance");
        return false;
    }
    
    rdpContext* context = inst->context;
    rdpSettings* settings = context->settings;
    rdpUpdate* update = context->update;
    
    if (!settings || !update) {
        LOGE("request_refresh: Invalid settings or update");
        return false;
    }
    
    /* Get screen dimensions */
    UINT32 width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    UINT32 height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    
    LOGI("Requesting full screen refresh (%ux%u)", width, height);
    
    RECTANGLE_16 rect = { 0, 0, 0, 0 };
    rect.left = 0;
    rect.top = 0;
    rect.right = (UINT16)width;
    rect.bottom = (UINT16)height;
    
    bool success = true;
    
    /* Method 1: RefreshRect PDU - asks server to re-send the area */
    if (update->RefreshRect) {
        if (!update->RefreshRect(context, 1, &rect)) {
            LOGW("RefreshRect PDU failed");
            success = false;
        } else {
            LOGI("RefreshRect PDU sent");
        }
    }
    
    /* Method 2: Mark GDI as invalid */
    rdpGdi* gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd) {
        HGDI_WND hwnd = gdi->primary->hdc->hwnd;
        
        if (hwnd->invalid) {
            hwnd->invalid->null = FALSE;
            hwnd->invalid->x = 0;
            hwnd->invalid->y = 0;
            hwnd->invalid->w = (INT32)width;
            hwnd->invalid->h = (INT32)height;
            LOGI("GDI invalid region set");
        }
    }
    
    /* Method 3: Trigger immediate callback with current buffer */
    if (g_onGraphicsUpdate) {
        g_onGraphicsUpdate((int64_t)(uintptr_t)inst, 0, 0, (int)width, (int)height);
        LOGI("Graphics update callback triggered");
    }
    
    return success;
}

/* Request partial screen refresh for specific area */
bool freerdp_harmonyos_request_refresh_rect(int64_t instance, int x, int y, int width, int height) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context) {
        LOGE("request_refresh_rect: Invalid instance");
        return false;
    }
    
    rdpContext* context = inst->context;
    rdpUpdate* update = context->update;
    
    if (!update) {
        LOGE("request_refresh_rect: Invalid update");
        return false;
    }
    
    RECTANGLE_16 rect = { 0, 0, 0, 0 };
    rect.left = (UINT16)x;
    rect.top = (UINT16)y;
    rect.right = (UINT16)(x + width);
    rect.bottom = (UINT16)(y + height);
    
    if (update->RefreshRect) {
        if (!update->RefreshRect(context, 1, &rect)) {
            LOGW("RefreshRect PDU failed for rect (%d,%d,%d,%d)", x, y, width, height);
            return false;
        }
        LOGI("RefreshRect sent for (%d,%d,%d,%d)", x, y, width, height);
    }
    
    return true;
}

/* Get the current frame buffer for immediate display */
bool freerdp_harmonyos_get_frame_buffer(int64_t instance, uint8_t** buffer, 
                                         int* width, int* height, int* stride) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context) {
        LOGE("get_frame_buffer: Invalid instance");
        return false;
    }
    
    rdpContext* context = inst->context;
    rdpGdi* gdi = context->gdi;
    
    if (!gdi || !gdi->primary) {
        LOGE("get_frame_buffer: GDI not initialized");
        return false;
    }
    
    /* 使用 gdi 直接获取尺寸，避免 HGDI_BITMAP/rdpBitmap 类型不匹配 */
    if (buffer) *buffer = gdi->primary_buffer;
    if (width) *width = (int)gdi->width;
    if (height) *height = (int)gdi->height;
    if (stride) *stride = (int)gdi->stride;
    
    return true;
}

/* Check if currently in background mode */
bool freerdp_harmonyos_is_in_background_mode(int64_t instance) {
    WINPR_UNUSED(instance);
    return g_isInBackgroundMode ? true : false;
}

/* Send a keepalive/heartbeat to maintain connection in background */
bool freerdp_harmonyos_send_keepalive(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context) {
        LOGE("send_keepalive: Invalid instance");
        return false;
    }
    
    rdpContext* context = inst->context;
    rdpInput* input = context->input;
    
    if (!input) {
        LOGE("send_keepalive: Invalid input");
        return false;
    }
    
    /* Send a synchronize event as heartbeat - this doesn't affect the session */
    if (!freerdp_input_send_synchronize_event(input, 0)) {
        LOGW("Keepalive synchronize event failed");
        return false;
    }
    
    update_network_activity();
    LOGD("Keepalive sent");
    return true;
}

/* Get time since last network activity in milliseconds */
uint64_t freerdp_harmonyos_get_idle_time(int64_t instance) {
    WINPR_UNUSED(instance);
    
    if (g_lastNetworkActivityTime == 0)
        return 0;
    
    return GetTickCount64() - g_lastNetworkActivityTime;
}

/* Force check connection health and return detailed status */
int freerdp_harmonyos_check_connection_status(int64_t instance) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;
    
    if (!inst || !inst->context)
        return -1; /* Invalid instance */
    
    rdpContext* context = inst->context;
    
    /* Check if disconnect was requested */
    if (freerdp_shall_disconnect_context(context))
        return 0; /* Disconnecting */
    
    /* Check network activity */
    if (!is_network_alive())
        return 1; /* Network timeout */
    
    /* Check if we can get event handles */
    HANDLE handles[8];
    DWORD count = freerdp_get_event_handles(context, handles, 8);
    
    if (count == 0)
        return 2; /* Event handles failed */
    
    /* Check if in background mode */
    if (g_isInBackgroundMode)
        return 10; /* Connected, background mode */
    
    return 100; /* Connected, foreground mode */
}

/* ==================== Frame Snapshot API ==================== */

bool freerdp_harmonyos_get_frame_snapshot_info(int* width, int* height, int* stride) {
    if (!width || !height || !stride) {
        LOGE("get_frame_snapshot_info: null output pointer");
        return false;
    }

    std::lock_guard<std::mutex> lock(g_external_buffer_mutex);
    if (!g_external_buffer || g_external_buffer_size == 0) {
        LOGW("get_frame_snapshot_info: no external buffer available");
        *width = 0;
        *height = 0;
        *stride = 0;
        return false;
    }

    /* Find the active instance to get GDI dimensions.
     * We scan contexts that have a valid GDI with primary_buffer == g_external_buffer.
     * Since this is a single-session app, the first valid GDI wins. */
    freerdp* inst = nullptr;
    /* Use the global client context list - iterate through known instances.
     * For single-session, we rely on the fact that update_graphics_buffer
     * stores the GDI primary buffer pointer. We need to find the instance
     * that owns this buffer. */
    /* Since we don't have a global instance registry, we reconstruct dims
     * from buffer size assuming standard 4-byte pixel format. However,
     * we cannot determine width/height from size alone without the instance.
     * Instead, we use a different approach: store GDI info alongside the buffer. */

    /* We need to track the instance that set the external buffer.
     * For now, return false to indicate snapshot not available via this path.
     * The NAPI layer should use freerdp_harmonyos_get_frame_buffer(instance, ...)
     * instead, which has direct access to the GDI. */
    *width = 0;
    *height = 0;
    *stride = 0;
    LOGW("get_frame_snapshot_info: use get_frame_buffer(instance, ...) instead");
    return false;
}

bool freerdp_harmonyos_copy_frame_snapshot(uint8_t* buffer, size_t buffer_size) {
    if (!buffer || buffer_size == 0) {
        LOGE("copy_frame_snapshot: invalid buffer");
        return false;
    }

    std::lock_guard<std::mutex> lock(g_external_buffer_mutex);
    if (!g_external_buffer || g_external_buffer_size == 0) {
        LOGW("copy_frame_snapshot: no external buffer available");
        return false;
    }

    size_t copySize = buffer_size < g_external_buffer_size ? buffer_size : g_external_buffer_size;
    memcpy(buffer, g_external_buffer, copySize);
    return true;
}

bool freerdp_harmonyos_set_surface_id(uint64_t surface_id) {
    std::lock_guard<std::mutex> lock(g_nativeWindow_mutex);
    
    LOGI("set_surface_id: creating NativeWindow from surface_id=%llu",
         (unsigned long long)surface_id);
    
    if (surface_id == 0) {
        LOGE("set_surface_id: invalid surface_id=0");
        return false;
    }
    
    if (g_nativeWindow) {
        LOGW("set_surface_id: releasing previous NativeWindow");
        freerdp_harmonyos_release_surface_unlocked();
    }
    
    int32_t ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surface_id, &g_nativeWindow);
    if (ret != 0 || !g_nativeWindow) {
        LOGE("set_surface_id: OH_NativeWindow_CreateNativeWindowFromSurfaceId failed, ret=%d", ret);
        g_nativeWindow = nullptr;
        return false;
    }
    
    LOGI("set_surface_id: NativeWindow created successfully, window=%p", (void*)g_nativeWindow);
    return true;
}

void freerdp_harmonyos_release_surface_unlocked(void) {
    g_activeContext = nullptr;

    if (g_mappedAddr && g_mappedSize > 0) {
        munmap(g_mappedAddr, g_mappedSize);
        g_mappedAddr = nullptr;
        g_mappedSize = 0;
    }
    
    if (g_nativeWindow) {
        OH_NativeWindow_DestroyNativeWindow(g_nativeWindow);
        g_nativeWindow = nullptr;
        LOGI("release_surface: NativeWindow destroyed");
    }
}

void freerdp_harmonyos_release_surface(void) {
    std::lock_guard<std::mutex> lock(g_nativeWindow_mutex);
    freerdp_harmonyos_release_surface_unlocked();
}

void freerdp_harmonyos_set_viewport(float scale, float offsetX, float offsetY) {
    std::lock_guard<std::mutex> lock(g_nativeWindow_mutex);
    g_viewportScale = scale;
    g_viewportOffsetX = offsetX;
    g_viewportOffsetY = offsetY;

    if (g_nativeWindow && g_activeContext) {
        freerdp_harmonyos_render_to_surface_unlocked(g_activeContext);
    }
}

bool freerdp_harmonyos_set_display_mode(int mode) {
    if (mode != HARMONYOS_DISPLAY_MODE_FIT && mode != HARMONYOS_DISPLAY_MODE_FILL) {
        LOGE("set_display_mode: invalid mode=%d", mode);
        return false;
    }

    std::lock_guard<std::mutex> lock(g_nativeWindow_mutex);
    if (g_displayMode == mode) {
        return true;
    }
    g_displayMode = mode;
    LOGI("set_display_mode: mode=%d (%s)", mode,
         mode == HARMONYOS_DISPLAY_MODE_FILL ? "fill" : "fit");

    if (g_nativeWindow && g_activeContext) {
        freerdp_harmonyos_render_to_surface_unlocked(g_activeContext);
    }
    return true;
}

int freerdp_harmonyos_get_display_mode(void) {
    std::lock_guard<std::mutex> lock(g_nativeWindow_mutex);
    return g_displayMode;
}

/*
 * 通过 Display Control (disp) 动态通道请求服务器调整桌面分辨率（旋转/铺满模式跟随屏幕方向）。
 * 需连接时启用 /dynamic-resolution；服务器不支持时返回 false（业务层保持 letterbox 兜底）。
 */
bool freerdp_harmonyos_request_desktop_resize(int64_t instance, int width, int height) {
    freerdp* inst = (freerdp*)(uintptr_t)instance;

    if (!inst || !inst->context) {
        LOGE("request_desktop_resize: invalid instance");
        return false;
    }

    /* [闪退修复] 仅在连接活跃时发送：断开/释放过程中的迟到请求会触发服务器
     * ResetGraphics PDU 撞上本地 teardown（异步 drdynvc 线程场景即 UAF 崩溃）。 */
    if (!freerdp_is_active_state(inst->context)) {
        LOGW("request_desktop_resize: connection not active");
        return false;
    }

    /* [闪退修复] disp 上下文按实例归属校验，拒绝陈旧实例使用新实例的通道 */
    if (inst != g_dispOwner) {
        LOGW("request_desktop_resize: instance %p does not own disp context (owner=%p)",
             (void*)inst, (void*)g_dispOwner);
        return false;
    }

    if (!g_dispContext) {
        LOGW("request_desktop_resize: disp channel not available");
        return false;
    }

    if (width < DISPLAY_CONTROL_MIN_MONITOR_WIDTH || width > DISPLAY_CONTROL_MAX_MONITOR_WIDTH ||
        height < DISPLAY_CONTROL_MIN_MONITOR_HEIGHT || height > DISPLAY_CONTROL_MAX_MONITOR_HEIGHT) {
        LOGE("request_desktop_resize: size %dx%d out of range", width, height);
        return false;
    }

    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
    memset(&layout, 0, sizeof(layout));
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = (UINT32)width;
    layout.Height = (UINT32)height;

    UINT rc = g_dispContext->SendMonitorLayout(g_dispContext, 1, &layout);
    if (rc != CHANNEL_RC_OK) {
        LOGE("request_desktop_resize: SendMonitorLayout failed rc=%u", (unsigned)rc);
        return false;
    }

    LOGI("request_desktop_resize: requested %dx%d", width, height);
    return true;
}

/* ==================== NativeWindow Rendering ==================== */

static bool freerdp_harmonyos_render_to_surface(rdpContext* context, int x1, int y1, int width, int height) {
    (void)x1;
    (void)y1;
    (void)width;
    (void)height;
    std::lock_guard<std::mutex> lock(g_nativeWindow_mutex);
    return freerdp_harmonyos_render_to_surface_unlocked(context);
}

static bool freerdp_harmonyos_render_to_surface_unlocked(rdpContext* context) {
    if (!g_nativeWindow) {
        return false;
    }

    if (!context || !context->gdi || !context->gdi->primary || !context->gdi->primary_buffer) {
        return false;
    }

    rdpGdi* gdi = context->gdi;
    int desktopWidth = (int)gdi->width;
    int desktopHeight = (int)gdi->height;
    int srcStride = (int)gdi->stride;
    uint8_t* srcBuffer = gdi->primary_buffer;

    if (desktopWidth <= 0 || desktopHeight <= 0 || srcStride <= 0) {
        return false;
    }

    int releaseFenceFd = -1;
    OHNativeWindowBuffer* nativeWindowBuffer = nullptr;
    int32_t ret = OH_NativeWindow_NativeWindowRequestBuffer(g_nativeWindow, &nativeWindowBuffer, &releaseFenceFd);
    if (ret != 0 || !nativeWindowBuffer) {
        return false;
    }

    BufferHandle* bufferHandle = OH_NativeWindow_GetBufferHandleFromNative(nativeWindowBuffer);
    if (!bufferHandle || bufferHandle->width <= 0 || bufferHandle->height <= 0) {
        OH_NativeWindow_NativeWindowAbortBuffer(g_nativeWindow, nativeWindowBuffer);
        return false;
    }

    if (releaseFenceFd != -1) {
        struct pollfd pollfds = {};
        pollfds.fd = releaseFenceFd;
        pollfds.events = POLLIN;
        int retCode = -1;
        do {
            retCode = poll(&pollfds, 1, 1000);
        } while (retCode == -1 && (errno == EINTR || errno == EAGAIN));
        close(releaseFenceFd);
    }

    void* mappedAddr = mmap(nullptr, bufferHandle->size, PROT_READ | PROT_WRITE, MAP_SHARED, bufferHandle->fd, 0);
    if (mappedAddr == MAP_FAILED) {
        OH_NativeWindow_NativeWindowAbortBuffer(g_nativeWindow, nativeWindowBuffer);
        return false;
    }

    auto* dst = static_cast<uint8_t*>(mappedAddr);
    int bufWidth = bufferHandle->width;
    int bufHeight = bufferHandle->height;
    int dstStride = bufferHandle->stride;

    /*
     * Uniform aspect-preserving transform (scale + top-left offset) from the
     * business layer. FILL ("fullscreen") requests a desktop sized to the
     * physical screen at connect time (/f + /size:<screen>), so uniform
     * scaling maps it 1:1 onto the surface without distortion; FIT letterboxes
     * the bookmarked desktop size. No per-axis stretching in either mode.
     */
    float scaleX = g_viewportScale;
    if (scaleX < 0.01f)
    {
        scaleX = 0.01f;
    }
    float scaleY = scaleX;
    float offsetX = g_viewportOffsetX;
    float offsetY = g_viewportOffsetY;

    /* Draw order: fill the whole canvas black first (letterbox bars). */
    memset(dst, 0, (size_t)dstStride * (size_t)bufHeight);

    /* Then draw the scaled & offset RDP image (nearest-neighbour). */
    for (int row = 0; row < bufHeight; row++) {
        float srcY = ((float)row - offsetY) / scaleY;
        if (srcY < 0.0f || srcY >= (float)desktopHeight) {
            continue;
        }
        int srcRow = (int)srcY;
        const uint8_t* srcRowPtr = srcBuffer + (size_t)srcRow * (size_t)srcStride;
        uint8_t* dstRow = dst + (size_t)row * (size_t)dstStride;

        for (int col = 0; col < bufWidth; col++) {
            float srcX = ((float)col - offsetX) / scaleX;
            if (srcX < 0.0f || srcX >= (float)desktopWidth) {
                continue;
            }
            int srcCol = (int)srcX;
            size_t srcOff = (size_t)srcCol * 4;
            size_t dstOff = (size_t)col * 4;
            dstRow[dstOff] = srcRowPtr[srcOff + 2];
            dstRow[dstOff + 1] = srcRowPtr[srcOff + 1];
            dstRow[dstOff + 2] = srcRowPtr[srcOff];
            dstRow[dstOff + 3] = 0xFF;
        }
    }

    munmap(mappedAddr, bufferHandle->size);

    Region region = {};
    Region::Rect* rects = new Region::Rect();
    rects->x = 0;
    rects->y = 0;
    rects->w = bufWidth;
    rects->h = bufHeight;
    region.rects = rects;
    region.rectNumber = 1;

    ret = OH_NativeWindow_NativeWindowFlushBuffer(g_nativeWindow, nativeWindowBuffer, -1, region);
    delete rects;

    if (ret != 0) {
        return false;
    }

    return true;
}
