/*
 * HarmonyOS FreeRDP Service
 * 
 * ArkTS wrapper for the FreeRDP native library
 * Provides the same interface as the Android LibFreeRDP.java
 * 
 * Copyright 2026 FreeRDP HarmonyOS Port
 */

import freerdpNativeImport from 'libfreerdp_harmonyos.so';

interface FreerdpNative {
  setOnConnectionSuccess(callback: (instance: number) => void): void;
  setOnConnectionFailure(callback: (instance: number) => void): void;
  setOnPreConnect(callback: (instance: number) => void): void;
  setOnDisconnecting(callback: (instance: number) => void): void;
  setOnDisconnected(callback: (instance: number) => void): void;
  // Receives dirty-region notifications from Native after a frame snapshot is ready.
  setOnGraphicsUpdate(callback: (instance: number, x: number, y: number, width: number, height: number) => void): void;
  // 连接建立后 Native 上报实际协商的桌面分辨率（instance, width, height, bpp）。
  setOnSettingsChanged(callback: (instance: number, width: number, height: number, bpp: number) => void): void;
  // 服务器动态调整桌面分辨率时 Native 上报（instance, width, height, bpp），随 setOnSettingsChanged 复用处理器。
  setOnGraphicsResize(callback: (instance: number, width: number, height: number, bpp: number) => void): void;
  // 远端光标形态位图上报（instance, cursorType, width, height, hotspotX, hotspotY, rgba, length）。
  // rgba 为 RGBA_8888 字节序（R,G,B,A）；length == 0 表示清除自定义光标（SetNull/SetDefault）。
  setOnCursorShapeChanged(callback: (instance: number, cursorType: number, width: number, height: number, hotspotX: number, hotspotY: number, rgba: ArrayBuffer, length: number) => void): void;
  // 远端通过重定向磁盘打开文件时上报（instance, fullPath, filename），fullPath 为本地沙箱路径。
  setOnFileOpen(callback: (instance: number, fullPath: string, filename: string) => void): void;
  // 通过 Display Control 通道请求服务器调整桌面分辨率（旋转跟随）。
  freerdpRequestDesktopResize(inst: number, width: number, height: number): boolean;
  freerdpHasH264(): boolean;
  freerdpNew(): number;
  freerdpDisconnect(inst: number): boolean;
  freerdpFree(inst: number): void;
  freerdpConnect(inst: number): boolean;
  freerdpParseArguments(inst: number, args: string[]): boolean;
  freerdpSendCursorEvent(inst: number, x: number, y: number, flags: number): boolean;
  freerdpSendKeyEvent(inst: number, keycode: number, down: boolean): boolean;
  freerdpSendUnicodeKeyEvent(inst: number, keycode: number, down: boolean): boolean;
  freerdpSetTcpKeepalive(inst: number, enabled: boolean, delay: number, interval: number, retries: number): boolean;
  freerdpSendSynchronizeEvent(inst: number, flags: number): boolean;
  freerdpSendClipboardData(inst: number, data: string): boolean;
  freerdpSetClientDecoding(inst: number, enable: boolean): number;
  freerdpGetLastErrorString(inst: number): string;
  freerdpGetVersion(): string;
  freerdpEnterBackgroundMode(inst: number): boolean;
  freerdpExitBackgroundMode(inst: number): boolean;
  freerdpConfigureAudio(inst: number, playback: boolean, capture: boolean, quality: number): boolean;
  freerdpSetAutoReconnect(inst: number, enabled: boolean, maxRetries: number, delayMs: number): boolean;
  freerdpGetConnectionHealth(inst: number): number;
  freerdpRequestRefresh(inst: number): boolean;
  freerdpRequestRefreshRect(inst: number, x: number, y: number, width: number, height: number): boolean;
  freerdpIsInBackgroundMode(inst: number): boolean;
  freerdpSendKeepalive(inst: number): boolean;
  freerdpGetIdleTime(inst: number): number;
  freerdpCheckConnectionStatus(inst: number): number;
  freerdpGetFrameBuffer(inst: number): FrameBuffer | null;
  freerdpSetSurfaceId(surfaceId: string): boolean;
  freerdpReleaseSurface(): void;
  freerdpSetViewport(scale: number, offsetX: number, offsetY: number): void;
  freerdpSetDisplayMode(mode: number): boolean;
  freerdpGetDisplayMode(): number;
}

interface FrameBuffer {
  width: number;
  height: number;
  stride: number;
  buffer: ArrayBuffer;
}

