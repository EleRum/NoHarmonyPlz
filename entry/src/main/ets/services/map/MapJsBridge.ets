/**
 * 地图 JSAPI 桥接层（ArkTS 侧）
 *
 * 通过 WebView 的 runJavaScript / javaScriptProxy 与 map.html 中的
 * FootMapBridge 双向通信，实现跨平台地图控制。
 *
 * 通信方向：
 *   ArkTS → JS:  controller.runJavaScript('FootMapBridge.xxx(args)')
 *   JS → ArkTS:  window.arkTsCallback(jsonStr) → javaScriptProxy → handleJsMessage()
 */
import { webview } from '@kit.ArkWeb';
import { Logger } from '../../common/Logger';
import {
  LatLng, LatLngBounds, MarkerOptions, MarkerIconStyle, PolylineOptions,
  MapType, PoiResult, GeocodeResult,
  MapReadyCallback, MarkerClickCallback, MapClickCallback,
  SearchCallback, GeocodeCallback, CameraState, MapInitConfig, BatchMarkerItem, NearbyPoi,
  DirectionMode, DirectionRoute, NavRoute, NavStep
} from './MapTypes';
import { IMapService, MapEventCallbacks } from './IMapService';

const TAG = 'MapJsBridge';

/** 生成唯一 ID */
let _idSeq: number = 0;
function nextId(): string {
  return 'm_' + (++_idSeq).toString();
}

export class MapJsBridge implements IMapService {
  private controller: webview.WebviewController | null = null;
  private apiKey: string = '';
  private readyCallbacks: Array<(err: Error | null) => void> = [];
  private isReady: boolean = false;
  // 多订阅者回调列表（避免 AmapSearchService 和其他组件互相覆盖）
  private callbackSubs: MapEventCallbacks[] = [];
  private camPosition: CameraState | null = null;
  // 导航路线 Promise 解析
  private directionResolveMap: Map<string, (result: DirectionRoute | null) => void> = new Map();
  private directionReqSeq: number = 0;
  // 增强导航路线 Promise（含步骤数据）
  private navRouteResolveMap: Map<string, (result: NavRoute | null) => void> = new Map();
  private navRouteReqSeq: number = 0;

  // ─── 生命周期 ───

  /**
   * 设置 WebView 控制器（由 MapPage 在 WebView 组件回调中调用）
   */
  setController(ctl: webview.WebviewController): void {
    this.controller = ctl;
    // 注册原生桥接对象 → JS 端通过 window.arkTsCallback.onMessage(msg) 调用
    ctl.registerJavaScriptProxy({
      onMessage: (message: string): void => {
        this.handleJsMessage(message);
      }
    }, 'arkTsCallback', ['onMessage']);
  }

  initialize(config: MapInitConfig): void {
    this.apiKey = config.apiKey;
    // map.html 自带 tryInitMap 自动初始化。
    // 若 map 已就绪（JSAPI 先于 onControllerAttached 加载完毕），
    // setCenter 后通过 _resendReady 重发 mapReady，解决 Java proxy
    // 注册晚于 auto-init mapReady 的竞态。
    if (this.controller) {
      const js = `
        if (FootMapBridge && FootMapBridge.isReady()) {
          FootMapBridge.setCenter(${config.lng}, ${config.lat}, ${config.zoom});
          FootMapBridge._resendReady();
        } else if (FootMapBridge) {
          FootMapBridge.initMap(${JSON.stringify({ lng: config.lng, lat: config.lat, zoom: config.zoom })});
        }
      `;
      try { this.controller.runJavaScript(js); } catch (e) { /* noop */ }
    }
  }

  onMapReady(callback: (err: Error | null) => void): void {
    if (this.isReady) {
      callback(null);
      return;
    }
    this.readyCallbacks.push(callback);
  }

  destroy(): void {
    if (this.controller) {
      try {
        this.controller.runJavaScript('FootMapBridge.destroy()');
      } catch (e) {
        // 忽略
      }
    }
    this.readyCallbacks = [];
    this.isReady = false;
    this.callbackSubs = [];
    this.controller = null;
  }

  // ─── 相机控制 ───

  moveCamera(target: LatLng, zoom: number): void {
    this.camPosition = { lng: target.longitude, lat: target.latitude, zoom: zoom };
    this.execJs(`FootMapBridge.setCenter(${target.longitude}, ${target.latitude}, ${zoom})`);
  }

