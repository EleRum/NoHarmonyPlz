/**
 * POI 搜索服务（跨平台版本）
 * 通过 MapJsBridge 调用高德 JSAPI PlaceSearch / Geocoder
 * 替代原 @amap/amap_lbs_search 原生 SDK
 */
import { Logger } from '../../common/Logger';
import { PoiResult, GeocodeResult, LatLng, NearbyPoi } from './MapTypes';
import { IMapService } from './IMapService';
import { MapServiceFactory } from './MapServiceFactory';

const TAG = 'AmapSearch';

export class AmapSearchService {
  private static instance: AmapSearchService | null = null;
  private mapService: IMapService | null = null;
  private searchResolve: ((pois: PoiResult[]) => void) | null = null;
  private geocodeResolve: ((result: GeocodeResult | null) => void) | null = null;

  static getInstance(): AmapSearchService {
    if (!AmapSearchService.instance) {
      AmapSearchService.instance = new AmapSearchService();
    }
    return AmapSearchService.instance;
  }

  /** 设置地图服务引用 */
  setMapService(service: IMapService): void {
    this.mapService = service;
    service.setEventCallbacks({
      onSearchResult: (pois: PoiResult[]) => {
        if (this.searchResolve) {
          const resolve = this.searchResolve;
          this.searchResolve = null;
          resolve(pois);
        }
      },
      onGeocodeResult: (result: GeocodeResult | null) => {
        if (this.geocodeResolve) {
          const resolve = this.geocodeResolve;
          this.geocodeResolve = null;
          resolve(result);
        }
      }
    });
  }

  /**
   * 周边搜索（Promise 封装）
   */
  async nearbySearch(
    keywords: string,
    latitude: number,
    longitude: number,
    radius: number = 3000
  ): Promise<PoiResult[]> {
    if (!this.mapService) {
      Logger.warn(TAG, 'Map service not available for search');
      return [];
    }

    return new Promise<PoiResult[]>((resolve) => {
      const timeout = setTimeout(() => {
        if (this.searchResolve) {
          this.searchResolve = null;
          resolve([]);
        }
      }, 10000);

      this.searchResolve = (pois: PoiResult[]) => {
        clearTimeout(timeout);
        resolve(pois);
      };

      this.mapService!.searchNearby(
        keywords,
        { latitude: latitude, longitude: longitude },
        radius
      );
    });
  }

  /**
   * 反向查找最近地点名称
   */
  async lookupNearestPlace(latitude: number, longitude: number): Promise<string> {
    if (!this.mapService) {
      return '';
    }

    return new Promise<string>((resolve) => {
      const timeout = setTimeout(() => {
        if (this.geocodeResolve) {
          this.geocodeResolve = null;
          resolve('');
        }
      }, 10000);

      this.geocodeResolve = (result: GeocodeResult | null) => {
        clearTimeout(timeout);
        if (result && result.nearbyPois && result.nearbyPois.length > 0) {
          resolve(this.pickBestPlaceName(result.nearbyPois));
        } else {
          resolve('');
        }
      };

      this.mapService!.lookupNearestPlace({ latitude: latitude, longitude: longitude });
    });
  }

  /**
   * 从 POI 列表中选择最佳地名（过滤通用名）
   */
  private pickBestPlaceName(pois: NearbyPoi[]): string {
    const blacklist: string[] = ['路口', '停车场', '公交站', '地铁站', '收费站', '服务区', '加油站', '充电站'];
    for (const p of pois) {
      if (!p.name || p.name.length === 0) continue;
      let blocked: boolean = false;
      for (const b of blacklist) {
        if (p.name.includes(b)) { blocked = true; break; }
      }
      if (!blocked) return p.name;
    }
    return pois[0]?.name || '';
  }
}
