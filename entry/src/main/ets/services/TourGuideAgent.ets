/**
 * 导游 AI Agent — 对话式旅游规划师
 * 每步工具执行后立即返回地图标记数据，实现渐进式可视化
 */
import { ClaudeService, ClaudeReply } from './ClaudeService';
import { AmapSearchService } from './map/AmapSearchService';
import { PoiResult, LatLng, NavRoute, DirectionMode } from './map/MapTypes';
import { TourPlan, TourDay, TourPoiItem, createEmptyPlan } from '../model/TourPlan';
import { Logger } from '../common/Logger';
import { haversineDistance } from '../common/LocationUtils';

const TAG = 'TourGuideAgent';

const SYSTEM_PROMPT: string = `你是小途，资深旅游规划师。

## 风格
口语化，像朋友聊天。一次只问1个问题。给出具体建议。

## 工作流程
1. 用户说想去某城市玩 → geocode_city 定位
2. 城市定位后 → search_hotels 搜酒店，推荐2-3个
3. 用户选好酒店 → make_plan 生成行程
4. 用户修改计划时 → search_and_add 一步完成搜+加

## 工具（回复末尾加 ---JSON---）
{"action":"geocode_city","city":"成都"}
{"action":"search_hotels"}
{"action":"search_hotels","lat":"30.66","lng":"104.06"}
{"action":"make_plan","hotel":"锦江宾馆","hotelLat":"30.6","hotelLng":"104.1","days":"3"}
{"action":"search_and_add","keywords":"熊猫基地","dayIndex":"0","timeSlot":"上午9:00"}
{"action":"remove_poi_from_day","dayIndex":"0","poiIndex":"1"}

## 规则
- 酒店是可选的：用户可能住在这个城市（不需要酒店），也可能几天换几个酒店
  * 用户没提酒店 → 不问酒店，直接 make_plan（不填 hotel 参数）
  * 用户说"住在XX附近" → search_hotels 搜附近推荐
  * 用户想中途换酒店 → make_plan 之后用 search_and_add 加新酒店到对应天
- geocode_city 只需一次。城市换了才重新geocode
- 用户说"第X天去/吃XX" → 直接 search_and_add，不要确认
- make_plan 只创建骨架，不自动加景点。完成后先问想看什么吃什么
- make_plan 填 days 参数反映用户说的天数
- 主动推进，不等用户催
- 不搜索时不要加 ---JSON---`;

export interface ToolCall {
  action: string;
  keywords?: string;
  city?: string;
  hotel?: string;
  hotelLat?: string;
  hotelLng?: string;
  days?: string;
  // 修改计划相关
  dayIndex?: string;
  poiIndex?: string;
  name?: string;
  lat?: string;
  lng?: string;
  type?: string;
  timeSlot?: string;
  note?: string;
  mode?: string;
}

/** 地图标记数据 */
export interface MapMarker {
  name: string;
  lat: number;
  lng: number;
  type: string;
  poiId?: string;
  address?: string;
}

export interface AgentResponse {
  text: string;
  toolCall?: ToolCall;
  plan?: TourPlan;
  mapCenter?: LatLng;
  markers?: MapMarker[];
  poiResults?: PoiResult[];
  polyline?: LatLng[];
}

export class TourGuideAgent {
  private claude: ClaudeService;
  private plan: TourPlan;
  private toolCallCount: number;
  /** 用户偏好上下文（软件引导，不强制） */
  private userPrefContext: string = '';

  constructor() {
    this.claude = new ClaudeService();
    this.claude.loadApiKey();
    this.plan = createEmptyPlan();
    this.toolCallCount = 0;
  }

  reset(): void {
    this.plan = createEmptyPlan();
    this.claude.clearHistory();
    this.toolCallCount = 0;
  }

  getPlan(): TourPlan {
    return this.plan;
  }

  /**
   * 设置用户偏好上下文（软件引导，不强制限制推荐）
   * @param userName 用户名
   * @param userCity 用户所在城市
   * @param preferences 偏好标签数组
   */
  setUserContext(userName: string, userCity: string, preferences: string[]): void {
    const parts: string[] = [];
    if (userName) parts.push(`用户叫${userName}`);
    if (userCity) parts.push(`常住${userCity}`);
    if (preferences.length > 0) {
      parts.push(`旅行偏好：${preferences.join('、')}`);
    }
    if (parts.length > 0) {
      this.userPrefContext = '\n## 用户信息（仅供参考，保持推荐多样性）\n' +
        parts.join('，') + '。\n' +
        '这些偏好仅作参考，你应根据目的地实际情况自由推荐，不要局限于用户偏好。\n';
    } else {
      this.userPrefContext = '';
    }
  }

