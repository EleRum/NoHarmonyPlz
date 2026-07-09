/**
 * 旅游计划数据模型
 */
import { NavRoute, LatLng } from '../services/map/MapTypes';

/** 单个 POI 项 */
export interface TourPoiItem {
  name: string;
  lat: number;
  lng: number;
  /** 景点/酒店/餐厅/购物 */
  type: string;
  /** 时间段描述，如 "上午9:00-11:00" */
  timeSlot: string;
  /** 建议停留时长 */
  duration: string;
  /** 备注/推荐语 */
  note: string;
  /** 到达此POI的交通方式: walking/driving/transit/bicycling，空=自动 */
  mode?: string;
}

/** 一天行程 */
export interface TourDay {
  dayIndex: number;
  /** 日期标签 "第1天" */
  label: string;
  /** 该天 POI 列表（按顺序） */
  pois: TourPoiItem[];
  /** 该天路线 */
  route: NavRoute | null;
}

/** 完整旅游计划 */
export interface TourPlan {
  /** 城市名 */
  city: string;
  /** 城市坐标 */
  cityLat: number;
  cityLng: number;
  /** 游玩天数 */
  days: number;
  /** 酒店 */
  hotel: TourPoiItem | null;
  /** 每日行程 */
  dailyPlans: TourDay[];
  /** 计划状态 */
  status: 'gathering' | 'planning' | 'complete';
}

/** 创建空计划 */
export function createEmptyPlan(): TourPlan {
  return {
    city: '',
    cityLat: 0,
    cityLng: 0,
    days: 1,
    hotel: null,
    dailyPlans: [],
    status: 'gathering',
  };
}
