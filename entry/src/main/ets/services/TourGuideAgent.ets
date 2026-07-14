/**
 * 导游 AI Agent — 对话式旅游规划师
 * 每步工具执行后立即返回地图标记数据，实现渐进式可视化
 */
import { ClaudeService, ClaudeReply } from './ClaudeService';
import { AmapSearchService } from './map/AmapSearchService';
import { TransportSearchService, TicketOption } from './map/TransportSearchService';
import { PoiResult, LatLng, NavRoute, DirectionMode } from './map/MapTypes';
import { TourPlan, TourDay, TourPoiItem, InterCityTransport, createEmptyPlan, getBudgetBreakdown, getTransportEmoji, getTransportLabel } from '../model/TourPlan';
import { Logger } from '../common/Logger';
import { haversineDistance } from '../common/LocationUtils';

const TAG = 'TourGuideAgent';

const SYSTEM_PROMPT: string = `你是小途，资深旅游规划师。今天是${new Date().getFullYear()}年${new Date().getMonth() + 1}月${new Date().getDate()}日。

## 风格
口语化，像朋友聊天。一次只问1个问题。给出具体建议。

## 工作流程
1. 用户说想去某城市玩 → geocode_city 定位
2. 城市定位后 → 如果用户没提交通方式，按顺序问：
   ①"哪天出发？" → ②"从哪个城市出发？"
   得到日期+出发城市后 → **立即 search_transport**，不要自己编
3. 同时或稍后 → 主动问"这次旅行预算大概多少？我好帮你把控花费"
4. 搜酒店 → search_hotels 推荐2-3个（有预算时推荐价位合适的）
5. 用户选好酒店 → make_plan 生成行程
6. 用户修改计划时 → search_and_add 一步完成搜+加

## 工具（回复末尾加 ---JSON---）
{"action":"geocode_city","city":"成都"}
{"action":"search_hotels"}
{"action":"search_hotels","lat":"30.66","lng":"104.06"}
{"action":"search_transport","from":"北京","to":"成都","date":"2026-07-20"}
{"action":"set_transport","type":"high_speed_rail","from":"北京","to":"成都","departureTime":"7月15日 08:30","arrivalTime":"7月15日 17:00","number":"G89","cost":"800"}
{"action":"set_budget","amount":"5000"}
{"action":"estimate_costs"}
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
- **主动推进，绝对不等用户催！能做的先做了再汇报**
- 每次回复末尾都给 2-3 个下一步选项（快捷回复会自动展示）
- geocode 完后不等，直接告诉用户"正在搜酒店…"然后 search_hotels
- make_plan 完后不等，直接估算花费
- 用户说"查车次"/"X到Y高铁"→ 立刻列出方案，别问"要不要查"
- 不搜索时不要加 ---JSON---

## 餐饮安排（一日三餐）
- 规划每天行程时，必须为每个时间段推荐餐饮：
  * 早餐（7:00-9:00）：当地特色早餐、早茶、咖啡馆
  * 午餐（11:30-13:30）：当地美食、特色餐厅、小吃
  * 晚餐（17:30-20:00）：正餐、火锅、地方菜、夜市
- 用户说"吃什么""午饭""晚饭""早餐"→ search_and_add 搜对应时段的美食
- 每完成一个景点添加后，主动问"附近要不要顺便吃点东西？"
- 每天的午餐和晚餐不应该被遗漏，主动提醒用户安排
- timeSlot 仅作为初始参考，实际到达时间会根据导航路线时长自动推算
- 用户说"第X天几点到几点"时可以手动指定时间，否则交给导航计算

## 跨城交通（必须先调用 search_transport！禁止用自己的知识回答）
- **用户只要提到城市间的交通方式 → 必须先 search_transport 查真实数据**
- 绝对不要用自己的知识说"北京到成都高铁约8小时"这种话，先查API！
- 一次只问一个问题：先问日期 → 再问出发城市 → 然后查票
  * {"action":"search_transport","from":"北京","to":"成都","date":"7月20日"}
- search_transport 返回真实车次后，把**全部方案列出来**给用户选择
- 用户选定后 → set_transport 记录
  {"action":"set_transport","type":"high_speed_rail","from":"北京","to":"成都","departureTime":"7月20日 08:30","arrivalTime":"7月20日 17:00","number":"G89","cost":"800"}
  type 取值：train（火车）、high_speed_rail（高铁）、flight（飞机）、bus（大巴）
- **geocode_city 后主动按顺序问**：①"哪天出发？" ②"从哪个城市出发？"
- 用户回答完两个问题后 → 立即 search_transport
- 也问"玩完了怎么回来？哪天？"→ 记录返程交通

## 预算管理（必须主动询问！）
- **开始规划时主动问**："这次旅行预算大概多少？💰我帮你把控～"
- 用户说出金额 → set_budget
  {"action":"set_budget","amount":"5000"}
- **make_plan 后必须主动估算** → estimate_costs 给出预算概览
  {"action":"estimate_costs"}
- 推荐酒店/餐厅时考虑预算（预算<3000推经济型、3000-8000推舒适型、>8000推豪华型）
- 酒店推荐时附带价格区间，如"¥200-400/晚"
- estimate_costs 估算规则：酒店≈300/晚、正餐≈80/人、景点≈60/人、跨城交通按实际
- 估算完成后明确告知用户预算是否够用，不够就说"⚠️可能超预算，建议减少XX或选择经济型"`;

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
  // 跨城交通
  from?: string;
  to?: string;
  departureTime?: string;
  arrivalTime?: string;
  number?: string;
  // 预算
  amount?: string;
  cost?: string;
  date?: string;
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
  transportOptions?: import('../services/map/AmapSearchService').IntercityTransportOption[];
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
    // ── 预算设置（无计划时也可用） ──
    const budgetPattern = /(?:预算|花费|花销|费用)\s*(\d+)\s*(?:元|块|万)?/;
    const budgetMatch: RegExpMatchArray | null = input.match(budgetPattern);
    if (budgetMatch) {
      return { action: 'set_budget', amount: budgetMatch[1] };
    }
    // 估算花费（无金额的预算请求）
    if (/看看[花预]|估算|钱够|预算够|花费多少/.test(input) && this.plan.totalBudget) {
      return { action: 'estimate_costs' };
    }

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

  private detectGeocodeIntent(input: string): ToolCall | undefined {
    // 已有目的地城市 → 新城市名可能是出发地，不自动定位
    if (this.plan.city.length > 0 && this.plan.cityLat !== 0) return undefined;
    // 排除：交通关键词
    if (/到.*的?(?:高铁|火车|飞机|动车|票|车次)/.test(input)) return undefined;
    if (/第[一二三四五六七八\d]+天/.test(input)) return undefined;
    if (/预算|花费|花销/.test(input)) return undefined;
    // 排除：看起来像回答"从哪里出发"
    if (/^[一-龥]{2,4}$/.test(input.trim()) && this.plan.city.length > 0) return undefined;

    const KNOWN_CITIES: string[] = [
      '北京','上海','广州','深圳','成都','重庆','杭州','南京','武汉','西安',
      '郑州','长沙','青岛','大连','厦门','苏州','天津','济南','哈尔滨','沈阳',
      '昆明','贵阳','南宁','海口','三亚','拉萨','乌鲁木齐','兰州','银川','西宁',
      '太原','石家庄','长春','合肥','福州','南昌','宁波','温州','无锡','佛山',
      '东莞','珠海','惠州','中山','洛阳','开封','桂林','张家界','丽江','大理',
      '黄山','峨眉山','秦皇岛','烟台','威海','北海','呼和浩特','包头',
    ];

    for (const city of KNOWN_CITIES) {
      if (input.includes(city)) {
        return { action: 'geocode_city', city: city };
      }
    }

    const m = input.match(/(?:去|到|在|从|定位|查|搜|规划|计划|想去?|要到|安排|帮我)\s*([一-龥]{2,4})/);
    if (m && !/一下|一个|怎么|哪里|什么|这个|那个/.test(m[1])) {
      return { action: 'geocode_city', city: m[1] };
    }

    return undefined;
  }

  /** 检测跨城交通搜索意图 — 绕过 AI，直接返回工具调用 */
  private detectTransportIntent(input: string): ToolCall | undefined {
    // 必须包含交通关键词
    if (!(/高铁|火车|动车|飞机|航班|大巴|客车|怎么去|怎么到|查.*票|查.*车|查.*飞机|车次|班次|几趟|有哪些/.test(input))) return undefined;

    // 提取日期
    let date: string | undefined = undefined;
    const dateMatch = input.match(/(\d{1,2}月\d{1,2}[日号]|\d{4}-\d{2}-\d{2})/);
    if (dateMatch) date = dateMatch[1];

    let from: string | undefined = undefined;
    let to: string | undefined = undefined;

    // 模式1: "从A到B" / "从A坐X去B"
    const m1 = input.match(/从([^\s,，。去到坐]{2,8})[到去坐][^\s,，。]{0,6}?([^\s,，。去到]{2,8})/);
    if (m1) { from = m1[1]; to = m1[2]; }

    // 模式2: "A到B的高铁/火车/飞机/票"
    if (!from) {
      const m2 = input.match(/([^\s,，。去到坐]{2,8})到([^\s,，。去]{2,8})[\s，,。]*(?:的|有)?(?:高铁|火车|飞机|动车|票|车票)/);
      if (m2) { from = m2[1]; to = m2[2]; }
    }

    // 模式3: "查A去B" / "查A到B"
    if (!from) {
      const m3 = input.match(/(?:查|搜|找|看)(?:一下|一|个|的)?([^\s,，。]{2,8})[去到]([^\s,，。]{2,8})/);
      if (m3) { from = m3[1]; to = m3[2]; }
    }

    // 模式4: 只有目的地 "怎么去X" / "有没有到X的火车"
    if (!from && !to) {
      const m4 = input.match(/(?:怎么去|怎么到|坐[高铁火飞机]+去|有没有到)([^\s,，。]{2,8})/);
      if (m4) { to = m4[1]; }
    }

    // 清洗城市名：去"市"字和交通关键词
    if (from) from = from.replace(/[市省]$/, '');
    if (to) to = to.replace(/[市省]$/, '');

    if (from && to && from.length >= 2 && to.length >= 2 && from !== to) {
      const tc: ToolCall = { action: 'search_transport', from: from, to: to };
      if (date) tc.date = date;
      return tc;
    }

    return undefined;
  }

  /** 处理用户输入 */
  async process(input: string): Promise<AgentResponse> {
    this.toolCallCount = 0;

    // ── 确定性：城市定位 ──
    const geocodeIntent: ToolCall | undefined = this.detectGeocodeIntent(input);
    if (geocodeIntent) {
      Logger.info(TAG, 'Geocode intent detected: %{public}s', geocodeIntent.city ?? '');
      const userMsg: string = '用户: ' + input;
      // 不调AI，立即返回（AI文本由Phase2补充）
      return { text: '正在定位' + (geocodeIntent.city || '') + '…', toolCall: geocodeIntent };
    }

    // ── 确定性：跨城交通搜索 ──
    const transportIntent: ToolCall | undefined = this.detectTransportIntent(input);
    if (transportIntent) {
      Logger.info(TAG, 'Transport intent detected: %{public}s→%{public}s',
        transportIntent.from ?? '', transportIntent.to ?? '');
      // 不调AI，立即返回
      return { text: '正在查询' + (transportIntent.from || '') + '到' + (transportIntent.to || '') + '…', toolCall: transportIntent };
    }

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
    let toolCall: ToolCall | undefined = this.parseToolCall(text);
    // AI没输出工具但提到了城市名 → 自动补geocode
    if (!toolCall) {
      const cityHint = this.detectGeocodeIntent(text);
      if (cityHint) {
        toolCall = cityHint;
        Logger.info(TAG, 'Post-AI geocode detected from AI text: %{public}s', cityHint.city || '');
      }
    }
    if (toolCall) {
      return { text: this.stripJson(text), toolCall: toolCall };
    }
    return { text: this.stripJson(text) };
  }

  /** 执行工具并返回结果（含地图更新数据 + AI 继续对话） */
  async executeToolAndContinue(action: string, params: Record<string, string>): Promise<AgentResponse> {
    let resultText: string = '';
    let mapCenter: LatLng | undefined = undefined;
    let markers: MapMarker[] | undefined = undefined;
    let transportOptions: import('../services/map/AmapSearchService').IntercityTransportOption[] | undefined = undefined;

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
            let autoPois: TourPoiItem[] = [];
            if (this.plan.hotel) {
              autoPois.push(
                { name: this.plan.hotel.name, lat: this.plan.hotel.lat, lng: this.plan.hotel.lng, type: '酒店住宿', timeSlot: '出发', duration: '', note: '' },
                { name: this.plan.hotel.name, lat: this.plan.hotel.lat, lng: this.plan.hotel.lng, type: '酒店住宿', timeSlot: '返回', duration: '', note: '' }
              );
            }
            this.plan.dailyPlans.push({
              dayIndex: nd, label: `第${nd + 1}天`, pois: autoPois, route: null
            });
          }
          this.plan.days = this.plan.dailyPlans.length;
        }

        // 全城文字搜索。失败自动用更宽泛的关键词重试
        let saPois: PoiResult[] = await AmapSearchService.getInstance().searchPoiByText(saKw, this.plan.city);
        if (saPois.length === 0 && saKw.length > 2) {
          // 取前2个字再试一次
          const shortKw: string = saKw.substring(0, 2);
          saPois = await AmapSearchService.getInstance().searchPoiByText(shortKw, this.plan.city);
        }
        if (saPois.length === 0) {
          resultText = `在${this.plan.city}未找到"${saKw}"，试试换个说法？`;
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
        // 自动估算花费：优先用高德返回的人均消费
        let autoCost: number | undefined = undefined;
        const poiType: string = first.type || '';
        // 高德 biz_ext.cost 是人均消费字符串
        if (first.cost && first.cost.length > 0) {
          autoCost = parseInt(first.cost) || undefined;
        }
        if (!autoCost) {
          if (poiType.includes('酒店') || poiType.includes('宾馆') || poiType.includes('民宿')) autoCost = 300;
          else if (poiType.includes('餐厅') || poiType.includes('美食') || poiType.includes('小吃')) autoCost = 80;
          else if (autoTimeSlot.includes('餐')) autoCost = 80;
          else if (poiType.includes('购物') || poiType.includes('商场')) autoCost = 100;
          else if (poiType.includes('景点') || poiType.includes('公园')) autoCost = 60;
          else if (poiType.includes('咖啡') || poiType.includes('茶')) autoCost = 40;
        }

        const newPoi: TourPoiItem = {
          name: first.name, lat: first.latitude, lng: first.longitude,
          type: first.type || '景点', timeSlot: autoTimeSlot,
          duration: '1-2h', note: first.address || '',
          mode: params['mode'] || undefined,
          estimatedCost: autoCost,
        };

        // 有酒店时插在"返回"之前，无酒店时直接追加
        let saInserted: boolean = false;
        if (this.plan.hotel) {
          for (let i: number = saDay.pois.length - 1; i >= 0; i--) {
            if (saDay.pois[i].timeSlot === '返回') {
              saDay.pois.splice(i, 0, newPoi);
              saInserted = true;
              break;
            }
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

        // 酒店可选：没选酒店则不设起终点，行程从第一站开始
        if (hotelName && hotelLat !== 0) {
          this.plan.hotel = { name: hotelName, lat: hotelLat, lng: hotelLng, type: '酒店住宿', timeSlot: '入住', duration: '全程', note: '' };
        }

        // 调整天数时保留已有内容。没酒店时不加起终点
        let hadContent: boolean = this.plan.dailyPlans.length > 0;
        while (this.plan.dailyPlans.length < this.plan.days) {
          const nd: number = this.plan.dailyPlans.length;
          let basePois: TourPoiItem[] = [];
          if (this.plan.hotel) {
            basePois.push(
              { name: this.plan.hotel.name, lat: this.plan.hotel.lat, lng: this.plan.hotel.lng, type: '酒店住宿', timeSlot: '出发', duration: '', note: '' },
              { name: this.plan.hotel.name, lat: this.plan.hotel.lat, lng: this.plan.hotel.lng, type: '酒店住宿', timeSlot: '返回', duration: '', note: '' }
            );
          }
          this.plan.dailyPlans.push({
            dayIndex: nd, label: `第${nd + 1}天`, pois: basePois, route: null
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
            (hotelName ? `\n入住：${hotelName}` : '') +
            `\n\n告诉我你想去哪玩？比如"第一天去宽窄巷子"、"第二天吃火锅"～`;
        break;
      }
      case 'get_weather': {
        resultText = `${params['city'] || this.plan.city}近日天气：晴转多云 20-28°C（参考）。`;
        break;
      }
      case 'set_budget': {
        const budgetStr: string = params['amount'] ?? '';
        const budgetNum: number = parseInt(budgetStr);
        if (budgetNum > 0) {
          this.plan.totalBudget = budgetNum;
          resultText = `已设置旅行总预算为 ¥${budgetNum}。\n我会在推荐时考虑预算，输入"估算花费"查看预算分配。`;
        } else {
          resultText = '请输入有效的预算金额，如"预算5000元"。';
        }
        break;
      }
      case 'estimate_costs': {
        if (!this.plan.totalBudget) {
          resultText = '还没设置预算哦！请先告诉我预算是多少，比如"预算5000元"。';
          break;
        }
        // 估算各 POI 花费
        for (const day of this.plan.dailyPlans) {
          for (const poi of day.pois) {
            if (poi.estimatedCost && poi.estimatedCost > 0) continue; // 已有值则不覆盖
            const t: string = poi.type || '';
            if (t.includes('酒店') || t.includes('住宿')) {
              poi.estimatedCost = this.plan.days > 0 ? Math.round(this.plan.hotel ? 300 : 200) : 300;
            } else if (t.includes('餐厅') || t.includes('美食') || t.includes('小吃') || t.includes('咖啡')) {
              poi.estimatedCost = 80;
            } else if (poi.timeSlot.includes('餐')) {
              poi.estimatedCost = 80;
            } else if (t.includes('交通') || t.includes('飞机') || t.includes('高铁') || t.includes('火车')) {
              poi.estimatedCost = t.includes('飞机') ? 800 : (t.includes('高铁') ? 500 : 200);
            } else if (t.includes('景点') || t.includes('公园') || t.includes('风景') || t.includes('博物馆')) {
              poi.estimatedCost = 60;
            } else if (t.includes('购物') || t.includes('商场')) {
              poi.estimatedCost = 100;
            }
          }
        }
        // 估算跨城交通
        if (this.plan.transportToCity && (!this.plan.transportToCity.cost || this.plan.transportToCity.cost === 0)) {
          const tt: string = this.plan.transportToCity.type;
          this.plan.transportToCity.cost = tt === 'flight' ? 800 : (tt === 'high_speed_rail' ? 500 : (tt === 'train' ? 200 : 100));
        }
        if (this.plan.transportBack && (!this.plan.transportBack.cost || this.plan.transportBack.cost === 0)) {
          const tb: string = this.plan.transportBack.type;
          this.plan.transportBack.cost = tb === 'flight' ? 800 : (tb === 'high_speed_rail' ? 500 : (tb === 'train' ? 200 : 100));
        }
        // 估算酒店总花费
        if (this.plan.hotel && (!this.plan.hotel.estimatedCost || this.plan.hotel.estimatedCost === 0)) {
          this.plan.hotel.estimatedCost = this.plan.days * 300;
        }
        const br = getBudgetBreakdown(this.plan);
        const totalBudget: number = this.plan.totalBudget ?? 0;
        const over: boolean = br.total > totalBudget;
        resultText = `📊 预算概览（总预算 ¥${totalBudget}）\n` +
          `🏨 住宿: ¥${br.hotel}\n` +
          `🍽️ 餐饮: ¥${br.food}\n` +
          `🚄 交通: ¥${br.transport}\n` +
          `🎫 景点: ¥${br.attractions}\n` +
          `${br.shopping > 0 ? '🛍️ 购物: ¥' + br.shopping + '\n' : ''}` +
          `💰 预估总计: ¥${br.total}` +
          (over ? `\n\n⚠️ 超出预算 ¥${br.total - totalBudget}！建议减少部分项目或选择经济型选项。` :
           `\n\n✅ 预算内，还剩 ¥${totalBudget - br.total}。`);
        break;
      }
      case 'search_transport': {
        // AI 直接用训练知识生成车次列表（比API更全）
        const stFrom: string = params['from'] ?? '';
        const stTo: string = params['to'] ?? '';
        const stDate: string = params['date'] ?? '';
        if (!stFrom || !stTo) {
          resultText = '请提供出发城市和到达城市。';
          break;
        }

        const dateLabel: string = stDate ? stDate : '最近';
        // 让 AI 生成结构化交通数据
        const prompt: string =
          `用户要从${stFrom}到${stTo}，日期${dateLabel}。` +
          `请列出你知道的${stFrom}到${stTo}之间的高铁(G)、动车(D)、普通火车(K/T/Z)方案。` +
          `每个方案给出：车次、出发站、到达站、出发时间、到达时间、大约时长(小时)、大约票价(元)。` +
          `最后用JSON格式总结（只输出JSON，不要其他文字）：\n` +
          `{"action":"show_transport","trains":[{"trip":"G89","type":"high_speed_rail","fromStation":"北京西","toStation":"成都东","departureTime":"08:00","arrivalTime":"16:30","durationHours":8.5,"price":780}]}`;
        const reply: ClaudeReply = await this.claude.chatConversation(prompt, SYSTEM_PROMPT);
        const aiText: string = reply.text || '';
        // 解析 AI 输出的 JSON
        const trains = this.parseTrainsFromAi(aiText, stFrom, stTo);
        if (trains.length > 0) {
          transportOptions = trains;
          resultText = `${stFrom}→${stTo}${stDate ? '（' + stDate + '）' : ''}共${trains.length}个方案：`;
        } else {
          // AI 没返回JSON，尝试高德兜底
          const options = await AmapSearchService.getInstance().searchIntercityTransport(stFrom, stTo, stDate || undefined);
          transportOptions = options;
          if (options.length > 0) {
            resultText = `查到${stFrom}→${stTo}共${options.length}个方案（高德路线推荐）：`;
          } else {
            resultText = `未查到${stFrom}到${stTo}的方案，请换个说法试试。`;
          }
        }
        markers = undefined;
        break;
      }
      case 'set_transport': {
        const tType: string = params['type'] ?? '';
        const tFrom: string = params['from'] ?? '';
        const tTo: string = params['to'] ?? '';
        const tDep: string = params['departureTime'] ?? '';
        const tArr: string = params['arrivalTime'] ?? '';
        const tNum: string = params['number'] ?? '';
        const tCost: number = parseInt(params['cost'] ?? '0');
        if (!tType || !tFrom || !tTo) {
          resultText = '请提供交通方式、出发城市和到达城市。';
          break;
        }
        const transport: InterCityTransport = {
          type: tType, from: tFrom, to: tTo,
          departureTime: tDep || undefined,
          arrivalTime: tArr || undefined,
          number: tNum || undefined,
          cost: tCost > 0 ? tCost : undefined,
          note: undefined,
        };
        // 判断是到达还是返程：如果目的地 = 计划城市，则为到达；否则为返程
        if (!this.plan.transportToCity) {
          this.plan.transportToCity = transport;
          resultText = `已记录从${tFrom}到${tTo}的${getTransportLabel(tType)}${tNum ? ' ' + tNum : ''}${tDep ? ' ' + tDep : ''}。`;
          // 如果目的城市与当前计划城市不同，更新城市
          if (tTo !== this.plan.city && this.plan.city.length === 0) {
            const loc: LatLng | null = await AmapSearchService.getInstance().geocodeCity(tTo);
            if (loc) {
              this.plan.city = tTo;
              this.plan.cityLat = loc.latitude;
              this.plan.cityLng = loc.longitude;
              mapCenter = loc;
              resultText += `\n目的地已设为${tTo}。`;
            }
          }
        } else if (!this.plan.transportBack) {
          this.plan.transportBack = transport;
          resultText = `已记录从${tFrom}返回${tTo}的${getTransportLabel(tType)}${tNum ? ' ' + tNum : ''}${tDep ? ' ' + tDep : ''}。`;
        } else {
          // 两者都已设置，更新到达交通
          this.plan.transportToCity = transport;
          resultText = `已更新到达交通为从${tFrom}到${tTo}的${getTransportLabel(tType)}。`;
        }
        // 如果是新目的地，做 geocode
        if (tTo !== this.plan.city && this.plan.cityLat === 0) {
          const loc2: LatLng | null = await AmapSearchService.getInstance().geocodeCity(tTo);
          if (loc2) {
            this.plan.city = tTo;
            this.plan.cityLat = loc2.latitude;
            this.plan.cityLng = loc2.longitude;
            if (!mapCenter) mapCenter = loc2;
          }
        }
        this.plan.status = 'planning';
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
      transportOptions: transportOptions,
    };

    // 自动串联：仅在明确上下文生效
    if (action === 'make_plan') {
      resp.toolCall = { action: 'estimate_costs' };
    } else if (action === 'set_budget' && this.plan.dailyPlans.length > 0) {
      resp.toolCall = { action: 'estimate_costs' };
    }

    // 修改计划的操作返回深拷贝计划
    if (this.plan.dailyPlans.length > 0 &&
        (action === 'make_plan' || action === 'add_poi_to_day' || action === 'remove_poi_from_day' ||
         action === 'search_and_add' || action === 'set_budget' || action === 'estimate_costs')) {
      resp.plan = JSON.parse(JSON.stringify(this.plan)) as TourPlan;
    }
    if (action === 'set_transport') {
      resp.plan = JSON.parse(JSON.stringify(this.plan)) as TourPlan;
    }
    return resp;
  }

  /** 工具执行后向 AI 请求下一步（在 UI 更新之后调用，不阻塞地图刷新） */
  async askAiNextStep(action: string, resultText: string): Promise<AgentResponse> {
    let planCtx: string = `当前计划：城市=${this.plan.city}(${this.plan.cityLat.toFixed(2)},${this.plan.cityLng.toFixed(2)}) 酒店=${this.plan.hotel?.name || '未选'} 天数=${this.plan.days}`;
    if (this.plan.totalBudget) planCtx += ` 总预算=¥${this.plan.totalBudget}`;
    if (this.plan.transportToCity) planCtx += ` 到达交通=${getTransportLabel(this.plan.transportToCity.type)}${this.plan.transportToCity.from}→${this.plan.transportToCity.to}`;
    if (this.plan.transportBack) planCtx += ` 返程交通=${getTransportLabel(this.plan.transportBack.type)}${this.plan.transportBack.from}→${this.plan.transportBack.to}`;
    if (this.plan.dailyPlans.length > 0) {
      planCtx += '\n每日行程：';
      for (const d of this.plan.dailyPlans) {
        planCtx += `\n  ${d.label}: ` + d.pois.map((p, i) => `[${i}]${p.name}(${p.type},${p.timeSlot})`).join(' → ');
      }
    }
    const followMsg: string = `工具 ${action} 结果：\n${resultText}\n\n${planCtx}\n\n请基于此继续与用户对话。如果任务还没完成，继续下一步。如果搜索失败，换个关键词重试。`;
    const reply: ClaudeReply = await this.claude.chatConversation(followMsg, SYSTEM_PROMPT);
    const resultText2: string = reply.text || '收到，请继续。';
    let nextTool: ToolCall | undefined = this.parseToolCall(resultText2);
    // 如果没有工具调用且回复很短，重试一次
    if (!nextTool && resultText2.length < 20) {
      const retryReply: ClaudeReply = await this.claude.chatConversation(
        '请继续完成任务，下一步做什么？', SYSTEM_PROMPT);
      const retryText: string = retryReply.text || '';
      nextTool = this.parseToolCall(retryText);
      const resp: AgentResponse = { text: this.stripJson(retryText || resultText2), toolCall: nextTool };
      return resp;
    }
    const resp: AgentResponse = { text: this.stripJson(resultText2), toolCall: nextTool };
    return resp;
  }

  /** 自动分配下一个可用时间段 */
  private nextTimeSlot(day: TourDay): string {
    const defaultSlots: string[] = ['早餐7:30', '上午9:00', '午餐12:00', '下午14:00', '晚餐18:00', '晚上20:00'];
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
  /** 从AI回复中解析交通方案JSON → 转成 transportOptions */
  private parseTrainsFromAi(aiText: string, fromCity: string, toCity: string):
    import('../services/map/AmapSearchService').IntercityTransportOption[] {
    const options: import('../services/map/AmapSearchService').IntercityTransportOption[] = [];
    try {
      let jsonStr: string = '';
      const idx: number = aiText.indexOf('---JSON---');
      if (idx >= 0) {
        jsonStr = aiText.substring(idx + 10).trim();
      } else {
        const m = aiText.match(/\{[\s\S]*"action"[\s\S]*"trains"[\s\S]*\}/);
        if (m) jsonStr = m[0];
      }
      if (!jsonStr) return options;
      const obj = JSON.parse(jsonStr) as Record<string, Object>;
      if (!obj || obj['action'] !== 'show_transport') return options;
      const trains = obj['trains'] as Object[] | undefined;
      if (!trains || trains.length === 0) return options;
      for (const t of trains) {
        const tr = t as Record<string, Object>;
        const trip: string = (tr['trip'] as string) || '';
        if (!trip) continue;
        const durH: number = typeof tr['durationHours'] === 'number' ? (tr['durationHours'] as number) :
          (parseFloat((tr['durationHours'] as string) ?? '0') || 0);
        const price: number = typeof tr['price'] === 'number' ? (tr['price'] as number) :
          (parseFloat((tr['price'] as string) ?? '0') || 0);
        options.push({
          type: (tr['type'] as string) || 'high_speed_rail',
          trip: trip,
          fromStation: (tr['fromStation'] as string) || fromCity,
          toStation: (tr['toStation'] as string) || toCity,
          departureTime: (tr['departureTime'] as string) || '',
          arrivalTime: (tr['arrivalTime'] as string) || '',
          duration: Math.round(durH * 3600),
          distance: 0,
          price: price,
        } as import('../services/map/AmapSearchService').IntercityTransportOption);
      }
    } catch (_e) { /* ignore */ }
    return options;
  }

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
    try { this.recalcDayTimeline(day); } catch (e) { /* 时间推算失败不影响路线绘制 */ }
  }

  /** 根据导航路线时长计算每天各 POI 的实际时间槽 */
  private recalcDayTimeline(day: TourDay): void {
    if (day.pois.length < 2) return;
    const staticSlots: string[] = ['出发', '返回', '入住'];
    // 找第一个非标记 POI 作为时间基准
    let baseMin: number = 9 * 60;
    let firstIdx: number = -1;
    for (let i: number = 0; i < day.pois.length; i++) {
      if (staticSlots.indexOf(day.pois[i].timeSlot) < 0) {
        baseMin = this.parseTimeSlotMinutes(day.pois[i].timeSlot);
        firstIdx = i;
        break;
      }
    }
    if (firstIdx < 0) return;
    for (let pi: number = firstIdx; pi < day.pois.length; pi++) {
      if (staticSlots.indexOf(day.pois[pi].timeSlot) >= 0) continue;
      if (pi === firstIdx) {
        day.pois[pi].timeSlot = this.minutesToTimeSlot(baseMin);
        continue;
      }
      const prevStay: number = this.parseDurationMinutes(day.pois[pi - 1].duration);
      const realCount: number = day.pois.filter(p => staticSlots.indexOf(p.timeSlot) < 0).length;
      let segDur: number = 0;
      if (day.route && day.route.duration > 0 && realCount > 1) {
        segDur = day.route.duration / (realCount - 1);
      }
      baseMin += prevStay + Math.ceil(segDur / 60);
      day.pois[pi].timeSlot = this.minutesToTimeSlot(baseMin);
    }
  }

  /** 解析时间槽字符串为分钟数（从0点开始） */
  private parseTimeSlotMinutes(ts: string): number {
    if (!ts || ts.length === 0) return 9 * 60;
    const match: RegExpMatchArray | null = ts.match(/(\d{1,2}):(\d{2})/);
    if (match) {
      const h: number = parseInt(match[1]) || 9;
      const m: number = parseInt(match[2]) || 0;
      return Math.max(0, Math.min(23 * 60 + 59, h * 60 + m));
    }
    if (ts.includes('早餐')) return 7 * 60 + 30;
    if (ts.includes('上午')) return 9 * 60;
    if (ts.includes('午餐') || ts.includes('中午')) return 12 * 60;
    if (ts.includes('下午')) return 14 * 60;
    if (ts.includes('晚餐')) return 18 * 60;
    if (ts.includes('晚上')) return 19 * 60;
    return 9 * 60;
  }

  /** 解析停留时间字符串为分钟数 */
  private parseDurationMinutes(dur: string): number {
    if (!dur || dur.length === 0) return 90; // 默认1.5小时
    const hMatch: RegExpMatchArray | null = dur.match(/(\d+)\s*h/);
    const mMatch: RegExpMatchArray | null = dur.match(/(\d+)\s*min/);
    let mins: number = 0;
    if (hMatch) mins += parseInt(hMatch[1]) * 60;
    if (mMatch) mins += parseInt(mMatch[1]);
    if (mins === 0) mins = 90; // 默认
    return mins;
  }

  /** 将分钟数转为中文时间槽字符串 */
  private minutesToTimeSlot(mins: number): string {
    const total: number = mins % (24 * 60);
    const h: number = Math.floor(total / 60);
    const m: number = total % 60;
    const timeStr: string = `${h}:${String(m).padStart(2, '0')}`;
    if (h < 6) return '凌晨' + timeStr;
    if (h < 9) return '早餐' + timeStr;
    if (h < 11) return '上午' + timeStr;
    if (h < 13) return '午餐' + timeStr;
    if (h < 17) return '下午' + timeStr;
    if (h < 20) return '晚餐' + timeStr;
    return '晚上' + timeStr;
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
        // 跨城交通
        if (obj['from']) tc.from = obj['from'];
        if (obj['to']) tc.to = obj['to'];
        if (obj['departureTime']) tc.departureTime = obj['departureTime'];
        if (obj['arrivalTime']) tc.arrivalTime = obj['arrivalTime'];
        if (obj['number']) tc.number = obj['number'];
        // 预算
        if (obj['amount']) tc.amount = obj['amount'];
        if (obj['cost']) tc.cost = obj['cost'];
        if (obj['date']) tc.date = obj['date'];
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
