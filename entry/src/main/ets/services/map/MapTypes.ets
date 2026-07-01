/**
 * 地图抽象层 —— 通用类型定义
 * 跨平台兼容（HarmonyOS / Android），不依赖平台特定类型
 */

/** 经纬度坐标 */
export interface LatLng {
  latitude: number;
  longitude: number;
}

/** 经纬度边界框 */
export interface LatLngBounds {
  southwest: LatLng;
  northeast: LatLng;
}

/** 地图样式 */
export enum MapType {
  STANDARD = 0,
  SATELLITE = 1,
  DARK = 2,
}

/** 相机位置参数 */
export interface CameraPosition {
  target: LatLng;
  zoom: number;
}

/** 地图初始化选项 */
export interface MapOptions {
  position: CameraPosition;
  mapType: MapType;
}

/** 标记图标样式（跨平台） */
export interface MarkerIconStyle {
  /** 图标颜色 (hex, e.g. "#FF5722") */
  color: string;
  /** 图标文字（单个 emoji 或字符） */
  text?: string;
  /** 图标大小 (px) */
  size?: number;
}

/** 添加标记的选项（跨平台版本） */
export interface MarkerOptions {
  position: LatLng;
  /** 标记图标样式（替代 PixelMap） */
  iconStyle?: MarkerIconStyle;
  title?: string;
  snippet?: string;
  anchorU?: number;
  anchorV?: number;
  zIndex?: number;
  clickable?: boolean;
}

/** 添加折线的选项 */
export interface PolylineOptions {
  points: LatLng[];
  /** 颜色 (hex string, e.g. "#3388FF") */
  color: string;
  width: number;
  zIndex?: number;
  clickable?: boolean;
}

/** POI 搜索结果 */
export interface PoiResult {
  name: string;
  type: string;
  latitude: number;
  longitude: number;
  address: string;
  distance: number;
  tel: string;
}

/** 逆地理编码结果 */
export interface GeocodeResult {
  formattedAddress: string;
  city: string;
  district: string;
  nearbyPois: NearbyPoi[];
}

export interface NearbyPoi {
  name: string;
  type: string;
  direction: string;
  distance: number;
}

/** 地图就绪回调类型 */
export type MapReadyCallback = (err: Error | null) => void;

/** 标记点击回调类型 */
export type MarkerClickCallback = (markerId: string, lat: number, lng: number, title: string) => void;

/** 地图点击回调类型 */
export type MapClickCallback = (lat: number, lng: number) => void;

/** 搜索完成回调类型 */
export type SearchCallback = (pois: PoiResult[]) => void;

/** 地理编码完成回调类型 */
export type GeocodeCallback = (result: GeocodeResult | null) => void;

/** 地图初始化配置 */
export interface MapInitConfig {
  lng: number;
  lat: number;
  zoom: number;
  apiKey: string;
}

/** 相机位置快照 */
export interface CameraState {
  lng: number;
  lat: number;
  zoom: number;
}

/** 批量添加标记的单个项 */
export interface BatchMarkerItem {
  id: string;
  lng: number;
  lat: number;
  title: string;
  iconStyle?: MarkerIconStyle;
}