let nativeLoaded = false;
let nativeInitAttempted = false;
let nativeLoadError: string | null = null;
let freerdpNative: FreerdpNative | null = null;

// 模块级监听：native 侧只注册一次，业务层通过 set/clear 接管与释放（SDK 作用域语义）
let settingsChangedCallback: ((instance: number, width: number, height: number, bpp: number) => void) | null = null;
let graphicsResizeCallback: ((instance: number, width: number, height: number, bpp: number) => void) | null = null;
let cursorShapeChangedCallback: ((instance: number, cursorType: number, width: number, height: number,
  hotspotX: number, hotspotY: number, rgba: ArrayBuffer, length: number) => void) | null = null;
let fileOpenCallback: ((instance: number, fullPath: string, filename: string) => void) | null = null;

function resolveNativeModule(): FreerdpNative | null {
  if (freerdpNative) {
    return freerdpNative;
  }

  if (freerdpNativeImport) {
    // Direct cast to FreerdpNative interface - ArkTS strict mode compatible
    freerdpNative = freerdpNativeImport as FreerdpNative;
    return freerdpNative;
  }

  return null;
}

// Display mode constants (matching C layer HARMONYOS_DISPLAY_MODE)
export const DISPLAY_MODE_FIT = 0;   // 自适应：按书签分辨率请求桌面，等比居中显示（留黑边）
export const DISPLAY_MODE_FILL = 1;  // 铺满全屏：FreeRDP Fullscreen（/f），按屏幕分辨率请求桌面，等比 1:1 铺满（不拉伸）

// Cursor type constants (matching C layer definitions)
export const CURSOR_TYPE_UNKNOWN = 0;export const CURSOR_TYPE_DEFAULT = 1;      // 默认箭头
export const CURSOR_TYPE_HAND = 2;         // 手型（链接）
export const CURSOR_TYPE_IBEAM = 3;        // I型（文本）
export const CURSOR_TYPE_SIZE_NS = 4;      // 上下双箭头（调整行高）
export const CURSOR_TYPE_SIZE_WE = 5;      // 左右双箭头（调整列宽）
export const CURSOR_TYPE_SIZE_NWSE = 6;    // 斜向双箭头（左上-右下）
export const CURSOR_TYPE_SIZE_NESW = 7;    // 斜向双箭头（右上-左下）
export const CURSOR_TYPE_CROSS = 8;        // 十字（移动）
export const CURSOR_TYPE_WAIT = 9;         // 等待（沙漏）

// Certificate verification flags
export const VERIFY_CERT_FLAG_NONE = 0x00;
export const VERIFY_CERT_FLAG_LEGACY = 0x02;
export const VERIFY_CERT_FLAG_REDIRECT = 0x10;
export const VERIFY_CERT_FLAG_GATEWAY = 0x20;
export const VERIFY_CERT_FLAG_CHANGED = 0x40;
export const VERIFY_CERT_FLAG_MISMATCH = 0x80;
export const VERIFY_CERT_FLAG_MATCH_LEGACY_SHA1 = 0x100;
export const VERIFY_CERT_FLAG_FP_IS_PEM = 0x200;

// Mouse event flags
export const PTR_FLAGS_MOVE = 0x0800;
export const PTR_FLAGS_DOWN = 0x8000;
export const PTR_FLAGS_BUTTON1 = 0x1000;  // Left button
export const PTR_FLAGS_BUTTON2 = 0x2000;  // Right button
export const PTR_FLAGS_BUTTON3 = 0x4000;  // Middle button
export const PTR_FLAGS_WHEEL = 0x0200;
export const PTR_FLAGS_WHEEL_NEGATIVE = 0x0100;
export const PTR_FLAGS_HWHEEL = 0x0400;  // 与 native freerdp/input.h 保持一致

// Event listener interface
export interface EventListener {
  OnPreConnect(instance: number): void;
  OnConnectionSuccess(instance: number): void;
  OnConnectionFailure(instance: number): void;
  OnDisconnecting(instance: number): void;
  OnDisconnected(instance: number): void;
  OnGraphicsUpdate(instance: number, x: number, y: number, width: number, height: number): void;
}

