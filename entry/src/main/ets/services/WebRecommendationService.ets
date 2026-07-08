/**
 * Web 推荐服务
 * 通过 DuckDuckGo 搜索大众点评/美团等网站，提取评分/评论/推荐菜
 * 结果与高德 POI 合并，提供更丰富的推荐
 */
import { Logger } from '../common/Logger';
import { PlatformBridge } from '../platform/PlatformBridge';
import { HttpResponse } from '../platform/network/INetworkProvider';
import {
  parseDuckDuckGoResults, parseBaiduResults, parseRatingFromSnippet, parseReviewCount,
  extractPopularItems, stripHtmlTags, nameSimilarity, normalizePlaceName,
  DdgResult, BaiduResult
} from './WebSearchParser';

const TAG = 'WebRecommendationService';

export interface WebPlaceResult {
  name: string;
  address: string;
  rating: number;          // 0-5, 0 = unknown
  reviewCount: number;     // 0 = unknown
  source: string;          // 'dianping' | 'meituan' | 'web_general'
  sourceUrl: string;
  popularItems: string;    // comma-separated
  latitude: number;
  longitude: number;
  sourceKeywords: string;
}

interface CacheEntry {
  data: WebPlaceResult[];
  expires: number;
}

const MIN_REQUEST_INTERVAL: number = 1500;  // 1.5s between requests
const REQUEST_TIMEOUT: number = 8000;
const CACHE_TTL: number = 30 * 60 * 1000;   // 30 min
const MAX_CACHE_SIZE: number = 50;
const MAX_SEARCHES_PER_CYCLE: number = 3;

export class WebRecommendationService {
  private static instance: WebRecommendationService | null = null;
  private lastRequestTime: number = 0;
  private cache: Record<string, CacheEntry> = {};
  private cacheKeys: string[] = [];
  private searchCount: number = 0;

  private constructor() {}

  static getInstance(): WebRecommendationService {
    if (!WebRecommendationService.instance) {
      WebRecommendationService.instance = new WebRecommendationService();
    }
    return WebRecommendationService.instance;
  }

