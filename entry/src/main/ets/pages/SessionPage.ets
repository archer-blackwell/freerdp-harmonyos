/*
 * HarmonyOS FreeRDP Session Page
 * 
 * Remote desktop session view with full interaction support
 * 
 * Copyright 2026 FreeRDP HarmonyOS Port
 */

import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import window from '@ohos.window';
import display from '@ohos.display';
import common from '@ohos.app.ability.common';
import { Want } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import image from '@ohos.multimedia.image';
import { BookmarkBase } from '../model/BookmarkBase';
import { SessionState, ConnectionState, GlobalSessionManager } from '../model/SessionState';
  import LibFreeRDP, { EventListener, BookmarkSettings, ScreenSettings, AdvancedSettings, PerformanceFlags, DebugSettings, GatewaySettings, PTR_FLAGS_MOVE, PTR_FLAGS_DOWN, PTR_FLAGS_BUTTON1, PTR_FLAGS_BUTTON2, PTR_FLAGS_WHEEL, PTR_FLAGS_WHEEL_NEGATIVE, PTR_FLAGS_HWHEEL, DISPLAY_MODE_FIT, DISPLAY_MODE_FILL, CURSOR_TYPE_IBEAM } from '../services/LibFreeRDP';
import { RdpBackgroundService } from '../services/RdpBackgroundService';
import { NetworkManager, SessionInfo } from '../services/NetworkManager';
import { VirtualKeyboard } from '../components/VirtualKeyboard';

interface SessionPageParams {
  bookmark?: object;
  /** 显示模式：DISPLAY_MODE_FIT(0)=自适应居中，DISPLAY_MODE_FILL(1)=铺满整屏；缺省为铺满整屏 */
  displayMode?: number;
}

interface DesktopCoord {
  dx: number;
  dy: number;
}

interface DrawSize {
  width: number;
  height: number;
}

const TAG = 'SessionPage';

let globalOnPreConnectCallback: ((instance: number) => void) | null = null;
let globalOnConnectionSuccessCallback: ((instance: number) => void) | null = null;
let globalOnConnectionFailureCallback: ((instance: number) => void) | null = null;
let globalOnDisconnectingCallback: ((instance: number) => void) | null = null;
let globalOnDisconnectedCallback: ((instance: number) => void) | null = null;

class SessionEventListenerImpl implements EventListener {
  OnPreConnect(instance: number): void {
    if (globalOnPreConnectCallback) {
      globalOnPreConnectCallback(instance);
    }
  }

  OnConnectionSuccess(instance: number): void {
    if (globalOnConnectionSuccessCallback) {
      globalOnConnectionSuccessCallback(instance);
    }
  }

  OnConnectionFailure(instance: number): void {
    if (globalOnConnectionFailureCallback) {
      globalOnConnectionFailureCallback(instance);
    }
  }

  OnDisconnecting(instance: number): void {
    if (globalOnDisconnectingCallback) {
      globalOnDisconnectingCallback(instance);
    }
  }

  OnDisconnected(instance: number): void {
    if (globalOnDisconnectedCallback) {
      globalOnDisconnectedCallback(instance);
    }
  }

  OnGraphicsUpdate(instance: number, x: number, y: number, width: number, height: number): void {
    if (globalSessionPage) {
      globalSessionPage.onGraphicsUpdate(instance, x, y, width, height);
    }
  }
}
let globalSessionPage: SessionPage | null = null;

const HEARTBEAT_INTERVAL_MS = 30000;

@Entry
@Component
struct SessionPage {
  @State session: SessionState | null = null;
  @State connectionState: ConnectionState = ConnectionState.DISCONNECTED;
  @State statusMessage: string = '正在连接...';
  
  @State desktopWidth: number = 1920;
  @State desktopHeight: number = 1080;
  @State viewWidth: number = 0;
  @State viewHeight: number = 0;
  @State surfaceWidth: number = 0;
  @State surfaceHeight: number = 0;
  @State surfaceReady: boolean = false;
  /** 显示模式：FIT=自适应居中（黑边），FILL=铺满整屏；缺省铺满整屏，可由路由参数覆盖 */
  @State displayMode: number = DISPLAY_MODE_FILL;
  @State viewScale: number = 1.0;
  @State panX: number = 0;
  @State panY: number = 0;
  /** 当前是否横屏（windowSizeChange 自动同步，toggleFullScreen 也可主动切换） */
  @State isLandscape: boolean = false;
  /** 进入页面时的窗口方向（离开页面时恢复） */
  private savedIsLandscape: boolean = false;
  /** 本页面作用域内的 windowSizeChange 监听（销毁时只解除自己的） */
  private windowSizeChangeCallback: ((size: window.Size) => void) | null = null;

  @State showToolbar: boolean = true;
  @State showKeyboard: boolean = false;
  @State isInBackground: boolean = false;

  private backgroundService: RdpBackgroundService | null = null;
  private context = getContext(this) as common.UIAbilityContext;
  private xComponentController: XComponentController = new XComponentController();

  private heartbeatTimer: number = -1;
  private toolbarHideTimer: number = -1;
  private static readonly TOOLBAR_HIDE_DELAY = 4000;
  private static readonly MIN_SCALE = 0.3;
  private static readonly MAX_SCALE = 3.0;
  private static readonly ORIENT_BTN_W = 21;
  private static readonly ORIENT_BTN_H = 22;
  private static readonly ORIENT_BTN_MARGIN = 12;
  private density: number = 1.0;
  private lastPinchScale: number = 1.0;
  private lastPanX: number = 0;
  private lastPanY: number = 0;
  private isPinching: boolean = false;
  /** 待确认的桌面 resize 请求（服务器可能丢弃 Display Control 请求，需要看护重试） */
  private pendingResizeW: number = 0;
  private pendingResizeH: number = 0;
  private resizeRetryCount: number = 0;
  private resizeRetryTimer: number = -1;
  private static readonly RESIZE_RETRY_DELAY_MS = 1500;
  private static readonly RESIZE_MAX_RETRY = 3;

  /** [远端光标同步] 当前自定义光标位图；null/不可见时隐藏叠加层 */
  @State cursorPixelMap: image.PixelMap | null = null;
  @State cursorVisible: boolean = false;
  @State cursorW: number = 0;
  @State cursorH: number = 0;
  @State cursorViewX: number = 0;
  @State cursorViewY: number = 0;
  private cursorHotspotX: number = 0;
  private cursorHotspotY: number = 0;
  /** 最近一次触控位置（vp），光标叠加层跟随该点（远端光标实际位置由己方触控驱动） */
  private lastTouchX: number = -1;
  private lastTouchY: number = -1;

  /* ==================== [触控重设计] tap 判定状态机 ====================
   * 旧实现把 Down/Move/Up 原样实时转发：手指抖动 ≥5vp 触发本地 PanGesture 后
   * Up 被 isPanning 门禁吞掉（远端按键卡死）；且 tap 两次落点有自然抖动，
   * 超过服务端双击矩形（4 远程像素）导致双击失效。
   * 新方案：按下先挂起，超 slop 进入拖动、超时进入长按、抬起即合成点击；
   * 双击的两次点击强制同坐标，保证服务端双击判定稳定成立。 */
  private static readonly TAP_SLOP_VP = 8;
  private static readonly HOLD_DELAY_MS = 250;
  private static readonly DOUBLE_TAP_MS = 350;
  private static readonly DOUBLE_TAP_DIST_VP = 40;
  /** 双指右键判定窗口：两指须几乎同时落地；迟到的第二触点视为手掌误触忽略 */
  private static readonly TWO_FINGER_TAP_MS = 120;
  /** 双指 tap：从落地到抬起的判定窗口与容许位移（超出则视为 pan/pinch 前奏） */
  private static readonly TWO_FINGER_LIFT_MS = 300;
  private static readonly TWO_FINGER_TAP_SLOP_VP = 20;
  /** 单指滑动 → 远端滚轮：每 N vp 位移发送一档（120 = Windows 一格标准） */
  private static readonly SCROLL_WHEEL_STEP_VP = 20;
  private static readonly WHEEL_DELTA_UNITS = 120;
  private tapDownX: number = 0;
  private tapDownY: number = 0;
  /** 主触点 id：多指场景仅第一根手指驱动远端事件（-1 = 无触点） */
  private activeTouchId: number = -1;
  /** 主触点按下时刻：双指右键窗口的计时起点 */
  private primaryDownMs: number = 0;
  private tapPending: boolean = false;     // 按下后尚未判定（未过 slop、未过 hold 延时）
  private tapButtonSent: boolean = false;  // 本次手势已向远端发送按键按下
  private touchCancelled: boolean = false; // 多指/本地手势接管，本次手势不再产生点击
  private moveCount: number = 0;          // 本次手势已发送的 MOVE 数（诊断日志）
  /** 滚动模式：slop 外快速滑动（长按未触发）→ 累积位移转远端滚轮 */
  private scrolling: boolean = false;
  private scrollLastX: number = 0;
  private scrollLastY: number = 0;
  private wheelAccumX: number = 0;
  private wheelAccumY: number = 0;
  private scrollWheelCount: number = 0;   // 本次滚动已发送档数（诊断日志）
  /** 双指已同时落地：右键挂起，待抬起确认（pan/pinch 激活则放弃） */
  private twoFingerPending: boolean = false;
  private twoFingerDownMs: number = 0;
  private holdPressTimer: number = -1;
  private lastTapX: number = -1;
  private lastTapY: number = -1;
  private lastTapTime: number = 0;
  /** 最近一次 tap 合成时刻：事件驱动 IME 自动弹的判定窗口起点 */
  private lastTapEndMs: number = 0;