  /** 获取完整的系统提示（含用户偏好） */
  private getSystemPrompt(): string {
    return SYSTEM_PROMPT + this.userPrefContext;
  }

  /** 检测是否为新规划请求（更换城市/重新规划）
   *  排除对已有计划的修改请求（如"第一天去看XX"） */
  private isNewTripRequest(input: string): boolean {
    const lower: string = input.toLowerCase();
    // 明确指向已有某一天 → 修改请求，不是新规划
    if (/第[一二三四五六七八\d]+天/.test(lower)) return false;
    if (/day\s*\d+/i.test(lower)) return false;

    return lower.includes('想去') || lower.includes('规划') || lower.includes('重新') ||
      lower.includes('换') || lower.includes('新') || lower.includes('再去');
  }

  /** 将中文或阿拉伯数字转为 number（一→1, 1→1） */
  private parseDayNumber(s: string): number {
    const map: Record<string, number> = {
      '一': 1, '二': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8
    };
    if (map[s]) return map[s];
    const n: number = parseInt(s);
    return isNaN(n) ? 1 : n;
  }

  /** 检测修改已有计划的意图，返回确定性工具调用（不依赖 AI 选择） */
  private detectModificationIntent(input: string): ToolCall | undefined {
    if (this.plan.dailyPlans.length === 0) return undefined;

    // 模式: 改成/换成 X天 → 调整计划天数
    const daysPattern = /(?:改[成为]?|换[成为]?|调整[成为]?|变成)([一二三四五六七八\d]+)天/;
    const daysMatch: RegExpMatchArray | null = input.match(daysPattern);
    if (daysMatch) {
      return { action: 'make_plan', days: this.parseDayNumber(daysMatch[1]).toString() };
    }

    // 模式: 去掉/删除 + 第X天 + 第N个 / POI名称
    const rmIdxPattern = /(?:去掉|删除|移除).*第([一二三四五六七八\d]+)天.*?第([一二三四五六七八\d]+)个/;
    const rmIdxMatch: RegExpMatchArray | null = input.match(rmIdxPattern);
    if (rmIdxMatch) {
      return {
        action: 'remove_poi_from_day',
        dayIndex: (this.parseDayNumber(rmIdxMatch[1]) - 1).toString(),
        poiIndex: (this.parseDayNumber(rmIdxMatch[2]) - 1).toString()
      };
    }

    // 模式: 去掉/删除 + 第X天 + POI名称 → 按名称找索引
    const rmNamePattern = /(?:去掉|删除|移除|不要|别).*?第([一二三四五六七八\d]+)天.*?([^\s，,。.!！?？]{2,10})/;
    const rmNameMatch: RegExpMatchArray | null = input.match(rmNamePattern);
    if (rmNameMatch) {
      const rmDay: number = this.parseDayNumber(rmNameMatch[1]) - 1;
      const rmName: string = rmNameMatch[2].trim();
      if (rmDay >= 0 && rmDay < this.plan.dailyPlans.length) {
        const day = this.plan.dailyPlans[rmDay];
        for (let i: number = 0; i < day.pois.length; i++) {
          if (day.pois[i].name.includes(rmName) && !day.pois[i].type.includes('酒店')) {
            return {
              action: 'remove_poi_from_day',
              dayIndex: rmDay.toString(),
              poiIndex: i.toString()
            };
          }
        }
      }
    }

    // 模式: 第X天 + 动词 + 关键词
    // 用非贪婪匹配 [^，。,\.]*? 避免吃掉关键词
    const addPattern = /第([一二三四五六七八\d]+)天[^，。,\.]*?(?:上午|下午|晚上|中午|早|晚)?[^，。,\.]*?(?:想去?|要?去|看|吃|逛|玩|加|增)[^，。,\.]*?(.+)/;
    const addMatch: RegExpMatchArray | null = input.match(addPattern);
    if (addMatch) {
      const dayNum: number = this.parseDayNumber(addMatch[1]);
      const rawKw: string = addMatch[2].trim();
      // 截断关键词到合理长度（去掉尾部废话）
      const kw: string = rawKw.length > 20 ? rawKw.substring(0, 20) : rawKw;
      let timeSlot: string = '';
      const lower: string = input.toLowerCase();
      if (lower.includes('上午') || lower.includes('早上') || lower.includes('早餐')) timeSlot = '上午9:00';
      else if (lower.includes('中午') || lower.includes('午餐')) timeSlot = '中午12:00';
      else if (lower.includes('下午')) timeSlot = '下午14:00';
      else if (lower.includes('晚上') || lower.includes('晚餐')) timeSlot = '晚上18:00';

      // 检测交通方式
      const mode: string | undefined = this.detectModeStr(input);

      const tc: ToolCall = {
        action: 'search_and_add',
        keywords: kw,
        dayIndex: (dayNum - 1).toString(),
        timeSlot: timeSlot
      };
      if (mode) tc.mode = mode;
      return tc;
    }

    return undefined;
  }

