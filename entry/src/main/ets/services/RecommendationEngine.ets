/**
 * 推荐引擎 v2
 * 学习用户行为偏好 → 地图附近搜索 + Web搜索(大众点评/美团) → 按偏好打分排序
 */
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { AmapSearchService } from './map/AmapSearchService';
import { PoiResult } from './map/MapTypes';
import { Recommendation } from '../model/Recommendation';
import { Dao } from '../database/Dao';
import { ActivitySegment } from '../model/ActivitySegment';
import { Footprint } from '../model/Footprint';
import { APP_TAG, ACTIVITY_LABELS } from '../common/Constants';
import { PlatformBridge } from '../platform/PlatformBridge';
import { HttpResponse } from '../platform/network/INetworkProvider';
import { WebRecommendationService, WebPlaceResult } from './WebRecommendationService';
import { nameSimilarity } from './WebSearchParser';

const TAG = 'RecommendationEngine';
const SEARCH_RADIUS: number = 1000; // 搜索半径 1km

interface UserPref {
  diningWeights: Record<string, number>;  // 餐饮类型权重
  shoppingWeights: Record<string, number>;
  sportsWeights: Record<string, number>;
  avgSpendHour: number;                   // 平均活跃时段
  preferredRadius: number;                // 活动半径(m)
  topPoiTypes: string[];                  // 最常去的POI类型
}

interface ScoredSegment {
  seg: ActivitySegment;
  score: number;
}

interface EnrichmentData {
  rating: number;
  reviewCount: number;
  popularItems: string;
  sourceUrl: string;
  source: string;
  tags: string[];
  enrichmentTimestamp: number;
}

/** Amap + Web 合并结果 */
interface MergedPlace {
  placeName: string;
  placeType: string;
  latitude: number;
  longitude: number;
  address: string;
  distance: number;
  enrichment: WebPlaceResult | null;    // Web 富数据（评分/评论/推荐菜）
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
  private webService: WebRecommendationService;

  constructor(dao: Dao) {
    this.dao = dao;
    this.webService = WebRecommendationService.getInstance();
  }

  setContext(ctx: common.Context): void {
    this.context = ctx;
  }

  /**
   * 主入口：根据当下情境生成推荐
   * @param doWebSearch 是否执行 Web 搜索（大众点评/美团），隔轮执行以控制频率
   */
  async generateNow(contextType: string, lat: number, lng: number, doWebSearch: boolean = false): Promise<Recommendation[]> {
    const pref: UserPref = await this.getPreferences();
    const hour: number = new Date().getHours();
    const day: number = new Date().getDay();

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

    // ── 并行多源搜索 ──
    const cityName: string = await this.cityFromCoords(lat, lng);
    const broadQuery: string = this.pickFallbackQuery(placeType, hour, day);

    // 同时搜：精确关键词 + 宽泛关键词 + Web（可选）
    const searchPromises: Promise<PoiResult[] | WebPlaceResult[] | PoiResult[]>[] = [
      this.safeAmapHttpSearch(query, lat, lng),
      this.safeAmapHttpSearch(broadQuery, lat, lng),
      doWebSearch
        ? this.webService.searchAll(query, cityName.length > 0 ? cityName : '附近', lat, lng).catch((): WebPlaceResult[] => [])
        : Promise.resolve([] as WebPlaceResult[])
    ];
    const searchResults: (PoiResult[] | WebPlaceResult[] | PoiResult[])[] = await Promise.all(searchPromises);
    const amapPois: PoiResult[] = searchResults[0] as PoiResult[];
    const broadPois: PoiResult[] = searchResults[1] as PoiResult[];
    const webPlaces: WebPlaceResult[] = searchResults[2] as WebPlaceResult[];

    Logger.info(TAG, 'Amap(exact): %{public}d, Amap(broad): %{public}d, Web: %{public}d',
      amapPois.length, broadPois.length, webPlaces.length);

    // ── 合并去重（精确 Amap + 宽泛 Amap + Web）──
    const allPois: PoiResult[] = this.dedupPoiResults(amapPois.concat(broadPois));
    const merged: MergedPlace[] = this.mergeResults(allPois, webPlaces);

    if (merged.length > 0) {
      return this.rankAndWrapMerged(merged, pref, placeType, contextType, lat, lng);
    }

    // 最终降级：从历史活动智能推荐
    const historyRecs: Recommendation[] = await this.fallbackRecs(placeType, contextType, pref, lat, lng);
    if (historyRecs.length > 0) {
      return historyRecs;
    }

    // 终极兜底：无关键词搜索附近任意 POI
    Logger.info(TAG, 'All searches empty — trying keyword-less nearby discovery');
    const anyPois: PoiResult[] = await this.safeAmapHttpSearch('', lat, lng);
    if (anyPois.length > 0) {
      return this.rankAndWrap(anyPois, pref, placeType, contextType, lat, lng);
    }

    return [];
  }

