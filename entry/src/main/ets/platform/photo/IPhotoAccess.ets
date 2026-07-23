/**
 * 相册访问抽象接口
 * 统一封装系统相册扫描，HarmonyOS 和 Android 各自实现
 */

/** 照片信息 */
export interface PhotoInfo {
  /** 照片 URI */
  uri: string;
  /** 显示名称 */
  displayName: string;
  /** 添加日期时间戳 (ms) */
  dateAdded: number;
  /** 纬度 (GPS) */
  latitude: number;
  /** 经度 (GPS) */
  longitude: number;
}

/**
 * 相册访问提供者接口
 * 所有平台需要实现此接口以提供相册扫描能力
 */
export interface IPhotoAccess {
  /**
   * 扫描系统相册中带 GPS 位置的照片
   * @returns 照片信息列表
   */
  scanPhotos(): Promise<PhotoInfo[]>;
}