  moveCameraBounds(bounds: LatLngBounds, _padding?: number): void {
    this.execJs(
      `FootMapBridge.fitBounds(${bounds.southwest.longitude}, ${bounds.southwest.latitude}, ${bounds.northeast.longitude}, ${bounds.northeast.latitude})`
    );
  }

  getCameraPosition(): CameraState | null {
    // 尝试从 JS 获取（异步结果通过上次缓存的 camPosition）
    // 也触发一次 JS 调用以更新缓存
    this.execJs(
      `(function(){ var c = FootMapBridge.getCenter(); window.arkTsCallback(JSON.stringify({type:'camPos',data:c})); })()`
    );
    return this.camPosition;
  }

  animateCamera(target: LatLng, zoom: number, _durationMs?: number): void {
    // JSAPI 平滑移动
    this.camPosition = { lng: target.longitude, lat: target.latitude, zoom: zoom };
    this.execJs(`FootMapBridge.setCenter(${target.longitude}, ${target.latitude}, ${zoom})`);
  }

  // ─── 标记 ───

  addMarker(options: MarkerOptions): string {
    const id: string = nextId();
    const iconStyle = options.iconStyle;
    const color = iconStyle?.color ?? '#FF5722';
    const text = iconStyle?.text ?? '';
    const size = iconStyle?.size ?? 24;

    // 使用 SVG data URI 生成彩色圆点图标
    const svgColor: string = color.replace('#', '%23');
    const iconUrl: string = `data:image/svg+xml,` +
      `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">` +
      `<circle cx="${size / 2}" cy="${size / 2}" r="${size / 2 - 2}" fill="${svgColor}" stroke="white" stroke-width="2"/>` +
      (text ? `<text x="${size / 2}" y="${size / 2 + size / 5}" text-anchor="middle" fill="white" font-size="${size * 0.6}">${text}</text>` : '') +
      `</svg>`;

    this.execJs(
      `FootMapBridge.addMarker('${id}', ${options.position.longitude}, ${options.position.latitude}, '${options.title ?? ''}', '${iconUrl}', false)`
    );
    return id;
  }

  removeMarker(markerId: string): void {
    this.execJs(`FootMapBridge.removeMarker('${markerId}')`);
  }

  clearMarkers(): void {
    this.execJs('FootMapBridge.clearMarkers()');
  }

  setMarkerPosition(markerId: string, target: LatLng): void {
    this.execJs(`FootMapBridge.setMarkerPosition('${markerId}', ${target.longitude}, ${target.latitude})`);
  }

  setMarkerVisible(markerId: string, visible: boolean): void {
    this.execJs(`FootMapBridge.setMarkerVisible('${markerId}', ${visible})`);
  }

  addMarkersBatch(markers: BatchMarkerItem[]): void {
    const jsonParts: string[] = [];
    for (let i: number = 0; i < markers.length; i++) {
      const m: BatchMarkerItem = markers[i];
      const icon: MarkerIconStyle | undefined = m.iconStyle;
      const color: string = icon !== undefined && icon.color ? icon.color : '#FF5722';
      const text: string = icon !== undefined && icon.text ? icon.text : '';
      const size: number = icon !== undefined && icon.size ? icon.size : 24;
      const svgColor: string = color.replace('#', '%23');
      const iconUrl: string =
        'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="' + size +
        '" height="' + size + '"><circle cx="' + (size / 2) + '" cy="' + (size / 2) +
        '" r="' + (size / 2 - 2) + '" fill="' + svgColor +
        '" stroke="white" stroke-width="2"/>' +
        (text ? '<text x="' + (size / 2) + '" y="' + (size / 2 + size / 5) +
         '" text-anchor="middle" fill="white" font-size="' + (size * 0.6) + '">' + text + '</text>' : '') +
        '</svg>';
      jsonParts.push(
        '{"id":"' + m.id + '","lng":' + m.lng + ',"lat":' + m.lat +
        ',"title":"' + m.title + '","iconUrl":"' + iconUrl +
        '","iconSize":[' + size + ',' + size + ']}'
      );
    }
    this.execJs('FootMapBridge.addMarkersBatch([' + jsonParts.join(',') + '])');
  }

  // ─── 折线 ───

  addPolyline(options: PolylineOptions): string {
    const id: string = nextId();
    const pointParts: string[] = [];
    for (let i: number = 0; i < options.points.length; i++) {
      pointParts.push('{"lng":' + options.points[i].longitude + ',"lat":' + options.points[i].latitude + '}');
    }
    const pointsJson: string = '[' + pointParts.join(',') + ']';
    this.execJs(
      `FootMapBridge.addPolyline('${id}', ${pointsJson}, '${options.color}', ${options.width})`
    );
    return id;
  }