  /* ==================== [软键盘桥接] ====================
   * 隐藏 TextInput 获得焦点即拉起系统输入法；输入内容 diff 后按
   * Unicode 键事件转发远端（删除发退格）。远端文本框被点击后
   * Windows 把光标切换为 I-beam，以该信号自动弹/收输入法。 */
  private static readonly IME_CHECK_DELAY_MS = 350;
  /** tap 后光标变为 I-beam 的自动弹窗窗口：触屏无 hover，窗口内的形态变化必然由该 tap 触发 */
  private static readonly IME_AUTO_POP_WINDOW_MS = 2500;
  private static readonly IME_BRIDGE_MAX_LEN = 512;
  private static readonly VK_BACKSPACE = 0x08;
  private imeInputController: TextInputController = new TextInputController();
  private imeTrackedValue: string = '';      // 已同步到远端的桥接框内容
  private imeLastPreview: string = '';       // 最近一次组合态 preview 文本（组合链跟踪）
  private imeLastComposeValue: string = '';  // 最近一次组合态桥接框全文
  /** onWillDelete 否决删空后：若框架无视否决仍产生 onChange('')，跳过差分防双发 */
  private imeVetoExpectedEmpty: boolean = false;
  private imeVisible: boolean = false;       // keyboardHeightChange 同步
  private imeCheckTimer: number = -1;
  private remoteCursorType: number = 0;      // 最近一次远端光标类型（CURSOR_TYPE_*）
  private lastLoggedCursorType: number = -1; // 光标类型变化日志去重
  private keyboardHeightCallback: ((height: number) => void) | null = null;

  aboutToAppear(): void {
    console.info(`${TAG}: aboutToAppear`);
    globalSessionPage = this;
    
    const params = router.getParams() as SessionPageParams;

    // 业务层传递的显示模式：缺省铺满整屏（FILL），显式传 FIT 才用自适应。
    // 必须先于 initSession：连接参数（是否全屏、桌面分辨率）依赖当前模式
    const mode = (params && params.displayMode === DISPLAY_MODE_FIT) ?
      DISPLAY_MODE_FIT : DISPLAY_MODE_FILL;
    this.applyDisplayMode(mode);
    this.initOrientationState();

    // 监听 Native 上报的实际协商桌面分辨率（/size 请求值可能与服务器返回不一致）
    LibFreeRDP.setOnSettingsChanged((instance: number, width: number, height: number, bpp: number) => {
      if (!this.session || this.session.getInstance() !== instance) {
        return;
      }
      this.onNegotiatedSettings(width, height, bpp);
    });

    // 监听服务器动态 resize（Display Control）后的新桌面尺寸，与协商分辨率同一处理
    LibFreeRDP.setOnGraphicsResize((instance: number, width: number, height: number, bpp: number) => {
      if (!this.session || this.session.getInstance() !== instance) {
        return;
      }
      this.onNegotiatedSettings(width, height, bpp);
    });

    // 监听远端光标形态位图（含热点）；length == 0 时清除自定义光标叠加层
    LibFreeRDP.setOnCursorShapeChanged((instance: number, cursorType: number, width: number,
      height: number, hotspotX: number, hotspotY: number, rgba: ArrayBuffer, length: number) => {
      if (!this.session || this.session.getInstance() !== instance) {
        return;
      }
      // 记录光标类型：软键盘自动弹出/收起以 I-beam（文本区）为信号
      if (cursorType !== this.lastLoggedCursorType) {
        this.lastLoggedCursorType = cursorType;
        console.info(`${TAG}: remote cursor type -> ${cursorType}`);
      }
      this.remoteCursorType = cursorType;
      // 事件驱动自动弹：刚 tap 过且光标变为 I-beam，说明点中了远端文本框。
      // 覆盖 IBEAM 事件晚于 scheduleImeCheck 350ms 延时到达的情况。
      if (cursorType === CURSOR_TYPE_IBEAM && !this.imeVisible && this.lastTapEndMs > 0 &&
        Date.now() - this.lastTapEndMs < SessionPage.IME_AUTO_POP_WINDOW_MS) {
        console.info(`${TAG}: IBEAM after tap, auto show IME`);
        this.showIme();
      }
      this.onCursorShapeChanged(width, height, hotspotX, hotspotY, rgba, length);
    });

    // 监听远端通过重定向磁盘打开文件（如资源管理器双击）
    LibFreeRDP.setOnFileOpen((instance: number, fullPath: string, filename: string) => {
      if (!this.session || this.session.getInstance() !== instance) {
        return;
      }
      this.onRemoteFileOpen(fullPath, filename);
    });

    if (params && params.bookmark) {
      const bookmark = BookmarkBase.fromJson(params.bookmark);
      this.initSession(bookmark);
    } else {
      console.error(`${TAG}: No bookmark provided`);
      this.statusMessage = '错误：未提供连接信息';
    }
    
    NetworkManager.initialize();
    NetworkManager.setOnNetworkLostCallback(() => {
      this.onNetworkLost();
    });
    NetworkManager.setOnReconnectSuccessCallback(() => {
      this.onReconnectSuccess();
    });
    
    this.setKeepScreenOn(true);
  }

  aboutToDisappear(): void {
    console.info(`${TAG}: aboutToDisappear`);
    this.cleanup();
    this.teardownOrientation();
    LibFreeRDP.clearOnSettingsChanged();
    LibFreeRDP.clearOnGraphicsResize();
    LibFreeRDP.clearOnCursorShapeChanged();
    LibFreeRDP.clearOnFileOpen();
    if (this.cursorPixelMap) {
      this.cursorPixelMap.release();
      this.cursorPixelMap = null;
    }
    this.cursorVisible = false;
    globalSessionPage = null;
  }

  onPageShow(): void {
    console.info(`${TAG}: onPageShow`);
    this.isInBackground = false;
    
    if (this.session) {
      this.session.setInBackground(false);
      if (this.session.getInstance() !== 0) {
        LibFreeRDP.setClientDecoding(this.session.getInstance(), true);
      }
    }
  }

  onPageHide(): void {
    console.info(`${TAG}: onPageHide`);
    this.isInBackground = true;
    
    if (this.session) {
      this.session.setInBackground(true);
    }
  }

  onGraphicsUpdate(instance: number, x: number, y: number, width: number, height: number): void {
    if (this.surfaceReady) {
      return;
    }
  }

  /**
   * Read the XComponent surface size (px) and recompute density + fit transform.
   * Called on area change (layout/rotation) to re-fit the remote desktop.
   */
  private updateSurfaceMetrics(): void {
    try {
      const rect = this.xComponentController.getXComponentSurfaceRect();
      const w = Number(rect.surfaceWidth);
      const h = Number(rect.surfaceHeight);
      if (w > 0 && h > 0) {
        this.surfaceWidth = w;
        this.surfaceHeight = h;
        this.surfaceReady = true;
      }
    } catch (e) {
      console.warn(`${TAG}: getXComponentSurfaceRect failed:`, e);
    }

    if (this.viewWidth > 0 && this.surfaceWidth > 0) {
      this.density = this.surfaceWidth / this.viewWidth;
    }

    this.applyFitTransform();
    this.maybeRequestDesktopResize();
  }

  /**
   * 铺满模式下，surface 方向（横/竖）与桌面方向不一致时，通过 Display Control 通道
   * 请求服务器把桌面 resize 成当前 surface 尺寸，旋转后保持等比 1:1 铺满（不拉伸）。
   * 同方向尺寸差异不触发（避免与服务器来回抖动）；通道不可用/服务器拒绝时保持 letterbox 兜底。
   * 服务器（Windows）可能丢弃高频 resize 请求：请求后由看护定时器确认是否生效，
   * 超时未生效自动重试，多次失败后放弃并保持 letterbox 兜底显示。
   */
  private maybeRequestDesktopResize(): void {
    /* [闪退修复] 仅已建立连接时才允许请求：连接中/断开中/重连中的迟到请求
     * 会在 teardown 期触发服务器 ResetGraphics，撞上本地资源释放。 */
    if (this.connectionState !== ConnectionState.CONNECTED) {
      return;
    }
    if (this.displayMode !== DISPLAY_MODE_FILL) {
      return;
    }
    const instance = this.session?.getInstance() ?? 0;
    if (instance === 0) {
      return;
    }
    if (this.surfaceWidth <= 0 || this.surfaceHeight <= 0) {
      return;
    }
    if (this.desktopWidth <= 0 || this.desktopHeight <= 0) {
      return;
    }
    const surfaceLandscape = this.surfaceWidth > this.surfaceHeight;
    const desktopLandscape = this.desktopWidth > this.desktopHeight;
    if (surfaceLandscape === desktopLandscape) {
      return;
    }
    /* 同目标请求已在看护中：等待看护定时器确认/重试，避免重复发送 */
    if (this.pendingResizeW === this.surfaceWidth && this.pendingResizeH === this.surfaceHeight) {
      return;
    }
    this.pendingResizeW = this.surfaceWidth;
    this.pendingResizeH = this.surfaceHeight;
    this.resizeRetryCount = 0;
    this.sendResizeRequest();
  }

  private sendResizeRequest(): void {
    const instance = this.session?.getInstance() ?? 0;
    if (instance === 0 || this.connectionState !== ConnectionState.CONNECTED) {
      this.clearPendingResize();
      return;
    }
    this.resizeRetryCount++;
    console.info(`${TAG}: requesting desktop resize to ${this.pendingResizeW}x${this.pendingResizeH}` +
      ` (attempt ${this.resizeRetryCount}/${SessionPage.RESIZE_MAX_RETRY})`);
    LibFreeRDP.requestDesktopResize(instance, this.pendingResizeW, this.pendingResizeH);
    if (this.resizeRetryTimer !== -1) {
      clearTimeout(this.resizeRetryTimer);
    }
    this.resizeRetryTimer = setTimeout(() => {
      this.resizeRetryTimer = -1;
      this.checkResizeResult();
    }, SessionPage.RESIZE_RETRY_DELAY_MS) as number;
  }