  /**
   * 并行搜索大众点评+美团，合并去重
   * @param keywords 搜索关键词（如 "火锅"）
   * @param city 城市名（如 "成都"）
   * @param lat 纬度（用于缓存 key）
   * @param lng 经度
   */
  async searchAll(keywords: string, city: string, lat: number, lng: number): Promise<WebPlaceResult[]> {
    this.searchCount = 0;
    const cacheKey: string = `searchAll:${keywords}:${city}`;
    const cached: WebPlaceResult[] | null = this.getCachedResult(cacheKey);
    if (cached) return cached;

    try {
      // 生成搜索词
      const queries: string[] = this.generateSearchQueries(keywords, city);
      const allResults: WebPlaceResult[] = [];

      // 搜索大众点评
      if (this.searchCount < MAX_SEARCHES_PER_CYCLE) {
        const dpResults: WebPlaceResult[] = await this.searchSite('dianping.com', queries, city, 'dianping');
        allResults.push(...dpResults);
      }

      // 搜索美团
      if (this.searchCount < MAX_SEARCHES_PER_CYCLE) {
        const mtResults: WebPlaceResult[] = await this.searchSite('meituan.com', queries, city, 'meituan');
        allResults.push(...mtResults);
      }

      // 去重
      const deduped: WebPlaceResult[] = this.dedupResults(allResults);

      this.setCachedResult(cacheKey, deduped);
      Logger.info(TAG, 'Web search: %{public}d results for "%{public}s" in %{public}s',
        deduped.length, keywords, city);
      return deduped;
    } catch (e) {
      Logger.warn(TAG, 'Web search failed: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  /**
   * 在指定域名搜索（通过 DuckDuckGo site: 语法）
   */
  private async searchSite(
    siteDomain: string, queries: string[], city: string, source: string
  ): Promise<WebPlaceResult[]> {
    const results: WebPlaceResult[] = [];

    for (const q of queries) {
      if (this.searchCount >= MAX_SEARCHES_PER_CYCLE) break;
      const searchQuery: string = `site:${siteDomain} ${q} ${city}`;
      try {
        const html: string = await this.webSearch(searchQuery);
        this.searchCount++;
        if (html.length === 0) continue;

        let webResults: (DdgResult | BaiduResult)[] = [];

        // 检测是否为百度搜索结果（包含 baidu.com 域名）
        if (html.includes('www.baidu.com') || html.includes('百度一下')) {
          webResults = parseBaiduResults(html, siteDomain);
        } else {
          // 否则当作 DDG 结果处理
          webResults = parseDuckDuckGoResults(html, siteDomain);
        }

        for (const r of webResults) {
          const name: string = normalizePlaceName(r.title);
          if (name.length < 2) continue;
          const rating: number = parseRatingFromSnippet(r.snippet);
          const reviewCount: number = parseReviewCount(r.snippet);
          results.push({
            name: name,
            address: '',
            rating: rating,
            reviewCount: reviewCount,
            source: source,
            sourceUrl: r.url,
            popularItems: '',
            latitude: 0,
            longitude: 0,
            sourceKeywords: q
          });
        }
      } catch (e) {
        Logger.warn(TAG, 'searchSite failed for %{public}s: %{public}s', siteDomain, JSON.stringify(e));
      }
    }
    return results;
  }

  /**
   * 抓取大众点评详情页，提取评分/推荐菜
   */
  async enrichFromDianping(url: string): Promise<WebPlaceResult | null> {
    try {
      await this.rateLimit();
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(url,
        { method: 'GET', connectTimeout: 5000, readTimeout: REQUEST_TIMEOUT }
      );
      if (resp.responseCode !== 200) return null;

      const html: string = resp.result;
      const rating: number = parseRatingFromSnippet(stripHtmlTags(html.substring(0, 5000)));
      const popularItems: string = extractPopularItems(html);
      const reviewCount: number = parseReviewCount(stripHtmlTags(html.substring(0, 5000)));

      return {
        name: '', address: '', rating: rating, reviewCount: reviewCount,
        source: 'dianping', sourceUrl: url, popularItems: popularItems,
        latitude: 0, longitude: 0, sourceKeywords: ''
      };
    } catch (e) {
      return null;
    }
  }

  /**
   * 基于关键词+城市生成搜索词组
   */
  generateSearchQueries(keywords: string, city: string): string[] {
    const queries: string[] = [];
    // 主搜索
    queries.push(`${keywords} 推荐`);
    // 加好评筛选
    if (queries.length < 3) queries.push(`${keywords} 好评`);
    // 加热门
    if (queries.length < 3) queries.push(`${keywords} 热门`);
    return queries;
  }

  /**
   * Web 搜索（优先百度，失败时回退到 DuckDuckGo）
   */
  private async webSearch(query: string): Promise<string> {
    await this.rateLimit();
    const bridge: PlatformBridge = PlatformBridge.getInstance();

    // 优先尝试百度搜索
    const baiduUrl: string = `https://www.baidu.com/s?wd=${encodeURI(query)}`;
    try {
      const baiduResp: HttpResponse = await bridge.network.request(
        baiduUrl,
        { method: 'GET', connectTimeout: 5000, readTimeout: REQUEST_TIMEOUT }
      );
      if (baiduResp.responseCode === 200) {
        Logger.info(TAG, 'Baidu search succeeded for: %{public}s', query);
        return baiduResp.result;
      }
      Logger.warn(TAG, 'Baidu search failed: %{public}d', baiduResp.responseCode);
    } catch (e) {
      Logger.warn(TAG, 'Baidu search exception: %{public}s', JSON.stringify(e));
    }

    // 百度失败时回退到 DuckDuckGo（海外用户兜底）
    const ddgUrl: string = `https://lite.duckduckgo.com/lite/?q=${encodeURI(query)}`;
    try {
      const ddgResp: HttpResponse = await bridge.network.request(
        ddgUrl,
        { method: 'GET', connectTimeout: 5000, readTimeout: REQUEST_TIMEOUT }
      );
      if (ddgResp.responseCode === 200) {
        Logger.info(TAG, 'DDG fallback succeeded for: %{public}s', query);
        return ddgResp.result;
      }
      Logger.warn(TAG, 'DDG fallback also failed: %{public}d', ddgResp.responseCode);
    } catch (e) {
      Logger.warn(TAG, 'DDG fallback exception: %{public}s', JSON.stringify(e));
    }

    return '';
  }

  /**
   * 请求间隔限速
   */
  private async rateLimit(): Promise<void> {
    const now: number = Date.now();
    const gap: number = now - this.lastRequestTime;
    if (gap < MIN_REQUEST_INTERVAL) {
      const wait: number = MIN_REQUEST_INTERVAL - gap;
      await new Promise<void>((resolve) => setTimeout(() => { resolve(); }, wait));
    }
    this.lastRequestTime = Date.now();
  }

  /**
   * 去重：名称相似度 > 0.6 视为同一家店
   */
  private dedupResults(results: WebPlaceResult[]): WebPlaceResult[] {
    const deduped: WebPlaceResult[] = [];
    for (const r of results) {
      let isDup: boolean = false;
      for (const d of deduped) {
        if (nameSimilarity(r.name, d.name) > 0.6) {
          isDup = true;
          // 保留评分更高的
          if (r.rating > d.rating) {
            d.rating = r.rating;
            d.reviewCount = r.reviewCount;
            d.sourceUrl = r.sourceUrl;
          }
          break;
        }
      }
      if (!isDup) deduped.push(r);
    }
    return deduped;
  }

  private getCachedResult(key: string): WebPlaceResult[] | null {
    const entry: CacheEntry | undefined = this.cache[key];
    if (entry && entry.expires > Date.now()) {
      return entry.data;
    }
    return null;
  }

  private setCachedResult(key: string, data: WebPlaceResult[]): void {
    // LRU: 超出容量时移除最旧
    if (this.cacheKeys.length >= MAX_CACHE_SIZE) {
      const oldest: string | undefined = this.cacheKeys.shift();
      if (oldest && oldest.length > 0) {
        // Clear cache entry by setting to empty array with expired time
        this.cache[oldest] = { data: [], expires: 0 };
      }
    }
    this.cache[key] = { data: data, expires: Date.now() + CACHE_TTL };
    this.cacheKeys.push(key);
  }

  /** 清除缓存 */
  clearCache(): void {
    this.cache = {};
    this.cacheKeys = [];
  }
}