  removePolyline(polylineId: string): void {
    this.execJs(`FootMapBridge.removePolyline('${polylineId}')`);
  }

  clearPolylines(): void {
    this.execJs('FootMapBridge.clearPolylines()');
  }

  setPolylinePoints(polylineId: string, points: LatLng[]): void {
    const partList: string[] = [];
    for (let i: number = 0; i < points.length; i++) {
      partList.push('{"lng":' + points[i].longitude + ',"lat":' + points[i].latitude + '}');
    }
    const ptsJson: string = '[' + partList.join(',') + ']';
    this.execJs('FootMapBridge.setPolylinePoints(\'' + polylineId + '\', ' + ptsJson + ')');
  }

  setPolylineVisible(polylineId: string, visible: boolean): void {
    this.execJs(`FootMapBridge.setPolylineVisible('${polylineId}', ${visible})`);
  }

  // ─── 我的位置 ───

  setMyLocation(target: LatLng): void {
    this.execJs(`FootMapBridge.setMyLocation(${target.longitude}, ${target.latitude})`);
  }

  // ─── 地图样式 ───

  setMapType(type: MapType): void {
    let styleUrl: string = 'amap://styles/light';
    if (type === MapType.SATELLITE) {
      styleUrl = 'amap://styles/6ac36c2fb7e2f9e6c7d2af3b8f9e1a4d';
    } else if (type === MapType.DARK) {
      styleUrl = 'amap://styles/dark';
    }
    this.execJs(
      'if(typeof AMap!==\'undefined\'&&AMap.Map){var m=document.querySelector(\'#container\')._amap;if(m)m.setMapStyle(\'' + styleUrl + '\')}'
    );
  }

  setMapStyle(style: string): void {
    this.execJs(
      'if(typeof AMap!==\'undefined\'&&AMap.Map){var m=document.querySelector(\'#container\')._amap;if(m)m.setMapStyle(\'' + style + '\')}'
    );
  }

  // ─── POI 搜索 ───

  searchNearby(keywords: string, center: LatLng, radius: number): void {
    this.execJs(
      `FootMapBridge.searchNearby('${keywords.replace(/'/g, "\\'")}', ${center.longitude}, ${center.latitude}, ${radius})`
    );
  }

  lookupNearestPlace(target: LatLng): void {
    this.execJs(
      `FootMapBridge.lookupNearestPlace(${target.longitude}, ${target.latitude})`
    );
  }

  // ─── 导航路线 ───

  requestDirectionRoute(from: LatLng, to: LatLng, mode: DirectionMode): Promise<DirectionRoute | null> {
    const requestId: string = 'dr_' + (++this.directionReqSeq).toString();
    return new Promise<DirectionRoute | null>((resolve) => {
      const timeout: number = setTimeout(() => {
        this.directionResolveMap.delete(requestId);
        resolve(null);
      }, 15000);

      this.directionResolveMap.set(requestId, (result: DirectionRoute | null) => {
        clearTimeout(timeout);
        resolve(result);
      });

      this.execJs(
        `FootMapBridge.getDirectionRoute(${from.longitude}, ${from.latitude}, ${to.longitude}, ${to.latitude}, '${mode}', '${requestId}')`
      );
    });
  }

  /**
   * 请求导航路线（返回包含逐步导航指令的完整路线）
   * 支持 driving / walking / transit / bicycling
   */
  requestNavigationRoute(from: LatLng, to: LatLng, mode: DirectionMode): Promise<NavRoute | null> {
    const requestId: string = 'nr_' + (++this.navRouteReqSeq).toString();
    return new Promise<NavRoute | null>((resolve) => {
      const timeout: number = setTimeout(() => {
        this.navRouteResolveMap.delete(requestId);
        resolve(null);
      }, 30000); // 公交查询可能需要更长时间

      this.navRouteResolveMap.set(requestId, (result: NavRoute | null) => {
        clearTimeout(timeout);
        resolve(result);
      });

      // 复用现有的 JS getDirectionRoute 函数（已扩展为支持四种模式和步骤数据）
      this.execJs(
        `FootMapBridge.getDirectionRoute(${from.longitude}, ${from.latitude}, ${to.longitude}, ${to.latitude}, '${mode}', '${requestId}')`
      );
    });
  }

  // ─── 事件回调 ───

