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
import { UserBasicInfo } from '../model/UserBasicInfo';
import { ActivitySegment } from '../model/ActivitySegment';
import { Footprint } from '../model/Footprint';
import { APP_TAG, ACTIVITY_LABELS } from '../common/Constants';
import { getPreferenceSearchQueries, matchPreferenceTag } from '../common/TravelPreferenceTags';
import { PlatformBridge } from '../platform/PlatformBridge';
import { HttpResponse } from '../platform/network/INetworkProvider';
import { WebRecommendationService, WebPlaceResult } from './WebRecommendationService';
import { nameSimilarity } from './WebSearchParser';
import { ClaudeService, ClaudeReply } from './ClaudeService';

const TAG = 'RecommendationEngine';
const SEARCH_RADII: number[] = [1000, 2000, 5000]; // 渐进半径：1km → 2km → 5km
const MIN_RECS: number = 10;                        // 最少推荐数

interface UserPref {
  diningWeights: Record<string, number>;  // 餐饮类型权重
  shoppingWeights: Record<string, number>;
  sportsWeights: Record<string, number>;
  avgSpendHour: number;                   // 平均活跃时段
  preferredRadius: number;                // 活动半径(m)
  topPoiTypes: string[];                  // 最常去的POI类型
  userPrefTags: string[];                 // 用户显式偏好标签（软引导用）
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
  enrichment: WebPlaceResult | null;
  poiId: string;
  photoUrl: string;  // Amap 返回的第一张照片 URL（来自 place/around 的 photos[0].url）
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

// 硬编码兜底（AI 不可用时使用）
const FALLBACK_QUERIES: string[] = [
  '火锅 川菜 餐厅', '咖啡 奶茶 甜品', '购物中心 商场', '公园 景点 影院', '健身房 运动'
];

export class RecommendationEngine {
  private context: common.Context | null = null;
  private dao: Dao;
  private prefCache: UserPref | null = null;
  private webService: WebRecommendationService;
  private resultCache: Recommendation[] | null = null;  // 上次成功结果缓存

  constructor(dao: Dao) {
    this.dao = dao;
    this.webService = WebRecommendationService.getInstance();
  }

  setContext(ctx: common.Context): void {
    this.context = ctx;
  }

