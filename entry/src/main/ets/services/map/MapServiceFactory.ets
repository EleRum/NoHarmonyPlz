/**
 * 地图服务工厂（跨平台版本）
 * 统一使用 MapJsBridge (WebView + 高德 JSAPI v2.0)
 * HarmonyOS / Android 共用同一实现
 */
import { IMapService } from './IMapService';
import { MapJsBridge } from './MapJsBridge';

export class MapServiceFactory {
  private static instance: MapJsBridge | null = null;

  /** 创建或获取地图服务实例 */
  static create(): IMapService {
    if (!MapServiceFactory.instance) {
      MapServiceFactory.instance = new MapJsBridge();
    }
    return MapServiceFactory.instance;
  }

  /** 获取已创建的实例 */
  static getInstance(): IMapService | null {
    return MapServiceFactory.instance;
  }
}