  /** 处理用户输入 */
  async process(input: string): Promise<AgentResponse> {
    this.toolCallCount = 0;
    // 如果是新规划请求，重置计划对象（保持新引用以触发 UI 刷新）
    if (this.isNewTripRequest(input) && this.plan.status === 'complete') {
      this.plan = createEmptyPlan();
      Logger.info(TAG, 'Reset plan for new trip request');
    }

    // 确定性修改意图检测：绕过 AI 工具选择，直接准备工具调用
    const modIntent: ToolCall | undefined = this.detectModificationIntent(input);
    if (modIntent && this.plan.dailyPlans.length > 0) {
      Logger.info(TAG, 'Modification intent detected: %{public}s', modIntent.action);
      // 仍然发送给 AI 获取对话文本
      const userMsg: string = '用户: ' + input;
      const reply: ClaudeReply = await this.claude.chatConversation(userMsg, this.getSystemPrompt());
      const text: string = reply.text || '好的，马上更新！';
      // AI 文本 + 确定性工具调用
      return { text: this.stripJson(text), toolCall: modIntent };
    }

    const userMsg: string = '用户: ' + input;
    const reply: ClaudeReply = await this.claude.chatConversation(userMsg, this.getSystemPrompt());
    const text: string = reply.text || '抱歉，我暂时无法回复。';
    const toolCall: ToolCall | undefined = this.parseToolCall(text);
    if (toolCall) {
      return { text: this.stripJson(text), toolCall: toolCall };
    }
    return { text: this.stripJson(text) };
  }