  /**
   * resize 请求看护：超时未生效（服务器丢弃/拒绝）则重试；
   * 达到上限仍失败则放弃，保持 letterbox 兜底显示。
   */
  private checkResizeResult(): void {
    if (this.pendingResizeW <= 0) {
      return;
    }
    if (this.connectionState !== ConnectionState.CONNECTED || this.displayMode !== DISPLAY_MODE_FILL) {
      this.clearPendingResize();
      return;
    }
    const surfaceLandscape = this.surfaceWidth > this.surfaceHeight;
    const desktopLandscape = this.desktopWidth > this.desktopHeight;
    if (surfaceLandscape === desktopLandscape) {
      /* 已生效（服务器可能取整到相近尺寸，方向一致即视为成功） */
      this.clearPendingResize();
      return;
    }
    if (this.resizeRetryCount >= SessionPage.RESIZE_MAX_RETRY) {
      console.warn(`${TAG}: desktop resize to ${this.pendingResizeW}x${this.pendingResizeH} ` +
        `not confirmed after ${this.resizeRetryCount} attempts, keep letterbox`);
      this.clearPendingResize();
      return;
    }
    this.sendResizeRequest();
  }

  private clearPendingResize(): void {
    this.pendingResizeW = 0;
    this.pendingResizeH = 0;
    this.resizeRetryCount = 0;
    if (this.resizeRetryTimer !== -1) {
      clearTimeout(this.resizeRetryTimer);
      this.resizeRetryTimer = -1;
    }
  }

  /**
   * 业务层控制的显示模式：FIT=自适应居中，FILL=铺满整屏。
   * 同步到 C 层并重置为当前模式的基准变换。
   */
  private applyDisplayMode(mode: number): void {
    this.displayMode = mode;
    LibFreeRDP.setDisplayMode(mode);
    this.applyFitTransform();
  }

  /**
   * Reset to the base transform: aspect-preserving fit and center (letterbox).
   * FIT letterboxes the bookmarked desktop size; FILL requests a screen-sized
   * desktop at connect time so the same math maps it 1:1 (no letterbox, no
   * stretch). Pinch/pan gestures compose on top of this base.
   * Uses the XComponent surface size (px), never the phone screen size.
   */
  private applyFitTransform(): void {
    if (this.surfaceWidth <= 0 || this.surfaceHeight <= 0) {
      return;
    }
    if (this.desktopWidth <= 0 || this.desktopHeight <= 0) {
      return;
    }

    const fitScale = Math.min(this.surfaceWidth / this.desktopWidth, this.surfaceHeight / this.desktopHeight);
    const drawW = this.desktopWidth * fitScale;
    const drawH = this.desktopHeight * fitScale;

    this.viewScale = fitScale;
    this.panX = (this.surfaceWidth - drawW) / 2;
    this.panY = (this.surfaceHeight - drawH) / 2;

    console.info(`${TAG}: fit rdp=${this.desktopWidth}x${this.desktopHeight} ` +
      `surface=${this.surfaceWidth}x${this.surfaceHeight} ` +
      `scale=${fitScale} offsetX=${this.panX} offsetY=${this.panY} density=${this.density}`);

    this.pushViewport();
  }

  /**
   * Push the current scale + top-left offset (surface px) to the native renderer.
   */
  private pushViewport(): void {
    if (!this.surfaceReady) {
      return;
    }
    LibFreeRDP.setViewport(this.viewScale, this.panX, this.panY);
  }

  private screenToDesktop(screenX: number, screenY: number): DesktopCoord {
    const px = screenX * this.density;
    const py = screenY * this.density;
    let dx: number;
    let dy: number;

    // 等比变换：desktop = (screenPx - offset) / scale（FIT/FILL 统一）
    dx = (px - this.panX) / this.viewScale;
    dy = (py - this.panY) / this.viewScale;

    const clampedDx = Math.max(0, Math.min(Math.round(dx), this.desktopWidth - 1));
    const clampedDy = Math.max(0, Math.min(Math.round(dy), this.desktopHeight - 1));
    const result: DesktopCoord = { dx: clampedDx, dy: clampedDy };
    return result;
  }

  private async initSession(bookmark: BookmarkBase): Promise<void> {
    console.info(`${TAG}: Initializing session for ${bookmark.hostname}`);
    
    this.session = new SessionState(bookmark);
    this.connectionState = ConnectionState.CONNECTING;
    this.statusMessage = '正在连接...';
    
    globalOnPreConnectCallback = (instance: number): void => {
      console.info(`${TAG}: OnPreConnect`);
      this.statusMessage = '正在建立连接...';
    };
    globalOnConnectionSuccessCallback = (instance: number): void => {
      console.info(`${TAG}: OnConnectionSuccess`);
      this.onConnectionSuccess(instance);
    };
    globalOnConnectionFailureCallback = (instance: number): void => {
      console.error(`${TAG}: OnConnectionFailure`);
      this.onConnectionFailure(instance);
    };
    globalOnDisconnectingCallback = (instance: number): void => {
      console.info(`${TAG}: OnDisconnecting`);
      this.statusMessage = '正在断开连接...';
    };
    globalOnDisconnectedCallback = (instance: number): void => {
      console.info(`${TAG}: OnDisconnected`);
      this.onDisconnected(instance);
    };
    
    const eventListener = new SessionEventListenerImpl();
    LibFreeRDP.setEventListener(eventListener);
    
    const instance = LibFreeRDP.newInstance();
    if (instance === 0) {
      this.statusMessage = '错误：无法创建连接实例';
      this.connectionState = ConnectionState.DISCONNECTED;
      return;
    }
    
    this.session.setInstance(instance);
    GlobalSessionManager.registerSession(instance, this.session);
    
    const connectionInfo: BookmarkSettings = this.createConnectionInfo(bookmark);
    if (!LibFreeRDP.setConnectionInfo(instance, connectionInfo, '',
      this.displayMode === DISPLAY_MODE_FILL)) {
      this.statusMessage = '错误：连接参数无效';
      this.connectionState = ConnectionState.DISCONNECTED;
      return;
    }
    
    const sessionInfo: SessionInfo = {
      instance: instance,
      hostname: bookmark.hostname,
      port: bookmark.port,
      username: bookmark.username,
      domain: bookmark.domain,
      password: bookmark.password
    };
    NetworkManager.setSessionInfo(sessionInfo);
    NetworkManager.markConnecting(instance);
    
    if (!LibFreeRDP.connect(instance)) {
      this.statusMessage = '错误：连接失败';
      this.connectionState = ConnectionState.DISCONNECTED;
    }
  }

  private async onConnectionSuccess(instance: number): Promise<void> {
    NetworkManager.markConnected(instance);
    this.connectionState = ConnectionState.CONNECTED;
    this.statusMessage = '已连接';

    if (this.session) {
      this.session.setConnectionState(ConnectionState.CONNECTED);
    }

    this.setupNativeSurface();

    /* 连接建立瞬间 surface 与桌面方向可能不一致（连接过程中旋转过手机）：
     * 此刻才满足 CONNECTED 门禁，主动触发一次 resize 检查 */
    this.maybeRequestDesktopResize();

    this.backgroundService = new RdpBackgroundService(this.context);
    await this.backgroundService.start();
    
    this.startHeartbeat();
    this.scheduleToolbarHide();
    
    promptAction.showToast({ message: '连接成功' });
  }
  
  /**
   * Native 上报实际协商桌面分辨率（可能与 /size 请求不同：服务器回落、FILL 按屏幕分辨率请求等）。
   * 以此为准重算视口基准，保证 FIT/FILL 两种模式都按真实桌面等比适配。
   */
  private onNegotiatedSettings(width: number, height: number, bpp: number): void {
    console.info(`${TAG}: negotiated desktop = ${width}x${height}@${bpp}`);
    this.desktopWidth = width;
    this.desktopHeight = height;
    if (this.session) {
      this.session.updateDisplaySettings(width, height, bpp);
    }
    this.applyFitTransform();
    /* 连接过程中旋转过手机时，协商桌面方向可能与 surface 不一致：
     * 协商尺寸落定后立即检查是否需要 Display Control resize */
    this.maybeRequestDesktopResize();
    /* 服务器已上报新分辨率：确认待处理的 resize 请求（生效则停止重试） */
    if (this.pendingResizeW > 0) {
      this.checkResizeResult();
    }
  }

  private setupNativeSurface(): void {
    try {
      const surfaceId = this.xComponentController.getXComponentSurfaceId();
      if (surfaceId && surfaceId !== '0') {
        const success = LibFreeRDP.setSurfaceId(surfaceId);
        if (success) {
          this.surfaceReady = true;
          // Surface 就绪后重新同步显示模式，确保 C 层渲染模式正确
          LibFreeRDP.setDisplayMode(this.displayMode);
          console.info(`${TAG}: Native surface set up successfully, surfaceId=${surfaceId}`);
        } else {
          console.error(`${TAG}: Failed to set native surface ID`);
        }
      } else {
        console.warn(`${TAG}: XComponent surface ID not available yet, will retry on load`);
      }
    } catch (e) {
      console.error(`${TAG}: setupNativeSurface error:`, e);
    }
  }

