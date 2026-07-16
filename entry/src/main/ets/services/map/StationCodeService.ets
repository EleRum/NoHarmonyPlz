/**
 * 12306 车站代码服务
 * 从 station_name.js 获取城市→车站电报码映射
 * 电报码格式: BJP=北京, CDW=成都, SHH=上海
 */
import { Logger } from '../../common/Logger';
import { http } from '@kit.NetworkKit';

const TAG = 'StationCode';

/** 车站信息 */
interface StationInfo {
  name: string;    // 站名 e.g. "北京西"
  code: string;    // 电报码 e.g. "BXP"
  pinyin: string;  // e.g. "beijingxi"
}

export class StationCodeService {
  private static instance: StationCodeService | null = null;
  private stations: StationInfo[] = [];
  private cityIndex: Map<string, string[]> = new Map(); // 城市名 → 代码列表
  private codeToName: Map<string, string> = new Map();  // 代码 → 站名（反向索引）
  private loaded: boolean = false;
  private loading: boolean = false;

  static getInstance(): StationCodeService {
    if (!StationCodeService.instance) {
      StationCodeService.instance = new StationCodeService();
    }
    return StationCodeService.instance;
  }

  /** 获取城市的所有车站电报码（取第一个为主站，其余为辅） */
  async getMainStationCode(cityName: string): Promise<string> {
    await this.ensureLoaded();
    const name: string = cityName.replace(/[市省]$/, '');
    // 精确匹配
    const codes: string[] | undefined = this.cityIndex.get(name);
    if (codes && codes.length > 0) {
      return codes[0];
    }
    // 前缀匹配（如"成都东"→"成都"）
    for (const key of this.cityIndex.keys()) {
      if (key.startsWith(name) || name.startsWith(key)) {
        const v: string[] | undefined = this.cityIndex.get(key);
        if (v && v.length > 0) return v[0];
      }
    }
    Logger.warn(TAG, 'Station code not found for: %{public}s', cityName);
    return '';
  }

  /** 获取城市的所有车站代码 */
  async getStationCodes(cityName: string): Promise<string[]> {
    await this.ensureLoaded();
    const name: string = cityName.replace(/[市省]$/, '');
    const codes: string[] | undefined = this.cityIndex.get(name);
    if (codes && codes.length > 0) return codes;
    // 前缀匹配
    for (const key of this.cityIndex.keys()) {
      if (key.startsWith(name) || name.startsWith(key)) {
        const v: string[] | undefined = this.cityIndex.get(key);
        if (v && v.length > 0) return v;
      }
    }
    return [];
  }

  private async ensureLoaded(): Promise<void> {
    if (this.loaded) return;
    if (this.loading) {
      // 等待加载完成
      let waited: number = 0;
      while (this.loading && waited < 5000) {
        await new Promise<void>((r) => setTimeout(r, 200));
        waited += 200;
      }
      if (this.loaded) return;
    }
    this.loading = true;
    try {
      await this.fetchStationNames();
      this.loaded = true;
    } catch (e) {
      Logger.warn(TAG, 'Failed to fetch station names, using fallback');
      this.buildFallbackIndex();
      this.loaded = true;
    }
    this.loading = false;
  }

  /** 从 12306 获取车站列表 */
  private async fetchStationNames(): Promise<void> {
    const url: string = 'https://kyfw.12306.cn/otn/resources/js/framework/station_name.js';
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        connectTimeout: 15000,
        readTimeout: 20000,
      } as http.HttpRequestOptions);
      if (resp.responseCode === 200 && resp.result) {
        const resultStr: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
        this.parseStationJs(resultStr);
        Logger.info(TAG, 'Loaded %{public}d stations from 12306', this.stations.length);
      } else {
        throw new Error(`Failed to fetch station_name.js: HTTP ${resp.responseCode}`);
      }
    } finally {
      req.destroy();
    }
  }

  /**
   * 解析 station_name.js
   * 格式: @bjb|北京北|VAP|beijingbei|bjb|0@bjd|北京东|BOP|beijingdong|bjd|1@...
   * 每段: 拼音|站名|电报码|拼音全|拼音首字母|序号
   */
  private parseStationJs(content: string): void {
    this.stations = [];
    this.cityIndex.clear();
    // 去掉 JS 变量声明头
    const start: number = content.indexOf("'") >= 0 ? content.indexOf("'") + 1 : 0;
    const end: number = content.lastIndexOf("'");
    const body: string = end > start ? content.substring(start, end) : content;

    const entries: string[] = body.split('@');
    for (const entry of entries) {
      const parts: string[] = entry.split('|');
      if (parts.length < 3) continue;
      const name: string = parts[1] || '';
      const code: string = parts[2] || '';
      const pinyin: string = parts[3] || '';
      if (!name || !code) continue;

      this.stations.push({ name, code, pinyin });
      // 反向索引：代码 → 站名
      if (!this.codeToName.has(code)) {
        this.codeToName.set(code, name);
      }

      // 索引：提取城市名（去掉"站"和"东西南北"后缀）
      let city: string = name.replace(/[站]$/, '');
      // 保留原站名作为索引，同时提取城市名
      this.addToIndex(name, code);
      // 北京西 → 北京
      const cityMatch: RegExpMatchArray | null = city.match(/^(.+?)[东西南北]$/);
      if (cityMatch) {
        this.addToIndex(cityMatch[1], code);
      } else {
        this.addToIndex(city, code);
      }
    }
  }

  /** 根据电报码反查中文站名 */
  getStationName(code: string): string {
    if (!code || code.length === 0) return '';
    return this.codeToName.get(code) || code;
  }

  private addToIndex(city: string, code: string): void {
    let codes: string[] | undefined = this.cityIndex.get(city);
    if (!codes) {
      codes = [];
      this.cityIndex.set(city, codes);
    }
    if (codes.indexOf(code) < 0) {
      codes.push(code);
    }
  }

  /** 极端兜底：仅 5 个最常见城市。正常情况由 fetchStationNames 从 12306 加载全量数据 */
  private buildFallbackIndex(): void {
    const minimal: Record<string, string> = {
      '北京': 'BJP', '上海': 'SHH', '广州': 'GZQ', '深圳': 'SZQ', '成都': 'CDW',
    };
    for (const city of Object.keys(minimal)) {
      this.cityIndex.set(city, [minimal[city]]);
      this.codeToName.set(minimal[city], city);
    }
    Logger.warn(TAG, 'Using minimal fallback (%{public}d cities) — station_name.js unavailable', Object.keys(minimal).length);
  }
}