  /** 执行工具并返回结果（含地图更新数据 + AI 继续对话） */
  async executeToolAndContinue(action: string, params: Record<string, string>): Promise<AgentResponse> {
    this.toolCallCount++;
    if (this.toolCallCount > 30) {
      return { text: '已进行较多操作，请确认当前的行程计划，或继续告诉我你的需求。' };
    }

    let resultText: string = '';
    let mapCenter: LatLng | undefined = undefined;
    let markers: MapMarker[] | undefined = undefined;

    switch (action) {
      case 'geocode_city': {
        const city: string = params['city'] ?? '';
        if (this.plan.city === city && this.plan.cityLat !== 0) {
          resultText = `城市${city}已定位。`;
        } else {
          const loc: LatLng | null = await AmapSearchService.getInstance().geocodeCity(city);
          if (loc) {
            this.plan.city = city;
            this.plan.cityLat = loc.latitude;
            this.plan.cityLng = loc.longitude;
            resultText = `城市${city}定位成功(${loc.latitude.toFixed(4)},${loc.longitude.toFixed(4)})。`;
            mapCenter = loc;
          } else {
            resultText = `城市"${city}"定位失败，请确认城市名。`;
          }
        }
        break;
      }
      case 'search_hotels': {
        // 支持用户指定区域：有 lat/lng 则搜附近，否则全城搜
        const hLat: number = parseFloat(params['lat'] ?? '0');
        const hLng: number = parseFloat(params['lng'] ?? '0');
        let pois: PoiResult[];
        if (hLat !== 0 && hLng !== 0) {
          pois = await AmapSearchService.getInstance().searchPoiByCategory('酒店|宾馆|民宿', hLat, hLng, 5000);
        } else if (this.plan.cityLat !== 0) {
          pois = await AmapSearchService.getInstance().searchPoiByCategory('酒店|宾馆|民宿', this.plan.cityLat, this.plan.cityLng, 30000);
        } else {
          pois = await AmapSearchService.getInstance().searchPoiByText('酒店|宾馆|民宿', this.plan.city);
        }
        const top5: PoiResult[] = pois.slice(0, 5);
        markers = top5.map((p: PoiResult): MapMarker => ({
          name: p.name, lat: p.latitude, lng: p.longitude, type: '酒店',
          poiId: p.id, address: p.address
        }));
        resultText = pois.length > 0
          ? `${this.plan.city}酒店(top5)：\n` + top5.map((p, i) => `${i + 1}. ${p.name} | ${p.address || ''} | ${p.distance}m`).join('\n')
          : `未找到${this.plan.city}酒店。`;
        break;
      }
      case 'search_poi': {
        if (this.plan.cityLat === 0) {
          const tc: ToolCall = { action: 'geocode_city', city: params['city'] || '' };
          return { text: '需要先定位城市。', toolCall: tc };
        }
        const kw: string = params['keywords'] ?? '景点';
        const pois: PoiResult[] = await AmapSearchService.getInstance().searchPoiByText(kw, this.plan.city);
        const top8: PoiResult[] = pois.slice(0, 8);
        markers = top8.map((p: PoiResult): MapMarker => ({
          name: p.name, lat: p.latitude, lng: p.longitude, type: kw,
          poiId: p.id, address: p.address
        }));
        resultText = pois.length > 0
          ? `"${kw}"搜索(top8)：\n` + top8.map((p, i) => `${i + 1}. ${p.name} | ${p.address || ''} | ${p.distance}m`).join('\n')
          : `未找到"${kw}"。`;
        break;
      }
      case 'search_and_add': {
        // 一步完成：搜索 + 自动添加到计划
        // 如果还没有计划，先自动创建一个基础计划
        if (this.plan.dailyPlans.length === 0) {
          this.plan.days = this.plan.days > 0 ? this.plan.days : 1;
          this.plan.dailyPlans = [{
            dayIndex: 0, label: '第1天',
            pois: this.plan.hotel ? [
              { name: this.plan.hotel.name, lat: this.plan.hotel.lat, lng: this.plan.hotel.lng, type: '酒店住宿', timeSlot: '出发', duration: '', note: '' },
              { name: this.plan.hotel.name, lat: this.plan.hotel.lat, lng: this.plan.hotel.lng, type: '酒店住宿', timeSlot: '返回', duration: '', note: '' }
            ] : [],
            route: null
          }];
          this.plan.status = 'planning';
        }
        if (this.plan.cityLat === 0) {
          const tc: ToolCall = { action: 'geocode_city', city: params['city'] || '' };
          return { text: '需要先定位城市。', toolCall: tc };
        }
        const saKw: string = params['keywords'] ?? '';
        const saDayIdx: number = parseInt(params['dayIndex'] ?? '0');
        const saTimeSlot: string = params['timeSlot'] ?? '';

        if (saDayIdx < 0 || saDayIdx >= this.plan.dailyPlans.length) {
          // 自动扩容到所需天数
          while (this.plan.dailyPlans.length <= saDayIdx) {
            const nd: number = this.plan.dailyPlans.length;
            this.plan.dailyPlans.push({
              dayIndex: nd, label: `第${nd + 1}天`, pois:
                this.plan.hotel ? [
                  { name: this.plan.hotel.name, lat: this.plan.hotel.lat, lng: this.plan.hotel.lng, type: '酒店住宿', timeSlot: '出发', duration: '', note: '' },
                  { name: this.plan.hotel.name, lat: this.plan.hotel.lat, lng: this.plan.hotel.lng, type: '酒店住宿', timeSlot: '返回', duration: '', note: '' }
                ] : [],
              route: null
            });
          }
          this.plan.days = this.plan.dailyPlans.length;
        }

        // 全城文字搜索，覆盖城市各个区域
        const saPois: PoiResult[] = await AmapSearchService.getInstance().searchPoiByText(saKw, this.plan.city);
        if (saPois.length === 0) {
          resultText = `未找到"${saKw}"。`;
          break;
        }

        // 取第一个结果
        const first: PoiResult = saPois[0];
        // 显示搜索结果（标记 + 文本）
        markers = saPois.slice(0, 5).map((p: PoiResult): MapMarker => ({
          name: p.name, lat: p.latitude, lng: p.longitude, type: saKw,
          poiId: p.id, address: p.address
        }));

        // 自动添加到计划
        const saDay: TourDay = this.plan.dailyPlans[saDayIdx];
        const autoTimeSlot: string = saTimeSlot || this.nextTimeSlot(saDay);
        const newPoi: TourPoiItem = {
          name: first.name, lat: first.latitude, lng: first.longitude,
          type: first.type || '景点', timeSlot: autoTimeSlot,
          duration: '1-2h', note: first.address || '',
          mode: params['mode'] || undefined
        };

        // 插入到"返回"之前（酒店或出发地的返回点）
        let saInserted: boolean = false;
        for (let i: number = saDay.pois.length - 1; i >= 0; i--) {
          if (saDay.pois[i].timeSlot === '返回') {
            saDay.pois.splice(i, 0, newPoi);
            saInserted = true;
            break;
          }
        }
        if (!saInserted) {
          saDay.pois.push(newPoi);
        }

        // 酒店：替换出发+终点（晚上到酒店就住下，不用再"返回"出发地）
        if (first.type.includes('酒店') || first.type.includes('宾馆') || first.type.includes('民宿')) {
          this.plan.hotel = { name: first.name, lat: first.latitude, lng: first.longitude,
            type: '酒店住宿', timeSlot: '入住', duration: '全程', note: first.address || '' };
          for (let i: number = saDay.pois.length - 1; i >= 0; i--) {
            if (saDay.pois[i].timeSlot === '返回') {
              saDay.pois[i] = { name: first.name, lat: first.latitude, lng: first.longitude,
                type: '酒店住宿', timeSlot: '入住', duration: '', note: first.address || '' };
              break;
            }
          }
          // 同时更新出发地（如果还没出发就定了酒店）
          for (let i: number = 0; i < saDay.pois.length; i++) {
            if (saDay.pois[i].timeSlot === '出发') {
              saDay.pois[i] = { name: first.name, lat: first.latitude, lng: first.longitude,
                type: '酒店住宿', timeSlot: '出发', duration: '', note: first.address || '' };
              break;
            }
          }
          resultText = `已更新${saDay.label}酒店为"${first.name}"（终点直接入住）。`;
        }

        // 重算路线
        await this.recalcDayRoute(saDay);

        if (!first.type.includes('酒店') && !first.type.includes('宾馆') && !first.type.includes('民宿')) {
          resultText = `已将"${first.name}"添加到${saDay.label}${autoTimeSlot ? ' ' + autoTimeSlot : ''}。${first.address ? '地址：' + first.address : ''}`;
        }
        break;
      }
      case 'make_plan': {
        const hotelName: string = params['hotel'] ?? '';
        const hotelLat: number = parseFloat(params['hotelLat'] ?? '0');
        const hotelLng: number = parseFloat(params['hotelLng'] ?? '0');
        const userDays: number = parseInt(params['days'] ?? '0');
        this.plan.days = userDays > 0 ? userDays : (this.plan.days > 0 ? this.plan.days : 3);

        // 酒店可选：没选酒店就用城市中心作为起点/终点
        let baseName: string;
        let baseLat: number;
        let baseLng: number;
        if (hotelName && hotelLat !== 0) {
          this.plan.hotel = { name: hotelName, lat: hotelLat, lng: hotelLng, type: '酒店住宿', timeSlot: '入住', duration: '全程', note: '' };
          baseName = hotelName;
          baseLat = hotelLat;
          baseLng = hotelLng;
        } else {
          baseName = this.plan.city + '市中心';
          baseLat = this.plan.cityLat;
          baseLng = this.plan.cityLng;
        }

        // 调整天数时保留已有的行程内容
        const hadContent: boolean = this.plan.dailyPlans.length > 0;
        while (this.plan.dailyPlans.length < this.plan.days) {
          const nd: number = this.plan.dailyPlans.length;
          this.plan.dailyPlans.push({
            dayIndex: nd, label: `第${nd + 1}天`,
            pois: [
              { name: baseName, lat: baseLat, lng: baseLng, type: '出发地', timeSlot: '出发', duration: '', note: '' },
              { name: baseName, lat: baseLat, lng: baseLng, type: '出发地', timeSlot: '返回', duration: '', note: '' }
            ],
            route: null
          });
        }
        // 减少天数则截断，保留前 N 天
        if (this.plan.dailyPlans.length > this.plan.days) {
          this.plan.dailyPlans = this.plan.dailyPlans.slice(0, this.plan.days);
        }
        // 如果已有内容且换了酒店，更新已有天的起点终点
        if (hadContent && hotelName && hotelLat !== 0) {
          for (const day of this.plan.dailyPlans) {
            for (const p of day.pois) {
              if (p.timeSlot === '出发' || p.timeSlot === '返回') {
                p.name = hotelName; p.lat = hotelLat; p.lng = hotelLng;
                p.type = '酒店住宿'; p.note = '';
              }
            }
          }
        }
        this.plan.status = 'complete';

        resultText = hadContent
          ? `已调整为${this.plan.days}天行程，已有内容已保留！` +
            (hotelName ? `\n入住：${hotelName}` : '')
          : `已创建${this.plan.days}天${this.plan.city}行程！` +
            (hotelName ? `\n入住：${hotelName}` : '\n起点：' + baseName) +
            `\n\n告诉我你想去哪玩？比如"第一天去宽窄巷子"、"第二天吃火锅"～`;
        break;
      }
      case 'get_weather': {
        resultText = `${params['city'] || this.plan.city}近日天气：晴转多云 20-28°C（参考）。`;
        break;
      }
      case 'add_poi_to_day': {
        if (this.plan.dailyPlans.length === 0) {
          resultText = '请先生成计划后再添加景点。';
          break;
        }
        const dayIdx: number = parseInt(params['dayIndex'] ?? '0');
        if (dayIdx < 0 || dayIdx >= this.plan.dailyPlans.length) {
          resultText = `第${dayIdx + 1}天不存在，当前共${this.plan.dailyPlans.length}天。`;
          break;
        }
        const poiName: string = params['name'] ?? '';
        const poiLat: number = parseFloat(params['lat'] ?? '0');
        const poiLng: number = parseFloat(params['lng'] ?? '0');
        if (!poiName || poiLat === 0) {
          resultText = '请提供景点名称和坐标（先用 search_poi 搜索）。';
          break;
        }
        const poiType: string = params['type'] ?? '景点';
        const poiTimeSlot: string = params['timeSlot'] ?? '';
        const poiNote: string = params['note'] ?? '';
        const insertPos: number = parseInt(params['poiIndex'] ?? '-1');

        const newPoi: TourPoiItem = {
          name: poiName, lat: poiLat, lng: poiLng,
          type: poiType, timeSlot: poiTimeSlot, duration: '1-2h', note: poiNote
        };

        const day: TourDay = this.plan.dailyPlans[dayIdx];
        if (insertPos >= 0 && insertPos < day.pois.length) {
          day.pois.splice(insertPos, 0, newPoi);
        } else {
          // 插入到酒店返回之前（即最后一个酒店住宿之前）
          let inserted: boolean = false;
          for (let i: number = day.pois.length - 1; i >= 0; i--) {
            if (day.pois[i].type.includes('酒店') && day.pois[i].timeSlot === '返回') {
              day.pois.splice(i, 0, newPoi);
              inserted = true;
              break;
            }
          }
          if (!inserted) {
            day.pois.push(newPoi);
          }
        }

        // 重新计算该天路线
        await this.recalcDayRoute(day);

        resultText = `已将"${poiName}"添加到${day.label}${poiTimeSlot ? ' ' + poiTimeSlot : ''}。`;
        break;
      }
      case 'remove_poi_from_day': {
        if (this.plan.dailyPlans.length === 0) {
          resultText = '请先生成计划后再删除景点。';
          break;
        }
        const rmDayIdx: number = parseInt(params['dayIndex'] ?? '0');
        const rmPoiIdx: number = parseInt(params['poiIndex'] ?? '-1');
        if (rmDayIdx < 0 || rmDayIdx >= this.plan.dailyPlans.length) {
          resultText = `第${rmDayIdx + 1}天不存在。`;
          break;
        }
        const rmDay: TourDay = this.plan.dailyPlans[rmDayIdx];
        if (rmPoiIdx < 0 || rmPoiIdx >= rmDay.pois.length) {
          resultText = `第${rmDayIdx + 1}天共${rmDay.pois.length}个地点，序号${rmPoiIdx}无效。`;
          break;
        }
        const removed: TourPoiItem = rmDay.pois[rmPoiIdx];
        rmDay.pois.splice(rmPoiIdx, 1);

        // 重新计算该天路线
        await this.recalcDayRoute(rmDay);

        resultText = `已从${rmDay.label}删除"${removed.name}"。`;
        break;
      }
      default:
        resultText = `工具 ${action} 执行完毕。`;
    }

    const resp: AgentResponse = {
      text: resultText,
      mapCenter: mapCenter,
      markers: markers,
    };

    // 修改计划的操作返回深拷贝计划，确保 @State 检测到新引用
    if (this.plan.dailyPlans.length > 0 &&
        (action === 'make_plan' || action === 'add_poi_to_day' || action === 'remove_poi_from_day' || action === 'search_and_add')) {
      resp.plan = JSON.parse(JSON.stringify(this.plan)) as TourPlan;
    }
    return resp;
  }

