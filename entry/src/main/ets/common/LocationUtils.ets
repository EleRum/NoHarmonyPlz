/**
 * 位置工具函数
 * 坐标距离计算、停留检测算法
 */

/**
 * 计算两点间的 Haversine 距离 (米)
 */
export function haversineDistance(
  lat1: number, lng1: number,
  lat2: number, lng2: number
): number {
  const R: number = 6371000; // 地球半径 (米)
  const dLat: number = toRadians(lat2 - lat1);
  const dLng: number = toRadians(lng2 - lng1);
  const a: number =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRadians(lat1)) * Math.cos(toRadians(lat2)) *
    Math.sin(dLng / 2) * Math.sin(dLng / 2);
  const c: number = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

function toRadians(degrees: number): number {
  return degrees * Math.PI / 180;
}

/**
 * 检测是否在停留状态
 * 如果一段时间内位置变化小于阈值，视为停留
 * @param distances 最近 N 个点的累计移动距离 (米)
 * @param durationSec 时间跨度 (秒)
 * @param distanceThreshold 距离阈值 (米)
 * @param timeThreshold 时间阈值 (秒)
 */
export function isStaying(
  distances: number,
  durationSec: number,
  distanceThreshold: number = 50,
  timeThreshold: number = 300
): boolean {
  if (durationSec < timeThreshold) {
    return false;
  }
  return distances < distanceThreshold;
}

/**
 * 根据速度估算移动方式
 * @param speedMs 速度 (米/秒)
 */
export function estimateMovementType(speedMs: number): string {
  if (speedMs < 0.5) {
    return 'stationary';
  } else if (speedMs < 2.0) {
    return 'walking';
  } else if (speedMs < 8.0) {
    return 'running';
  } else if (speedMs < 15.0) {
    return 'cycling';
  } else if (speedMs < 40.0) {
    return 'vehicle';
  } else {
    return 'high_speed';
  }
}

/**
 * 获取日期Key (YYYYMMDD)
 */
export function getDayKey(timestamp: number): string {
  const date: Date = new Date(timestamp);
  const year: string = date.getFullYear().toString();
  const month: string = (date.getMonth() + 1).toString().padStart(2, '0');
  const day: string = date.getDate().toString().padStart(2, '0');
  return year + month + day;
}

/**
 * 格式化时间戳为可读字符串
 */
export function formatTimestamp(timestamp: number): string {
  const date: Date = new Date(timestamp);
  const h: string = date.getHours().toString().padStart(2, '0');
  const m: string = date.getMinutes().toString().padStart(2, '0');
  return `${h}:${m}`;
}
