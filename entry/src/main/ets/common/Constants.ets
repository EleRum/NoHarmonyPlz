/**
 * 常量定义
 * 数据库名、表名、定位参数、日志DOMAIN、行为标签枚举
 */

// ========== 数据库常量 ==========
export const DB_NAME: string = 'Footprint.db';
export const DB_VERSION: number = 1;

export const TABLE_FOOTPRINT: string = 'footprint';
export const TABLE_ACTIVITY_SEGMENT: string = 'activity_segment';
export const TABLE_USER_PROFILE: string = 'user_profile';
export const TABLE_RECOMMENDATION: string = 'recommendation';

// ========== 定位参数 ==========
/** 最小定位间隔 (秒) */
export const LOCATION_INTERVAL_SEC: number = 60;
/** 最小记录距离 (米) — 移动小于此距离不记录新点 */
export const MIN_DISTANCE_METERS: number = 50;
/** 停留检测最小时间 (秒) */
export const STAY_DURATION_THRESHOLD_SEC: number = 300;

// ========== 日志 ==========
// (日志已迁移到 common/Logger.ets，使用 console API 替代 hilog)
export const APP_TAG: string = 'FootprintMap';

// ========== 行为标签枚举 ==========
export enum ActivityType {
  HOME = 'home',           // 🏠 居家
  WORK = 'work',           // 💼 工作
  DINING = 'dining',       // 🍽️ 餐饮
  SHOPPING = 'shopping',   // 🛍️ 购物
  SPORTS = 'sports',       // 🏃 运动
  COMMUTE = 'commute',     // 🚇 通勤
  LEISURE = 'leisure',     // 🎠 休闲
  TRAVEL = 'travel'        // ✈️ 出行
}

export const ACTIVITY_LABELS: Record<string, string> = {
  [ActivityType.HOME]: '🏠 居家',
  [ActivityType.WORK]: '💼 工作',
  [ActivityType.DINING]: '🍽️ 餐饮',
  [ActivityType.SHOPPING]: '🛍️ 购物',
  [ActivityType.SPORTS]: '🏃 运动',
  [ActivityType.COMMUTE]: '🚇 通勤',
  [ActivityType.LEISURE]: '🎠 休闲',
  [ActivityType.TRAVEL]: '✈️ 出行'
};

// ========== 数据来源 ==========
export enum DataSource {
  GPS = 'gps',
  PHOTO = 'photo',
  MANUAL = 'manual'
}

// ========== 高德地图 API Key ==========
export const AMAP_API_KEY: string = 'fc2c6f05fd1c51af417ddb1aa4f0aec3';