  /**
   * 主入口：AI 生成搜索意图 + 渐进半径多类别搜索 → 确保 ≥10 条推荐，20-30% 非餐饮
   */
  async generateNow(contextType: string, lat: number, lng: number, doWebSearch: boolean = false): Promise<Recommendation[]> {
    const pref: UserPref = await this.getPreferences();
    const hour: number = new Date().getHours();
    const day: number = new Date().getDay();
    const cityName: string = await this.cityFromCoords(lat, lng);

    // ── 1) AI 生成搜索意图（硬编码兜底）──
    const aiQueries: string[] = await this.getAiSearchQueries(hour, day, pref, cityName);

    // ── 2) 渐进半径搜索（跟踪每个查询的结果，用于交错混合）──
    // queryGroups[query] = 来自该查询的合并结果
    const queryGroups: Record<string, MergedPlace[]> = {};
    for (const q of aiQueries) { queryGroups[q] = []; }

    for (const radius of SEARCH_RADII) {
      let totalCount = 0;
      for (const q of aiQueries) { totalCount += queryGroups[q].length; }
      if (totalCount >= MIN_RECS) break;

      const batchPromises: Promise<PoiResult[]>[] = [];
      for (const q of aiQueries) {
        batchPromises.push(this.amapSearchRadius(q, lat, lng, radius));
      }

      const batchResults: PoiResult[][] = await Promise.all(batchPromises);

      for (let qi = 0; qi < aiQueries.length; qi++) {
        const newPois: MergedPlace[] = this.mergeResults(
          this.dedupPoiResults(batchResults[qi]), []);
        // 去重后加入对应查询的分组
        const existing: MergedPlace[] = queryGroups[aiQueries[qi]];
        for (const np of newPois) {
          let dup = false;
          for (const ex of existing) { if (ex.placeName === np.placeName) { dup = true; break; } }
          if (!dup) existing.push(np);
        }
        queryGroups[aiQueries[qi]] = existing;
      }

      Logger.info(TAG, 'Radius %{public}dm results:', radius);
      for (const q of aiQueries) {
        Logger.info(TAG, '  [%{public}s]: %{public}d', q, queryGroups[q].length);
      }
    }

    // Web 搜索（异步补充）
    const webPlaces: WebPlaceResult[] = doWebSearch
      ? await this.webService.searchAll(aiQueries.join(' '), cityName || '附近', lat, lng).catch(() => [] as WebPlaceResult[])
      : [];

    // ── 3) 交错混合：从每个查询轮流取结果，保证类别多样性 ──
    const interleaved: MergedPlace[] = [];
    let maxQLen = 0;
    for (const q of aiQueries) { if (queryGroups[q].length > maxQLen) maxQLen = queryGroups[q].length; }

    for (let round = 0; round < maxQLen && interleaved.length < MIN_RECS; round++) {
      for (const q of aiQueries) {
        if (round < queryGroups[q].length && interleaved.length < MIN_RECS) {
          interleaved.push(queryGroups[q][round]);
        }
      }
    }

    // 合并 Web 结果（去重追加）
    for (const wp of webPlaces) {
      if (!wp.name || wp.name.length < 2) continue;
      let dup = false;
      for (const im of interleaved) { if (im.placeName === wp.name) { dup = true; break; } }
      if (!dup) {
        interleaved.push({
          placeName: wp.name, placeType: '', latitude: wp.latitude, longitude: wp.longitude,
          address: wp.address, distance: 0, enrichment: wp, poiId: '', photoUrl: ''
        });
      }
    }

    const allMerged: MergedPlace[] = interleaved;
    Logger.info(TAG, 'Interleaved: %{public}d from %{public}d queries + %{public}d web (target ≥%{public}d)',
      allMerged.length, aiQueries.length, webPlaces.length, MIN_RECS);

    if (allMerged.length > 0) {
      let mixed: Recommendation[] = await this.rankAndWrapMerged(allMerged, pref, 'dining', contextType, lat, lng);
      // 数量不足时混合同城历史补齐，避免单独一页全是"你曾去过"
      if (mixed.length < MIN_RECS) {
        const historyRecs: Recommendation[] = await this.fallbackRecs(cityName, contextType, pref, lat, lng);
        for (const hr of historyRecs) {
          if (mixed.length >= MIN_RECS) break;
          let dup = false;
          for (const mr of mixed) { if (mr.placeName === hr.placeName) { dup = true; break; } }
          if (!dup) mixed.push(hr);
        }
      }
      this.resultCache = mixed;
      return mixed;
    }

    // ── 3) 扩大搜索：无关键词搜附近 POI（优先于历史）──
    for (const radius of SEARCH_RADII) {
      const anyPois: PoiResult[] = await this.amapSearchRadius('', lat, lng, radius);
      if (anyPois.length >= MIN_RECS) {
        const recs: Recommendation[] = this.rankAndWrap(anyPois, pref, 'dining', contextType, lat, lng);
        this.resultCache = recs;
        return recs;
      }
    }

    // ── 4) 缓存兜底：API 暂时失败时复用上次结果，不回退到历史 ──
    if (this.resultCache && this.resultCache.length > 0) {
      Logger.info(TAG, 'All searches empty — reusing cached %{public}d results', this.resultCache.length);
      return this.resultCache;
    }

    // ── 5) 最后手段：同城历史（最多 3 条）──
    const historyRecs: Recommendation[] = await this.fallbackRecs(cityName, contextType, pref, lat, lng);
    if (historyRecs.length > 0) return historyRecs.slice(0, 3);

    return [];
  }

  /** 对指定半径执行 Amap 搜索 */
  private async amapSearchRadius(query: string, lat: number, lng: number, radius: number): Promise<PoiResult[]> {
    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const apiKey: string = 'bb0c1640992e6c7f2b1467498d8ae848';
      const url: string =
        `https://restapi.amap.com/v3/place/around?key=${apiKey}&location=${lng},${lat}&radius=${radius}&keywords=${encodeURIComponent(query)}&offset=20&page=1`;
      const resp: HttpResponse = await bridge.network.request(url,
        { method: 'GET', connectTimeout: 5000, readTimeout: 8000 });
      if (resp.responseCode !== 200 || resp.result.length < 20) return [];
      return this.parseAmapJson(resp.result);
    } catch (e) {
      return [];
    }
  }