  /** 工具执行后向 AI 请求下一步（在 UI 更新之后调用，不阻塞地图刷新） */
  async askAiNextStep(action: string, resultText: string): Promise<AgentResponse> {
    let planCtx: string = `当前计划：城市=${this.plan.city}(${this.plan.cityLat.toFixed(2)},${this.plan.cityLng.toFixed(2)}) 酒店=${this.plan.hotel?.name || '未选'} 天数=${this.plan.days}`;
    if (this.plan.dailyPlans.length > 0) {
      planCtx += '\n每日行程：';
      for (const d of this.plan.dailyPlans) {
        planCtx += `\n  ${d.label}: ` + d.pois.map((p, i) => `[${i}]${p.name}(${p.type},${p.timeSlot})`).join(' → ');
      }
    }
    const followMsg: string = `工具 ${action} 结果：\n${resultText}\n\n${planCtx}\n\n请基于此继续与用户对话。`;
    const reply: ClaudeReply = await this.claude.chatConversation(followMsg, SYSTEM_PROMPT);
    const resultText2: string = reply.text || '收到，请继续。';
    const nextTool: ToolCall | undefined = this.parseToolCall(resultText2);
    const resp: AgentResponse = { text: this.stripJson(resultText2), toolCall: nextTool };
    return resp;
  }

