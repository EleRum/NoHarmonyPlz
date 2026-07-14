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
              cost: this.extractCost(poi),
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
   * 支持传入不同 city/cityd 实现跨城公交查询
   */
  async directionRouteRest(
    fromLat: number, fromLng: number,
    toLat: number, toLng: number,
    mode: DirectionMode,
    city?: string,
    cityd?: string
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

    // 公交需要 city + cityd 参数（不同值=跨城）
    if (mode === DirectionMode.TRANSIT) {
      const cFrom: string = city || '北京';
      const cTo: string = cityd || city || '北京';
      url += `&city=${encodeURIComponent(cFrom)}&cityd=${encodeURIComponent(cTo)}`;
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
    const steps: NavStep[] = [];
    const fullPath: LatLng[] = [];

    if (mode === DirectionMode.TRANSIT) {
      // 公交/跨城：路径在 segments[].walking/bus/subway/railway/train/coach.polyline 中
      const segments: Object[] = (route['segments'] as Object[]) ?? [];
      for (let i: number = 0; i < segments.length; i++) {
        const seg = segments[i] as Record<string, Object>;
        const walking = seg['walking'] as Record<string, Object> | undefined;
        if (walking) {
          const wpoly: string = (walking['polyline'] as string) ?? '';
          for (const pt of this.parsePolyline(wpoly)) fullPath.push(pt);
          steps.push({
            instruction: (walking['instruction'] as string) ?? '步行',
            road: '',
            distance: parseInt((walking['distance'] as string) ?? '0'),
            duration: parseInt((walking['duration'] as string) ?? '0'),
            orientation: '', action: 'walking', path: this.parsePolyline(wpoly),
          } as NavStep);
        }
        // 火车/高铁/动车
        const railway = seg['railway'] as Record<string, Object> | undefined;
        if (railway) {
          const rpoly: string = (railway['polyline'] as string) ?? '';
          for (const pt of this.parsePolyline(rpoly)) fullPath.push(pt);
          const trip = (railway['trip'] as string) ?? '';
          const departureStop = (railway['departure_stop'] as string) ?? '';
          const arrivalStop = (railway['arrival_stop'] as string) ?? '';
          const departureTime = (railway['departure_time'] as string) ?? '';
          const arrivalTime = (railway['arrival_time'] as string) ?? '';
          const price: string = (railway['price'] as string) ?? '';
          const type: string = (railway['type'] as string) ?? '火车';
          const distanceRail: number = parseInt((railway['distance'] as string) ?? '0');
          const durationRail: number = parseInt((railway['duration'] as string) ?? '0');
          const priceNum: number = parseFloat(price) || 0;
          const label: string = `${type} ${trip}`;
          steps.push({
            instruction: `${label}: ${departureStop} ${departureTime} → ${arrivalStop} ${arrivalTime}${priceNum > 0 ? ' ¥' + priceNum : ''}`,
            road: trip,
            distance: isNaN(distanceRail) ? 0 : distanceRail,
            duration: isNaN(durationRail) ? 0 : durationRail,
            orientation: `${departureStop}→${arrivalStop}`,
            action: type.includes('高铁') ? 'high_speed_rail' : (type.includes('动车') ? 'high_speed_rail' : 'train'),
            path: this.parsePolyline(rpoly),
          } as NavStep);
          continue;
        }
        // 火车（旧版字段名）
        const train = seg['train'] as Record<string, Object> | undefined;
        if (train) {
          const tpoly: string = (train['polyline'] as string) ?? '';
          for (const pt of this.parsePolyline(tpoly)) fullPath.push(pt);
          steps.push({
            instruction: (train['instruction'] as string) ?? '火车',
            road: (train['trip'] as string) ?? '',
            distance: parseInt((train['distance'] as string) ?? '0'),
            duration: parseInt((train['duration'] as string) ?? '0'),
            orientation: '', action: 'train', path: this.parsePolyline(tpoly),
          } as NavStep);
          continue;
        }
        // 长途客车
        const coach = seg['coach'] as Record<string, Object> | undefined;
        if (coach) {
          const copoly: string = (coach['polyline'] as string) ?? '';
          for (const pt of this.parsePolyline(copoly)) fullPath.push(pt);
          steps.push({
            instruction: (coach['instruction'] as string) ?? '长途客车',
            road: (coach['trip'] as string) ?? '',
            distance: parseInt((coach['distance'] as string) ?? '0'),
            duration: parseInt((coach['duration'] as string) ?? '0'),
            orientation: '', action: 'bus', path: this.parsePolyline(copoly),
          } as NavStep);
          continue;
        }
        const bus = seg['bus'] as Record<string, Object> | undefined;
        if (bus) {
          const bpoly: string = (bus['polyline'] as string) ?? '';
          for (const pt of this.parsePolyline(bpoly)) fullPath.push(pt);
          let busRoad: string = '';
          const buslinesArr = bus['buslines'] as Object[] | undefined;
          if (buslinesArr && buslinesArr.length > 0) {
            const firstLine = buslinesArr[0] as Record<string, Object>;
            busRoad = (firstLine['name'] as string) ?? '';
          }
          steps.push({
            instruction: (bus['instruction'] as string) ?? '公交',
            road: busRoad,
            distance: parseInt((bus['distance'] as string) ?? '0'),
            duration: parseInt((bus['duration'] as string) ?? '0'),
            orientation: '', action: 'bus', path: this.parsePolyline(bpoly),
          } as NavStep);
          continue;
        }
        const subway = seg['subway'] as Record<string, Object> | undefined;
        if (subway) {
          const spoly: string = (subway['polyline'] as string) ?? '';
          for (const pt of this.parsePolyline(spoly)) fullPath.push(pt);
          let subwayRoad: string = '';
          const linesArr = subway['lines'] as Object[] | undefined;
          if (linesArr && linesArr.length > 0) {
            const firstLine = linesArr[0] as Record<string, Object>;
            subwayRoad = (firstLine['name'] as string) ?? '';
          }
          steps.push({
            instruction: (subway['instruction'] as string) ?? '地铁',
            road: subwayRoad,
            distance: parseInt((subway['distance'] as string) ?? '0'),
            duration: parseInt((subway['duration'] as string) ?? '0'),
            orientation: '', action: 'subway', path: this.parsePolyline(spoly),
          } as NavStep);
          continue;
        }
      }
    } else {
      const stepsRaw: Object[] = (route['steps'] as Object[]) ?? [];
      for (let i: number = 0; i < stepsRaw.length; i++) {
        const s = stepsRaw[i] as Record<string, Object>;
        const polyline: string = (s['polyline'] as string) ?? '';
        const stepPath: LatLng[] = this.parsePolyline(polyline);
        for (const pt of stepPath) fullPath.push(pt);
        steps.push({
          instruction: (s['instruction'] as string) ?? '',
          road: (s['road'] as string) ?? '',
          distance: parseInt((s['distance'] as string) ?? '0'),
          duration: parseInt((s['duration'] as string) ?? '0'),
          orientation: (s['orientation'] as string) ?? '',
          action: (s['action'] as string) ?? '',
          path: stepPath,
        } as NavStep);
      }
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
  /** 从高德POI结果提取人均消费 */
  private extractCost(poi: Record<string, Object>): string {
    const bizExt = poi['biz_ext'] as Record<string, Object> | undefined;
    if (bizExt) {
      const c = (bizExt['cost'] as string) ?? '';
      if (c && c.length > 0) return c;
    }
    return '';
  }

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
   * 全文搜索 POI — 全城搜索，按相关性排序，不局限在某个坐标周围
   */
  async searchPoiByText(keywords: string, city: string): Promise<PoiResult[]> {
    // 尝试多种城市名格式
    const cityFormats: string[] = [city, city + '市'];
    if (city.endsWith('市')) cityFormats.unshift(city.replace('市', ''));

    for (const cityFmt of cityFormats) {
      const url: string =
        `https://restapi.amap.com/v3/place/text?key=${AMAP_KEY}` +
        `&keywords=${encodeURIComponent(keywords)}&city=${encodeURIComponent(cityFmt)}&offset=20`;
      try {
        const bridge: PlatformBridge = PlatformBridge.getInstance();
        const resp = await bridge.network.request(url, { method: 'GET' });
        if (resp.responseCode === 200 && resp.result) {
          const json = JSON.parse(resp.result) as Record<string, Object>;
          if ((json['status'] as string) === '1' && json['pois']) {
            const poisRaw: Object[] = json['pois'] as Object[];
            if (poisRaw.length > 0) {
              const results: PoiResult[] = [];
              for (let i: number = 0; i < poisRaw.length; i++) {
                const poi = poisRaw[i] as Record<string, Object>;
                const locStr: string = (poi['location'] as string) ?? '';
                const locParts: string[] = locStr.split(',');
                results.push({
                  name: (poi['name'] as string) ?? '',
                  type: (poi['type'] as string) ?? '',
                  latitude: locParts.length === 2 ? parseFloat(locParts[1]) : 0,
                  longitude: locParts.length === 2 ? parseFloat(locParts[0]) : 0,
                  address: (poi['address'] as string) ?? '',
                  distance: 0,
                  tel: (poi['tel'] as string) ?? '',
                  id: (poi['id'] as string) ?? '',
                  cost: this.extractCost(poi),
                } as PoiResult);
              }
              Logger.info(TAG, 'Text search "%{public}s" in "%{public}s": %{public}d results', keywords, cityFmt, results.length);
              return results;
            }
          }
        }
      } catch (e) {
        Logger.warn(TAG, 'Text search failed for "%{public}s": %{public}s', cityFmt, JSON.stringify(e));
      }
    }
    Logger.warn(TAG, 'Text search returned no results for "%{public}s"', keywords);
    return [];
  }

  /**
   * POI 详情（REST API）— 获取评分、均价、电话等扩展信息
   */
  async getPoiDetail(id: string): Promise<Record<string, Object> | null> {
    if (!id || id.length === 0) return null;
    const url: string =
      `https://restapi.amap.com/v3/place/detail?key=${AMAP_KEY}&id=${encodeURIComponent(id)}`;
    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp = await bridge.network.request(url, { method: 'GET' });
      if (resp.responseCode === 200 && resp.result) {
        const json = JSON.parse(resp.result) as Record<string, Object>;
        if ((json['status'] as string) === '1' && json['pois']) {
          const pois = json['pois'] as Object[];
          if (pois.length > 0) return pois[0] as Record<string, Object>;
        }
      }
    } catch (e) { /* ignore */ }
    return null;
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

  /**
   * 跨城交通搜索 — 查询两个城市间的火车/高铁/大巴方案
   * 使用高德 transit/integrated API，传入不同的 city 和 cityd
   * @returns 跨城交通方案列表
   */
  async searchIntercityTransport(
    fromCity: string, toCity: string, date?: string
  ): Promise<IntercityTransportOption[]> {
    const fromLoc: LatLng | null = await this.geocodeCity(fromCity);
    const toLoc: LatLng | null = await this.geocodeCity(toCity);
    if (!fromLoc || !toLoc) {
      Logger.warn(TAG, 'Intercity transport: failed to geocode cities');
      return [];
    }

    // 两种城市名格式
    const cfList: string[] = [fromCity, fromCity.endsWith('市') ? fromCity : fromCity + '市'];
    const ctList: string[] = [toCity, toCity.endsWith('市') ? toCity : toCity + '市'];

    const allOptions: IntercityTransportOption[] = [];

    for (const cf of cfList) {
      for (const ct of ctList) {
        let tryUrl: string =
          `https://restapi.amap.com/v3/direction/transit/integrated?key=${AMAP_KEY}` +
          `&origin=${fromLoc.longitude},${fromLoc.latitude}` +
          `&destination=${toLoc.longitude},${toLoc.latitude}` +
          `&city=${encodeURIComponent(cf)}&cityd=${encodeURIComponent(ct)}` +
          `&extensions=all`;
        if (date && date.length > 0) tryUrl += `&date=${encodeURIComponent(date)}`;

        try {
          const bridge: PlatformBridge = PlatformBridge.getInstance();
          const resp = await bridge.network.request(tryUrl, { method: 'GET' });
          if (resp.responseCode !== 200 || !resp.result) continue;
          const json = JSON.parse(resp.result) as Record<string, Object>;
          if ((json['status'] as string) !== '1') {
            continue;
          }
          const routeData = json['route'] as Record<string, Object>;
          const transits: Object[] = (routeData?.['transits'] as Object[]) ?? [];
          Logger.info(TAG, 'Transit %{public}s→%{public}s: %{public}d transits', cf, ct, transits.length);

          const options: IntercityTransportOption[] = [];
          for (let t: number = 0; t < transits.length; t++) {
            const transit = transits[t] as Record<string, Object>;
            const segments: Object[] = (transit['segments'] as Object[]) ?? [];
            const totalDist: number = parseInt((transit['distance'] as string) ?? '0');
            const totalDur: number = parseInt((transit['duration'] as string) ?? '0');

            for (let s: number = 0; s < segments.length; s++) {
              const seg = segments[s] as Record<string, Object>;
              // 统一提取火车数据: railway 段(K/T/Z) 或 bus 段(G/D/C type=2011/2012/2013)
              let trainSrc: Record<string, Object> | undefined = undefined;
              let isBusTrain: boolean = false;
              const railway = seg['railway'] as Record<string, Object> | undefined;
              if (railway) {
                trainSrc = railway;
              } else {
                const bus = seg['bus'] as Record<string, Object> | undefined;
                const busType: string = bus ? ((bus['type'] as string) || '') : '';
                if (busType === '2011' || busType === '2012' || busType === '2013') {
                  trainSrc = bus;
                  isBusTrain = true;
                }
              }
              if (!trainSrc) continue;

              const trip: string = isBusTrain ?
                ((trainSrc['name'] as string) || (trainSrc['trip'] as string) || '') :
                ((trainSrc['trip'] as string) || (trainSrc['name'] as string) || '');
              const typeCode: string = (trainSrc['type'] as string) || '';

              const depObj = trainSrc['departure_stop'] as Record<string, Object> | undefined;
              const arrObj = trainSrc['arrival_stop'] as Record<string, Object> | undefined;
              let depStop: string = depObj ? ((depObj['name'] as string) ?? '') : '';
              let arrStop: string = arrObj ? ((arrObj['name'] as string) ?? '') : '';
              if (!trip && !depStop && !arrStop) continue;
              let depTimeRaw: string = depObj ? ((depObj['time'] as string) ?? '') : '';
              let arrTimeRaw: string = arrObj ? ((arrObj['time'] as string) ?? '') : '';

              const fmtTm = (raw: string): string => {
                if (!raw) return '';
                let n = parseInt(raw);
                if (isNaN(n)) return raw;
                if (n >= 2400) n -= 2400;
                let h = Math.floor(n / 100);
                let m = n % 100;
                return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m;
              };

              const dist: number = parseInt((trainSrc['distance'] as string) ?? '0') || 0;
              const durSec: number = parseInt((trainSrc['time'] as string) ?? '0') || totalDur || 0;

              let price: number = 0;
              if (isBusTrain) {
                price = parseFloat((trainSrc['price'] as string) ?? '0') || 0;
              } else {
                const alters = trainSrc['alters'] as Object[] | undefined;
                if (alters && alters.length > 0) {
                  const sps = (alters[0] as Record<string, Object>)['spaces'] as Object[] | undefined;
                  if (sps) {
                    for (const sp of sps) {
                      let c = parseFloat(((sp as Record<string, Object>)['cost'] as string) ?? '0') || 0;
                      if (c > 0 && (price === 0 || c < price)) price = c;
                    }
                  }
                }
              }

              let mode: string = 'train';
              if (typeCode === '2011' || typeCode === '2012' || typeCode === '2013' || isBusTrain) mode = 'high_speed_rail';
              if (trip && (trip.startsWith('G') || trip.startsWith('D') || trip.startsWith('C'))) mode = 'high_speed_rail';

              options.push({
                type: mode, trip: trip || (mode === 'high_speed_rail' ? '高铁' : '火车'),
                fromStation: depStop || fromCity, toStation: arrStop || toCity,
                departureTime: fmtTm(depTimeRaw), arrivalTime: fmtTm(arrTimeRaw),
                duration: (!isNaN(durSec) && durSec > 0) ? durSec : 0,
                distance: isNaN(dist) ? (isNaN(totalDist) ? 0 : totalDist) : dist,
                price: price,
              } as IntercityTransportOption);
            }
          }

          // 合并去重（按车次）
          for (const opt of options) {
            let dup: boolean = false;
            for (const existing of allOptions) {
              if (existing.trip && opt.trip && existing.trip === opt.trip) { dup = true; break; }
            }
            if (!dup) allOptions.push(opt);
          }
        } catch (e) {
          Logger.warn(TAG, 'Transit request failed %{public}s→%{public}s', cf, ct);
        }
      } // ct
    } // cf

    Logger.info(TAG, 'Intercity transport %{public}s→%{public}s: %{public}d options',
      fromCity, toCity, allOptions.length);
    return allOptions;
  }

}

/** 跨城交通方案 */
export interface IntercityTransportOption {
  type: string;           // train / high_speed_rail / flight / bus
  trip: string;           // 车次/航班号 e.g. "G89"
  fromStation: string;    // 出发站
  toStation: string;      // 到达站
  departureTime: string;  // "08:30"
  arrivalTime: string;    // "17:00"
  duration: number;       // 秒
  distance: number;       // 米
  price: number;          // 预估票价(元)
  note?: string;
}
