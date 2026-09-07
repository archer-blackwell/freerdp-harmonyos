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
import { BookmarkBase } from '../model/BookmarkBase';
import { SessionState, ConnectionState, GlobalSessionManager } from '../model/SessionState';
import LibFreeRDP, { EventListener, BookmarkSettings, ScreenSettings, AdvancedSettings, PerformanceFlags, DebugSettings, GatewaySettings, PTR_FLAGS_MOVE, PTR_FLAGS_DOWN, PTR_FLAGS_BUTTON1, PTR_FLAGS_BUTTON2, DISPLAY_MODE_FIT, DISPLAY_MODE_FILL } from '../services/LibFreeRDP';
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
  private isPanning: boolean = false;
  /** 待确认的桌面 resize 请求（服务器可能丢弃 Display Control 请求，需要看护重试） */
  private pendingResizeW: number = 0;
  private pendingResizeH: number = 0;
  private resizeRetryCount: number = 0;
  private resizeRetryTimer: number = -1;
  private static readonly RESIZE_RETRY_DELAY_MS = 1500;
  private static readonly RESIZE_MAX_RETRY = 3;

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
        this.showKeyboard = !this.showKeyboard;
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
            PinchGesture({ fingers: 2 })
              .onActionStart((event: GestureEvent) => {
                this.isPinching = true;
                this.lastPinchScale = this.viewScale;
              })
              .onActionUpdate((event: GestureEvent) => {
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
            PanGesture({ fingers: 1, distance: 5 })
              .onActionStart((event: GestureEvent) => {
                this.isPanning = true;
                this.lastPanX = this.panX;
                this.lastPanY = this.panY;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.isPinching) {
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
                this.isPanning = false;
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
        Column() {
          VirtualKeyboard({
            instance: this.session?.getInstance() ?? 0
          })
        }
        .width('100%')
        .position({ x: 0, y: '100%' })
        .translate({ y: -200 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
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

  private onSessionTouch(event: TouchEvent): void {
    const instance = this.session?.getInstance() ?? 0;
    if (instance === 0) {
      return;
    }
    if (this.isPinching || this.isPanning) {
      return;
    }
    if (this.viewWidth <= 0 || this.viewHeight <= 0) {
      return;
    }

    if (event.touches.length === 1) {
      const touch = event.touches[0];
      const coord = this.screenToDesktop(touch.x, touch.y);

      switch (event.type) {
        case TouchType.Down:
          LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1);
          break;
        case TouchType.Move:
          LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_MOVE);
          break;
        case TouchType.Up:
        case TouchType.Cancel:
          LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_BUTTON1);
          break;
      }
    } else if (event.touches.length === 2 && event.type === TouchType.Down) {
      const touch = event.touches[0];
      const coord = this.screenToDesktop(touch.x, touch.y);
      LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON2);
      LibFreeRDP.sendCursorEvent(instance, coord.dx, coord.dy, PTR_FLAGS_BUTTON2);
    }
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