  /** 直接 HTTP 调 Amap REST API（不依赖 WebView/JS 桥） */
  private async safeAmapHttpSearch(query: string, lat: number, lng: number): Promise<PoiResult[]> {
    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const apiKey: string = 'bb0c1640992e6c7f2b1467498d8ae848';
      const url: string =
        `https://restapi.amap.com/v3/place/around?key=${apiKey}&location=${lng},${lat}&radius=${SEARCH_RADIUS}&keywords=${encodeURIComponent(query)}&offset=20&page=1`;

      Logger.info(TAG, 'nearbySearch(HTTP): url=%{public}s', url);
      const resp: HttpResponse = await bridge.network.request(
        url, { method: 'GET', connectTimeout: 5000, readTimeout: 8000 }
      );

      Logger.info(TAG, 'nearbySearch(HTTP): responseCode=%{public}d', resp.responseCode);
      if (resp.responseCode !== 200) {
        return [];
      }

      const json: string = resp.result;
      if (json.length < 20) {
        Logger.warn(TAG, 'nearbySearch(HTTP): response too short');
        return [];
      }

      // 简单解析：按 "name":"xxx","location":"lng,lat" 配对提取
      const results: PoiResult[] = [];
      const nameRegex: RegExp = new RegExp('"name"\\s*:\\s*"([^"]*)"', 'g');
      const locRegex: RegExp = new RegExp('"location"\\s*:\\s*"([^"]*)"', 'g');
      const typeRegex: RegExp = new RegExp('"type"\\s*:\\s*"([^"]*)"', 'g');
      const addrRegex: RegExp = new RegExp('"address"\\s*:\\s*"([^"]*)"', 'g');
      const distRegex: RegExp = new RegExp('"distance"\\s*:\\s*"([^"]*)"', 'g');

      // 收集所有字段
      const names: string[] = [];
      const locs: string[] = [];
      const types: string[] = [];
      const addrs: string[] = [];
      const dists: string[] = [];

      let m: RegExpExecArray | null = nameRegex.exec(json);
      while (m) { names.push(m[1]); m = nameRegex.exec(json); }

      m = locRegex.exec(json);
      while (m) { locs.push(m[1]); m = locRegex.exec(json); }

      m = typeRegex.exec(json);
      while (m) { types.push(m[1]); m = typeRegex.exec(json); }

      m = addrRegex.exec(json);
      while (m) { addrs.push(m[1]); m = addrRegex.exec(json); }

      m = distRegex.exec(json);
      while (m) { dists.push(m[1]); m = distRegex.exec(json); }

      // 按 name 数量合并（name 必须存在，其余可选）
      const count: number = names.length;
      for (let i: number = 0; i < count; i++) {
        let poiLat: number = 0;
        let poiLng: number = 0;
        if (i < locs.length) {
          const parts: string[] = locs[i].split(',');
          if (parts.length === 2) {
            poiLng = parseFloat(parts[0]);
            poiLat = parseFloat(parts[1]);
          }
        }
        const distVal: number = i < dists.length ? parseInt(dists[i]) : 0;
        results.push({
          name: names[i],
          type: i < types.length ? types[i] : '',
          latitude: poiLat,
          longitude: poiLng,
          address: i < addrs.length ? addrs[i] : '',
          distance: isNaN(distVal) ? 0 : distVal,
          tel: ''
        } as PoiResult);
      }

      Logger.info(TAG, 'nearbySearch(HTTP): %{public}d results', results.length);
      return results;
    } catch (e) {
      Logger.warn(TAG, 'nearbySearch HTTP failed: %{public}s', JSON.stringify(e));
    }
    return [];
  }

  /** 反地理编码获取城市名（直接 HTTP 调用 Amap REST API，不依赖 WebView） */
  private async cityFromCoords(lat: number, lng: number): Promise<string> {
    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(
        `https://restapi.amap.com/v3/geocode/regeo?key=bb0c1640992e6c7f2b1467498d8ae848&location=${lng},${lat}&radius=1000&extensions=base`,
        { method: 'GET', connectTimeout: 5000, readTimeout: 8000 }
      );
      if (resp.responseCode === 200) {
        const json: string = resp.result;
        // 从 JSON 提取城市名: "addressComponent":{"city":"成都市"}
        const cityRegex: RegExp = new RegExp('"city"\\s*:\\s*"([^"]+)"');
        const cityMatch: RegExpExecArray | null = cityRegex.exec(json);
        if (cityMatch && cityMatch[1].length > 0) {
          return cityMatch[1];
        }
        // 如果 city 为空（直辖市），取 province
        const provRegex: RegExp = new RegExp('"province"\\s*:\\s*"([^"]+)"');
        const provMatch: RegExpExecArray | null = provRegex.exec(json);
        if (provMatch && provMatch[1].length > 0) {
          return provMatch[1];
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'cityFromCoords HTTP failed: %{public}s', JSON.stringify(e));
    }
    // 降级：尝试通过 AmapSearchService（需要 WebView）
    try {
      const place: string = await AmapSearchService.getInstance().lookupNearestPlace(lat, lng);
      if (place.length > 0) {
        const cityRegex: RegExp = new RegExp('^([一-龥]{2,4}市)');
        const cityMatch: RegExpExecArray | null = cityRegex.exec(place);
        if (cityMatch) return cityMatch[1];
        if (place.length >= 2) return place.substring(0, 2);
      }
    } catch (e) { /* ignore */ }
    return '';
  }

  /** 去重 POI 结果（同名去重） */
  private dedupPoiResults(pois: PoiResult[]): PoiResult[] {
    const seen: string[] = [];
    const result: PoiResult[] = [];
    for (const p of pois) {
      const key: string = p.name || '';
      if (key.length === 0) continue;
      let isDup: boolean = false;
      for (const s of seen) {
        if (s === key) { isDup = true; break; }
      }
      if (!isDup) {
        seen.push(key);
        result.push(p);
      }
    }
    return result;
  }

  /** 合并 Amap POI + Web 结果，按名称相似度去重 */
  private mergeResults(amapPois: PoiResult[], webPlaces: WebPlaceResult[]): MergedPlace[] {
    const merged: MergedPlace[] = [];
    const usedWebIndices: number[] = [];

    // Amap 结果优先，尝试匹配 Web 富数据
    for (const p of amapPois) {
      if (!p.name || p.name.length === 0) continue;
      let enrichment: WebPlaceResult | null = null;
      for (let wi = 0; wi < webPlaces.length; wi++) {
        if (usedWebIndices.includes(wi)) continue;
        if (nameSimilarity(p.name, webPlaces[wi].name) > 0.6) {
          enrichment = webPlaces[wi];
          usedWebIndices.push(wi);
          break;
        }
      }
      merged.push({
        placeName: p.name,
        placeType: p.type || '',
        latitude: p.latitude,
        longitude: p.longitude,
        address: p.address || '',
        distance: p.distance || 0,
        enrichment: enrichment
      });
    }

    // Web 独有结果（Amap 未匹配的）
    for (let wi = 0; wi < webPlaces.length; wi++) {
      if (usedWebIndices.includes(wi)) continue;
      const w: WebPlaceResult = webPlaces[wi];
      if (w.name.length < 2) continue;
      merged.push({
        placeName: w.name,
        placeType: '',
        latitude: w.latitude,
        longitude: w.longitude,
        address: w.address,
        distance: 0,
        enrichment: w
      });
    }

    return merged;
  }

  /** 合并结果打分排序 */
  private rankAndWrapMerged(places: MergedPlace[], pref: UserPref,
                             placeType: string, contextType: string,
                             lat: number, lng: number): Recommendation[] {
    const results: Recommendation[] = [];
    const scoreMap: Record<string, number> = {};

    for (const p of places) {
      const siteLat: number = p.latitude || lat;
      const siteLng: number = p.longitude || lng;
      const distVal: number = p.distance || 0;
      let score: number = this.scorePlace(p.placeName, pref, distVal);

      // Web 富数据加分
      if (p.enrichment) {
        if (p.enrichment.rating > 4.0) score += 0.1;
        if (p.enrichment.reviewCount > 500) score += 0.05;
      }

      score = Math.min(1.0, Math.max(0, score));
      scoreMap[p.placeName] = score;

      const r: Recommendation = this.makeRec(p.placeName, placeType, contextType, siteLat, siteLng, distVal, score);

      // 附加 Web 富数据
      if (p.enrichment) {
        const e: WebPlaceResult = p.enrichment;
        r.enrichmentJson = JSON.stringify({
          rating: e.rating,
          reviewCount: e.reviewCount,
          popularItems: e.popularItems,
          sourceUrl: e.sourceUrl,
          source: e.source,
          tags: [],
          enrichmentTimestamp: Date.now()
        });
      }

      results.push(r);
    }

    results.sort((a, b) => {
      const sa: number = scoreMap[a.placeName] ?? 0;
      const sb: number = scoreMap[b.placeName] ?? 0;
      return sb - sa;
    });

    return results.slice(0, 8).map(r => {
      const sc: number = scoreMap[r.placeName] ?? 0;
      // 丰富化 reason
      if (r.enrichmentJson.length > 0) {
        try {
          const ej: EnrichmentData = JSON.parse(r.enrichmentJson) as EnrichmentData;
          const rating: number = ej.rating || 0;
          const source: string = ej.source || '';
          const popularItems: string = ej.popularItems || '';
          const sourceLabel: string = source === 'dianping' ? '大众点评' : source === 'meituan' ? '美团' : '网页';
          let reason: string = '';
          if (rating > 0) reason += `${sourceLabel}评分${rating.toFixed(1)}`;
          if (popularItems.length > 0) reason += ` · 推荐：${popularItems}`;
          r.reason = reason.length > 0 ? reason : (sc > 0.5 ? '根据你的口味偏好推荐' : '附近热门选择');
        } catch (e) {
          r.reason = sc > 0.5 ? '根据你的口味偏好推荐' : '附近热门选择';
        }
      } else {
        r.reason = sc > 0.5 ? '根据你的口味偏好推荐' : '附近热门选择';
      }
      return r;
    });
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

  // 最终降级：从用户历史 ActivitySegment 中智能提取推荐
  private async fallbackRecs(placeType: string, context: string, pref: UserPref,
                             lat: number, lng: number): Promise<Recommendation[]> {
    try {
      // 不允许作为推荐的活动类型
      const BLOCKED_TYPES: string[] = ['work', 'commute', 'home'];

      // 获取最近 14 天的活动片段
      const fourteenDaysAgo: number = Date.now() - 14 * 24 * 60 * 60 * 1000;
      const allSegments: ActivitySegment[] = await this.dao.queryAllActivitySegments(200);
      const validSegments: ActivitySegment[] = allSegments.filter(
        seg => seg.endTime > fourteenDaysAgo
          && seg.activityType && seg.activityType.length > 0
          && !BLOCKED_TYPES.includes(seg.activityType)
      );

      if (validSegments.length === 0) {
        Logger.warn(TAG, 'No valid history segments (filtered work/commute/home)');
        return [];
      }

      // 打分所有有效 segment（不加类型限制），但匹配当前时段的加分
      const scoredSegments: ScoredSegment[] = [];
      for (const seg of validSegments) {
        let score: number = 0.3; // 基础分

        // 1. 类型匹配当前时段 → 大幅加分
        if (seg.activityType === placeType) {
          score += 0.3;
        } else if (seg.activityType === 'dining') {
          score += 0.2;
        } else if (seg.activityType === 'shopping') {
          score += 0.15;
        } else if (seg.activityType === 'leisure' || seg.activityType === 'travel') {
          score += 0.1;
        }

        // 2. 有 POI 名称 → 加分
        if (seg.poiName && seg.poiName.length > 1) {
          score += 0.15;
        }

        // 3. 距离扣分
        const distance: number = this.calculateDistance(lat, lng, seg.latitude, seg.longitude);
        if (distance > 50000) {
          score *= 0.2;
        } else if (distance > 20000) {
          score *= 0.3;
        } else if (distance > 10000) {
          score *= 0.5;
        } else if (distance > 5000) {
          score *= 0.7;
        }

        // 4. 时长加分
        const durationHours: number = (seg.endTime - seg.startTime) / (60 * 60 * 1000);
        if (durationHours > 0.5) {
          score += Math.min(0.2, durationHours * 0.1);
        }

        scoredSegments.push({ seg: seg, score: score });
      }

      // 按分数排序，取前 3 个
      scoredSegments.sort((a, b) => b.score - a.score);
      const topSegments = scoredSegments.slice(0, 3);

      // 转换为 Recommendation 对象
      const recommendations: Recommendation[] = [];
      for (const item of topSegments) {
        const seg = item.seg;
        const rec: Recommendation = new Recommendation();
        rec.placeName = seg.poiName || this.activityLabel(seg.activityType) || '推荐地点';
        rec.placeType = seg.activityType;
        rec.latitude = seg.latitude;
        rec.longitude = seg.longitude;
        rec.triggerContext = context;
        rec.reason = '根据你的历史出行习惯推荐';
        rec.isAccepted = 0;
        rec.timestamp = Date.now();
        recommendations.push(rec);
      }

      Logger.info(TAG, 'Fallback recs from history: %{public}d (placeType=%{public}s)',
        recommendations.length, placeType);
      return recommendations;

    } catch (e) {
      Logger.warn(TAG, 'Fallback recs failed: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  // 计算两点间距离（简单球面距离）
  private calculateDistance(lat1: number, lng1: number, lat2: number, lng2: number): number {
    const R = 6371000; // 地球半径（米）
    const dLat = (lat2 - lat1) * Math.PI / 180;
    const dLng = (lng2 - lng1) * Math.PI / 180;
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
              Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
              Math.sin(dLng / 2) * Math.sin(dLng / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
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
   * 二级重试：用宽泛关键词（不依赖用户偏好）
   */
  private pickFallbackQuery(placeType: string, hour: number, day: number): string {
    if (placeType === 'leisure') {
      return '公园 景点 商场';
    }
    if (hour >= 7 && hour < 10) {
      return '早餐 面馆';
    } else if (hour >= 11 && hour < 14) {
      return '午餐 餐厅 美食';
    } else if (hour >= 14 && hour < 17) {
      return '咖啡 下午茶';
    } else if (hour >= 17 && hour < 21) {
      return '晚餐 餐厅 美食';
    }
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

  /**
   * 获取活动类型的中文标签
   */
  private activityLabel(type: string): string {
    return ACTIVITY_LABELS[type] || type;
  }
}