// UI event listener interface
export interface UIEventListener {
  OnSettingsChanged(width: number, height: number, bpp: number): void;
  OnAuthenticate(username: string, domain: string, password: string): boolean;
  OnGatewayAuthenticate(username: string, domain: string, password: string): boolean;
  OnVerifyCertificateEx(host: string, port: number, commonName: string, subject: string, 
                        issuer: string, fingerprint: string, flags: number): number;
  OnVerifyChangedCertificateEx(host: string, port: number, commonName: string, subject: string,
                               issuer: string, fingerprint: string, oldSubject: string,
                               oldIssuer: string, oldFingerprint: string, flags: number): number;
  OnGraphicsUpdate(x: number, y: number, width: number, height: number): void;
  OnGraphicsResize(width: number, height: number, bpp: number): void;
  OnRemoteClipboardChanged(data: string): void;
  OnCursorTypeChanged(cursorType: number): void;
}

// Bookmark settings interfaces
export interface ScreenSettings {
  width: number;
  height: number;
  colors: number;
}

export interface AdvancedSettings {
  consoleMode: boolean;
  security: number;
  remoteProgram: string;
  workDir: string;
  redirectSDCard: boolean;
  redirectSound: number;
  redirectMicrophone: boolean;
}

export interface PerformanceFlags {
  remoteFX: boolean;
  gfx: boolean;
  h264: boolean;
  wallpaper: boolean;
  fullWindowDrag: boolean;
  menuAnimations: boolean;
  theming: boolean;
  fontSmoothing: boolean;
  desktopComposition: boolean;
}

export interface DebugSettings {
  asyncChannel: boolean;
  asyncUpdate: boolean;
  debugLevel: string;
}

export interface GatewaySettings {
  enabled: boolean;
  hostname: string;
  port: number;
  username: string;
  domain: string;
  password: string;
}

export interface BookmarkSettings {
  hostname: string;
  port: number;
  username: string;
  domain: string;
  password: string;
  screenSettings: ScreenSettings;
  advancedSettings: AdvancedSettings;
  performanceFlags: PerformanceFlags;
  debugSettings: DebugSettings;
  gatewaySettings?: GatewaySettings;
}

// Instance state tracking
const instanceState: Map<number, boolean> = new Map();

// Instances pending native free after their async disconnect completes
const pendingFree: Set<number> = new Set();

// Global event listener
let eventListener: EventListener | null = null;

function freeNativeIfPending(instance: number): void {
  if (!pendingFree.has(instance)) {
    return;
  }
  pendingFree.delete(instance);
  try {
    freerdpNative!.freerdpFree(instance);
  } catch (e) {
    console.error(`[LibFreeRDP] Deferred native free failed for instance ${instance}`, e);
  }
}

// H.264 support flag
let hasH264Support: boolean = false;

// Initialize native callbacks
function initCallbacks(nativeModule: FreerdpNative): void {
  nativeModule.setOnConnectionSuccess((instance: number) => {
    console.info(`[LibFreeRDP] OnConnectionSuccess: instance=${instance}`);
    instanceState.set(instance, true);
    if (eventListener) {
      eventListener.OnConnectionSuccess(instance);
    }
  });

  nativeModule.setOnConnectionFailure((instance: number) => {
    console.error(`[LibFreeRDP] OnConnectionFailure: instance=${instance}`);
    instanceState.delete(instance);
    freeNativeIfPending(instance);
    if (eventListener) {
      eventListener.OnConnectionFailure(instance);
    }
  });

  nativeModule.setOnPreConnect((instance: number) => {
    console.info(`[LibFreeRDP] OnPreConnect: instance=${instance}`);
    if (eventListener) {
      eventListener.OnPreConnect(instance);
    }
  });

  nativeModule.setOnDisconnecting((instance: number) => {
    console.info(`[LibFreeRDP] OnDisconnecting: instance=${instance}`);
    if (eventListener) {
      eventListener.OnDisconnecting(instance);
    }
  });

  nativeModule.setOnDisconnected((instance: number) => {
    console.info(`[LibFreeRDP] OnDisconnected: instance=${instance}`);
    instanceState.delete(instance);
    freeNativeIfPending(instance);
    if (eventListener) {
      eventListener.OnDisconnected(instance);
    }
  });

  // Register this independently of the disconnect callback. Registering it
  // inside setOnDisconnected would delay graphics registration until teardown.
  nativeModule.setOnGraphicsUpdate((instance: number, x: number, y: number, width: number, height: number) => {
    console.info(`[LibFreeRDP] Graphics callback consumed: instance=${instance}`);
    if (eventListener) {
      eventListener.OnGraphicsUpdate(instance, x, y, width, height);
    }
  });

  // 实际协商桌面分辨率回调（PostConnect 时 Native 上报 settings 的 DesktopWidth/Height）
  nativeModule.setOnSettingsChanged((instance: number, width: number, height: number, bpp: number) => {
    console.info(`[LibFreeRDP] OnSettingsChanged: instance=${instance} ${width}x${height}@${bpp}`);
    if (settingsChangedCallback) {
      settingsChangedCallback(instance, width, height, bpp);
    }
  });

  // 服务器动态 resize 桌面（Display Control）时上报新尺寸
  nativeModule.setOnGraphicsResize((instance: number, width: number, height: number, bpp: number) => {
    console.info(`[LibFreeRDP] OnGraphicsResize: instance=${instance} ${width}x${height}@${bpp}`);
    if (graphicsResizeCallback) {
      graphicsResizeCallback(instance, width, height, bpp);
    }
  });

  // 远端光标形态位图（含热点）；length == 0 表示清除自定义光标叠加层
  nativeModule.setOnCursorShapeChanged((instance: number, cursorType: number, width: number,
    height: number, hotspotX: number, hotspotY: number, rgba: ArrayBuffer, length: number) => {
    if (cursorShapeChangedCallback) {
      cursorShapeChangedCallback(instance, cursorType, width, height, hotspotX, hotspotY, rgba, length);
    }
  });

  // 远端在重定向磁盘上打开文件（如资源管理器双击）
  nativeModule.setOnFileOpen((instance: number, fullPath: string, filename: string) => {
    console.info(`[LibFreeRDP] OnFileOpen: instance=${instance} file=${fullPath}`);
    if (fileOpenCallback) {
      fileOpenCallback(instance, fullPath, filename);
    }
  });

  // Check H.264 support
  hasH264Support = nativeModule.freerdpHasH264();
  console.info(`[LibFreeRDP] H.264 support: ${hasH264Support}`);
}

