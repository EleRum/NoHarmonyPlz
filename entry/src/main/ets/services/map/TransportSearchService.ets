/**
 * 票务搜索服务
 * 火车：12306 官方 queryG API（免费，返回当天全部车次 + 余票）
 * 机票：WebXml 免费 WebService（非商用免费）
 */
import { Logger } from '../../common/Logger';
import { PlatformBridge } from '../../platform/PlatformBridge';
import { StationCodeService } from './StationCodeService';
import { http } from '@kit.NetworkKit';

const TAG = 'TransportSearch';

/** 票务查询参数 */
export interface TicketQueryParams {
  from: string;      // 出发城市/站名
  to: string;        // 到达城市/站名
  date: string;      // 出发日期 YYYY-MM-DD
  type?: string;     // train / flight
}

/** 12306 价格（从 queryAllPublicPrice API） */
interface TicketPrice {
  ze?: number;   // 二等座
  zy?: number;   // 一等座
  swz?: number;  // 商务座
  yz?: number;   // 硬座
  yw?: number;   // 硬卧
  rw?: number;   // 软卧
  wz?: number;   // 无座
}

/** 票务结果（统一格式，供 UI 展示） */
export interface TicketOption {
  // 基础信息
  type: string;           // train / high_speed_rail / flight
  tripNo: string;         // 车次/航班号 如 G89 / CA1234
  // 站点
  fromStation: string;    // 出发站/机场
  toStation: string;      // 到达站/机场
  // 时间
  departureTime: string;  // "08:30"
  arrivalTime: string;    // "16:30"
  duration: number;       // 秒
  // 价格
  price: number;          // 最低票价
  seatTypes?: string;     // 可选座位类型 "二等座¥780,一等座¥1250"
  // 其他
  note?: string;          // 备注(余票状态等)
}

export class TransportSearchService {
  private static instance: TransportSearchService | null = null;
  /** 最近一次查询的诊断信息，调用方读取后自行重置 */
  public lastDiag: string = '';

  static getInstance(): TransportSearchService {
    if (!TransportSearchService.instance) {
      TransportSearchService.instance = new TransportSearchService();
    }
    return TransportSearchService.instance;
  }

  /** 搜索火车票 — 12306 queryG API（免费，返回当天全部车次 + 余票）
   *  端点: kyfw.12306.cn/otn/leftTicket/queryG */
  async searchTrainsVia12306(fromCity: string, toCity: string, date: string): Promise<TicketOption[]> {
    this.lastDiag = '';
    // 12306 必须传日期 — 未指定时默认今天
    const queryDate: string = date && date.length > 0 ? date : this.defaultDateStr();
    if (!queryDate) {
      this.lastDiag = '[车站] 日期无法确定';
      Logger.warn(TAG, '12306: cannot determine date');
      return [];
    }

    const stnService: StationCodeService = StationCodeService.getInstance();
    const fromCodes: string[] = await stnService.getStationCodes(fromCity);
    const toCodes: string[] = await stnService.getStationCodes(toCity);

    if (fromCodes.length === 0) {
      this.lastDiag = '[车站] 出发城市"' + fromCity + '"未匹配到车站代码';
      Logger.warn(TAG, '12306: no station codes for %{public}s', fromCity);
      return [];
    }
    if (toCodes.length === 0) {
      this.lastDiag = '[车站] 到达城市"' + toCity + '"未匹配到车站代码';
      Logger.warn(TAG, '12306: no station codes for %{public}s', toCity);
      return [];
    }

    // 只取主站查询（减少12306请求量，避免触发限流）
    const maxFrom: number = Math.min(1, fromCodes.length);
    const maxTo: number = Math.min(1, toCodes.length);
    const allOptions: TicketOption[] = [];
    const seenTrips: Set<string> = new Set();

    for (let fi: number = 0; fi < maxFrom; fi++) {
      for (let ti: number = 0; ti < maxTo; ti++) {
        const fromCode: string = fromCodes[fi];
        const toCode: string = toCodes[ti];
        if (fromCode === toCode) continue;

        try {
          const options: TicketOption[] = await this.query12306(fromCode, toCode, queryDate);
          for (const o of options) {
            const key: string = `${o.tripNo}|${o.fromStation}|${o.toStation}`;
            if (!seenTrips.has(key)) {
              seenTrips.add(key);
              allOptions.push(o);
            }
          }
        } catch (e) {
          Logger.warn(TAG, '12306 query failed %{public}s→%{public}s', fromCode, toCode);
        }
      }
    }

    // 查询价格（独立 API，和车次搜索需要同一个 session）
    if (allOptions.length > 0) {
      try {
        const priceMap: Record<string, TicketPrice> = await this.query12306Prices(fromCodes[0], toCodes[0], queryDate);
        for (const opt of allOptions) {
          const p: TicketPrice | undefined = priceMap[opt.tripNo];
          if (p) {
            opt.price = p.ze || p.yz || p.yw || 0; // 最低价
            const seatParts: string[] = [];
            if (p.swz && p.swz > 0) seatParts.push('商务座¥' + p.swz.toFixed(1));
            if (p.zy && p.zy > 0) seatParts.push('一等座¥' + p.zy.toFixed(1));
            if (p.ze && p.ze > 0) seatParts.push('二等座¥' + p.ze.toFixed(1));
            if (p.yw && p.yw > 0) seatParts.push('硬卧¥' + p.yw.toFixed(1));
            if (p.rw && p.rw > 0) seatParts.push('软卧¥' + p.rw.toFixed(1));
            if (p.yz && p.yz > 0) seatParts.push('硬座¥' + p.yz.toFixed(1));
            if (p.wz && p.wz > 0) seatParts.push('无座¥' + p.wz.toFixed(1));
            opt.seatTypes = seatParts.join(', ');
          }
        }
      } catch (e) {
        Logger.warn(TAG, 'Price query failed: %{public}s', JSON.stringify(e));
      }
    }

    // 按出发时间排序
    allOptions.sort((a: TicketOption, b: TicketOption): number => {
      if (a.departureTime && b.departureTime) {
        return a.departureTime.localeCompare(b.departureTime);
      }
      return 0;
    });

    Logger.info(TAG, '12306: %{public}s→%{public}s = %{public}d trains',
      fromCity, toCity, allOptions.length);
    return allOptions;
  }

