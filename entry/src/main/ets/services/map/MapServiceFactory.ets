/**
 * 地图服务工厂
 * 使用 MapJsBridge (WebView + 高德 JSAPI v2.0)
 */
import { IMapService } from './IMapService';
import { MapJsBridge } from './MapJsBridge';

export class MapServiceFactory {
  private static instance: MapJsBridge | null = null;

  static create(): IMapService {
    if (!MapServiceFactory.instance) {
      MapServiceFactory.instance = new MapJsBridge();
    }
    return MapServiceFactory.instance;
  }

  static getInstance(): IMapService | null {
    return MapServiceFactory.instance;
  }
}
