/**
 * POI 搜索服务（跨平台版本）
 * 通过 MapJsBridge 调用高德 JSAPI PlaceSearch / Geocoder
 * 也支持 REST API 直连（不依赖 WebView JS Bridge）
 */
import { Logger } from '../../common/Logger';
import { PoiResult, GeocodeResult, LatLng, NearbyPoi, NavRoute, NavStep, DirectionMode } from './MapTypes';
import { IMapService } from './IMapService';
import { MapServiceFactory } from './MapServiceFactory';
import { PlatformBridge } from '../../platform/PlatformBridge';

const TAG = 'AmapSearch';
const AMAP_KEY: string = 'bb0c1640992e6c7f2b1467498d8ae848';

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
   * 周边搜索（Promise 封装，通过 JS Bridge）
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
   * 反向查找最近地点名称（通过 JS Bridge）
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
   * 周边搜索（REST API 直连，绕过 JS Bridge，保证可用）
   */
  async nearbySearchRest(
    keywords: string,
    latitude: number,
    longitude: number,
    radius: number = 10000
  ): Promise<PoiResult[]> {
    const url: string =
      `https://restapi.amap.com/v3/place/around?key=${AMAP_KEY}` +
      `&location=${longitude},${latitude}&radius=${radius}` +
      `&keywords=${encodeURIComponent(keywords)}&offset=20`;

    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp = await bridge.network.request(url, { method: 'GET' });
      if (resp.responseCode === 200 && resp.result) {
        const json = JSON.parse(resp.result) as Record<string, Object>;
        const statusStr: string = json['status'] as string ?? '0';
        if (statusStr === '1' && json['pois']) {
          const poisRaw: Object[] = json['pois'] as Object[];
          const results: PoiResult[] = [];
          for (let i: number = 0; i < poisRaw.length; i++) {
            const poi = poisRaw[i] as Record<string, Object>;
            const locStr: string = (poi['location'] as string) ?? '';
            const locParts: string[] = locStr.split(',');
            const distStr: string = (poi['distance'] as string) ?? '0';
            const distNum: number = parseInt(distStr);
            results.push({
              name: (poi['name'] as string) ?? '',
              type: (poi['type'] as string) ?? '',
              latitude: locParts.length === 2 ? parseFloat(locParts[1]) : 0,
              longitude: locParts.length === 2 ? parseFloat(locParts[0]) : 0,
              address: (poi['address'] as string) ?? '',
              distance: isNaN(distNum) ? 0 : distNum,
              tel: (poi['tel'] as string) ?? '',
              id: (poi['id'] as string) ?? '',
            } as PoiResult);
          }
          Logger.info(TAG, 'REST search OK: %{public}d results', results.length);
          return results;
        }
      }
      Logger.warn(TAG, 'REST search failed: responseCode=%{public}d', resp.responseCode);
    } catch (e) {
      Logger.warn(TAG, 'REST search exception');
    }
    return [];
  }

  /**
   * 逆地理编码（REST API 直连）
   */
  async lookupNearestPlaceRest(latitude: number, longitude: number): Promise<string> {
    const url: string =
      `https://restapi.amap.com/v3/geocode/regeo?key=${AMAP_KEY}` +
      `&location=${longitude},${latitude}&extensions=all&radius=200`;

    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp = await bridge.network.request(url, { method: 'GET' });
      if (resp.responseCode === 200 && resp.result) {
        const json = JSON.parse(resp.result) as Record<string, Object>;
        const statusStr: string = json['status'] as string ?? '0';
        if (statusStr === '1') {
          const regeo = json['regeocode'] as Record<string, Object>;
          if (regeo) {
            const pois: Object[] = (regeo['pois'] as Object[]) ?? [];
            const nearbyPois: NearbyPoi[] = [];
            for (let i: number = 0; i < pois.length; i++) {
              const poi = pois[i] as Record<string, Object>;
              const distStr: string = (poi['distance'] as string) ?? '0';
              const distNum: number = parseInt(distStr);
              nearbyPois.push({
                name: (poi['name'] as string) ?? '',
                type: (poi['type'] as string) ?? '',
                direction: (poi['direction'] as string) ?? '',
                distance: isNaN(distNum) ? 0 : distNum,
              });
            }
            return this.pickBestPlaceName(nearbyPois);
          }
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'REST geocode exception');
    }
    return '';
  }

  /**
   * 导航路线计算（REST API 直连，绕过 JS Bridge）
   */
  async directionRouteRest(
    fromLat: number, fromLng: number,
    toLat: number, toLng: number,
    mode: DirectionMode
  ): Promise<NavRoute | null> {
    let type: string = 'driving';
    if (mode === DirectionMode.WALKING) type = 'walking';
    else if (mode === DirectionMode.TRANSIT) type = 'transit/integrated';
    else if (mode === DirectionMode.BICYCLING) type = 'bicycling';

    const origin: string = `${fromLng},${fromLat}`;
    const dest: string = `${toLng},${toLat}`;
    let url: string =
      `https://restapi.amap.com/v3/direction/${type}?key=${AMAP_KEY}` +
      `&origin=${origin}&destination=${dest}&extensions=all`;

    // 公交需要 city 参数
    if (mode === DirectionMode.TRANSIT) {
      url += `&city=北京`;
    }

    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp = await bridge.network.request(url, { method: 'GET' });
      if (resp.responseCode === 200 && resp.result) {
        const json = JSON.parse(resp.result) as Record<string, Object>;
        const statusStr: string = json['status'] as string ?? '0';
        if (statusStr === '1') {
          const routeData = json['route'] as Record<string, Object>;
          if (routeData) {
            // 公共交通返回的是 transits，其它是 paths
            let paths: Object[] | null = null;
            if (mode === DirectionMode.TRANSIT) {
              paths = routeData['transits'] as Object[] ?? null;
            } else {
              paths = routeData['paths'] as Object[] ?? null;
            }
            if (paths && paths.length > 0) {
              const best = paths[0] as Record<string, Object>;
              return this.parseAmapRoute(best, mode);
            }
          }
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'REST direction exception');
    }
    return null;
  }

  /**
   * 解析高德 REST API 路线 JSON 为 NavRoute
   */
  private parseAmapRoute(route: Record<string, Object>, mode: DirectionMode): NavRoute {
    const distance: number = parseInt((route['distance'] as string) ?? '0');
    const duration: number = parseInt((route['duration'] as string) ?? '0');

    // 解析步骤
    const stepsRaw: Object[] = (route['steps'] as Object[]) ?? [];
    const steps: NavStep[] = [];
    const fullPath: LatLng[] = [];

    for (let i: number = 0; i < stepsRaw.length; i++) {
      const s = stepsRaw[i] as Record<string, Object>;
      const polyline: string = (s['polyline'] as string) ?? '';
      const stepPath: LatLng[] = this.parsePolyline(polyline);
      for (const pt of stepPath) fullPath.push(pt);

      const stepDistStr: string = (s['distance'] as string) ?? '0';
      const stepDurStr: string = (s['duration'] as string) ?? '0';
      steps.push({
        instruction: (s['instruction'] as string) ?? '',
        road: (s['road'] as string) ?? '',
        distance: parseInt(stepDistStr),
        duration: parseInt(stepDurStr),
        orientation: (s['orientation'] as string) ?? '',
        action: (s['action'] as string) ?? '',
        path: stepPath,
      } as NavStep);
    }

    return {
      distance: isNaN(distance) ? 0 : distance,
      duration: isNaN(duration) ? 0 : duration,
      path: fullPath,
      steps: steps,
      origin: '',
      destination: '',
    } as NavRoute;
  }

  /**
   * 解析 polyline 字符串 "lng,lat;lng,lat;..." 为 LatLng[]
   */
  private parsePolyline(polyline: string): LatLng[] {
    const result: LatLng[] = [];
    if (!polyline || polyline.length === 0) return result;
    const pts: string[] = polyline.split(';');
    for (let i: number = 0; i < pts.length; i++) {
      if (pts[i]) {
        const coord: string[] = pts[i].split(',');
        if (coord.length === 2) {
          const lng: number = parseFloat(coord[0]);
          const lat: number = parseFloat(coord[1]);
          if (!isNaN(lng) && !isNaN(lat)) {
            result.push({ latitude: lat, longitude: lng } as LatLng);
          }
        }
      }
    }
    return result;
  }

  /**
   * 城市名转坐标（REST API）
   */
  async geocodeCity(cityName: string): Promise<LatLng | null> {
    const url: string =
      `https://restapi.amap.com/v3/geocode/geo?key=${AMAP_KEY}` +
      `&address=${encodeURIComponent(cityName)}`;

    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp = await bridge.network.request(url, { method: 'GET' });
      if (resp.responseCode === 200 && resp.result) {
        const json = JSON.parse(resp.result) as Record<string, Object>;
        const statusStr: string = json['status'] as string ?? '0';
        if (statusStr === '1') {
          const geocodes: Object[] = (json['geocodes'] as Object[]) ?? [];
          if (geocodes.length > 0) {
            const geo = geocodes[0] as Record<string, Object>;
            const locStr: string = (geo['location'] as string) ?? '';
            const parts: string[] = locStr.split(',');
            if (parts.length === 2) {
              return { latitude: parseFloat(parts[1]), longitude: parseFloat(parts[0]) } as LatLng;
            }
          }
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'REST geocode city error');
    }
    return null;
  }

  /**
   * 搜索酒店（REST API）
   */
  async searchHotels(lat: number, lng: number): Promise<PoiResult[]> {
    return this.nearbySearchRest('酒店|宾馆|民宿', lat, lng, 20000);
  }

  /**
   * 按分类搜索 POI（REST API）
   */
  async searchPoiByCategory(
    keywords: string, lat: number, lng: number, radius: number = 10000
  ): Promise<PoiResult[]> {
    return this.nearbySearchRest(keywords, lat, lng, radius);
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
