/**
 * 推荐引擎 v2
 * 学习用户行为偏好 → 地图附近搜索 → 按偏好打分排序
 */
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { AmapSearchService } from './map/AmapSearchService';
import { PoiResult } from './map/MapTypes';
import { Recommendation } from '../model/Recommendation';
import { Dao } from '../database/Dao';
import { ActivitySegment } from '../model/ActivitySegment';
import { Footprint } from '../model/Footprint';
import { APP_TAG } from '../common/Constants';

const TAG = 'RecommendationEngine';
const SEARCH_RADIUS: number = 3000; // 搜索半径 3km

interface UserPref {
  diningWeights: Record<string, number>;  // 餐饮类型权重
  shoppingWeights: Record<string, number>;
  sportsWeights: Record<string, number>;
  avgSpendHour: number;                   // 平均活跃时段
  preferredRadius: number;                // 活动半径(m)
  topPoiTypes: string[];                  // 最常去的POI类型
}

// 餐饮关键词 → 搜索 query
const DINING_QUERIES: Array<[string[], string]> = [
  [['火锅', '海底捞'], '火锅'],
  [['咖啡', '星巴克', '拿铁', 'Starbucks'], '咖啡馆'],
  [['面馆', '小吃', '米粉', '米线'], '面馆小吃'],
  [['川菜', '麻辣', '串串', '冒菜'], '川菜'],
  [['日料', '寿司', '拉面'], '日料'],
  [['烧烤', '烤肉'], '烧烤'],
  [['茶', '奶茶', '甜品'], '奶茶甜品'],
];

export class RecommendationEngine {
  private context: common.Context | null = null;
  private dao: Dao;
  private prefCache: UserPref | null = null;

  constructor(dao: Dao) {
    this.dao = dao;
  }

  setContext(ctx: common.Context): void {
    this.context = ctx;
  }

  /**
   * 主入口：根据当下情境生成推荐
   */
  async generateNow(contextType: string, lat: number, lng: number): Promise<Recommendation[]> {
    const pref: UserPref = await this.getPreferences();
    const hour: number = new Date().getHours();
    const day: number = new Date().getDay();
    const results: Recommendation[] = [];

    // ── 根据时段确定搜索意图 ──
    let query: string = '';
    let placeType: string = '';

    if (hour >= 7 && hour < 10) {
      query = '早餐 面馆 咖啡';
      placeType = 'dining';
    } else if (hour >= 11 && hour < 14) {
      query = this.pickDiningQuery(pref);
      placeType = 'dining';
    } else if (hour >= 14 && hour < 17) {
      query = '咖啡馆 甜品 下午茶';
      placeType = 'dining';
    } else if (hour >= 17 && hour < 21) {
      query = this.pickDiningQuery(pref);
      placeType = 'dining';
    } else if ((day === 0 || day === 6) && hour >= 8 && hour < 18) {
      query = '公园 景点 商圈';
      placeType = 'leisure';
    } else {
      query = this.pickDiningQuery(pref);
      placeType = 'dining';
    }

    try {
      Logger.info(TAG, 'nearbySearch: query="%{public}s" radius=%{public}d', query, SEARCH_RADIUS);
      const pois: PoiResult[] = await AmapSearchService.getInstance().nearbySearch(
        query, lat, lng, SEARCH_RADIUS
      );

      if (pois.length > 0) {
        Logger.info(TAG, 'nearbySearch found %{public}d sites', pois.length);
        return this.rankAndWrap(pois, pref, placeType, contextType, lat, lng);
      }
    } catch (e) {
      Logger.warn(TAG, 'nearbySearch failed, using fallback: %{public}s', JSON.stringify(e));
    }

    // 降级：根据偏好从本地已知地点生成推荐
    return this.fallbackRecs(placeType, contextType, pref, lat, lng);
  }

  // 给搜索结果打分排序
  private rankAndWrap(pois: PoiResult[], pref: UserPref,
                       placeType: string, contextType: string,
                       lat: number, lng: number): Recommendation[] {
    const results: Recommendation[] = [];
    const scoreMap: Record<string, number> = {};
    for (const p of pois) {
      if (!p.name || p.name.length === 0) continue;
      const siteLat: number = p.latitude || lat;
      const siteLng: number = p.longitude || lng;
      const distVal: number = p.distance || 0;
      const score: number = this.scorePlace(p.name, pref, distVal);
      scoreMap[p.name] = score;
      results.push(this.makeRec(p.name, placeType, contextType, siteLat, siteLng, distVal, score));
    }
    results.sort((a, b) => {
      const sa: number = scoreMap[a.placeName] ?? 0;
      const sb: number = scoreMap[b.placeName] ?? 0;
      return sb - sa;
    });
    return results.slice(0, 8).map(r => {
      const sc: number = scoreMap[r.placeName] ?? 0;
      r.reason = sc > 0.5 ? '根据你的口味偏好推荐' : '附近热门选择';
      return r;
    });
  }

  // 降级：附近搜索不可用时返回空，不使用硬编码地点（避免跨城推荐）
  private fallbackRecs(placeType: string, context: string, pref: UserPref,
                        lat: number, lng: number): Recommendation[] {
    Logger.warn(TAG, 'nearbySearch unavailable — no fallback, returning empty');
    return [];
  }

