/**
 * 跨平台桥接中心
 * ─────────────────────────────────────
 * HarmonyOS → 原生 @kit.* 实现
 * Android   → ArkUI-X 自动映射 @kit.* → Android API
 *             仅 photo 使用 AndroidPhotoAccess（无映射）
 *
 * ArkUI-X API 映射关系：
 *   @kit.ArkData       → Android SQLite
 *   @kit.NetworkKit    → Android OkHttp
 *   @kit.LocationKit   → Android LocationManager
 *   @kit.ArkWeb        → Android WebView
 *   @kit.AbilityKit    → Android Activity
 *   @kit.MediaLibraryKit → ❌ 无映射（需单独实现）
 */
import { common } from '@kit.AbilityKit';
import { IDatabase } from './database/IDatabase';
import { HarmonyDatabase } from './database/HarmonyDatabase';
import { INetworkProvider } from './network/INetworkProvider';
import { HarmonyNetworkProvider } from './network/HarmonyNetworkProvider';
import { ILocationProvider } from './location/ILocationProvider';
import { HarmonyLocationProvider } from './location/HarmonyLocationProvider';
import { IPhotoAccess } from './photo/IPhotoAccess';
import { HarmonyPhotoAccess } from './photo/HarmonyPhotoAccess';
import { AndroidPhotoAccess } from './photo/AndroidPhotoAccess';

export enum PlatformType {
  HARMONYOS = 'harmonyos',
  ANDROID = 'android'
}

export class PlatformBridge {
  private static instance: PlatformBridge | null = null;

  private _database: IDatabase | null = null;
  private _network: INetworkProvider | null = null;
  private _location: ILocationProvider | null = null;
  private _photo: IPhotoAccess | null = null;
  private _platformType: PlatformType = PlatformType.HARMONYOS;
  private _initialized: boolean = false;

  static getInstance(): PlatformBridge {
    if (!PlatformBridge.instance) {
      PlatformBridge.instance = new PlatformBridge();
    }
    return PlatformBridge.instance;
  }

  get platformType(): PlatformType { return this._platformType; }
  get isHarmonyOS(): boolean { return this._platformType === PlatformType.HARMONYOS; }
  get isAndroid(): boolean { return this._platformType === PlatformType.ANDROID; }

  get database(): IDatabase {
    if (!this._database) throw new Error('PlatformBridge not initialized');
    return this._database;
  }
  get network(): INetworkProvider {
    if (!this._network) throw new Error('PlatformBridge not initialized');
    return this._network;
  }
  get location(): ILocationProvider {
    if (!this._location) throw new Error('PlatformBridge not initialized');
    return this._location;
  }
  get photo(): IPhotoAccess {
    if (!this._photo) throw new Error('PlatformBridge not initialized');
    return this._photo;
  }
  get initialized(): boolean { return this._initialized; }

  async initialize(context: common.Context): Promise<void> {
    if (this._initialized) return;

    this._platformType = PlatformBridge.detectPlatform();

    // 数据库、网络、定位 — Harmony 实现在两个平台都可用
    // (Android 侧由 ArkUI-X 自动映射 @kit.* → Android API)
    this._database = new HarmonyDatabase(context);
    this._network = new HarmonyNetworkProvider();
    this._location = new HarmonyLocationProvider();

    // 相册 — Android 侧 @kit.MediaLibraryKit 无映射，需单独实现
    if (this._platformType === PlatformType.ANDROID) {
      this._photo = new AndroidPhotoAccess();
    } else {
      this._photo = new HarmonyPhotoAccess(context);
    }

    this._initialized = true;
  }

  private static detectPlatform(): PlatformType {
    // 默认 HarmonyOS
    // Android (ArkUI-X) 环境下通过模块编译时条件或运行时检测区分
    return PlatformType.HARMONYOS;
  }
}