  /** 自动分配下一个可用时间段 */
  private nextTimeSlot(day: TourDay): string {
    const defaultSlots: string[] = ['上午9:00', '上午11:00', '中午12:00', '下午14:00', '下午16:00', '晚上18:00'];
    const usedSlots: Set<string> = new Set(day.pois.map((p) => p.timeSlot));
    for (const s of defaultSlots) {
      if (!usedSlots.has(s)) return s;
    }
    return '上午10:00'; // fallback
  }

  /** Fisher-Yates 洗牌，随机打乱数组 */
  private shuffleArray(arr: Object[]): void {
    for (let i: number = arr.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: Object = arr[i];
      arr[i] = arr[j];
      arr[j] = tmp;
    }
  }

  /** 根据两点距离自动选择交通方式（驾车最稳定，公交需用户明确要求） */
  private autoMode(lat1: number, lng1: number, lat2: number, lng2: number): DirectionMode {
    const dist: number = haversineDistance(lat1, lng1, lat2, lng2);
    if (dist < 1000) return DirectionMode.WALKING;
    return DirectionMode.DRIVING;
  }

  /** 从用户输入中检测交通方式（返回字符串） */
  private detectModeStr(input: string): string | undefined {
    if (/地铁|公交|公交地铁|坐车|公共交通/.test(input)) return 'transit';
    if (/开车|驾车|打车|出租车|自驾/.test(input)) return 'driving';
    if (/走路|步行|徒步/.test(input)) return 'walking';
    if (/骑车|骑行|自行车/.test(input)) return 'bicycling';
    return undefined;
  }

