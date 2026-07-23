/**
 * 旅行偏好标签常量
 * 供 UserProfilePage、RecommendationEngine、Agent 共用
 */

/**
 * 跨页面刷新信号 — UserProfilePage 保存后通知 SettingsPage 刷新
 */
export class ProfileRefreshSignal {
  static counter: number = 0;

  static fire(): void {
    ProfileRefreshSignal.counter++;
  }
}

/** 推荐刷新信号 — RecommendPage 刷新后通知 MapPage 更新标记 */
export class RecRefreshSignal {
  static counter: number = 0;

  static fire(): void {
    RecRefreshSignal.counter++;
  }
}

/** 地图标记显隐信号 — SettingsPage 切换开关后通知 MapPage */
export class MapMarkerSignal {
  static counter: number = 0;

  static fire(): void {
    MapMarkerSignal.counter++;
  }
}

/** 用户可选的旅行偏好标签 */
export const TRAVEL_PREFERENCE_OPTIONS: string[] = [
  '美食探索',
  '自然风光',
  '历史文化',
  '购物休闲',
  '户外运动',
  '亲子游乐',
  '夜生活',
  '文艺打卡',
  '小众秘境',
  '都市漫游'
];

/** 偏好标签 → Amap POI 搜索关键词映射 */
export const PREFERENCE_SEARCH_MAP: Record<string, string[]> = {
  '美食探索': ['火锅', '川菜', '日料', '咖啡', '烧烤', '美食'],
  '自然风光': ['公园', '景区', '自然风景', '花海', '湖泊', '山'],
  '历史文化': ['博物馆', '古镇', '寺庙', '历史遗迹', '文化景点'],
  '购物休闲': ['购物中心', '商场', '百货', '步行街', '超市'],
  '户外运动': ['健身房', '游泳', '骑行', '徒步', '攀岩', '滑雪'],
  '亲子游乐': ['游乐园', '动物园', '水族馆', '亲子', '儿童'],
  '夜生活': ['酒吧', 'KTV', '夜店', '夜市', 'livehouse'],
  '文艺打卡': ['咖啡馆', '书店', '画廊', '创意园', '展览'],
  '小众秘境': ['小众', '秘境', '冷门', '打卡', '网红'],
  '都市漫游': ['步行街', '特色街区', '地标', '观景台', '江景']
};

/** 偏好标签 → 对应活动类型 */
export const PREFERENCE_ACTIVITY_MAP: Record<string, string[]> = {
  '美食探索': ['dining'],
  '自然风光': ['leisure', 'travel'],
  '历史文化': ['leisure', 'travel'],
  '购物休闲': ['shopping'],
  '户外运动': ['sports'],
  '亲子游乐': ['leisure'],
  '夜生活': ['leisure', 'dining'],
  '文艺打卡': ['leisure', 'shopping'],
  '小众秘境': ['travel', 'leisure'],
  '都市漫游': ['commute', 'leisure']
};

/**
 * 从偏好标签列表生成搜索关键词（最多返回 2 个）
 * 用于在推荐引擎搜索时温和地引入用户偏好
 */
export function getPreferenceSearchQueries(tags: string[], maxCount: number = 2): string[] {
  const queries: string[] = [];
  for (const tag of tags) {
    const kws: string[] | undefined = PREFERENCE_SEARCH_MAP[tag];
    if (kws && kws.length > 0) {
      // 取该标签的前两个关键词拼接
      queries.push(kws.slice(0, 2).join(' '));
    }
    if (queries.length >= maxCount) break;
  }
  return queries;
}

/**
 * 检查 POI 名称/类型是否与用户偏好标签相关
 * @returns 匹配度 0-1
 */
export function matchPreferenceTag(name: string, poiType: string, tags: string[]): number {
  let score: number = 0;
  for (const tag of tags) {
    const kws: string[] | undefined = PREFERENCE_SEARCH_MAP[tag];
    if (!kws) continue;
    for (const kw of kws) {
      if (name.includes(kw)) {
        score += 0.05;
        break;
      }
    }
    const activityTypes: string[] | undefined = PREFERENCE_ACTIVITY_MAP[tag];
    if (activityTypes && activityTypes.includes(poiType)) {
      score += 0.03;
    }
  }
  return Math.min(score, 0.10); // cap at 0.10
}
