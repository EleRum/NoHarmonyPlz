/**
 * 票务搜索服务
 * 火车票：聚合数据，免费 10次/天，注册: https://www.juhe.cn
 * 机票：WebXml 免费 WebService，非商用免费: http://www.webxml.com.cn
 */
import { Logger } from '../../common/Logger';
import { PlatformBridge } from '../../platform/PlatformBridge';

const TAG = 'TransportSearch';
const JUHE_KEY: string = ''; // TODO: 填入聚合数据 API Key (juhe.cn 注册获取)

/** 票务查询参数 */
export interface TicketQueryParams {
  from: string;      // 出发城市/站名
  to: string;        // 到达城市/站名
  date: string;      // 出发日期 YYYY-MM-DD
  type?: string;     // train / flight
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
  note?: string;          // 备注
}

export class TransportSearchService {
  private static instance: TransportSearchService | null = null;

  static getInstance(): TransportSearchService {
    if (!TransportSearchService.instance) {
      TransportSearchService.instance = new TransportSearchService();
    }
    return TransportSearchService.instance;
  }

  /** 搜索火车票 */
  async searchTrains(from: string, to: string, date: string): Promise<TicketOption[]> {
    if (!JUHE_KEY || JUHE_KEY.length === 0) {
      Logger.warn(TAG, 'Juhe API key not configured');
      return [];
    }
    const url: string =
      `https://apis.juhe.cn/train/ticket?key=${JUHE_KEY}` +
      `&from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}` +
      `&date=${encodeURIComponent(date)}`;

    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp = await bridge.network.request(url, { method: 'GET' });
      if (resp.responseCode === 200 && resp.result) {
        const json = JSON.parse(resp.result) as Record<string, Object>;
        Logger.info(TAG, 'Train API response: %{public}s', resp.result.substring(0, 300));
        if ((json['error_code'] as number) === 0 && json['result']) {
          const result = json['result'] as Record<string, Object>;
          const list: Object[] = (result['list'] as Object[]) ?? (result['data'] as Object[]) ?? [];
          return this.parseJuheTrainList(list);
        } else {
          Logger.warn(TAG, 'Train API error: %{public}s', json['reason'] as string ?? 'unknown');
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'Train search failed: %{public}s', JSON.stringify(e));
    }
    return [];
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
        Logger.info(TAG, 'Flight API response: %{public}s', resp.result.substring(0, 300));
        // WebXml 返回 XML 格式
        const xml = resp.result;
        return this.parseWebXmlFlightXml(xml);
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

  /** 统一搜索：火车(聚合数据) + 飞机(WebXml免费) */
  async searchAll(from: string, to: string, date: string): Promise<TicketOption[]> {
    const results: TicketOption[] = [];
    // 火车：需要聚合数据 Key
    if (JUHE_KEY && JUHE_KEY.length > 0) {
      try {
        const trains = await this.searchTrains(from, to, date);
        for (const t of trains) results.push(t);
      } catch (_e) { /* ignore */ }
    }
    // 飞机：WebXml 免费，无需 Key
    try {
      const flights = await this.searchFlights(from, to, date);
      for (const f of flights) results.push(f);
    } catch (_e) { /* ignore */ }
    return results;
  }

  // ─── 解析聚合数据火车票响应 ───

  private parseJuheTrainList(list: Object[]): TicketOption[] {
    const options: TicketOption[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const item = list[i] as Record<string, Object>;
      // 聚合数据火车票字段（常见格式）
      const trainNo: string = (item['train_no'] as string) || (item['station_train_code'] as string) ||
        (item['trainCode'] as string) || '';
      const fromSt: string = (item['from_station'] as string) || (item['start_station_name'] as string) ||
        (item['fromStation'] as string) || '';
      const toSt: string = (item['to_station'] as string) || (item['end_station_name'] as string) ||
        (item['toStation'] as string) || '';
      const startTime: string = (item['start_time'] as string) || (item['departure_time'] as string) ||
        (item['startTime'] as string) || '';
      const arriveTime: string = (item['arrive_time'] as string) || (item['arrival_time'] as string) ||
        (item['endTime'] as string) || '';
      const duration: number = this.parseJuheDuration(item);
      const typeStr: string = (item['train_type'] as string) || (item['type'] as string) || '';
      const price: number = this.parseJuhePrice(item);

      let mode: string = 'train';
      if (trainNo.startsWith('G') || typeStr.includes('高铁')) mode = 'high_speed_rail';
      else if (trainNo.startsWith('D') || typeStr.includes('动车')) mode = 'high_speed_rail';
      else if (trainNo.startsWith('C')) mode = 'high_speed_rail';
      else if (trainNo.startsWith('K') || trainNo.startsWith('T') || trainNo.startsWith('Z')) mode = 'train';

      if (trainNo || (fromSt && toSt)) {
        options.push({
          type: mode,
          tripNo: trainNo || typeStr,
          fromStation: fromSt,
          toStation: toSt,
          departureTime: startTime,
          arrivalTime: arriveTime,
          duration: duration,
          price: price,
          seatTypes: this.buildSeatTypes(item),
        } as TicketOption);
      }
    }
    return options;
  }

  // ─── 解析 WebXml 航班 XML ───

  private parseWebXmlFlightXml(xml: string): TicketOption[] {
    const options: TicketOption[] = [];
    // WebXml 返回格式: <DomesticAirline>...</DomesticAirline>
    const flightRegex = /<DomesticAirline>([\s\S]*?)<\/DomesticAirline>/g;
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
          duration: 0, // WebXml 不直接给时长
          price: 0,     // WebXml 不提供票价
          note: airline,
        } as TicketOption);
      }
    }
    Logger.info(TAG, 'WebXml parsed %{public}d flights', options.length);
    return options;
  }

  // ─── 旧版：解析聚合数据机票响应（保留备用）───

  private parseJuheFlightList(list: Object[]): TicketOption[] {
    const options: TicketOption[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const item = list[i] as Record<string, Object>;
      const flightNo: string = (item['flight_no'] as string) || (item['flightNo'] as string) ||
        (item['flight_code'] as string) || '';
      const depAirport: string = (item['dep_airport'] as string) || (item['fromAirport'] as string) ||
        (item['depAirport'] as string) || '';
      const arrAirport: string = (item['arr_airport'] as string) || (item['toAirport'] as string) ||
        (item['arrAirport'] as string) || '';
      const depTime: string = (item['dep_time'] as string) || (item['departureTime'] as string) ||
        (item['startTime'] as string) || '';
      const arrTime: string = (item['arr_time'] as string) || (item['arrivalTime'] as string) ||
        (item['endTime'] as string) || '';
      const duration: number = this.parseJuheDuration(item);
      const price: number = this.parseJuhePrice(item);
      const company: string = (item['airline_company'] as string) || (item['company'] as string) || '';

      if (flightNo || (depAirport && arrAirport)) {
        options.push({
          type: 'flight',
          tripNo: flightNo || company,
          fromStation: depAirport,
          toStation: arrAirport,
          departureTime: depTime,
          arrivalTime: arrTime,
          duration: duration,
          price: price,
          note: company,
        } as TicketOption);
      }
    }
    return options;
  }

  // ─── 辅助 ───

  private parseJuheDuration(item: Record<string, Object>): number {
    // 尝试多种格式："3h30m" / "210" (分钟) / "12600" (秒)
    const durStr: string = (item['duration'] as string) || (item['run_time'] as string) ||
      (item['lishi'] as string) || '';
    if (durStr) {
      const hMatch = durStr.match(/(\d+)\s*[h时]/);
      const mMatch = durStr.match(/(\d+)\s*[m分]/);
      let secs: number = 0;
      if (hMatch) secs += parseInt(hMatch[1]) * 3600;
      if (mMatch) secs += parseInt(mMatch[1]) * 60;
      if (secs > 0) return secs;
      // 纯数字可能是分钟
      const num = parseInt(durStr);
      if (!isNaN(num)) {
        if (num < 100) return num * 3600;       // "3" → 3小时
        if (num < 1000) return num * 60;         // "210" → 210分钟
        return num;                                 // 已经是秒
      }
    }
    return 0;
  }

  private parseJuhePrice(item: Record<string, Object>): number {
    // 尝试多种价格字段
    const candidates = [
      item['price'], item['ticket_price'], item['min_price'],
      item['gr_price'], item['qt_price'],  // 高级软卧/其他
      item['swz_price'], item['tz_price'], item['zy_price'], item['ze_price'], // 商务座/特等座/一等座/二等座
      item['yw_price'], item['rw_price'], item['yz_price'], item['rz_price'], // 硬卧/软卧/硬座/软座
      item['wz_price'], // 无座
    ];
    for (const c of candidates) {
      if (c !== undefined && c !== null) {
        const num = typeof c === 'string' ? parseFloat(c) : (c as number);
        if (!isNaN(num) && num > 0) return num;
      }
    }
    return 0;
  }

  private buildSeatTypes(item: Record<string, Object>): string {
    const parts: string[] = [];
    const seatMap: Record<string, string> = {
      'swz_price': '商务座', 'tz_price': '特等座', 'zy_price': '一等座', 'ze_price': '二等座',
      'yw_price': '硬卧', 'rw_price': '软卧', 'yz_price': '硬座', 'rz_price': '软座',
      'wz_price': '无座', 'gr_price': '高级软卧', 'qt_price': '其他',
    };
    for (const key of Object.keys(seatMap)) {
      const val = item[key];
      if (val !== undefined && val !== null) {
        const num = typeof val === 'string' ? parseFloat(val) : (val as number);
        if (!isNaN(num) && num > 0) {
          parts.push(seatMap[key] + '¥' + num);
        }
      }
    }
    return parts.join(', ');
  }
}