  private onConnectionFailure(instance: number): void {
    NetworkManager.markDisconnected(instance);
    
    const errorStr = LibFreeRDP.getLastErrorString(instance);
    let userMessage = '连接失败';
    
    if (errorStr) {
      const lowerError = errorStr.toLowerCase();
      if (lowerError.includes('authentication') || lowerError.includes('logon') ||
           lowerError.includes('access denied') || lowerError.includes('credentials')) {
        userMessage = '连接失败: 用户名或密码错误';
      } else if (lowerError.includes('dns') || lowerError.includes('resolve') ||
                 lowerError.includes('name or service not known')) {
        userMessage = '连接失败: 无法解析主机名，请检查地址';
      } else if (lowerError.includes('connect') || lowerError.includes('refused') ||
                 lowerError.includes('timeout') || lowerError.includes('unreachable')) {
        userMessage = '连接失败: 无法连接到服务器，请检查地址和端口';
      } else if (lowerError.includes('tls') || lowerError.includes('ssl') ||
                 lowerError.includes('certificate')) {
        userMessage = '连接失败: 安全连接错误';
      } else if (lowerError.includes('negotiation')) {
        userMessage = '连接失败: 协议协商失败';
      } else {
        userMessage = `连接失败: ${errorStr}`;
      }
    }
    
    this.statusMessage = userMessage;
    this.connectionState = ConnectionState.DISCONNECTED;
    
    if (this.session) {
      this.session.setConnectionState(ConnectionState.DISCONNECTED);
    }
    
    promptAction.showToast({ message: userMessage });
  }

  private async onDisconnected(instance: number): Promise<void> {
    NetworkManager.markDisconnected(instance);
    this.connectionState = ConnectionState.DISCONNECTED;
    this.statusMessage = '已断开连接';
    this.clearPendingResize();
    
    if (this.session) {
      this.session.setConnectionState(ConnectionState.DISCONNECTED);
    }
    
    if (this.backgroundService) {
      await this.backgroundService.stop();
    }
    
    this.stopHeartbeat();
    
    promptAction.showToast({ message: '连接已断开' });
  }

  private onNetworkLost(): void {
    console.warn(`${TAG}: Network lost`);
    this.statusMessage = '网络连接丢失，正在等待重连...';
    this.connectionState = ConnectionState.RECONNECTING;
  }

