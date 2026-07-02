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
  SearchCallback, GeocodeCallback, CameraState, MapInitConfig, BatchMarkerItem, NearbyPoi
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
  private callbacks: MapEventCallbacks = {};
  private camPosition: CameraState | null = null;

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
    this.callbacks = {};
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

  // ─── 事件回调 ───

  setEventCallbacks(callbacks: MapEventCallbacks): void {
    // Merge（而非替换），避免后来者覆盖已注册的回调（如 AmapSearchService 的 onSearchResult）
    if (callbacks.onMapReady !== undefined) {
      this.callbacks.onMapReady = callbacks.onMapReady;
    }
    if (callbacks.onMarkerClick !== undefined) {
      this.callbacks.onMarkerClick = callbacks.onMarkerClick;
    }
    if (callbacks.onMapClick !== undefined) {
      this.callbacks.onMapClick = callbacks.onMapClick;
    }
    if (callbacks.onSearchResult !== undefined) {
      this.callbacks.onSearchResult = callbacks.onSearchResult;
    }
    if (callbacks.onGeocodeResult !== undefined) {
      this.callbacks.onGeocodeResult = callbacks.onGeocodeResult;
    }
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
          if (this.callbacks.onMapReady) {
            this.callbacks.onMapReady(null);
          }
          Logger.info(TAG, 'Map ready (JSAPI)');
          break;

        case 'mapClick':
          if (this.callbacks.onMapClick) {
            this.callbacks.onMapClick(
              data['lat'] as number ?? 0,
              data['lng'] as number ?? 0
            );
          }
          break;

        case 'markerClick':
          if (this.callbacks.onMarkerClick) {
            this.callbacks.onMarkerClick(
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

        case 'searchResult':
          if (this.callbacks.onSearchResult) {
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
            this.callbacks.onSearchResult(pois);
          }
          break;

        case 'geocodeResult':
          if (this.callbacks.onGeocodeResult) {
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
              this.callbacks.onGeocodeResult({
                formattedAddress: addr['formattedAddress'] as string ?? '',
                city: addr['city'] as string ?? '',
                district: addr['district'] as string ?? '',
                nearbyPois: parsedPois
              });
            } else {
              this.callbacks.onGeocodeResult(null);
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