  /** 从用户输入中检测偏好的交通方式 */
  private detectMode(input: string): DirectionMode | undefined {
    if (/地铁|公交|公交地铁|坐车|公共交通/.test(input)) return DirectionMode.TRANSIT;
    if (/开车|驾车|打车|出租车|自驾/.test(input)) return DirectionMode.DRIVING;
    if (/走路|步行|徒步/.test(input)) return DirectionMode.WALKING;
    if (/骑车|骑行|自行车/.test(input)) return DirectionMode.BICYCLING;
    return undefined; // 未指定→自动选择
  }

  /** 重新计算某一天的路线。失败时最多重试3次，仍失败才用直线 */
  private async recalcDayRoute(day: TourDay): Promise<void> {
    if (day.pois.length < 2) return;
    day.route = { distance: 0, duration: 0, path: [], steps: [], origin: '', destination: '' };
    const allPts: LatLng[] = [];
    for (let pi: number = 0; pi < day.pois.length - 1; pi++) {
      const a = day.pois[pi];
      const b = day.pois[pi + 1];
      let mode: DirectionMode;
      if (b.mode === 'walking') mode = DirectionMode.WALKING;
      else if (b.mode === 'driving') mode = DirectionMode.DRIVING;
      else if (b.mode === 'transit') mode = DirectionMode.TRANSIT;
      else if (b.mode === 'bicycling') mode = DirectionMode.BICYCLING;
      else mode = this.autoMode(a.lat, a.lng, b.lat, b.lng);

      let route: NavRoute | null = null;
      for (let retry: number = 0; retry < 5; retry++) {
        try {
          route = await AmapSearchService.getInstance().directionRouteRest(
            a.lat, a.lng, b.lat, b.lng, mode, this.plan.city
          );
          if (route && route.path.length > 0) break;
        } catch (_e) { /* ignore */ }
        if (retry < 4) await new Promise<void>((r) => setTimeout(r, 800));
      }

      if (route && route.path.length > 0) {
        for (const pt of route.path) allPts.push(pt);
        day.route.distance += route.distance;
        day.route.duration += route.duration;
      } else {
        // 3次都失败 → 直线后备
        allPts.push({ latitude: a.lat, longitude: a.lng } as LatLng);
        allPts.push({ latitude: b.lat, longitude: b.lng } as LatLng);
      }
    }
    day.route.path = allPts;
  }