function ensureNativeLoaded(): boolean {
  if (nativeLoaded) {
    return true;
  }
  if (nativeInitAttempted) {
    return false;
  }
  nativeInitAttempted = true;
  try {
    const nativeModule = resolveNativeModule();
    if (!nativeModule) {
      throw new Error(nativeLoadError ?? 'Native module is undefined');
    }
    if (typeof nativeModule.setOnConnectionSuccess !== 'function') {
      throw new Error('Native module exports are missing');
    }
    freerdpNative = nativeModule;
    initCallbacks(nativeModule);
    nativeLoaded = true;
  } catch (e) {
    nativeLoadError = e instanceof Error ? e.message : String(e);
  }
  return nativeLoaded;
}

export class LibFreeRDP {
  private static TAG = 'LibFreeRDP';

  /**
   * Check if H.264 is supported
   */
  static hasH264Support(): boolean {
    if (!ensureNativeLoaded()) {
      return false;
    }
    return hasH264Support;
  }

  /**
   * Check if native module is loaded
   */
  static isNativeLoaded(): boolean {
    return ensureNativeLoaded();
  }

  /**
   * Get native module load error
   */
  static getLoadError(): string | null {
    ensureNativeLoaded();
    return nativeLoadError;
  }

  private static ensureNativeReady(): boolean {
    if (ensureNativeLoaded()) {
      return true;
    }
    console.error(`${LibFreeRDP.TAG}: Native library not loaded: ${nativeLoadError ?? 'unknown'}`);
    return false;
  }

  /**
   * Set the event listener
   */
  static setEventListener(listener: EventListener): void {
    eventListener = listener;
  }

  /**
   * Create a new FreeRDP instance
   */
  static newInstance(): number {
    if (!LibFreeRDP.ensureNativeReady()) {
      return 0;
    }
    const instance: number = freerdpNative!.freerdpNew();
    console.info(`${LibFreeRDP.TAG}: newInstance() = ${instance}`);
    return instance;
  }

