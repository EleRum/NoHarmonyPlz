/**
 * 旅游计划数据模型
 * v2: 新增跨城交通 + 预算概念
 */
import { NavRoute, LatLng } from '../services/map/MapTypes';

/** 跨城交通方式 */
export enum IntercityMode {
  TRAIN = 'train',
  HIGH_SPEED_RAIL = 'high_speed_rail',
  FLIGHT = 'flight',
  BUS = 'bus',
}

/** 跨城交通信息 */
export interface InterCityTransport {
  type: string;               // train / high_speed_rail / flight / bus
  from: string;               // 出发城市
  to: string;                 // 到达城市
  departureTime?: string;     // "7月15日 08:30"
  arrivalTime?: string;       // "7月15日 11:45"
  number?: string;            // 车次/航班号 "G123"/"CA1234"
  cost?: number;              // 预估费用(元)
  note?: string;
}

/** 单个 POI 项 */
export interface TourPoiItem {
  name: string;
  lat: number;
  lng: number;
  /** 景点/酒店/餐厅/购物/交通 */
  type: string;
  /** 时间段描述，如 "上午9:00-11:00" */
  timeSlot: string;
  /** 建议停留时长 */
  duration: string;
  /** 备注/推荐语 */
  note: string;
  /** 到达此POI的交通方式: walking/driving/transit/bicycling，空=自动 */
  mode?: string;
  /** 预估人均花费(元) */
  estimatedCost?: number;
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
  /** 总预算(元) */
  totalBudget?: number;
  /** 到达目的地交通 */
  transportToCity?: InterCityTransport;
  /** 返程交通 */
  transportBack?: InterCityTransport;
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
    totalBudget: undefined,
    transportToCity: undefined,
    transportBack: undefined,
  };
}

/** 迁移旧版计划数据 — 兼容没有预算/交通字段的旧 JSON */
export function migrateTourPlan(plan: TourPlan): TourPlan {
  if (plan.totalBudget === undefined) {
    plan.totalBudget = undefined;
  }
  if (plan.transportToCity === undefined) {
    plan.transportToCity = undefined;
  }
  if (plan.transportBack === undefined) {
    plan.transportBack = undefined;
  }
  for (const day of plan.dailyPlans) {
    for (const poi of day.pois) {
      if (poi.estimatedCost === undefined) {
        poi.estimatedCost = undefined;
      }
    }
  }
  return plan;
}

/** 预算概览 */
export interface BudgetBreakdown {
  transport: number;
  hotel: number;
  food: number;
  attractions: number;
  shopping: number;
  other: number;
  total: number;
}

/** 计算预算概览 */
export function getBudgetBreakdown(plan: TourPlan): BudgetBreakdown {
  let transport: number = 0;
  let hotel: number = 0;
  let food: number = 0;
  let attractions: number = 0;
  let shopping: number = 0;
  let other: number = 0;

  // 跨城交通
  if (plan.transportToCity?.cost) transport += plan.transportToCity.cost;
  if (plan.transportBack?.cost) transport += plan.transportBack.cost;

  for (const day of plan.dailyPlans) {
    for (const poi of day.pois) {
      const c: number = poi.estimatedCost ?? 0;
      const t: string = poi.type || '';
      if (t.includes('酒店') || t.includes('住宿')) {
        hotel += c;
      } else if (t.includes('餐厅') || t.includes('美食') || t.includes('小吃') || t.includes('咖啡') || t.includes('茶')) {
        food += c;
      } else if (t.includes('景点') || t.includes('公园') || t.includes('风景') || t.includes('博物馆')) {
        attractions += c;
      } else if (t.includes('购物') || t.includes('商场')) {
        shopping += c;
      } else if (t.includes('交通') || t.includes('飞机') || t.includes('高铁') || t.includes('火车') || t.includes('大巴')) {
        transport += c;
      } else {
        other += c;
      }
    }
  }

  const total: number = transport + hotel + food + attractions + shopping + other;
  const result: BudgetBreakdown = {
    transport: transport, hotel: hotel, food: food,
    attractions: attractions, shopping: shopping, other: other, total: total
  };
  return result;
}

/** 跨城交通类型 → emoji */
export function getTransportEmoji(type: string): string {
  switch (type) {
    case 'flight': return '✈️';
    case 'high_speed_rail': return '🚄';
    case 'train': return '🚂';
    case 'bus': return '🚌';
    default: return '🚗';
  }
}

/** 跨城交通类型 → 中文名 */
export function getTransportLabel(type: string): string {
  switch (type) {
    case 'flight': return '飞机';
    case 'high_speed_rail': return '高铁';
    case 'train': return '火车';
    case 'bus': return '大巴';
    default: return '交通';
  }
}
