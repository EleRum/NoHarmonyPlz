/**
 * 地图抽象层 —— 核心地图服务接口（跨平台 WebView 版本）
 *
 * 所有地图实现（JSAPI WebView、原生 SDK 等）必须实现此接口。
 * MapPage 只通过此接口操作地图，不直接依赖任何具体 SDK。
 */
import {
  LatLng, LatLngBounds, MarkerOptions, PolylineOptions,
  MapType, MapReadyCallback, MarkerClickCallback, MapClickCallback,
  SearchCallback, GeocodeCallback, MapInitConfig, CameraState, BatchMarkerItem
} from './MapTypes';

/** 地图事件回调集合 */
export interface MapEventCallbacks {
  onMapReady?: MapReadyCallback;
  onMarkerClick?: MarkerClickCallback;
  onMapClick?: MapClickCallback;
  onSearchResult?: SearchCallback;
  onGeocodeResult?: GeocodeCallback;
}

export interface IMapService {
  // ─── 生命周期 ───

  /**
   * 注册地图就绪回调。
   * 地图初始化完成后触发（WebView 中 JSAPI 加载完成）
   */
  onMapReady(callback: (err: Error | null) => void): void;

  /**
   * 初始化地图。
   * 在 WebView 组件 onPageEnd 后调用，传入 controller 和配置。
   */
  initialize(config: MapInitConfig): void;

  /** 销毁地图资源 */
  destroy(): void;

  // ─── 相机控制 ───

  /** 移动相机到指定位置和缩放级别 */
  moveCamera(target: LatLng, zoom: number): void;

  /** 移动相机以适配指定边界 */
  moveCameraBounds(bounds: LatLngBounds, padding?: number): void;

  /** 获取当前相机状态 */
  getCameraPosition(): CameraState | null;

  /** 平滑动画移动相机 */
  animateCamera(target: LatLng, zoom: number, durationMs?: number): void;

  // ─── 覆盖物 ───

  /** 添加标记，返回标记 ID */
  addMarker(options: MarkerOptions): string;

  /** 移除标记 */
  removeMarker(markerId: string): void;

  /** 清除所有标记 */
  clearMarkers(): void;

  /** 批量添加标记（性能优化） */
  addMarkersBatch(markers: BatchMarkerItem[]): void;

  /** 更新标记位置 */
  setMarkerPosition(markerId: string, target: LatLng): void;

  /** 设置标记可见性 */
  setMarkerVisible(markerId: string, visible: boolean): void;

  /** 添加折线，返回折线 ID */
  addPolyline(options: PolylineOptions): string;

  /** 移除折线 */
  removePolyline(polylineId: string): void;

  /** 清除所有折线 */
  clearPolylines(): void;

  /** 更新折线点位 */
  setPolylinePoints(polylineId: string, points: LatLng[]): void;

  /** 设置折线可见性 */
  setPolylineVisible(polylineId: string, visible: boolean): void;

  // ─── 我的位置 ───

  /** 更新我的位置标记 */
  setMyLocation(target: LatLng): void;

  // ─── 地图样式 ───

  /** 切换地图样式 */
  setMapType(type: MapType): void;

  // ─── POI 搜索（通过 JSAPI PlaceSearch） ───

  /** 周边搜索 */
  searchNearby(keywords: string, center: LatLng, radius: number): void;

  /** 逆地理编码 / 查找最近地点 */
  lookupNearestPlace(target: LatLng): void;

  // ─── 事件 ───

  /** 设置事件回调 */
  setEventCallbacks(callbacks: MapEventCallbacks): void;

  /** 处理来自 WebView JS 桥的消息 */
  handleJsMessage(message: string): void;
}