  private parseToolCall(text: string): ToolCall | undefined {
    const idx: number = text.indexOf('---JSON---');
    let jsonStr: string = '';
    if (idx >= 0) {
      jsonStr = text.substring(idx + 10).trim();
    } else {
      const m = text.match(/\{[\s\S]*"action"[\s\S]*\}/);
      if (m) jsonStr = m[0];
    }
    if (!jsonStr) return undefined;
    try {
      const obj = JSON.parse(jsonStr) as Record<string, string>;
      if (obj['action']) {
        const tc: ToolCall = { action: obj['action'] ?? '' };
        if (obj['keywords']) tc.keywords = obj['keywords'];
        if (obj['city']) tc.city = obj['city'];
        if (obj['hotel']) tc.hotel = obj['hotel'];
        if (obj['hotelLat']) tc.hotelLat = obj['hotelLat'];
        if (obj['hotelLng']) tc.hotelLng = obj['hotelLng'];
        if (obj['days']) tc.days = obj['days'];
        if (obj['dayIndex']) tc.dayIndex = obj['dayIndex'];
        if (obj['poiIndex']) tc.poiIndex = obj['poiIndex'];
        if (obj['name']) tc.name = obj['name'];
        if (obj['lat']) tc.lat = obj['lat'];
        if (obj['lng']) tc.lng = obj['lng'];
        if (obj['type']) tc.type = obj['type'];
        if (obj['timeSlot']) tc.timeSlot = obj['timeSlot'];
        if (obj['note']) tc.note = obj['note'];
        if (obj['mode']) tc.mode = obj['mode'];
        return tc;
      }
    } catch (_e) { /* ignore */ }
    return undefined;
  }

  private stripJson(text: string): string {
    const idx: number = text.indexOf('---JSON---');
    if (idx >= 0) return text.substring(0, idx).trim();
    return text.replace(/\n*\{[\s\S]*"action"[\s\S]*\}$/, '').trim();
  }
}