  /** AI 生成搜索关键词 — AI 自由决定类别和比例，无硬编码限制。用户偏好作为温和引导，不替代 AI 查询。 */
  private async getAiSearchQueries(hour: number, day: number, pref: UserPref, city: string): Promise<string[]> {
    // 加载用户偏好标签，生成 1-2 个偏好相关查询（软引导，不替代 AI）
    let userPrefQueries: string[] = [];
    try {
      const userInfo: UserBasicInfo | null = await Dao.getInstance().queryUserBasicInfo();
      if (userInfo) {
        const tags: string[] = userInfo.getPreferenceTags();
        if (tags.length > 0) {
          userPrefQueries = getPreferenceSearchQueries(tags, 2);
          Logger.info(TAG, 'User pref queries: %{public}s', userPrefQueries.join(', '));
        }
      }
    } catch (e) { /* ignore */ }

    try {
      const claude: ClaudeService = new ClaudeService();
      await claude.loadApiKey();
      if (!claude.hasKey) {
        return [...userPrefQueries, ...FALLBACK_QUERIES];
      }
      const timeLabel: string = hour < 10 ? '早上' : hour < 14 ? '中午' : hour < 17 ? '下午' : hour < 21 ? '晚上' : '深夜';
      const weekLabel: string = (day === 0 || day === 6) ? '周末' : '工作日';
      const topTypes: string = pref.topPoiTypes.slice(0, 3).join('、');
      const prefHint: string = userPrefQueries.length > 0
        ? `用户偏好：${userPrefQueries.join('、')}。可适当参考但不要局限于此。` : '';
      const prompt: string = `用户在${city || '当前城市'}，${weekLabel}${timeLabel}${hour}点。
用户近期去过：${topTypes || '未知'}。
${prefHint}
生成 5 个高德地图POI搜索关键词，用逗号分隔。
要求：必须覆盖至少 2 种不同类别（餐饮+休闲、或购物+运动+餐饮等），不能全是同一类。
根据时间和情境合理分配：早上偏早餐咖啡，中午偏午餐，下午偏休闲购物，晚上偏晚餐娱乐，深夜偏宵夜。
格式示例：川菜,购物中心,咖啡馆,电影院,火锅
只返回逗号分隔的关键词。`;

      const reply: ClaudeReply = await claude.chatSimple(prompt);
      if (reply.text.length > 0 && !reply.text.includes('密钥')) {
        // 先按逗号分隔，如果只有1个再按空格分（AI 可能不按逗号返回）
        let queries: string[] = reply.text.split(/[,，、\n]/).map((s: string) => s.trim()).filter((s: string) => s.length >= 2);
        if (queries.length < 3) {
          queries = reply.text.split(/\s+/).map((s: string) => s.trim()).filter((s: string) => s.length >= 2);
        }
        if (queries.length >= 3) {
          // 在 AI 查询前添加 1-2 个用户偏好查询（软引导）
          const allQueries: string[] = [...userPrefQueries, ...queries.slice(0, 5)];
          Logger.info(TAG, 'AI queries (%{public}d + %{public}d pref): %{public}s',
            queries.length, userPrefQueries.length, allQueries.join(', '));
          return allQueries.slice(0, 7); // 最多 7 个查询
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'AI query generation failed, using fallback');
    }
    // 后备：偏好查询 + 兜底查询
    return [...userPrefQueries, ...FALLBACK_QUERIES];
  }

  // 非目的地 POI 黑名单（快递/设施/交通节点 等不应被推荐）
  private static readonly POI_BLACKLIST: string[] = [
    '快递', '驿站', '停车场', '停车', '厕所', '洗手间', '卫生间',
    '配电', '变电', '垃圾', '收费站', '岗亭', '公交站', '地铁站',
    '加油站', '充电站', '维修', '洗车', 'ATM', '银行', '药店',
    '社区', '街道', '居委会', '警务', '消防', '邮局', '移动',
    '联通', '电信', '营业厅', '服务区', '收费站'
  ];

  /** 过滤非目的地 POI */
  private isDestinationPoi(name: string): boolean {
    if (!name || name.length < 2) return false;
    for (const kw of RecommendationEngine.POI_BLACKLIST) {
      if (name.includes(kw)) return false;
    }
    return true;
  }

  /** 解析 Amap JSON 响应为 PoiResult[]，过滤快递驿站等非目的地，同时提取 POI ID */
  private parseAmapJson(json: string): PoiResult[] {
    const results: PoiResult[] = [];
    const nameRegex: RegExp = new RegExp('"name"\\s*:\\s*"([^"]*)"', 'g');
    const locRegex: RegExp = new RegExp('"location"\\s*:\\s*"([^"]*)"', 'g');
    const typeRegex: RegExp = new RegExp('"type"\\s*:\\s*"([^"]*)"', 'g');
    const addrRegex: RegExp = new RegExp('"address"\\s*:\\s*"([^"]*)"', 'g');
    const distRegex: RegExp = new RegExp('"distance"\\s*:\\s*"([^"]*)"', 'g');
    const names: string[] = []; const locs: string[] = []; const types: string[] = [];
    const addrs: string[] = []; const dists: string[] = [];
    let m: RegExpExecArray | null = nameRegex.exec(json);
    while (m) { names.push(m[1]); m = nameRegex.exec(json); }
    m = locRegex.exec(json); while (m) { locs.push(m[1]); m = locRegex.exec(json); }
    m = typeRegex.exec(json); while (m) { types.push(m[1]); m = typeRegex.exec(json); }
    m = addrRegex.exec(json); while (m) { addrs.push(m[1]); m = addrRegex.exec(json); }
    m = distRegex.exec(json); while (m) { dists.push(m[1]); m = distRegex.exec(json); }
    // 提取每个 POI 的第一张照片：找 "photos":[ 后的第一个 "url"，空数组则记空
    const firstPhotoUrls: string[] = [];
    let searchFrom = 0;
    while (true) {
      const photosIdx: number = json.indexOf('"photos":', searchFrom);
      if (photosIdx < 0) break;
      // 检查是否是空数组 "photos":[]
      const afterPhotos: string = json.substring(photosIdx + 9, photosIdx + 13).trim();
      if (afterPhotos.startsWith('[]')) {
        firstPhotoUrls.push('');  // 空照片
        searchFrom = photosIdx + 12;
        continue;
      }
      const urlIdx: number = json.indexOf('"url":"http', photosIdx + 9);
      if (urlIdx < 0) { firstPhotoUrls.push(''); searchFrom = photosIdx + 12; continue; }
      const urlStart: number = urlIdx + 7;
      const urlEnd: number = json.indexOf('"', urlStart);
      if (urlEnd < 0) break;
      firstPhotoUrls.push(json.substring(urlStart, urlEnd));
      searchFrom = urlEnd + 1;
    }
    for (let i = 0; i < names.length; i++) {
      let poiLat = 0; let poiLng = 0;
      if (i < locs.length) { const parts = locs[i].split(','); if (parts.length === 2) { poiLng = parseFloat(parts[0]); poiLat = parseFloat(parts[1]); } }
      if (this.isDestinationPoi(names[i])) {
        // 使用 i 索引匹配 photo（firstPhotoUrls 与 names 一一对应，按原始 POI 顺序）
        const photoUrl: string = i < firstPhotoUrls.length ? firstPhotoUrls[i] : '';
        results.push({ name: names[i], type: i < types.length ? types[i] : '', latitude: poiLat, longitude: poiLng, address: i < addrs.length ? addrs[i] : '', distance: i < dists.length ? parseInt(dists[i]) : 0, tel: '', id: photoUrl } as PoiResult);
      }
    }
    return results;
  }

  /** 根据 POI 名生成 Unsplash 搜索词 */
  private photoQuery(name: string, placeType: string): string {
    const m: Record<string, string> = {
      'dining':'restaurant food', 'shopping':'shopping mall', 'sports':'gym fitness',
      'leisure':'park nature', 'travel':'travel scenery', 'work':'office building',
      'home':'home cozy', 'commute':'city street'
    };
    let base: string = m[placeType] || 'city life';
    // 加店名前 2 个字增加相关性
    if (name.length >= 2) base = name.substring(0, 2) + ' ' + base;
    return base;
  }

  /** 合并结果去重（按名称） */
  private dedupMerged(places: MergedPlace[]): MergedPlace[] {
    const seen: string[] = [];
    const result: MergedPlace[] = [];
    for (const p of places) {
      const key: string = p.placeName || '';
      if (key.length === 0) continue;
      let dup = false;
      for (const s of seen) { if (s === key) { dup = true; break; } }
      if (!dup) { seen.push(key); result.push(p); }
    }
    return result;
  }

  /** 兼容旧接口，委托给新方法 */
  private async safeAmapHttpSearch(query: string, lat: number, lng: number): Promise<PoiResult[]> {
    return this.amapSearchRadius(query, lat, lng, SEARCH_RADII[0]);
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
        enrichment: enrichment,
        poiId: '',
        photoUrl: p.id || ''   // p.id 现在存储第一个照片 URL（从 parseAmapJson）
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
        enrichment: w,
        poiId: '',
        photoUrl: ''
      });
    }

    return merged;
  }

  /** 合并结果打分排序 */
  private async rankAndWrapMerged(places: MergedPlace[], pref: UserPref,
                                   placeType: string, contextType: string,
                                   lat: number, lng: number): Promise<Recommendation[]> {
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

      const r: Recommendation = this.makeRec(p.placeName, p.placeType || 'dining', contextType, siteLat, siteLng, distVal, score);

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

    // AI 搜索词已自然决定类别比例，直接取 top 结果，确保 ≥10 条
    let mixed: Recommendation[] = results.slice(0, Math.min(results.length, MIN_RECS + 5));

    // 轻度洗牌：打破每次刷新完全相同的顺序（相同位置相同查询的结果不变，但顺序微调）
    for (let i = mixed.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * Math.min(4, i + 1));
      if (i !== j) { const tmp: Recommendation = mixed[i]; mixed[i] = mixed[j]; mixed[j] = tmp; }
    }
    mixed = mixed.slice(0, MIN_RECS);

    // 从 Amap place/around 响应中提取照片（按名称映射，不依赖索引顺序）
    const photoMap: Record<string, string> = {};
    for (const p of places) { if (p.photoUrl) photoMap[p.placeName] = p.photoUrl; }
    for (const r of mixed) {
      const url: string = photoMap[r.placeName] || '';
      if (url) {
        try {
          const ej: Record<string, Object> = r.enrichmentJson.length > 0
            ? JSON.parse(r.enrichmentJson) as Record<string, Object> : {};
          ej['photoUrl'] = url;
          r.enrichmentJson = JSON.stringify(ej);
        } catch (e) { /* ignore */ }
      }
    }

    // 先用富数据生成初始理由
    for (const r of mixed) {
      if (r.enrichmentJson.length > 0) {
        try {
          const ej: Record<string, Object> = JSON.parse(r.enrichmentJson) as Record<string, Object>;
          const rating: number = (ej['rating'] as number) || 0;
          const source: string = (ej['source'] as string) || '';
          const items: string = (ej['popularItems'] as string) || '';
          const sourceLabel: string = source === 'dianping' ? '大众点评' : source === 'meituan' ? '美团' : '';
          if (rating > 0) r.reason = `${sourceLabel}${rating.toFixed(1)}分`;
          if (items.length > 0) r.reason += ` · ${items}`;
        } catch (e) { /* ignore */ }
      }
      // 兜底：无富数据时用关键词描述
      if (!r.reason || r.reason.length === 0) {
        r.reason = this.generateDescription(r.placeName, r.placeType);
      }
    }

    // AI 批量生成推荐理由（覆盖上述初始理由，AI 不可用时保留初始值）
    await this.enrichAiReasons(mixed);

    // 最终确保每条都有理由
    for (const r of mixed) {
      if (!r.reason || r.reason.length === 0) {
        r.reason = '值得一去的好地方';
      }
    }
    return mixed;
  }

  /** AI 批量生成推荐理由（异步，不阻塞主流程） */
  private async enrichAiReasons(recs: Recommendation[]): Promise<void> {
    try {
      const claude: ClaudeService = new ClaudeService();
      await claude.loadApiKey();
      if (recs.length === 0 || !claude.hasKey) return;

      let placeList: string = '';
      for (let i = 0; i < recs.length; i++) {
        placeList += `${i + 1}. ${recs[i].placeName}（${recs[i].placeType || '未知类型'}）\n`;
      }

      const prompt: string = `附近地点：\n${placeList}\n为每个地点写一句推荐语（≤15字），要有画面感、让人想去。用换行分隔。\n示例：\n- 周末遛娃圣地，草坪超大\n- 深夜撸串喝啤酒超爽\n- 隐秘宝藏咖啡馆`;

      const reply: ClaudeReply = await claude.chatSimple(prompt);
      // 跳过错误/无密钥回复
      if (reply.text.length > 0 && !reply.text.includes('密钥') && !reply.text.includes('请先设置')) {
        const lines: string[] = reply.text.split('\n').filter((s: string) => s.trim().length >= 3);
        for (let i = 0; i < Math.min(lines.length, recs.length); i++) {
          const clean: string = lines[i].replace(/^\d+[.、)\s]+/, '').trim();
          if (clean.length > 0 && !clean.includes('密钥')) {
            recs[i].reason = clean;
          }
        }
        Logger.info(TAG, 'AI reasons enriched: %{public}d', Math.min(lines.length, recs.length));
      }
    } catch (e) {
      // AI 失败不阻塞，保留原有 reason
    }
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
      results.push(this.makeRec(p.name, p.type || 'dining', contextType, siteLat, siteLng, distVal, score));
    }
    results.sort((a, b) => {
      const sa: number = scoreMap[a.placeName] ?? 0;
      const sb: number = scoreMap[b.placeName] ?? 0;
      return sb - sa;
    });
    return results.slice(0, MIN_RECS).map(r => {
      const sc: number = scoreMap[r.placeName] ?? 0;
      r.reason = sc > 0.5 ? '附近热门选择' : '周边发现';
      return r;
    });
  }

  // 同城历史降级：仅推荐同城（< 30km）的历史活动，最多 6 条
  private async fallbackRecs(cityName: string, context: string, pref: UserPref,
                             lat: number, lng: number): Promise<Recommendation[]> {
    try {
      const BLOCKED_TYPES: string[] = ['work', 'commute', 'home'];
      const fourteenDaysAgo: number = Date.now() - 14 * 24 * 60 * 60 * 1000;
      const allSegments: ActivitySegment[] = await this.dao.queryAllActivitySegments(200);

      // 过滤：14 天内 + 非屏蔽类型 + 同城（< 30km）
      const SAME_CITY_RADIUS: number = 30000;
      const validSegments: ActivitySegment[] = allSegments.filter(seg =>
        seg.endTime > fourteenDaysAgo
        && seg.activityType && seg.activityType.length > 0
        && !BLOCKED_TYPES.includes(seg.activityType)
        && this.calculateDistance(lat, lng, seg.latitude, seg.longitude) < SAME_CITY_RADIUS
      );

      if (validSegments.length === 0) {
        Logger.warn(TAG, 'No same-city history segments');
        return [];
      }

      // 打分
      const scoredSegments: ScoredSegment[] = [];
      for (const seg of validSegments) {
        let score: number = 0.3;
        if (seg.poiName && seg.poiName.length > 1) score += 0.2;
        const distance: number = this.calculateDistance(lat, lng, seg.latitude, seg.longitude);
        if (distance < 5000) score += 0.3;
        else if (distance < 15000) score += 0.15;
        const durationHours: number = (seg.endTime - seg.startTime) / (60 * 60 * 1000);
        if (durationHours > 0.5) score += Math.min(0.15, durationHours * 0.05);
        scoredSegments.push({ seg, score });
      }

      scoredSegments.sort((a, b) => b.score - a.score);
      const topSegments = scoredSegments.slice(0, 6);

      const recommendations: Recommendation[] = [];
      for (const item of topSegments) {
        const seg = item.seg;
        const rec: Recommendation = new Recommendation();
        rec.placeName = seg.poiName || this.activityLabel(seg.activityType) || '附近地点';
        rec.placeType = seg.activityType;
        rec.latitude = seg.latitude;
        rec.longitude = seg.longitude;
        rec.triggerContext = context;
        rec.reason = cityName ? `${cityName}你曾去过` : '同城你曾去过';
        rec.isAccepted = 0;
        rec.timestamp = Date.now();
        recommendations.push(rec);
      }

      Logger.info(TAG, 'Same-city fallback: %{public}d (in %{public}s)', recommendations.length, cityName);
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
      topPoiTypes: [],
      userPrefTags: []
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

      // 同时加载用户显式偏好标签
      try {
        const userInfo: UserBasicInfo | null = await this.dao.queryUserBasicInfo();
        if (userInfo) {
          pref.userPrefTags = userInfo.getPreferenceTags();
        }
      } catch (e) { /* ignore */ }

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

  /** 根据 POI 名称生成描述介绍（不依赖 placeType，因为传进来的是 context 而非 activity type） */
  private generateDescription(name: string, _placeType: string): string {
    // 按关键词细化描述 — 覆盖足够广，确保大部分 POI 都有匹配
    const descMap: Array<[string[], string]> = [
      [['火锅', '海底捞'], '热气腾腾的火锅店，朋友聚餐首选'],
      [['咖啡', '星巴克', '瑞幸'], '醇香咖啡，享受慢时光'],
      [['奶茶', '茶', '甜品', 'CoCo', '蜜雪'], '甜蜜下午茶，治愈一整天'],
      [['公园', '花园', '绿道'], '散步遛弯，呼吸新鲜空气'],
      [['健身房', '体育馆', '游泳', '运动', '瑜伽'], '燃烧卡路里，释放压力'],
      [['影院', '电影院', '万达', 'IMAX'], '精彩大片上映中'],
      [['商场', '购物', '百货', '银泰', '万达', '万象', '龙湖', '天街'], '逛逛逛买买买的好地方'],
      [['烤肉', '烧烤', '烧肉'], '滋滋美味烤肉，香气四溢'],
      [['面馆', '米粉', '米线', '小吃', '拉面'], '地道风味，一口满足'],
      [['川菜', '麻辣', '串串', '冒菜', '火锅'], '正宗川味，麻辣鲜香'],
      [['日料', '寿司', '拉面', '居酒屋'], '精致日料，视觉味觉双享受'],
      [['KTV', '唱歌', 'K歌'], '尽情欢唱，释放歌喉'],
      [['景区', '景点', '博物馆', '古镇'], '值得一逛的好地方'],
      [['书店', '图书馆', '书城'], '书香时光，充电放松'],
      [['酒吧', '酒馆', '精酿'], '微醺夜晚，放松心情'],
      [['超市', '便利店', '盒马', '永辉', '沃尔玛'], '日常购物补给站'],
      [['酒店', '宾馆', '民宿'], '舒适住宿，宾至如归'],
      [['洗浴', '温泉', '汗蒸', '足疗'], '泡汤放松，洗去疲惫'],
      [['台球', '棋牌', '密室', '剧本', '电竞', '网吧'], '休闲娱乐好去处'],
      [['花', '宠物', '猫咖', '狗咖'], '治愈系萌宠时光'],
      [['烘焙', '面包', '蛋糕'], '新鲜出炉，香甜可口'],
      [['快餐', '汉堡', '炸鸡', '披萨', '肯德基', '麦当劳'], '快速美味，随时享用'],
    ];
    for (const entry of descMap) {
      const kws: string[] = entry[0]; const desc: string = entry[1];
      for (const kw of kws) { if (name.includes(kw)) return desc; }
    }
    // 通用兜底：通过名称长度和结尾词推断
    if (name.includes('餐') || name.includes('饭') || name.includes('食')) return '美食打卡地';
    if (name.includes('店')) return '值得一探的好店';
    if (name.includes('广') || name.includes('中') || name.includes('大')) return '热门去处值得一去';
    return '附近不错的选择';
  }

  /**
   * 给地点打分（基于用户行为偏好 + 用户显式偏好标签）
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

    // 用户显式偏好标签温和加分（最多 +0.10）
    if (pref.userPrefTags.length > 0) {
      const prefBonus: number = matchPreferenceTag(name, pref.topPoiTypes[0] || '', pref.userPrefTags);
      score += prefBonus;
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
    this.resultCache = null;
  }

  /** Amap POI 类型 → 活动类型 */
  private mapPoiType(amapType: string): string {
    if (!amapType) return 'dining';
    if (amapType.includes('餐饮') || amapType.includes('餐厅') || amapType.includes('火锅') || amapType.includes('咖啡') || amapType.includes('奶茶')) return 'dining';
    if (amapType.includes('购物') || amapType.includes('商场') || amapType.includes('超市')) return 'shopping';
    if (amapType.includes('体育') || amapType.includes('运动') || amapType.includes('健身') || amapType.includes('游泳')) return 'sports';
    if (amapType.includes('公园') || amapType.includes('景点') || amapType.includes('风景') || amapType.includes('电影院') || amapType.includes('KTV') || amapType.includes('娱乐')) return 'leisure';
    if (amapType.includes('酒店') || amapType.includes('住宿') || amapType.includes('旅游')) return 'travel';
    if (amapType.includes('公司') || amapType.includes('写字楼')) return 'work';
    if (amapType.includes('交通') || amapType.includes('地铁') || amapType.includes('公交')) return 'commute';
    return 'dining';
  }

  private makeRec(name: string, poiType: string, context: string,
                   lat: number, lng: number, dist: number, score: number): Recommendation {
    const r: Recommendation = new Recommendation();
    r.placeName = name;
    r.placeType = this.mapPoiType(poiType);  // 使用真实 POI 类型，而非上下文
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