  private onReconnectSuccess(): void {
    console.info(`${TAG}: Reconnect success`);
    this.statusMessage = '已重新连接';
    this.connectionState = ConnectionState.CONNECTED;
    promptAction.showToast({ message: '已重新连接' });
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    
    const heartbeatCallback = (): void => {
      if (this.session && this.session.getInstance() !== 0 && 
          this.connectionState === ConnectionState.CONNECTED) {
        LibFreeRDP.sendHeartbeat(this.session.getInstance());
      }
    };
    this.heartbeatTimer = setInterval(heartbeatCallback, HEARTBEAT_INTERVAL_MS) as number;
    
    console.info(`${TAG}: Heartbeat started (interval: ${HEARTBEAT_INTERVAL_MS}ms)`);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
      console.info(`${TAG}: Heartbeat stopped`);
    }
  }

  private createConnectionInfo(bookmark: BookmarkBase): BookmarkSettings {
    const screenSettings: ScreenSettings = {
      width: bookmark.screenSettings.width,
      height: bookmark.screenSettings.height,
      colors: bookmark.screenSettings.colors
    };

    // 铺满模式：按屏幕物理分辨率请求桌面，服务器返回与屏幕一致的桌面后等比 1:1 铺满（不拉伸）；
    // 获取失败则回退书签分辨率
    if (this.displayMode === DISPLAY_MODE_FILL) {
      try {
        const dsp = display.getDefaultDisplaySync();
        if (dsp.width > 0 && dsp.height > 0) {
          screenSettings.width = dsp.width;
          screenSettings.height = dsp.height;
          console.info(`${TAG}: fullscreen desktop size = ${dsp.width}x${dsp.height}`);
        }
      } catch (e) {
        console.warn(`${TAG}: getDefaultDisplaySync failed, fallback to bookmark size`, e);
      }
    }

    const advancedSettings: AdvancedSettings = {
      consoleMode: bookmark.advancedSettings.consoleMode,
      security: bookmark.advancedSettings.security,
      remoteProgram: bookmark.advancedSettings.remoteProgram,
      workDir: bookmark.advancedSettings.workDir,
      redirectSDCard: bookmark.advancedSettings.redirectSDCard,
      redirectSound: bookmark.advancedSettings.redirectSound,
      redirectMicrophone: bookmark.advancedSettings.redirectMicrophone
    };

    const performanceFlags: PerformanceFlags = {
      remoteFX: bookmark.performanceFlags.remoteFX,
      gfx: bookmark.performanceFlags.gfx,
      h264: bookmark.performanceFlags.h264,
      wallpaper: bookmark.performanceFlags.wallpaper,
      fullWindowDrag: bookmark.performanceFlags.fullWindowDrag,
      menuAnimations: bookmark.performanceFlags.menuAnimations,
      theming: bookmark.performanceFlags.theming,
      fontSmoothing: bookmark.performanceFlags.fontSmoothing,
      desktopComposition: bookmark.performanceFlags.desktopComposition
    };

    const debugSettings: DebugSettings = {
      asyncChannel: bookmark.debugSettings.asyncChannel,
      asyncUpdate: bookmark.debugSettings.asyncUpdate,
      debugLevel: bookmark.debugSettings.debugLevel
    };

    const info: BookmarkSettings = {
      hostname: bookmark.hostname,
      port: bookmark.port,
      username: bookmark.username,
      domain: bookmark.domain,
      password: bookmark.password,
      screenSettings: screenSettings,
      advancedSettings: advancedSettings,
      performanceFlags: performanceFlags,
      debugSettings: debugSettings
    };

    if (bookmark.gatewaySettings && bookmark.gatewaySettings.enabled) {
      const gatewaySettings: GatewaySettings = {
        enabled: bookmark.gatewaySettings.enabled,
        hostname: bookmark.gatewaySettings.hostname,
        port: bookmark.gatewaySettings.port,
        username: bookmark.gatewaySettings.username,
        domain: bookmark.gatewaySettings.domain,
        password: bookmark.gatewaySettings.password
      };
      info.gatewaySettings = gatewaySettings;
    }
    return info;
  }

  private scheduleToolbarHide(): void {
    if (this.toolbarHideTimer !== -1) {
      clearTimeout(this.toolbarHideTimer);
    }
    
    const hideCallback = (): void => {
      this.showToolbar = false;
    };
    this.toolbarHideTimer = setTimeout(hideCallback, SessionPage.TOOLBAR_HIDE_DELAY) as number;
  }

  private toggleToolbar(): void {
    this.showToolbar = !this.showToolbar;
    if (this.showToolbar) {
      this.scheduleToolbarHide();
    }
  }

  private disconnect(): void {
    if (this.session && this.session.getInstance() !== 0) {
      LibFreeRDP.disconnect(this.session.getInstance());
    }
  }

  private async setKeepScreenOn(keepOn: boolean): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      await win.setWindowKeepScreenOn(keepOn);
    } catch (error) {
      console.error(`${TAG}: Failed to set keep screen on:`, error);
    }
  }

  private async cleanup(): Promise<void> {
    console.info(`${TAG}: Cleaning up`);

    this.stopHeartbeat();
    this.clearPendingResize();
    if (this.toolbarHideTimer !== -1) {
      clearTimeout(this.toolbarHideTimer);
    }
    if (this.holdPressTimer !== -1) {
      clearTimeout(this.holdPressTimer);
      this.holdPressTimer = -1;
    }
    if (this.imeCheckTimer !== -1) {
      clearTimeout(this.imeCheckTimer);
      this.imeCheckTimer = -1;
    }
    
    LibFreeRDP.releaseSurface();
    this.surfaceReady = false;
    
    if (this.session && this.session.getInstance() !== 0) {
      LibFreeRDP.freeInstance(this.session.getInstance());
      GlobalSessionManager.removeSession(this.session.getInstance());
    }
    
    if (this.backgroundService) {
      await this.backgroundService.stop();
    }
    
    NetworkManager.clearSessionInfo();
    this.setKeepScreenOn(false);
  }

  private goBack(): void {
    promptAction.showDialog({
      title: '断开连接',
      message: '确定要断开远程桌面连接吗？',
      buttons: [
        { text: '取消', color: '#888888' },
        { text: '断开', color: '#F44336' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.disconnect();
        router.back();
      }
    });
  }

  private resetZoom(): void {
    this.applyFitTransform();
  }

  @Builder
  Toolbar() {
    Row() {
      Button({ type: ButtonType.Circle }) {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor('#FFFFFF')
      }
      .width(44)
      .height(44)
      .backgroundColor('#80424242')
      .onClick(() => {
        this.goBack();
      })
      
      Blank()
      
      Text(this.statusMessage)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor('#80000000')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(16)
      
      Blank()
      
      Button({ type: ButtonType.Circle }) {
        Image($r('sys.media.ohos_ic_public_edit'))
          .width(24)
          .height(24)
          .fillColor('#FFFFFF')
      }
      .width(44)
      .height(44)
      .backgroundColor('#80424242')
      .margin({ right: 8 })
      .onClick(() => {
        // 直接切换系统输入法：不依赖光标启发式的可靠手动路径
        this.toggleIme();
      })
      
      Button({ type: ButtonType.Circle }) {
        Image($r('sys.media.ohos_ic_public_more'))
          .width(24)
          .height(24)
          .fillColor('#FFFFFF')
      }
      .width(44)
      .height(44)
      .backgroundColor('#80424242')
      .onClick(() => {
        // more：切换特殊键面板（Ctrl/Alt/方向键等）
        if (this.showKeyboard) {
          this.showKeyboard = false;
        } else {
          this.hideIme(); // 特殊键面板与系统输入法互斥
          this.showKeyboard = true;
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor('#40000000')
  }

  build() {
    Stack() {
      if (this.connectionState === ConnectionState.CONNECTED) {
        Stack() {
          XComponent({ id: 'rdpSurface', type: XComponentType.SURFACE, libraryname: 'freerdp_harmonyos', controller: this.xComponentController })
            .width('100%')
            .height('100%')
            .onLoad(() => {
              console.info(`${TAG}: XComponent loaded, setting up surface`);
              this.setupNativeSurface();
              this.updateSurfaceMetrics();
            })
            .onDestroy(() => {
              console.info(`${TAG}: XComponent destroyed, releasing surface`);
              LibFreeRDP.releaseSurface();
              this.surfaceReady = false;
            })

          Image(this.isLandscape ? $rawfile('portrait_orientation.svg') : $rawfile('landscape_screen.svg'))
            .width(SessionPage.ORIENT_BTN_W)
            .height(SessionPage.ORIENT_BTN_H)
            .draggable(false)
            .position({
              x: this.orientBtnX(),
              y: this.orientBtnY()
            })
            .onClick(() => {
              this.toggleFullScreen()
            })

          // [远端光标同步] 自定义光标叠加层：跟随触控点、热点对齐、随视口缩放
          if (this.cursorVisible && this.cursorPixelMap) {
            Image(this.cursorPixelMap)
              .width(this.cursorW * this.cursorOverlayScale())
              .height(this.cursorH * this.cursorOverlayScale())
              .position({
                x: this.cursorViewX,
                y: this.cursorViewY
              })
              .draggable(false)
              .hitTestBehavior(HitTestMode.None)
          }

          // [软键盘桥接] 隐藏输入框：获得焦点即拉起系统输入法，输入内容转发远端。
          // 不参与命中测试（不拦截会话触控），仅由 focusControl 程序化聚焦。
          // 非受控模式（不绑定 text 参数）：受控模式下组合态 onChange 不回写会导致
          // 框架将内部文本重置回参数值，静默取消输入法组合，之后不再产生任何事件。
          // 删除走 onWillDelete 拦截：桥接框将删空时否决删除并手动补发远端退格，
          // 字段永不清空 → 退格可无限删除桥接范围外（PC 端预输入）的内容。
          TextInput({ controller: this.imeInputController })
            .id('imeBridge')
            .key('imeBridge')
            .type(InputType.Normal)
            .width(1)
            .height(1)
            .fontSize(1)
            .opacity(0)
            .caretColor(Color.Transparent)
            .hitTestBehavior(HitTestMode.None)
            .onChange((value: string, previewText?: PreviewText) => {
              this.onImeTextChanged(value, previewText);
            })
            .onWillDelete((value: DeleteValue): boolean => {
              return this.onImeWillDelete(value);
            })
            .onWillInsert((value: InsertValue): boolean => {
              console.info(`${TAG}: ime onWillInsert off=${value.insertOffset} value='${value.insertValue}'`);
              return true;
            })
            .onDidInsert((value: InsertValue) => {
              console.info(`${TAG}: ime onDidInsert off=${value.insertOffset} value='${value.insertValue}'`);
            })
            .onDidDelete((value: DeleteValue) => {
              console.info(`${TAG}: ime onDidDelete off=${value.deleteOffset} len=${value.deleteValue.length}`);
            })
            .onEditChange((editing: boolean) => {
              console.info(`${TAG}: ime onEditChange -> ${editing}`);
              if (!editing) {
                this.imeLastPreview = '';
                this.imeLastComposeValue = '';
              }
            })
        }
        .width('100%')
        .height('100%')
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const newW = Number(newArea.width);
          const newH = Number(newArea.height);
          if (newW > 0 && newH > 0 && (newW !== this.viewWidth || newH !== this.viewHeight)) {
            this.viewWidth = newW;
            this.viewHeight = newH;
            console.info(`${TAG}: View area changed to ${newW}x${newH} vp`);
            this.updateSurfaceMetrics();
          }
        })
        .onTouch((event: TouchEvent) => {
          this.onSessionTouch(event);
        })
        .parallelGesture(
          GestureGroup(GestureMode.Exclusive,
            // 捏合激活门槛 9vp：单侧捏合的相对距离增速约为双指共同位移的 2 倍，
            // 门槛设为 pan(5vp) 的近 2 倍可让双指平移在互斥竞争中先激活，
            // 否则捏合方向的自然抖动总是先达 5vp、pan 永远无法生效
            PinchGesture({ fingers: 2, distance: 9 })
              .onActionStart((event: GestureEvent) => {
                this.isPinching = true;
                this.lastPinchScale = this.viewScale;
                this.twoFingerPending = false;
                // 本地双指手势接管：取消挂起的 tap/滚动；远端拖动进行中
                // （已发按下）不取消——手掌误触引发本地手势不应打断拖动
                if (!this.tapButtonSent) {
                  this.cancelTapTracking();
                }
              })
              .onActionUpdate((event: GestureEvent) => {
                // 远端拖动进行中：手掌伪手势不得改变视口坐标
                if (this.tapButtonSent) {
                  return;
                }
                const newScale = Math.max(SessionPage.MIN_SCALE, Math.min(this.lastPinchScale * event.scale, SessionPage.MAX_SCALE));
                const cx = event.pinchCenterX * this.density;
                const cy = event.pinchCenterY * this.density;
                const ratio = newScale / this.viewScale;
                this.panX = cx - (cx - this.panX) * ratio;
                this.panY = cy - (cy - this.panY) * ratio;
                this.viewScale = newScale;
                this.clampPan();
                this.pushViewport();
              })
              .onActionEnd((event: GestureEvent) => {
                this.isPinching = false;
              }),
            // 双指平移本地视口（放大态）。单指必须留给远端拖动：
            // 旧配置 fingers:1 在 5vp 即激活，早于 tap 8vp slop，
            // 导致单指拖动被本地手势整体吞掉（无法拖动远端窗口/选择文本）
            PanGesture({ fingers: 2, distance: 5 })
              .onActionStart((event: GestureEvent) => {
                this.lastPanX = this.panX;
                this.lastPanY = this.panY;
                // Exclusive 组内 pinch/pan 互斥，不会并发；清除残留标记防卡死
                this.isPinching = false;
                this.twoFingerPending = false;
                if (!this.tapButtonSent) {
                  this.cancelTapTracking();
                }
              })
              .onActionUpdate((event: GestureEvent) => {
                // 远端拖动进行中：手掌伪手势不得改变视口坐标
                if (this.tapButtonSent) {
                  return;
                }
                const drawSize = this.getDrawSize();
                if (drawSize.width > this.surfaceWidth || drawSize.height > this.surfaceHeight) {
                  this.panX = this.lastPanX + event.offsetX * this.density;
                  this.panY = this.lastPanY + event.offsetY * this.density;
                  this.clampPan();
                  this.pushViewport();
                }
              })
              .onActionEnd((event: GestureEvent) => {
              })
          )
        )
      } else {
        Column() {
          if (this.connectionState === ConnectionState.CONNECTING ||
              this.connectionState === ConnectionState.RECONNECTING) {
            LoadingProgress()
              .width(64)
              .height(64)
              .color('#2196F3')
          } else {
            Image($r('sys.media.ohos_ic_public_fail'))
              .width(64)
              .height(64)
              .fillColor('#F44336')
          }
          
          Text(this.statusMessage)
            .fontSize(18)
            .fontColor('#FFFFFF')
            .margin({ top: 24 })
            .textAlign(TextAlign.Center)
          
          if (this.connectionState === ConnectionState.DISCONNECTED) {
            Button('返回')
              .width(120)
              .height(44)
              .backgroundColor('#2196F3')
              .margin({ top: 24 })
              .onClick(() => {
                router.back();
              })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#121212')
        .justifyContent(FlexAlign.Center)
      }
      
      if (this.showToolbar) {
        Column() {
          this.Toolbar()
        }
        .width('100%')
        .position({ x: 0, y: 0 })
      }
      
      if (this.showKeyboard) {
        // [键盘面板] 直接挂根 Stack 底部（旧实现的 translate(-200) 恒截断面板且
        // 内部 isVisible 永远为 false，面板从未真正显示过）
        VirtualKeyboard({
          instance: this.session?.getInstance() ?? 0,
          showPanel: $showKeyboard,
          onImeRequest: () => {
            this.toggleIme();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .alignContent(Alignment.Bottom)
  }

  /**
   * 当前变换下画面在 Surface 上的绘制尺寸（px）：desktop 尺寸 × 等比缩放（FIT/FILL 统一）。
   */
  private getDrawSize(): DrawSize {
    const size: DrawSize = {
      width: this.desktopWidth * this.viewScale,
      height: this.desktopHeight * this.viewScale
    };
    return size;
  }

  private clampPan(): void {
    const drawSize = this.getDrawSize();
    const drawW = drawSize.width;
    const drawH = drawSize.height;

    if (drawW <= this.surfaceWidth) {
      this.panX = (this.surfaceWidth - drawW) / 2;
    } else {
      this.panX = Math.min(0, Math.max(this.surfaceWidth - drawW, this.panX));
    }

    if (drawH <= this.surfaceHeight) {
      this.panY = (this.surfaceHeight - drawH) / 2;
    } else {
      this.panY = Math.min(0, Math.max(this.surfaceHeight - drawH, this.panY));
    }
  }

  /**
   * [远端光标同步] 远端光标形态位图上报：
   * rgba 为 RGBA_8888 字节序位图，转 PixelMap 后叠加在 XComponent 上层，
   * 跟随最近触控点、按热点对齐、按当前视口比例缩放。
   * length == 0 表示 SetNull/SetDefault：清除自定义光标叠加层。
   */
  private async onCursorShapeChanged(width: number, height: number, hotspotX: number,
    hotspotY: number, rgba: ArrayBuffer, length: number): Promise<void> {
    if (length <= 0 || !rgba || rgba.byteLength <= 0 || width <= 0 || height <= 0) {
      this.cursorVisible = false;
      this.cursorPixelMap = null;
      return;
    }

    try {
      const opts: image.InitializationOptions = {
        size: { width: width, height: height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      };
      const pm = await image.createPixelMap(rgba, opts);
      if (this.cursorPixelMap) {
        this.cursorPixelMap.release();
      }
      this.cursorPixelMap = pm;
      this.cursorW = width;
      this.cursorH = height;
      this.cursorHotspotX = hotspotX;
      this.cursorHotspotY = hotspotY;
      this.cursorVisible = true;
      this.repositionCursorOverlay();
    } catch (e) {
      console.warn(`${TAG}: createPixelMap for cursor failed:`, e);
    }
  }

  /** 桌面像素 → 屏幕 vp 的比例（surface px / density(vp→px)，再乘视口缩放） */
  private cursorOverlayScale(): number {
    return this.viewScale / this.density;
  }

  /** 按最近触控点重放光标叠加层位置（热点对齐） */
  private repositionCursorOverlay(): void {
    if (this.lastTouchX < 0 || this.lastTouchY < 0) {
      return;
    }
    const scale = this.cursorOverlayScale();
    this.cursorViewX = this.lastTouchX - this.cursorHotspotX * scale;
    this.cursorViewY = this.lastTouchY - this.cursorHotspotY * scale;
  }

  /**
   * [文件打开重定向] 远端在重定向磁盘上打开了本地文件（如资源管理器双击）。
   * 尽力而为：toast 提示 + 尝试用系统应用打开；沙箱文件跨应用可见性受限，失败仅记录。
   */
  private onRemoteFileOpen(fullPath: string, filename: string): void {
    console.info(`${TAG}: remote opened file: ${fullPath}`);
    promptAction.showToast({ message: `远端打开了文件：${filename}` });

    try {
      const uri = fileUri.getUriFromPath(fullPath);
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: uri,
        type: this.guessMimeType(filename)
      };
      this.context.startAbility(want).catch((err: Error) => {
        console.warn(`${TAG}: startAbility(viewData) failed: ${err.message}`);
      });
    } catch (e) {
      console.warn(`${TAG}: open file externally failed:`, e);
    }
  }

  /** 按扩展名推断 MIME 类型（系统应用按 type 路由） */
  private guessMimeType(filename: string): string {
    const name = filename.toLowerCase();
    if (name.endsWith('.txt') || name.endsWith('.log') || name.endsWith('.md')) {
      return 'text/plain';
    }
    if (name.endsWith('.pdf')) {
      return 'application/pdf';
    }
    if (name.endsWith('.png') || name.endsWith('.jpg') || name.endsWith('.jpeg') ||
      name.endsWith('.bmp') || name.endsWith('.gif') || name.endsWith('.webp')) {
      return 'image/*';
    }
    if (name.endsWith('.mp4') || name.endsWith('.mkv') || name.endsWith('.avi') ||
      name.endsWith('.mov')) {
      return 'video/*';
    }
    if (name.endsWith('.mp3') || name.endsWith('.wav') || name.endsWith('.flac') ||
      name.endsWith('.aac')) {
      return 'audio/*';
    }
    return 'application/octet-stream';
  }

  private onSessionTouch(event: TouchEvent): void {
    const instance = this.session?.getInstance() ?? 0;
    if (instance === 0) {
      return;
    }
    if (this.viewWidth <= 0 || this.viewHeight <= 0) {
      return;
    }

    const changed = event.changedTouches;
    if (changed.length === 0) {
      return;
    }

    switch (event.type) {
      case TouchType.Down:
        // 主触点已消失但未收到对应 Up（异常兜底）：先回收主触点资格，防止触控永久失效
        if (this.activeTouchId !== -1 &&
          this.findTouchById(event.touches, this.activeTouchId) === undefined) {
          console.warn(`${TAG}: stale primary touch ${this.activeTouchId}, reset`);
          this.resetTapTracking();
          this.activeTouchId = -1;
        }
        for (let i = 0; i < changed.length; i++) {
          const down = changed[i];
          if (this.activeTouchId === -1) {
            this.beginPrimaryTouch(instance, down);
          } else if (down.id !== this.activeTouchId) {
            this.onSecondaryTouchDown();
          }
        }
        break;

      case TouchType.Move: {
        const touch = this.findTouchById(changed, this.activeTouchId);
        if (touch === undefined) {
          break; // 非主触点移动，忽略
        }
        // 光标叠加层跟随主触点（远端光标位置由己方触控驱动）
        this.lastTouchX = touch.x;
        this.lastTouchY = touch.y;
        if (this.cursorVisible) {
          this.repositionCursorOverlay();
        }
        this.handlePrimaryMove(instance, touch);
        break;
      }

      case TouchType.Up:
      case TouchType.Cancel: {
        const touch = this.findTouchById(changed, this.activeTouchId);
        if (touch === undefined) {
          break; // 非主触点抬起，忽略
        }
        this.lastTouchX = touch.x;
        this.lastTouchY = touch.y;
        this.handlePrimaryEnd(instance, event.type, touch);
        this.activeTouchId = -1;
        break;
      }
    }
  }

  private findTouchById(touches: TouchObject[], id: number): TouchObject | undefined {
    for (let i = 0; i < touches.length; i++) {
      if (touches[i].id === id) {
        return touches[i];
      }
    }
    return undefined;
  }

  /** 主触点按下：挂起 tap 判定并启动长按计时 */
  private beginPrimaryTouch(instance: number, touch: TouchObject): void {
    this.activeTouchId = touch.id;
    this.primaryDownMs = Date.now();
    this.tapDownX = touch.x;
    this.tapDownY = touch.y;
    this.tapPending = true;
    this.tapButtonSent = false;
    this.touchCancelled = false;
    this.moveCount = 0;
    console.info(`${TAG}: touch Down id=${touch.id} (${touch.x.toFixed(0)},${touch.y.toFixed(0)})`);
    if (this.holdPressTimer !== -1) {
      clearTimeout(this.holdPressTimer);
    }
    // 长按延时：超时仍未判定为 tap/拖动，则补发按下（保持远端"按住"能力）
    this.holdPressTimer = setTimeout(() => {
      this.holdPressTimer = -1;
      if (this.tapPending) {
        const c = this.screenToDesktop(this.tapDownX, this.tapDownY);
        console.info(`${TAG}: hold-press -> down (${c.dx},${c.dy})`);
        LibFreeRDP.sendCursorEvent(instance, c.dx, c.dy, PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1);
        this.tapPending = false;
        this.tapButtonSent = true;
      }
    }, SessionPage.HOLD_DELAY_MS) as number;
  }

  /**
   * 第二触点落下：仅当主触点仍处于 tap 挂起、未进入滚动且双指几乎同时落地
   * （<=TWO_FINGER_TAP_MS）才挂起双指右键，待主触点抬起时确认；迟到的触点
   * （长按/拖动/滚动进行中、手掌误触通常滞后数百毫秒）直接忽略，不干扰手势。
   */
  private onSecondaryTouchDown(): void {
    const elapsed = Date.now() - this.primaryDownMs;
    if (!this.tapButtonSent && !this.touchCancelled && !this.scrolling &&
      elapsed <= SessionPage.TWO_FINGER_TAP_MS) {
      console.info(`${TAG}: two-finger down (${elapsed}ms), right click pending`);
      this.cancelTapTracking();
      this.twoFingerPending = true;
      this.twoFingerDownMs = Date.now();
    } else {
      console.info(`${TAG}: extra finger ignored (elapsed=${elapsed}ms, sent=${this.tapButtonSent}, cancelled=${this.touchCancelled}, scrolling=${this.scrolling})`);
    }
  }

  private handlePrimaryMove(instance: number, touch: TouchObject): void {
    if (this.touchCancelled) {
      return;
    }
    if (this.scrolling) {
      // 滚动模式：位移累积转滚轮，不向远端发送鼠标移动
      this.wheelAccumX += touch.x - this.scrollLastX;
      this.wheelAccumY += touch.y - this.scrollLastY;
      this.scrollLastX = touch.x;
      this.scrollLastY = touch.y;
      this.sendAccumulatedWheel(instance, touch);
      return;
    }
    const coord = this.screenToDesktop(touch.x, touch.y);
    if (this.tapPending) {
      const dx = touch.x - this.tapDownX;
      const dy = touch.y - this.tapDownY;
      if (dx * dx + dy * dy <= SessionPage.TAP_SLOP_VP * SessionPage.TAP_SLOP_VP) {
        return; // 位移在 tap 容差内，继续挂起
      }
      // 位移超容差且长按（250ms）尚未触发：快速滑动 → 滚轮滚动。
      // 拖动语义变为"长按后再移动"：hold-press 已补发按下后移动即为拖动。
      if (this.holdPressTimer !== -1) {
        clearTimeout(this.holdPressTimer);
        this.holdPressTimer = -1;
      }
      this.tapPending = false;
      this.scrolling = true;
      this.scrollLastX = touch.x;
      this.scrollLastY = touch.y;
      this.wheelAccumX = 0;
      this.wheelAccumY = 0;
      this.scrollWheelCount = 0;
      console.info(`${TAG}: scroll begin`);
      return;
    }
    if (this.tapButtonSent) {
      this.moveCount++;
      LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_MOVE);
    }
  }

  /**
   * 滑动位移 → 远端滚轮（自然触屏方向，内容跟随手指）：
   * 垂直：手指下滑 → 向上滚（WHEEL 正）；上滑 → 向下滚（WHEEL|NEG）。
   * 水平：手指右滑 → 向左滚（HWHEEL 正）；左滑 → 向右滚（HWHEEL|NEG）。
   * 每档 120（Windows 一格），每 SCROLL_WHEEL_STEP_VP 位移发送一档。
   */
  private sendAccumulatedWheel(instance: number, touch: TouchObject): void {
    const coord = this.screenToDesktop(touch.x, touch.y);
    const step = SessionPage.SCROLL_WHEEL_STEP_VP;
    const unit = SessionPage.WHEEL_DELTA_UNITS;
    while (this.wheelAccumY >= step) {
      this.wheelAccumY -= step;
      LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_WHEEL | unit);
      this.scrollWheelCount++;
    }
    while (this.wheelAccumY <= -step) {
      this.wheelAccumY += step;
      LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy,
        PTR_FLAGS_WHEEL | PTR_FLAGS_WHEEL_NEGATIVE | unit);
      this.scrollWheelCount++;
    }
    while (this.wheelAccumX >= step) {
      this.wheelAccumX -= step;
      LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_HWHEEL | unit);
      this.scrollWheelCount++;
    }
    while (this.wheelAccumX <= -step) {
      this.wheelAccumX += step;
      LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy,
        PTR_FLAGS_HWHEEL | PTR_FLAGS_WHEEL_NEGATIVE | unit);
      this.scrollWheelCount++;
    }
  }

  private handlePrimaryEnd(instance: number, type: TouchType, touch: TouchObject): void {
    if (this.holdPressTimer !== -1) {
      clearTimeout(this.holdPressTimer);
      this.holdPressTimer = -1;
    }
    const coord = this.screenToDesktop(touch.x, touch.y);
    {
      const kind = this.scrolling ? `scroll(${this.scrollWheelCount} wheels)` :
        this.twoFingerPending ? 'two-finger' :
        this.touchCancelled ? 'cancelled' :
        (this.tapPending ? 'tap' : `drag(${this.moveCount} moves)`);
      console.info(`${TAG}: touch end: ${kind}`);
    }
    if (this.scrolling) {
      console.info(`${TAG}: scroll end`);
      this.lastTapTime = 0; // 滚动打断双击序列
      this.resetTapTracking();
      return;
    }
    if (this.twoFingerPending) {
      // 双指右键确认：须在判定窗口内以小位移正常抬起，否则视为 pan/pinch 前奏
      const liftElapsed = Date.now() - this.twoFingerDownMs;
      const moveVp = Math.abs(touch.x - this.tapDownX) + Math.abs(touch.y - this.tapDownY);
      if (type === TouchType.Up && liftElapsed <= SessionPage.TWO_FINGER_LIFT_MS &&
        moveVp <= SessionPage.TWO_FINGER_TAP_SLOP_VP) {
        console.info(`${TAG}: two-finger tap -> right click (lift ${liftElapsed}ms, move ${moveVp.toFixed(0)}vp)`);
        LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON2);
        LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_BUTTON2);
      } else {
        console.info(`${TAG}: two-finger not a tap (up=${type === TouchType.Up}, lift=${liftElapsed}ms, move=${moveVp.toFixed(0)}vp)`);
      }
      this.resetTapTracking();
      return;
    }
    if (this.touchCancelled) {
      // 手势已被多指/本地手势取消：若曾发送按下则必须补发抬起（防远端按键卡死）
      if (this.tapButtonSent) {
        LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_BUTTON1);
      }
      this.resetTapTracking();
      return;
    }
    if (this.tapPending) {
      // 纯 tap：未发送过按下，抬起时合成完整点击
      if (type === TouchType.Up) {
        this.handleTap(instance, this.tapDownX, this.tapDownY);
      }
      this.resetTapTracking();
    } else if (this.tapButtonSent) {
      // 拖动/长按结束：无条件补发抬起（历史上此处可能被手势状态吞掉）
      LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_BUTTON1);
      this.lastTapTime = 0; // 拖动打断双击序列
      this.resetTapTracking();
    }
  }

  private resetTapTracking(): void {
    this.tapPending = false;
    this.tapButtonSent = false;
    this.touchCancelled = false;
    this.scrolling = false;
    this.twoFingerPending = false;
  }

  private cancelTapTracking(): void {
    if (this.holdPressTimer !== -1) {
      clearTimeout(this.holdPressTimer);
      this.holdPressTimer = -1;
    }
    this.tapPending = false;
    this.touchCancelled = true;
    this.lastTapTime = 0;
    this.scrolling = false;
    this.twoFingerPending = false;
  }

  /**
   * tap 判定完成 → 合成点击。350ms/40vp 内的连续两次 tap 合成为双击：
   * 第二次点击强制使用第一次的坐标，两次点击坐标完全一致，规避触屏
   * 自然抖动超过服务端双击矩形（默认 4 远程像素）导致的双击失效。
   */
  private handleTap(instance: number, x: number, y: number): void {
    const now = Date.now();
    this.lastTapEndMs = now;
    const isDoubleTap = this.lastTapTime > 0 &&
      now - this.lastTapTime <= SessionPage.DOUBLE_TAP_MS &&
      Math.abs(x - this.lastTapX) <= SessionPage.DOUBLE_TAP_DIST_VP &&
      Math.abs(y - this.lastTapY) <= SessionPage.DOUBLE_TAP_DIST_VP;

    if (isDoubleTap) {
      const c = this.screenToDesktop(this.lastTapX, this.lastTapY);
      console.info(`${TAG}: tap double -> (${c.dx},${c.dy})`);
      LibFreeRDP.sendCursorEvent(instance, c.dx, c.dy, PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1);
      LibFreeRDP.sendCursorEvent(instance, c.dx, c.dy, PTR_FLAGS_BUTTON1);
      this.lastTapTime = 0;
    } else {
      const c = this.screenToDesktop(x, y);
      console.info(`${TAG}: tap single -> (${c.dx},${c.dy})`);
      LibFreeRDP.sendCursorEvent(instance, c.dx, c.dy, PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1);
      LibFreeRDP.sendCursorEvent(instance, c.dx, c.dy, PTR_FLAGS_BUTTON1);
      this.lastTapX = x;
      this.lastTapY = y;
      this.lastTapTime = now;
    }
    this.scheduleImeCheck();
  }

  /**
   * 点击后延迟判定软键盘：远端处理点击、切换光标形态后（点击文本框会
   * 使光标变为 I-beam），若当前为文本光标则自动拉起系统输入法，否则收起。
   */
  private scheduleImeCheck(): void {
    if (this.imeCheckTimer !== -1) {
      clearTimeout(this.imeCheckTimer);
    }
    this.imeCheckTimer = setTimeout(() => {
      this.imeCheckTimer = -1;
      if (!this.session || this.connectionState !== ConnectionState.CONNECTED || this.isInBackground) {
        return;
      }
      if (this.remoteCursorType === CURSOR_TYPE_IBEAM) {
        this.showIme();
      } else if (this.imeVisible) {
        this.hideIme();
      }
    }, SessionPage.IME_CHECK_DELAY_MS) as number;
  }

  private showIme(): void {
    this.showKeyboard = false; // 特殊键面板与系统输入法互斥
    const ok = focusControl.requestFocus('imeBridge');
    console.info(`${TAG}: showIme requestFocus('imeBridge') -> ${ok}`);
  }

  private hideIme(): void {
    console.info(`${TAG}: hideIme (stopEditing), imeVisible=${this.imeVisible}`);
    this.imeInputController.stopEditing();
  }

  private toggleIme(): void {
    console.info(`${TAG}: toggleIme, imeVisible=${this.imeVisible}`);
    if (this.imeVisible) {
      this.hideIme();
    } else {
      this.showIme();
    }
  }

  /**
   * 系统输入法 → 远端：对桥接框内容做 diff，新增字符按 Unicode 键事件发送
   * （每个 UTF-16 码元一个事件，代理对各发两半，符合 VK_PACKET 语义），
   * 删除按退格发送。输入法组合态（拼音候选未上屏）不发送：仅当组合
   * preview 与最近组合构成扩展/缩短/相等链时跳过；preview 与组合链无关
   * （如拼音选字后整体替换）按上屏处理——部分输入法的 commit 事件同样
   * 携带 previewText，不能仅凭其非空一概丢弃。
   * 桥接框内容保留不清空，保证 IME 退格可继续删除远端已上屏内容。
   */
  /**
   * 删除拦截：桥接框即将被删空时否决本次删除，改为手动向远端补发等量退格。
   * 框架被否决后删不掉最后的字符 → 字段永不清空 → 之后每次退格都触发本回调，
   * 每按一次即向远端补一个退格，从而能删除桥接范围之外（PC 端预输入）的内容。
   * 普通删除（不会清空）放行，由 onChange 差分同步退格。
   */
  private onImeWillDelete(value: DeleteValue): boolean {
    const instance = this.session?.getInstance() ?? 0;
    const trackedLen = this.imeTrackedValue.length;
    console.info(`${TAG}: ime onWillDelete off=${value.deleteOffset} dir=${value.direction}` +
      ` len=${value.deleteValue.length} tracked=${trackedLen}`);
    if (trackedLen > 0 && value.deleteValue.length >= trackedLen) {
      // 删空操作（整段选中删除 / 仅剩单字符退格）：否决并手动补发退格
      if (instance !== 0) {
        for (let i = 0; i < trackedLen; i++) {
          if (!LibFreeRDP.sendKeyEvent(instance, SessionPage.VK_BACKSPACE, true) ||
            !LibFreeRDP.sendKeyEvent(instance, SessionPage.VK_BACKSPACE, false)) {
            console.error(`${TAG}: sendKeyEvent BACKSPACE failed`);
            break;
          }
        }
      }
      console.info(`${TAG}: ime veto emptying delete, sent ${trackedLen} remote backspace(s)`);
      this.imeVetoExpectedEmpty = true;
      return false;
    }
    if (trackedLen === 0 && value.deleteValue.length === 0) {
      // 空字段上的退格（若框架仍派发本回调）：远端补一个退格
      if (instance !== 0) {
        LibFreeRDP.sendKeyEvent(instance, SessionPage.VK_BACKSPACE, true);
        LibFreeRDP.sendKeyEvent(instance, SessionPage.VK_BACKSPACE, false);
      }
      console.info(`${TAG}: ime backspace on empty bridge -> remote backspace`);
      return false;
    }
    return true;
  }

  private onImeTextChanged(value: string, previewText?: PreviewText): void {
    // 否决失效兜底：若框架无视 onWillDelete 的 false 仍执行了删空操作，
    // 此处会收到空值——退格已在回调中手动补发，跳过差分防止双发
    if (value === '' && this.imeVetoExpectedEmpty) {
      console.warn(`${TAG}: ime veto ignored by framework, skip diff`);
      this.imeVetoExpectedEmpty = false;
      this.imeTrackedValue = '';
      return;
    }
    if (value !== '') {
      this.imeVetoExpectedEmpty = false;
    }
    // 全量插桩：每次 onChange 记录内容码点与组合态，用于定位组合后事件哑掉
    let codes = '';
    for (let i = 0; i < value.length && i < 32; i++) {
      codes += (i > 0 ? ',' : '') + value.charCodeAt(i);
    }
    if (previewText !== undefined) {
      console.info(`${TAG}: ime onChange len=${value.length} codes=[${codes}]` +
        ` preview(len=${previewText.value.length},off=${previewText.offset})='${previewText.value}'`);
      if (this.isCompositionPreview(value, previewText.value)) {
        this.imeLastPreview = previewText.value;
        this.imeLastComposeValue = value;
        return; // IME 组合未上屏
      }
      console.info(`${TAG}: ime preview breaks compose chain -> commit (last='${this.imeLastPreview}')`);
    } else {
      console.info(`${TAG}: ime onChange len=${value.length} codes=[${codes}] preview=<none>`);
    }
    this.imeLastPreview = '';
    this.imeLastComposeValue = '';

    const instance = this.session?.getInstance() ?? 0;
    if (instance !== 0) {
      let prefix = 0;
      const minLen = Math.min(this.imeTrackedValue.length, value.length);
      while (prefix < minLen && this.imeTrackedValue.charAt(prefix) === value.charAt(prefix)) {
        prefix++;
      }

      const deletions = this.imeTrackedValue.length - prefix;
      const inserts: number[] = [];
      for (let i = prefix; i < value.length; i++) {
        inserts.push(value.charCodeAt(i));
      }
      console.info(`${TAG}: ime diff -> del=${deletions} ins=[${inserts.join(',')}]`);

      for (let i = 0; i < deletions; i++) {
        if (!LibFreeRDP.sendKeyEvent(instance, SessionPage.VK_BACKSPACE, true) ||
          !LibFreeRDP.sendKeyEvent(instance, SessionPage.VK_BACKSPACE, false)) {
          console.error(`${TAG}: sendKeyEvent BACKSPACE failed`);
        }
      }

      for (let i = prefix; i < value.length; i++) {
        const code = value.charCodeAt(i);
        if (!LibFreeRDP.sendUnicodeKeyEvent(instance, code, true)) {
          console.error(`${TAG}: sendUnicodeKeyEvent down failed code=${code}`);
        }
        if (!LibFreeRDP.sendUnicodeKeyEvent(instance, code, false)) {
          console.error(`${TAG}: sendUnicodeKeyEvent up failed code=${code}`);
        }
      }
    } else {
      console.warn(`${TAG}: ime onChange but instance=0, len=${value.length}`);
    }

    this.imeTrackedValue = value;

    // 防极端膨胀：超限时全选旧内容，下一次输入整段替换实现软清空
    // （API 12 无 clearText；内容已同步远端，仅失去 IME 侧连续退格能力）
    if (this.imeTrackedValue.length > SessionPage.IME_BRIDGE_MAX_LEN) {
      this.imeInputController.setTextSelection(0, this.imeTrackedValue.length);
      this.imeTrackedValue = '';
    }
  }

  /**
   * 组合链判定：preview 是最近组合的自然演进（扩展/缩短/相等）或新组合
   * 起点时视为组合态跳过；空 preview 仅在全文与已同步内容（tracked）一致
   * 时跳过（组合结束信号），否则——选字上屏、退格删除到空、快捷短语
   * finalize——一律按 commit 差分同步（差分幂等，无变化时为空操作）。
   */
  private isCompositionPreview(value: string, preview: string): boolean {
    const last = this.imeLastPreview;
    if (preview === '') {
      // 判据必须是 tracked（已同步内容）而非 imeLastComposeValue：
      // 退格到空时 value=''+lastCompose='' 会被误判跳过，导致最后一词删不掉；
      // 快捷短语"组合态插入→finalize"两步都会被吞，导致快捷输入失效
      return value === this.imeTrackedValue;
    }
    if (last === '') {
      return true; // 新组合起点（英文键盘逐字母组合等）
    }
    return last === preview || last.startsWith(preview) || preview.startsWith(last);
  }

  /**
   * 横竖屏切换：竖屏→锁定横屏（按钮切换为 portrait_orientation.svg），横屏→恢复竖屏。
   */
  private async toggleFullScreen(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      if (this.isLandscape) {
        await win.setPreferredOrientation(window.Orientation.PORTRAIT);
      } else {
        await win.setPreferredOrientation(window.Orientation.LANDSCAPE);
      }
      this.isLandscape = !this.isLandscape;
      console.info(`${TAG}: toggleFullScreen -> ${this.isLandscape ? 'landscape' : 'portrait'}`);
    } catch (e) {
      console.error(`${TAG}: toggleFullScreen failed:`, e);
    }
  }

  /**
   * 按窗口实际方向初始化 isLandscape，保存进入时的方向（离开时恢复），
   * 并注册本页面作用域内的 windowSizeChange 监听：物理旋转/系统切换时自动同步横竖屏状态。
   */
  private async initOrientationState(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      const rect = win.getWindowProperties().windowRect;
      this.savedIsLandscape = rect.width > rect.height;
      this.isLandscape = this.savedIsLandscape;

      // 会话页内跟随传感器旋转（覆盖 module.json5 的全局竖屏锁定），
      // 离开页面时由 teardownOrientation 恢复进入前的方向
      await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION);

      this.windowSizeChangeCallback = (size: window.Size) => {
        const landscape = size.width > size.height;
        if (landscape !== this.isLandscape) {
          console.info(`${TAG}: windowSizeChange -> ${landscape ? 'landscape' : 'portrait'}`);
          this.isLandscape = landscape;
        }
      };
      win.on('windowSizeChange', this.windowSizeChangeCallback);

      // 系统输入法弹出/收起高度：手动开关输入法与 tap 自动判定共用
      this.keyboardHeightCallback = (height: number) => {
        if ((height > 0) !== this.imeVisible) {
          console.info(`${TAG}: keyboard height ${height} -> imeVisible=${height > 0}`);
        }
        this.imeVisible = height > 0;
        if (height === 0) {
          this.imeLastPreview = '';
          this.imeLastComposeValue = '';
        }
      };
      win.on('keyboardHeightChange', this.keyboardHeightCallback);
    } catch (e) {
      console.warn(`${TAG}: initOrientationState failed:`, e);
    }
  }

  /**
   * 页面销毁：只解除本页面注册的 windowSizeChange 监听（SDK 作用域语义），
   * 并把窗口方向恢复为进入页面时保存的方向。
   */
  private async teardownOrientation(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      if (this.windowSizeChangeCallback) {
        win.off('windowSizeChange', this.windowSizeChangeCallback);
        this.windowSizeChangeCallback = null;
      }
      if (this.keyboardHeightCallback) {
        win.off('keyboardHeightChange', this.keyboardHeightCallback);
        this.keyboardHeightCallback = null;
      }
      await win.setPreferredOrientation(this.savedIsLandscape ?
        window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT);
      console.info(`${TAG}: orientation restored to ${this.savedIsLandscape ? 'landscape' : 'portrait'}`);
    } catch (e) {
      console.warn(`${TAG}: teardownOrientation failed:`, e);
    }
  }

  /**
   * 画面右下角按钮 X（vp）：跟随当前画面（FIT=画幅区 / FILL=整屏）的可见右边界，
   * 画面缩放/平移/旋转时联动，画面超出视图时收缩到视图右缘。
   */
  private orientBtnX(): number {
    if (this.viewWidth <= 0) {
      return 0;
    }
    if (this.surfaceWidth <= 0 || this.density <= 0) {
      return this.viewWidth - SessionPage.ORIENT_BTN_MARGIN - SessionPage.ORIENT_BTN_W;
    }
    const drawSize = this.getDrawSize();
    const picRightVp = (this.panX + drawSize.width) / this.density;
    const rightVp = Math.min(picRightVp, this.viewWidth);
    return rightVp - SessionPage.ORIENT_BTN_MARGIN - SessionPage.ORIENT_BTN_W;
  }

  /**
   * 画面右下角按钮 Y（vp）：逻辑同 orientBtnX，沿画面可见下边界。
   */
  private orientBtnY(): number {
    if (this.viewHeight <= 0) {
      return 0;
    }
    if (this.surfaceHeight <= 0 || this.density <= 0) {
      return this.viewHeight - SessionPage.ORIENT_BTN_MARGIN - SessionPage.ORIENT_BTN_H;
    }
    const drawSize = this.getDrawSize();
    const picBottomVp = (this.panY + drawSize.height) / this.density;
    const bottomVp = Math.min(picBottomVp, this.viewHeight);
    return bottomVp - SessionPage.ORIENT_BTN_MARGIN - SessionPage.ORIENT_BTN_H;
  }
}