  /**
   * 获取/更新用户偏好
   */
  private async getPreferences(): Promise<UserPref> {
    if (this.prefCache) return this.prefCache;

    const pref: UserPref = {
      diningWeights: {},
      shoppingWeights: {},
      sportsWeights: {},
      avgSpendHour: 12,
      preferredRadius: 3000,
      topPoiTypes: []
    };

    try {
      const segments: ActivitySegment[] = await this.dao.queryAllActivitySegments(200);
      const typeCount: Record<string, number> = {};
      let totalHour: number = 0;
      let segCount: number = 0;

      for (const seg of segments) {
        if (!seg.activityType) continue;
        typeCount[seg.activityType] = (typeCount[seg.activityType] || 0) + 1;
        if (seg.poiName && seg.poiName.length > 0) {
          const wt: Record<string, number> =
            seg.activityType === 'dining' ? pref.diningWeights :
            seg.activityType === 'shopping' ? pref.shoppingWeights :
            pref.sportsWeights;
          for (const rule of DINING_QUERIES) {
            for (const kw of rule[0]) {
              if (seg.poiName.includes(kw)) {
                wt[rule[1]] = (wt[rule[1]] || 0) + 1;
                break;
              }
            }
          }
        }
        if (seg.startTime > 0) {
          totalHour += new Date(seg.startTime).getHours();
          segCount++;
        }
      }

      pref.topPoiTypes = Object.keys(typeCount)
        .sort((a, b) => (typeCount[b] || 0) - (typeCount[a] || 0));
      pref.avgSpendHour = segCount > 0 ? totalHour / segCount : 12;

      // 计算活动半径
      const fps: Footprint[] = await this.dao.queryAllFootprints(200);
      if (fps.length >= 2) {
        const lats: number[] = fps.map(f => f.latitude);
        const lngs: number[] = fps.map(f => f.longitude);
        pref.preferredRadius = Math.max(2000,
          (Math.max(...lats) - Math.min(...lats)) * 111000 * 0.5);
      }

      this.prefCache = pref;
    } catch (e) {
      // use defaults
    }

    return pref;
  }

  /**
   * 根据偏好选搜索关键词
   */
  private pickDiningQuery(pref: UserPref): string {
    const w = pref.diningWeights;
    const sorted: string[] = Object.keys(w).sort((a, b) => (w[b] || 0) - (w[a] || 0));
    if (sorted.length > 0) return sorted.slice(0, 3).join(' ');
    return '餐厅 美食';
  }

  /**
   * 给地点打分（基于用户偏好）
   */
  private scorePlace(name: string, pref: UserPref, distance: number): number {
    let score: number = 0.3; // 基础分

    // 类型匹配加分
    for (const rule of DINING_QUERIES) {
      for (const kw of rule[0]) {
        if (name.includes(kw)) {
          score += (pref.diningWeights[rule[1]] || 0) * 0.15;
          break;
        }
      }
    }
    score = Math.min(1.0, score);

    // 距离扣分（超过偏好半径的扣分）
    if (distance > pref.preferredRadius) {
      score *= 0.7;
    }

    return Math.min(1.0, Math.max(0, score));
  }

  /**
   * 清除缓存（数据更新后调用）
   */
  clearCache(): void {
    this.prefCache = null;
  }

  private makeRec(name: string, type: string, context: string,
                   lat: number, lng: number, dist: number, score: number): Recommendation {
    const r: Recommendation = new Recommendation();
    r.placeName = name;
    r.placeType = type;
    r.latitude = lat;
    r.longitude = lng;
    r.triggerContext = context;
    r.reason = '';
    r.isAccepted = 0;
    r.timestamp = Date.now();
    return r;
  }

  /**
   * 根据坐标查找最近的地标名称
   */
  // 高质量地名词尾（含这些词的更可能是商场/餐厅/写字楼等目的地）
  private static readonly GOOD_SUFFIXES: string[] = [
    '广场', '中心', '大厦', '大楼', '商场', '城', '酒店', '饭店',
    '餐厅', '公园', '花园', '影院', '超市', '书店', '咖啡馆',
    '写字楼', '办公楼', '产业园', '科技园', '创意园', '小区',
    '学校', '学院', '大学', '医院', '银行', '博物馆', '图书馆'
  ];

  /** 给地名打分：越长越好、含目的地词加分 */
  private static scorePlaceName(name: string): number {
    let score: number = name.length; // 基础分：名字长者更可能是真地标
    for (const sfx of RecommendationEngine.GOOD_SUFFIXES) {
      if (name.includes(sfx)) score += 10;
    }
    // 扣分项：设施类词汇
    if (name.includes('停车') || name.includes('厕所') || name.includes('洗手间')) score -= 30;
    if (name.includes('配电') || name.includes('变电') || name.includes('垃圾')) score -= 30;
    if (name.includes('公交站') || name.includes('岗亭') || name.includes('收费站')) score -= 30;
    return score;
  }

  static async lookupPlaceName(lat: number, lng: number): Promise<string> {
    try {
      const pois: PoiResult[] = await AmapSearchService.getInstance().nearbySearch('', lat, lng, 200);
      if (pois.length > 0) {
        let best: string = '';
        let bestScore: number = -100;
        for (const p of pois) {
          const name: string = p.name || '';
          const sc: number = RecommendationEngine.scorePlaceName(name);
          if (sc > bestScore) { bestScore = sc; best = name; }
        }
        return best;
      }
    } catch (e) { /* ignore */ }
    return '';
  }
}