  /** 调用 12306 queryG — 最多重试4次，HTML拦截则延长等待 */
  private async query12306(fromCode: string, toCode: string, date: string): Promise<TicketOption[]> {
    let lastErr: string = '';
    for (let retry: number = 0; retry < 4; retry++) {
      const req: http.HttpRequest = http.createHttp();
      try {
        const url: string =
          'https://kyfw.12306.cn/otn/leftTicket/queryG' +
          `?leftTicketDTO.train_date=${encodeURIComponent(date)}` +
          `&leftTicketDTO.from_station=${encodeURIComponent(fromCode)}` +
          `&leftTicketDTO.to_station=${encodeURIComponent(toCode)}` +
          '&purpose_codes=ADULT';

        const resp: http.HttpResponse = await req.request(url, {
          method: http.RequestMethod.GET,
          header: {
            'Host': 'kyfw.12306.cn',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': 'application/json, text/plain, */*',
            'Referer': 'https://www.12306.cn/',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            'X-Requested-With': 'XMLHttpRequest',
            'Connection': 'keep-alive',
            'Cache-Control': 'no-cache',
          },
          connectTimeout: 30000, readTimeout: 20000,
        } as http.HttpRequestOptions);

        if (resp.responseCode !== 200 || !resp.result) {
          throw new Error(`HTTP_${resp.responseCode}`);
        }

        const resultStr: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
        // 12306 反爬：返回HTML而非JSON时直接判定被拦截
        if (resultStr.trimStart().startsWith('<!') || resultStr.trimStart().startsWith('<html') ||
            resultStr.includes('<HTML>') || resultStr.includes('<script')) {
          throw new Error('REJECTED_HTML_NOT_JSON');
        }
        const json: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
        const httpstatus: number = (json['httpstatus'] as number) ?? 200;
        if (httpstatus !== 200) {
          throw new Error(`REJECTED_httpstatus=${httpstatus}`);
        }

        const data: Record<string, Object> = json['data'] as Record<string, Object>;
        const resultArr: string[] = (data?.['result'] as string[]) ?? [];
        if (resultArr.length === 0) {
          this.lastDiag = '[queryG] ' + fromCode + '→' + toCode + ' 返回0条结果(该日期无车次)';
          Logger.warn(TAG, '12306 returned 0 results for %{public}s→%{public}s', fromCode, toCode);
        }

        return this.parse12306Result(resultArr, fromCode, toCode);
      } catch (e) {
        lastErr = JSON.stringify(e);
        // 补充原生错误信息（e.code / e.message 可能不在 stringify 里）
        try {
          const code: string = String((e as Record<string, number>)['code'] ?? '');
          const msg: string = String((e as Record<string, string>)['message'] ?? '');
          if (code && code !== 'undefined') lastErr += ' code=' + code;
          if (msg && msg !== 'undefined') lastErr += ' msg=' + msg;
        } catch (_ign) { /* ignore */ }
        if (lastErr.includes('REJECTED_HTML_NOT_JSON')) {
          this.lastDiag = '[queryG] ' + fromCode + '→' + toCode + ' 被反爬拦截(返回HTML非JSON)';
        } else if (lastErr === '{}' || lastErr === '0' || lastErr.includes('"responseCode":-1')) {
          this.lastDiag = '[queryG] ' + fromCode + '→' + toCode + ' 连接失败(网络不可达/TLS拒绝)';
        } else if (lastErr.includes('INIT_HTTP_')) {
          const m: RegExpMatchArray | null = lastErr.match(/INIT_HTTP_(\d+)/);
          this.lastDiag = '[init] ' + fromCode + '→' + toCode + ' HTTP' + (m ? m[1] : '?');
        } else if (lastErr.includes('HTTP_-1') || lastErr.includes('timeout') || lastErr.includes('TIMEOUT')) {
          this.lastDiag = '[queryG] ' + fromCode + '→' + toCode + ' HTTP连接失败/超时';
        } else if (lastErr.includes('REJECTED_httpstatus=')) {
          this.lastDiag = '[queryG] ' + fromCode + '→' + toCode + ' 12306拒绝(httpstatus≠200)';
        } else if (lastErr.includes('Unexpected Text') || lastErr.includes('Invalid Token') || lastErr.includes('SyntaxError')) {
          this.lastDiag = '[queryG] ' + fromCode + '→' + toCode + ' 响应非JSON(可能被反爬)';
        } else if (lastErr.includes('HTTP_400')) {
          this.lastDiag = '[queryG] ' + fromCode + '→' + toCode + ' 请求被拒(HTTP400，缺Cookie或参数错误)';
        } else if (lastErr.includes('HTTP_')) {
          const httpCode: string = lastErr.match(/HTTP_(\d+)/)?.[1] ?? '?';
          this.lastDiag = '[queryG] ' + fromCode + '→' + toCode + ' HTTP' + httpCode;
        } else {
          this.lastDiag = '[queryG] ' + fromCode + '→' + toCode + ' 异常: ' + lastErr.substring(0, 60);
        }
        Logger.warn(TAG, '12306 queryG attempt %{public}d/4 failed %{public}s→%{public}s: %{public}s',
          retry + 1, fromCode, toCode, lastErr);
      } finally {
        req.destroy();
      }
      // 反爬拦截 → 等更久；连接失败 → 短等
      const isAntiBot: boolean = lastErr.includes('REJECTED_HTML') || lastErr.includes('被反爬');
      const delay: number = isAntiBot ? 2000 + retry * 1000 : 800 + retry * 400;
      if (retry < 3) await new Promise<void>((r) => setTimeout(r, delay));
    }
    Logger.error(TAG, '12306 queryG all %{public}d attempts failed %{public}s→%{public}s', 4, fromCode, toCode);
    return [];
  }

  /** 查询 12306 票价。价格格式: 整数/10=元。最多重试2次 */
  private async query12306Prices(fromCode: string, toCode: string, date: string):
    Promise<Record<string, TicketPrice>> {
    for (let retry: number = 0; retry < 2; retry++) {
      const req: http.HttpRequest = http.createHttp();
      try {
        const url: string = 'https://kyfw.12306.cn/otn/leftTicketPrice/queryAllPublicPrice' +
          `?leftTicketDTO.train_date=${encodeURIComponent(date)}` +
          `&leftTicketDTO.from_station=${encodeURIComponent(fromCode)}` +
          `&leftTicketDTO.to_station=${encodeURIComponent(toCode)}&purpose_codes=ADULT`;

        const resp: http.HttpResponse = await req.request(url, {
          method: http.RequestMethod.GET,
          header: {
            'Host': 'kyfw.12306.cn',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': 'application/json, text/plain, */*',
            'Referer': 'https://www.12306.cn/',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            'X-Requested-With': 'XMLHttpRequest',
            'Connection': 'keep-alive',
            'Cache-Control': 'no-cache',
          },
          connectTimeout: 30000, readTimeout: 20000,
        } as http.HttpRequestOptions);

        if (resp.responseCode !== 200 || !resp.result) throw new Error(`HTTP ${resp.responseCode}`);
        const resultStr: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
        const json: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
        const dataArr: Object[] = (json['data'] as Object[]) ?? [];
        const map: Record<string, TicketPrice> = {};
        for (const item of dataArr) {
          const dto: Record<string, Object> = (item as Record<string, Object>)['queryLeftNewDTO'] as Record<string, Object>;
          if (!dto) continue;
          const trainCode: string = (dto['station_train_code'] as string) || '';
          if (!trainCode) continue;
          map[trainCode] = {
            ze: this.parsePriceField(dto['ze_price'] as string), zy: this.parsePriceField(dto['zy_price'] as string),
            swz: this.parsePriceField(dto['swz_price'] as string), yz: this.parsePriceField(dto['yz_price'] as string),
            yw: this.parsePriceField(dto['yw_price'] as string), rw: this.parsePriceField(dto['rw_price'] as string),
            wz: this.parsePriceField(dto['wz_price'] as string),
          };
        }
        Logger.info(TAG, 'Price query: %{public}d trains', Object.keys(map).length);
        return map;
      } catch (e) {
        Logger.warn(TAG, '12306 price attempt %{public}d/2 failed %{public}s→%{public}s', retry + 1, fromCode, toCode);
      } finally {
        req.destroy();
      }
      if (retry < 1) await new Promise<void>((r) => setTimeout(r, 800));
    }
    return {};
  }

  /** 解析价格字段: 12306 单位 0.1元 → "09340" = 934.0 */
  private parsePriceField(raw: string | undefined): number | undefined {
    if (!raw || raw === '--' || raw === '无' || raw.length === 0) return undefined;
    const n: number = parseFloat(raw);
    if (isNaN(n) || n <= 0) return undefined;
    return n / 10;
  }

  /**
   * 解析 12306 queryG 返回的 result 数组（字段按|分隔）
   * queryG 格式:
   *   [0]=加密数据 [1]="预订" [2]=ID [3]=车次号
   *   [6]=出发站码 [7]=到达站码 [8]=出发时间
   *   [9]=到达时间 [10]=历时 [11]=有票标记(Y/N)
   */
  private parse12306Result(resultArr: string[], fromCode: string, toCode: string): TicketOption[] {
    const options: TicketOption[] = [];

    for (const line of resultArr) {
      if (!line || line.length === 0) continue;
      const parts: string[] = line.split('|');
      if (parts.length < 12) continue;

      const tripNo: string = parts[3] || '';
      if (!tripNo) continue;

      // 电报码 → 中文站名
      const codeService: StationCodeService = StationCodeService.getInstance();
      // [6][7]=本次查询的上/下车站码, [8]=出发, [9]=到达, [10]=历时
      const depStation: string = codeService.getStationName(parts[6]) || parts[6] || fromCode;
      const arrStation: string = codeService.getStationName(parts[7]) || parts[7] || toCode;
      const depTime: string = parts[8] || '';
      const arrTime: string = parts[9] || '';
      const durationStr: string = parts[10] || '';
      const hasTicket: string = parts[11] || '';

      let mode: string = 'train';
      const upper: string = tripNo.toUpperCase();
      if (upper.startsWith('G') || upper.startsWith('D') || upper.startsWith('C')) {
        mode = 'high_speed_rail';
      }

      let duration: number = 0;
      const durMatch: RegExpMatchArray | null = durationStr.match(/(\d{2}):(\d{2})/);
      if (durMatch) {
        duration = parseInt(durMatch[1]) * 3600 + parseInt(durMatch[2]) * 60;
      }

      let note: string = '';
      if (hasTicket === 'Y') note = '有票';
      else if (hasTicket === 'N') note = '无票';
      else note = hasTicket || '';

      options.push({
        type: mode,
        tripNo: tripNo,
        fromStation: depStation,
        toStation: arrStation,
        departureTime: depTime,
        arrivalTime: arrTime,
        duration: duration,
        price: 0,
        seatTypes: '',
        note: note,
      } as TicketOption);
    }

    return options;
  }

  /** 从 12306 字段中解析价格（可能带 '¥' 前缀） */
  private parsePrice(parts: string[], idx: number): number {
    if (idx >= parts.length) return 0;
    const raw: string = parts[idx] || '';
    if (!raw) return 0;
    const num: number = parseFloat(raw.replace('¥', ''));
    return isNaN(num) ? 0 : num;
  }

  /** 搜索机票 — WebXml 免费接口 (非商用) */
  async searchFlights(from: string, to: string, date: string): Promise<TicketOption[]> {
    // WebXml 免费航班 WebService (格式: YYYY-MM-DD)
    const url: string =
      `http://www.webxml.com.cn/webservices/DomesticAirline.asmx/getDomesticAirlinesTime` +
      `?startCity=${encodeURIComponent(from)}&lastCity=${encodeURIComponent(to)}` +
      `&theDate=${encodeURIComponent(date)}&userID=`;

    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp = await bridge.network.request(url, { method: 'GET' });
      if (resp.responseCode === 200 && resp.result) {
        return this.parseWebXmlFlightXml(resp.result);
      }
    } catch (e) {
      Logger.warn(TAG, 'WebXml flight search failed: %{public}s', JSON.stringify(e));
    }

    // WebXml 不通 → 尝试 HTTPS
    try {
      const url2: string =
        `https://www.webxml.com.cn/webservices/DomesticAirline.asmx/getDomesticAirlinesTime` +
        `?startCity=${encodeURIComponent(from)}&lastCity=${encodeURIComponent(to)}` +
        `&theDate=${encodeURIComponent(date)}&userID=`;
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp2 = await bridge.network.request(url2, { method: 'GET' });
      if (resp2.responseCode === 200 && resp2.result) {
        return this.parseWebXmlFlightXml(resp2.result);
      }
    } catch (_e2) { /* ignore */ }

    return [];
  }

  /** 统一搜索：火车(12306) + 飞机(WebXml免费) */
  async searchAll(from: string, to: string, date: string): Promise<TicketOption[]> {
    const results: TicketOption[] = [];
    // 火车：12306 官方 API
    try {
      const trains: TicketOption[] = await this.searchTrainsVia12306(from, to, date);
      for (const t of trains) results.push(t);
      Logger.info(TAG, '12306: %{public}d results for %{public}s→%{public}s', trains.length, from, to);
    } catch (e) {
      if (!this.lastDiag) this.lastDiag = '[searchAll] 异常: ' + JSON.stringify(e).substring(0, 80);
      Logger.warn(TAG, '12306 search failed for %{public}s→%{public}s: %{public}s', from, to, JSON.stringify(e));
    }
    // 飞机：WebXml 免费接口
    try {
      const flights: TicketOption[] = await this.searchFlights(from, to, date);
      for (const f of flights) results.push(f);
    } catch (e) {
      Logger.warn(TAG, 'Flight search failed for %{public}s→%{public}s: %{public}s', from, to, JSON.stringify(e));
    }
    Logger.info(TAG, 'searchAll %{public}s→%{public}s: %{public}d total', from, to, results.length);
    return results;
  }

  /** 获取 5 天后的日期 YYYY-MM-DD（用户未指定日期时的默认值） */
  private defaultDateStr(): string {
    const d: Date = new Date();
    d.setDate(d.getDate() + 5);
    const y: number = d.getFullYear();
    const m: string = String(d.getMonth() + 1).padStart(2, '0');
    const day: string = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }

  // ─── 解析 WebXml 航班 XML ───

  private parseWebXmlFlightXml(xml: string): TicketOption[] {
    const options: TicketOption[] = [];
    const flightRegex: RegExp = /<DomesticAirline>([\s\S]*?)<\/DomesticAirline>/g;
    let match: RegExpExecArray | null;
    while ((match = flightRegex.exec(xml)) !== null) {
      const block: string = match[1];
      const getTag = (tag: string): string => {
        const m2 = block.match(new RegExp(`<${tag}>([^<]*)<\\/${tag}>`));
        return m2 ? m2[1].trim() : '';
      };
      const flightCode: string = getTag('FlightCode');
      const airline: string = getTag('AirlineName');
      const startAirport: string = getTag('StartAirport');
      const lastAirport: string = getTag('LastAirport');
      const startTime: string = getTag('StartTime');
      const lastTime: string = getTag('LastTime');
      const startCity: string = getTag('StartCity');
      const lastCity: string = getTag('LastCity');

      if (flightCode || airline) {
        options.push({
          type: 'flight',
          tripNo: flightCode || airline,
          fromStation: startAirport || startCity,
          toStation: lastAirport || lastCity,
          departureTime: startTime,
          arrivalTime: lastTime,
          duration: 0,
          price: 0,
          note: airline,
        } as TicketOption);
      }
    }
    Logger.info(TAG, 'WebXml parsed %{public}d flights', options.length);
    return options;
  }

}