  /**
   * Free a FreeRDP instance
   */
  static freeInstance(inst: number): void {
    if (!LibFreeRDP.ensureNativeReady()) {
      return;
    }
    console.info(`${LibFreeRDP.TAG}: freeInstance(${inst})`);

    if (instanceState.get(inst)) {
      // Still connected: initiate an async disconnect. The native instance is
      // freed in the disconnect callback (which runs on this same main thread)
      // after the native worker thread has fully stopped. Do NOT busy-wait here:
      // the disconnect callback must run on the main thread, so a synchronous
      // wait would deadlock and freeze the UI (THREAD_BLOCK / ANR).
      pendingFree.add(inst);
      try {
        freerdpNative!.freerdpDisconnect(inst);
      } catch (e) {
        console.error(`${LibFreeRDP.TAG}: Failed to disconnect instance ${inst}`, e);
        pendingFree.delete(inst);
        instanceState.delete(inst);
      }
      return;
    }

    // Not connected: free immediately.
    try {
      freerdpNative!.freerdpFree(inst);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: Failed to free instance ${inst}`, e);
    }
    instanceState.delete(inst);
  }

  /**
   * Connect to a remote desktop
   */
  static connect(inst: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (instanceState.get(inst)) {
      throw new Error('Instance already connected');
    }
    return freerdpNative!.freerdpConnect(inst);
  }

  /**
   * Disconnect from a remote desktop
   */
  static disconnect(inst: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (instanceState.get(inst)) {
      return freerdpNative!.freerdpDisconnect(inst);
    }
    return true;
  }

  /**
   * Cancel an ongoing connection
   */
  static cancelConnection(inst: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (instanceState.get(inst)) {
      return freerdpNative!.freerdpDisconnect(inst);
    }
    return true;
  }

  /**
   * Set connection info from bookmark settings
   */
  static setConnectionInfo(inst: number, bookmark: BookmarkSettings, clientName: string = '',
    isFullscreen: boolean = false): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    const args: string[] = [];
    
    args.push('FreeRDP');
    args.push('/gdi:sw');
    
    if (clientName) {
      args.push(`/client-hostname:${clientName}`);
    }
    
    // Host and port
    args.push(`/v:${bookmark.hostname}`);
    args.push(`/port:${bookmark.port}`);
    
    // Credentials
    if (bookmark.username) {
      args.push(`/u:${bookmark.username}`);
    }
    if (bookmark.domain) {
      args.push(`/d:${bookmark.domain}`);
    }
    if (bookmark.password) {
      args.push(`/p:${bookmark.password}`);
    }
    
    // Screen settings
    if (isFullscreen) {
      // 全屏模式：FreeRDP Fullscreen（/f，等价安卓侧 isFullscreen=true）；
      // 配合业务层按屏幕分辨率下发的 /size，服务器返回与屏幕一致的桌面，等比 1:1 铺满（不拉伸）
      args.push('/f');
      // 启用 Display Control 动态分辨率：旋转/方向切换时业务层可请求服务器 resize 桌面保持铺满
      args.push('/dynamic-resolution');
    }
    args.push(`/size:${bookmark.screenSettings.width}x${bookmark.screenSettings.height}`); // 桌面分辨率（全屏模式=屏幕分辨率）
    args.push(`/bpp:${bookmark.screenSettings.colors}`);
    
    // Advanced settings
    if (bookmark.advancedSettings.consoleMode) {
      args.push('/admin');
    }
    
    switch (bookmark.advancedSettings.security) {
      case 3: args.push('/sec:nla'); break;
      case 2: args.push('/sec:tls'); break;
      case 1: args.push('/sec:rdp'); break;
    }
    
    // Performance flags
    const perf = bookmark.performanceFlags;
    if (perf.remoteFX) {
      args.push('/rfx');
      args.push('/network:auto');
    }
    if (perf.gfx) {
      args.push('/gfx');
      args.push('/network:auto');
    }
    if (perf.h264 && hasH264Support) {
      args.push('/gfx:AVC444');
      args.push('/network:auto');
    }
    
    args.push(perf.wallpaper ? '+wallpaper' : '-wallpaper');
    args.push(perf.fullWindowDrag ? '+window-drag' : '-window-drag');
    args.push(perf.menuAnimations ? '+menu-anims' : '-menu-anims');
    args.push(perf.theming ? '+themes' : '-themes');
    args.push(perf.fontSmoothing ? '+fonts' : '-fonts');
    args.push(perf.desktopComposition ? '+aero' : '-aero');
    
    // Mouse motion
    args.push('+mouse-motion');
    
    // Remote program
    if (bookmark.advancedSettings.remoteProgram) {
      args.push(`/shell:${bookmark.advancedSettings.remoteProgram}`);
    }
    if (bookmark.advancedSettings.workDir) {
      args.push(`/shell-dir:${bookmark.advancedSettings.workDir}`);
    }
    
    // Debug settings
    args.push(bookmark.debugSettings.asyncChannel ? '+async-channels' : '-async-channels');
    args.push(bookmark.debugSettings.asyncUpdate ? '+async-update' : '-async-update');
    
    // SD Card redirect
    if (bookmark.advancedSettings.redirectSDCard) {
      // TODO: Get proper storage path for HarmonyOS
      args.push('/drive:sdcard,/data/storage');
    }
    
    // Clipboard
    args.push('/clipboard');
    
    // Gateway settings
    if (bookmark.gatewaySettings?.enabled) {
      const gw = bookmark.gatewaySettings;
      let gwArg = `/gateway:g:${gw.hostname}:${gw.port}`;
      if (gw.username) gwArg += `,u:${gw.username}`;
      if (gw.domain) gwArg += `,d:${gw.domain}`;
      if (gw.password) gwArg += `,p:${gw.password}`;
      args.push(gwArg);
    }
    
    // Audio
    args.push(`/audio-mode:${bookmark.advancedSettings.redirectSound}`);
    if (bookmark.advancedSettings.redirectSound === 0) {
      args.push('/sound:latency:150,quality:medium');
    }
    
    if (bookmark.advancedSettings.redirectMicrophone) {
      args.push('/microphone');
    }
    
    // Keyboard and certificate
    args.push('/kbd:unicode:on');
    args.push('/cert:ignore');
    args.push(`/log-level:${bookmark.debugSettings.debugLevel}`);
    
    // Parse arguments
    if (!freerdpNative!.freerdpParseArguments(inst, args)) {
      return false;
    }
    
    // Enable TCP keepalive (15s interval for NAT traversal)
    const tcpKeepaliveResult = LibFreeRDP.setTcpKeepalive(inst, true, 15, 15, 3);
    if (tcpKeepaliveResult) {
      console.info(`${LibFreeRDP.TAG}: TCP Keepalive enabled: 15s interval (NAT-friendly)`);
    } else {
      console.error(`${LibFreeRDP.TAG}: Failed to enable TCP keepalive!`);
    }
    
    return true;
  }

  /**
   * Send a cursor/mouse event
   */
  static sendCursorEvent(inst: number, x: number, y: number, flags: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (inst === 0) {
      return false;
    }
    return freerdpNative!.freerdpSendCursorEvent(inst, x, y, flags);
  }

  /**
   * Send a key event
   */
  static sendKeyEvent(inst: number, keycode: number, down: boolean): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    return freerdpNative!.freerdpSendKeyEvent(inst, keycode, down);
  }

  /**
   * Send a Unicode key event
   */
  static sendUnicodeKeyEvent(inst: number, keycode: number, down: boolean): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    return freerdpNative!.freerdpSendUnicodeKeyEvent(inst, keycode, down);
  }

  /**
   * Set TCP Keepalive settings (must be called before connect)
   */
  static setTcpKeepalive(inst: number, enabled: boolean, delay: number, interval: number, retries: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    return freerdpNative!.freerdpSetTcpKeepalive(inst, enabled, delay, interval, retries);
  }

  /**
   * Send a synchronize event (used for heartbeat)
   */
  static sendSynchronizeEvent(inst: number, flags: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    return freerdpNative!.freerdpSendSynchronizeEvent(inst, flags);
  }

  /**
   * Send a heartbeat (using Synchronize Event)
   */
  static sendHeartbeat(inst: number): boolean {
    return LibFreeRDP.sendSynchronizeEvent(inst, 0);
  }

  /**
   * Send clipboard data
   */
  static sendClipboardData(inst: number, data: string): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    return freerdpNative!.freerdpSendClipboardData(inst, data);
  }

  /**
   * Set client decoding (for background mode)
   * When disabled, stops receiving graphics updates but keeps audio
   */
  static setClientDecoding(inst: number, enable: boolean): number {
    if (!LibFreeRDP.ensureNativeReady()) {
      return 0;
    }
    return freerdpNative!.freerdpSetClientDecoding(inst, enable);
  }

  /**
   * Get the last error string
   */
  static getLastErrorString(inst: number): string {
    if (!LibFreeRDP.ensureNativeReady()) {
      return 'native library not loaded';
    }
    return freerdpNative!.freerdpGetLastErrorString(inst);
  }

  /**
   * Get FreeRDP version
   */
  static getVersion(): string {
    if (!LibFreeRDP.ensureNativeReady()) {
      return 'unknown';
    }
    return freerdpNative!.freerdpGetVersion();
  }

  /**
   * Check if an instance is connected
   */
  static isInstanceConnected(inst: number): boolean {
    return instanceState.get(inst) ?? false;
  }

  /**
   * Get the count of active connections
   */
  static getActiveConnectionCount(): number {
    return instanceState.size;
  }

  /**
   * Check if instance is alive with timeout verification
   */
  static isInstanceAliveWithTimeout(inst: number, timeoutMs: number): boolean {
    if (!LibFreeRDP.isInstanceConnected(inst)) {
      return false;
    }
    // TODO: Add heartbeat verification
    return true;
  }

  // ==================== Background Mode & Audio Priority ====================

  /**
   * Enter background mode (stop graphics, continue audio)
   * Use when app goes to background or screen is locked
   */
  static enterBackgroundMode(inst: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (inst === 0) {
      return false;
    }
    try {
      return freerdpNative!.freerdpEnterBackgroundMode(inst);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: enterBackgroundMode error:`, e);
      return false;
    }
  }

  /**
   * Exit background mode (resume graphics)
   * Use when app comes to foreground or screen is unlocked
   */
  static exitBackgroundMode(inst: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (inst === 0) {
      return false;
    }
    try {
      return freerdpNative!.freerdpExitBackgroundMode(inst);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: exitBackgroundMode error:`, e);
      return false;
    }
  }

  /**
   * Configure audio settings
   * @param playback Enable audio playback
   * @param capture Enable audio capture (microphone)
   * @param quality Audio quality: 0=dynamic, 1=medium, 2=high
   */
  static configureAudio(inst: number, playback: boolean, capture: boolean, quality: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (inst === 0) {
      return false;
    }
    try {
      return freerdpNative!.freerdpConfigureAudio(inst, playback, capture, quality);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: configureAudio error:`, e);
      return false;
    }
  }

  /**
   * Configure auto-reconnect settings
   * @param enabled Enable auto-reconnect
   * @param maxRetries Maximum reconnect attempts
   * @param delayMs Initial delay between attempts
   */
  static setAutoReconnect(inst: number, enabled: boolean, maxRetries: number, delayMs: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (inst === 0) {
      return false;
    }
    try {
      return freerdpNative!.freerdpSetAutoReconnect(inst, enabled, maxRetries, delayMs);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: setAutoReconnect error:`, e);
      return false;
    }
  }

  /**
   * Get connection health status
   * Returns: -1=invalid, 0=disconnected, 1=degraded, 2=healthy
   */
  static getConnectionHealth(inst: number): number {
    if (!LibFreeRDP.ensureNativeReady()) {
      return -1;
    }
    if (inst === 0) {
      return -1;
    }
    try {
      return freerdpNative!.freerdpGetConnectionHealth(inst);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: getConnectionHealth error:`, e);
      return -1;
    }
  }

  // ==================== Screen Refresh ====================

  /**
   * Request full screen refresh
   * Use after unlock/foreground to prevent static screen
   */
  static requestRefresh(inst: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (inst === 0) {
      return false;
    }
    try {
      return freerdpNative!.freerdpRequestRefresh(inst);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: requestRefresh error:`, e);
      return false;
    }
  }

  /**
   * Request partial screen refresh for specific area
   */
  static requestRefreshRect(inst: number, x: number, y: number, width: number, height: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (inst === 0) {
      return false;
    }
    try {
      return freerdpNative!.freerdpRequestRefreshRect(inst, x, y, width, height);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: requestRefreshRect error:`, e);
      return false;
    }
  }

  // ==================== Connection Stability ====================

  /**
   * Check if in background mode
   */
  static isInBackgroundMode(inst: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (inst === 0) {
      return false;
    }
    try {
      return freerdpNative!.freerdpIsInBackgroundMode(inst);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: isInBackgroundMode error:`, e);
      return false;
    }
  }

  /**
   * Send keepalive to maintain connection
   */
  static sendKeepalive(inst: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    if (inst === 0) {
      return false;
    }
    try {
      return freerdpNative!.freerdpSendKeepalive(inst);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: sendKeepalive error:`, e);
      return false;
    }
  }

  /**
   * Get idle time since last network activity (milliseconds)
   */
  static getIdleTime(inst: number): number {
    if (!LibFreeRDP.ensureNativeReady()) {
      return 0;
    }
    if (inst === 0) {
      return 0;
    }
    try {
      return freerdpNative!.freerdpGetIdleTime(inst);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: getIdleTime error:`, e);
      return 0;
    }
  }

  /**
   * Check detailed connection status
   * Returns: -1=invalid, 0=disconnecting, 1=network_timeout, 2=event_failed, 10=background, 100=foreground
   */
  static checkConnectionStatus(inst: number): number {
    if (!LibFreeRDP.ensureNativeReady()) {
      return -1;
    }
    if (inst === 0) {
      return -1;
    }
    try {
      return freerdpNative!.freerdpCheckConnectionStatus(inst);
    } catch (e) {
      console.error(`${LibFreeRDP.TAG}: checkConnectionStatus error:`, e);
      return -1;
    }
  }

  static getFrameBuffer(inst: number): FrameBuffer | null {
    if (!LibFreeRDP.ensureNativeReady()) {
      return null;
    }
    return freerdpNative!.freerdpGetFrameBuffer(inst);
  }

  static setSurfaceId(surfaceId: string): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    return freerdpNative!.freerdpSetSurfaceId(surfaceId);
  }

  static releaseSurface(): void {
    if (LibFreeRDP.ensureNativeReady()) {
      freerdpNative!.freerdpReleaseSurface();
    }
  }

  /**
   * Set the render viewport transform.
   * FIT 模式: scale = 绝对缩放比，offset 为画面左上角在 Surface 中的像素偏移。
   * FILL 模式: scale = 相对铺满基准的缩放系数（1.0 = 正好铺满），offset 为平移像素偏移。
   */
  static setViewport(scale: number, offsetX: number, offsetY: number): void {
    if (!LibFreeRDP.ensureNativeReady()) {
      return;
    }
    freerdpNative!.freerdpSetViewport(scale, offsetX, offsetY);
  }

  /**
   * Set the native renderer display mode.
   * mode: DISPLAY_MODE_FIT (0) = 自适应居中；DISPLAY_MODE_FILL (1) = 铺满整屏。
   * 两种模式下捏合缩放/平移均可用。
   */
  static setDisplayMode(mode: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    return freerdpNative!.freerdpSetDisplayMode(mode);
  }

  /**
   * Get the current native renderer display mode (0 = FIT, 1 = FILL).
   */
  static getDisplayMode(): number {
    if (!LibFreeRDP.ensureNativeReady()) {
      return DISPLAY_MODE_FIT;
    }
    return freerdpNative!.freerdpGetDisplayMode();
  }

  /**
   * 注册"实际协商桌面分辨率"监听（连接建立时 Native 上报一次）。
   * 回调携带 instance，业务层需自行过滤当前会话；重复注册会覆盖前一个。
   */
  static setOnSettingsChanged(callback: (instance: number, width: number, height: number,
    bpp: number) => void): void {
    settingsChangedCallback = callback;
  }

  /**
   * 释放"实际协商桌面分辨率"监听（只清除本模块作用域内的回调，页面销毁时调用）。
   */
  static clearOnSettingsChanged(): void {
    settingsChangedCallback = null;
  }

  /**
   * 注册"服务器动态 resize 桌面"监听；重复注册会覆盖前一个。
   */
  static setOnGraphicsResize(callback: (instance: number, width: number, height: number,
    bpp: number) => void): void {
    graphicsResizeCallback = callback;
  }

  /**
   * 释放"服务器动态 resize 桌面"监听（页面销毁时调用）。
   */
  static clearOnGraphicsResize(): void {
    graphicsResizeCallback = null;
  }

  /**
   * 注册"远端光标形态位图"监听；重复注册会覆盖前一个。
   * rgba 为 RGBA_8888 字节序；length == 0 表示清除自定义光标叠加层。
   */
  static setOnCursorShapeChanged(callback: (instance: number, cursorType: number, width: number,
    height: number, hotspotX: number, hotspotY: number, rgba: ArrayBuffer, length: number) => void): void {
    cursorShapeChangedCallback = callback;
  }

  /**
   * 释放"远端光标形态位图"监听（页面销毁时调用）。
   */
  static clearOnCursorShapeChanged(): void {
    cursorShapeChangedCallback = null;
  }

  /**
   * 注册"远端打开重定向磁盘文件"监听；重复注册会覆盖前一个。
   */
  static setOnFileOpen(callback: (instance: number, fullPath: string, filename: string) => void): void {
    fileOpenCallback = callback;
  }

  /**
   * 释放"远端打开重定向磁盘文件"监听（页面销毁时调用）。
   */
  static clearOnFileOpen(): void {
    fileOpenCallback = null;
  }

  /**
   * 请求服务器调整桌面分辨率（Display Control 通道，需连接时启用 /dynamic-resolution）。
   * 返回 false 表示通道不可用或服务器拒绝（业务层保持 letterbox 兜底）。
   */
  static requestDesktopResize(inst: number, width: number, height: number): boolean {
    if (!LibFreeRDP.ensureNativeReady()) {
      return false;
    }
    return freerdpNative!.freerdpRequestDesktopResize(inst, width, height);
  }
}

export default LibFreeRDP;