  setEventCallbacks(callbacks: MapEventCallbacks): void {
    // 追加订阅者（而非替换），多个组件可同时接收同一事件
    this.callbackSubs.push(callbacks);
  }

  /**
   * 处理来自 WebView JS 桥的消息
   * 由 MapPage 的 Web 组件 javaScriptProxy 回调触发
   */
  handleJsMessage(message: string): void {
    try {
      const data: Record<string, Object> = JSON.parse(message) as Record<string, Object>;
      const type: string = (data['type'] as string) ?? '';

      switch (type) {
        case 'mapReady':
          this.isReady = true;
          for (const cb of this.readyCallbacks) {
            cb(null);
          }
          this.readyCallbacks = [];
          for (const sub of this.callbackSubs) {
            if (sub.onMapReady) sub.onMapReady(null);
          }
          Logger.info(TAG, 'Map ready (JSAPI)');
          break;

        case 'mapClick':
          for (const sub of this.callbackSubs) {
            if (sub.onMapClick) sub.onMapClick(
              data['lat'] as number ?? 0,
              data['lng'] as number ?? 0
            );
          }
          break;

        case 'markerClick':
          for (const sub of this.callbackSubs) {
            if (sub.onMarkerClick) sub.onMarkerClick(
              data['id'] as string ?? '',
              data['lat'] as number ?? 0,
              data['lng'] as number ?? 0,
              data['title'] as string ?? ''
            );
          }
          break;

        case 'mapMoveEnd':
          this.camPosition = {
            lng: data['lng'] as number ?? 0,
            lat: data['lat'] as number ?? 0,
            zoom: data['zoom'] as number ?? 15
          };
          break;

        case 'camPos':
          const d: Record<string, Object> = JSON.parse(data['data'] as string ?? '{}') as Record<string, Object>;
          this.camPosition = {
            lng: d['lng'] as number ?? 0,
            lat: d['lat'] as number ?? 0,
            zoom: d['zoom'] as number ?? 15
          };
          break;

        case 'searchResult': {
            const pois: PoiResult[] = [];
            const arr: Object[] = data['pois'] as Object[] ?? [];
            for (const p of arr) {
              const poi = p as Record<string, Object>;
              pois.push({
                name: poi['name'] as string ?? '',
                type: poi['type'] as string ?? '',
                latitude: poi['lat'] as number ?? 0,
                longitude: poi['lng'] as number ?? 0,
                address: poi['address'] as string ?? '',
                distance: poi['distance'] as number ?? 0,
                tel: poi['tel'] as string ?? ''
              });
            }
            for (const sub of this.callbackSubs) {
              if (sub.onSearchResult) sub.onSearchResult(pois);
            }
          }
          break;

        case 'geocodeResult': {
            const addr: Record<string, Object> | null = data['address'] as Record<string, Object> | null;
            if (addr) {
              const nearby: Object[] = addr['pois'] as Object[] ?? [];
              const parsedPois: NearbyPoi[] = [];
              for (let pi: number = 0; pi < nearby.length; pi++) {
                const np = nearby[pi] as Record<string, Object>;
                const poiEntry: NearbyPoi = {
                  name: np['name'] as string ?? '',
                  type: np['type'] as string ?? '',
                  direction: np['direction'] as string ?? '',
                  distance: np['distance'] as number ?? 0
                };
                parsedPois.push(poiEntry);
              }
              const geoResult: GeocodeResult = {
                formattedAddress: addr['formattedAddress'] as string ?? '',
                city: addr['city'] as string ?? '',
                district: addr['district'] as string ?? '',
                nearbyPois: parsedPois
              };
              for (const sub of this.callbackSubs) {
                if (sub.onGeocodeResult) sub.onGeocodeResult(geoResult);
              }
            } else {
              for (const sub of this.callbackSubs) {
                if (sub.onGeocodeResult) sub.onGeocodeResult(null);
              }
            }
          }
          break;

        case 'directionResult':
          const dirReqId: string = data['requestId'] as string ?? '';

          // 解析 route 数据（公共逻辑）
          const routeData: Record<string, Object> | null = data['route'] as Record<string, Object> | null;

          if (!routeData) {
            // 两个 resolver 都可能存在，统一处理失败
            const dirResolveFail = this.directionResolveMap.get(dirReqId);
            if (dirResolveFail) { this.directionResolveMap.delete(dirReqId); dirResolveFail(null); }
            const navResolveFail = this.navRouteResolveMap.get(dirReqId);
            if (navResolveFail) { this.navRouteResolveMap.delete(dirReqId); navResolveFail(null); }
            break;
          }

          // 解析基础路径
          const pathRaw: Object[] = routeData['path'] as Object[] ?? [];
          const path: LatLng[] = [];
          for (let pi: number = 0; pi < pathRaw.length; pi++) {
            const pt = pathRaw[pi] as Record<string, Object>;
            path.push({
              latitude: pt['lat'] as number ?? 0,
              longitude: pt['lng'] as number ?? 0,
            } as LatLng);
          }

          // 解析旧版 DirectionRoute resolver
          const dirResolve = this.directionResolveMap.get(dirReqId);
          if (dirResolve) {
            this.directionResolveMap.delete(dirReqId);
            const dr: DirectionRoute = {
              distance: routeData['distance'] as number ?? 0,
              duration: routeData['duration'] as number ?? 0,
              path: path,
            };
            dirResolve(dr);
          }

          // 解析新版 NavRoute resolver（含步骤数据）
          const navResolve = this.navRouteResolveMap.get(dirReqId);
          if (navResolve) {
            this.navRouteResolveMap.delete(dirReqId);
            // 解析 steps
            const stepsRaw: Object[] = routeData['steps'] as Object[] ?? [];
            const steps: NavStep[] = [];
            for (let si: number = 0; si < stepsRaw.length; si++) {
              const s = stepsRaw[si] as Record<string, Object>;
              const stepPathRaw: Object[] = s['path'] as Object[] ?? [];
              const stepPath: LatLng[] = [];
              for (let spi: number = 0; spi < stepPathRaw.length; spi++) {
                const spt = stepPathRaw[spi] as Record<string, Object>;
                stepPath.push({
                  latitude: spt['lat'] as number ?? 0,
                  longitude: spt['lng'] as number ?? 0,
                } as LatLng);
              }
              steps.push({
                instruction: s['instruction'] as string ?? '',
                road: s['road'] as string ?? '',
                distance: s['distance'] as number ?? 0,
                duration: s['duration'] as number ?? 0,
                orientation: s['orientation'] as string ?? '',
                action: s['action'] as string ?? '',
                path: stepPath,
              } as NavStep);
            }
            const nr: NavRoute = {
              distance: routeData['distance'] as number ?? 0,
              duration: routeData['duration'] as number ?? 0,
              path: path,
              steps: steps,
              origin: routeData['origin'] as string ?? '',
              destination: routeData['destination'] as string ?? '',
            };
            navResolve(nr);
          }

          // 触发回调（通知所有订阅者）
          for (const sub of this.callbackSubs) {
            if (sub.onNavRouteResult) {
            const stepsRawCb: Object[] = routeData['steps'] as Object[] ?? [];
            const stepsCb: NavStep[] = [];
            for (let sci: number = 0; sci < stepsRawCb.length; sci++) {
              const sc = stepsRawCb[sci] as Record<string, Object>;
              const spRaw: Object[] = sc['path'] as Object[] ?? [];
              const sp: LatLng[] = [];
              for (let spi2: number = 0; spi2 < spRaw.length; spi2++) {
                const spt2 = spRaw[spi2] as Record<string, Object>;
                sp.push({ latitude: spt2['lat'] as number ?? 0, longitude: spt2['lng'] as number ?? 0 } as LatLng);
              }
              stepsCb.push({
                instruction: sc['instruction'] as string ?? '',
                road: sc['road'] as string ?? '',
                distance: sc['distance'] as number ?? 0,
                duration: sc['duration'] as number ?? 0,
                orientation: sc['orientation'] as string ?? '',
                action: sc['action'] as string ?? '',
                path: sp,
              } as NavStep);
            }
            sub.onNavRouteResult({
              distance: routeData['distance'] as number ?? 0,
              duration: routeData['duration'] as number ?? 0,
              path: path,
              steps: stepsCb,
              origin: routeData['origin'] as string ?? '',
              destination: routeData['destination'] as string ?? '',
            } as NavRoute);
            }
          }
          break;
      }
    } catch (e) {
      Logger.warn(TAG, 'Failed to parse JS message: %{public}s', message);
    }
  }

  // ─── 内部辅助 ───

  private execJs(code: string): void {
    if (this.controller) {
      try {
        this.controller.runJavaScript(code);
      } catch (e) {
        Logger.warn(TAG, 'JS exec error: %{public}s', JSON.stringify(e));
      }
    }
  }
}
