/**
 * 定位服务抽象接口
 * 统一封装 GPS 定位和逆地理编码
 */

/** 地理位置数据 */
export interface GeoLocation {
  /** 纬度 */
  latitude: number;
  /** 经度 */
  longitude: number;
  /** 精度 (米) */
  accuracy: number;
  /** 速度 (m/s) */
  speed: number;
  /** 时间戳 (ms) */
  timestamp: number;
}

/** 逆地理编码结果 */
export interface GeoAddress {
  /** 地点名称 */
  placeName: string;
  /** 详细地址 */
  address?: string;
  /** 城市 */
  city?: string;
  /** 区县 */
  district?: string;
}

/** 定位回调函数类型 */
export type LocationCallback = (location: GeoLocation) => void;

/**
 * 定位提供者接口
 * 所有平台需要实现此接口以提供 GPS 定位能力
 */
export interface ILocationProvider {
  /**
   * 启动持续定位
   * @param callback 位置更新回调
   */
  startTracking(callback: LocationCallback): void;

  /**
   * 停止定位
   */
  stopTracking(): void;

  /**
   * 是否正在追踪
   */
  isTracking(): boolean;

  /**
   * 逆地理编码 - 根据经纬度获取地址
   * @param latitude 纬度
   * @param longitude 经度
   * @returns 地址信息，失败返回 null
   */
  reverseGeocode(latitude: number, longitude: number): Promise<GeoAddress | null>;
}
