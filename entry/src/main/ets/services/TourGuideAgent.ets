/**
 * 导游 AI Agent — 对话式旅游规划师
 * 每步工具执行后立即返回地图标记数据，实现渐进式可视化
 */
import { ClaudeService, ClaudeReply } from './ClaudeService';
import { AmapSearchService } from './map/AmapSearchService';
import { TransportSearchService, TicketOption as TransportTicketOption } from './map/TransportSearchService';
import { PoiResult, LatLng, NavRoute, DirectionMode } from './map/MapTypes';
import { TourPlan, TourDay, TourPoiItem, InterCityTransport, createEmptyPlan, getBudgetBreakdown, getTransportEmoji, getTransportLabel } from '../model/TourPlan';
import { Logger } from '../common/Logger';
import { haversineDistance } from '../common/LocationUtils';

const TAG = 'TourGuideAgent';

const SYSTEM_PROMPT: string = `你是小途，资深旅游规划师。今天是${new Date().getFullYear()}年${new Date().getMonth() + 1}月${new Date().getDate()}日。

## 风格
口语化，像朋友聊天。一次只问1个问题。给出具体建议。

## 工作流程
**每步都要等用户回应，不要连续跳步！**
1. 用户说想去某城市玩 → geocode_city 定位
2. 定位后 → **先问**"哪天出发？""从哪个城市出发？"→ 等用户回答 → search_transport
3. 交通搞定后 → **问**"预算大概多少？"→ 等用户回答 → set_budget
4. 以上都有了 → **问**"需要帮你找酒店吗？想住哪个区域？"→ 用户说要 → search_hotels
5. 天数+交通+预算全齐 → **问**"帮你创建X天行程？"→ 用户同意 → make_plan
6. 用户说"第X天去/吃XX" → search_and_add 一步完成

## 工具调用格式
回复末尾加 ---JSON---，可以一次调用多个工具（数组格式，推荐！）：

单工具（兼容）：
---JSON---
{"action":"geocode_city","city":"成都"}
{"action":"search_hotels"}
{"action":"search_hotels","keywords":"春熙路"}

多工具（数组 — 能并行的事一次性做完，减少等待！）：
---JSON---
[{"action":"geocode_city","city":"成都"},{"action":"search_transport","from":"北京","to":"成都","date":"7月20日"},{"action":"search_hotels"}]

## 并行规则
- geocode_city 如果和搜索类工具一起调用，系统会自动先定位再搜索，放心放在同一个数组里
- 独立搜索（搜酒店+搜交通+搜景点+多个 search_and_add）可以放心并行
- search_and_add 多次调用可以并行（搜宽窄巷子+搜火锅 一次搞定）
- **不要串行做能并行的事！**一次数组输出比多次往返快得多

## 规则（每一条都必须遵守！）
- **最重要的规则：每次回复末尾都必须带 ---JSON--- 工具调用！**
  * 只有纯粹闲聊（打招呼、道谢）才不加。其余情况：定位→搜交通→问预算→搜酒店→生成计划→完善行程，每一步都输出工具！
  * 宁可多调用一次，也不能闲着！
- 酒店是可选的：用户可能住在这个城市（不需要酒店），也可能几天换几个酒店
  * **搜酒店前必须先问用户**："想住在哪个区域？" 或 "对酒店有什么偏好吗？" — 不要擅自搜全城
  * 用户指定了区域（如"春熙路"） → search_hotels 带 keywords 精准搜
  * 用户选了酒店 → **用 search_and_add 添加**（不要用 make_plan），这样酒店会自动显示在地图上并纳入预算
  * 用户没提酒店 → 不问不搜
- geocode_city 只需一次。城市换了才重新geocode
- 用户说"第X天去/吃XX" → 直接 search_and_add，不要确认
- **make_plan 不要抢着调用！必须等以下条件全部满足后再问用户确认：**
  ① 用户已经说了玩几天（没说的话先问"打算玩几天？"）
  ② 交通已定（出发城市+日期已有搜索结果 或 本地游）
  ③ 预算已设
  满足了 → 问用户"现在帮你创建X天行程骨架？" → 用户同意再 make_plan
- make_plan 只创建骨架，不自动加景点。完成后立即 search_and_add 推荐几个景点
- make_plan 填 days 参数反映用户说的天数
- **主动推进但不越界！**
  * geocode 完 → 按顺序问：哪天出发？从哪个城市出发？→ 搜交通
  * 不要一上来就搜酒店！等用户给了预算或明确说"帮我找酒店"再 search_hotels
  * 信息不完整时先问，不要硬猜
  * **不要替用户做决定！天数、酒店、预算都要等用户确认**
- make_plan 完后立即 estimate_costs，不要等
- 每次回复末尾都给 2-3 个快捷选项
- 工具调用失败了没关系，换个参数重试，别停下来聊天

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
- search_transport 直接查询 12306 官方接口，返回当天全部车次（含余票状态和各座位票价）
- 如果所有数据源都没有返回结果，诚实告诉用户"暂未查到实时方案，建议到12306 App查询"
- **绝对不要自己编造车次、时间或价格！** 不确定就说"建议到12306确认"，不要猜测
- 用户选定后 → set_transport 记录

## 预算管理（必须主动询问！）
- **开始规划时主动问**："这次旅行预算大概多少？💰我帮你把控～"
- 用户说出金额 → set_budget
  {"action":"set_budget","amount":"5000"}
- **make_plan 后必须主动估算** → estimate_costs 给出预算概览
  {"action":"estimate_costs"}
- 推荐酒店/餐厅时考虑预算（预算<3000推经济型、3000-8000推舒适型、>8000推豪华型）
- 酒店推荐时附带价格区间，如"¥200-400/晚"
- estimate_costs 估算规则（会根据城市自动调整）：
  * 港澳：餐饮×3.5、酒店×3.5（如香港正餐≈280/人，酒店≈1050/晚）
  * 一线（北上广深）：×1.4-1.5（正餐≈120/人，酒店≈450/晚）
  * 新一线（成都杭州等）：×1.2（正餐≈95/人，酒店≈360/晚）
  * 二线及以下：×1.0（正餐≈80/人，酒店≈300/晚）
  * 跨城交通按实际票价
- **绝不能用二线城市价格估算香港！** 香港吃一顿快餐也要50-80港币，正餐150-400港币
- 估算完成后明确告知用户预算是否够用，不够就说"⚠️可能超预算，建议减少XX或选择经济型"

## 本地人模式（用户常住城市 = 目的地城市）
- 用户就在本地，不需要跨城交通！不要问"哪天出发""从哪个城市出发""怎么回来"
- 不要主动推荐酒店（用户有房住），除非用户明确说想住酒店
- 专注于推荐景点、美食、购物、本地体验
- 预算不含酒店和跨城交通：estimate_costs 时跳过这两项
- 不要说"返程""回去"之类的话，用户就在本地`;

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
  fromStation?: string;
  toStation?: string;
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

/** 单个工具执行结果 */
export interface ToolResult {
  action: string;
  params: Record<string, string>;
  text: string;
  mapCenter?: LatLng;
  markers?: MapMarker[];
  transportOptions?: import('../services/map/AmapSearchService').IntercityTransportOption[];
}

export interface AgentResponse {
  text: string;
  toolCalls: ToolCall[];  // 多工具并行，空数组 = 无工具调用
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
  /** 最近一次批量工具执行的结果，供 askAiNextStep 使用 */
  private lastToolResults: ToolResult[] = [];
  /** 最近一次用户输入（确定性检测时保留，供 askAiNextStep 带上原始上下文） */
  private lastUserInput: string = '';
  /** 用户偏好上下文（软件引导，不强制） */
  private userPrefContext: string = '';
  /** 用户常住城市，用于判断本地人模式 */
  private userCity: string = '';

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

  /** 获取最近一次批量工具执行的结果 */
  getLastToolResults(): ToolResult[] {
    return this.lastToolResults;
  }

  /** 从外部同步计划数据（UI恢复持久化数据后调用，防止agent/UI两套plan不同步） */
  setPlan(plan: TourPlan): void {
    this.plan = plan;
  }

  /**
   * 设置用户偏好上下文（软件引导，不强制限制推荐）
   * @param userName 用户名
   * @param userCity 用户所在城市
   * @param preferences 偏好标签数组
   */
  setUserContext(userName: string, userCity: string, preferences: string[]): void {
    this.userCity = userCity || '';
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

  /** 获取用户常住城市 */
  getUserCity(): string {
    return this.userCity;
  }

  /** 城市消费水平分级 → 物价乘数 */
  private static readonly CITY_COST_TIERS: Record<string, number> = {
    // 港澳（超高消费）
    '香港': 3.5, '澳门': 3.0,
    // 一线城市
    '北京': 1.5, '上海': 1.5, '广州': 1.4, '深圳': 1.4,
    // 新一线 / 强二线
    '成都': 1.2, '杭州': 1.3, '重庆': 1.1, '武汉': 1.1,
    '西安': 1.1, '南京': 1.2, '苏州': 1.2, '天津': 1.2,
    '长沙': 1.1, '青岛': 1.2, '厦门': 1.3, '大连': 1.2,
    '郑州': 1.0, '济南': 1.0, '合肥': 1.0, '福州': 1.1,
    '沈阳': 1.0, '哈尔滨': 1.0, '长春': 1.0,
    // 旅游热门（中等偏上）
    '三亚': 1.8, '丽江': 1.4, '大理': 1.3, '拉萨': 1.5,
    '昆明': 1.1, '贵阳': 0.9, '南宁': 0.9, '海口': 1.2,
    '乌鲁木齐': 1.2, '兰州': 0.9, '银川': 0.9, '西宁': 0.9,
    '桂林': 1.1, '张家界': 1.2, '黄山': 1.2, '峨眉山': 1.1,
    '洛阳': 0.9, '开封': 0.9, '秦皇岛': 1.1, '烟台': 1.0,
    '威海': 1.0, '北海': 1.0, '呼和浩特': 1.0, '包头': 0.9,
    '太原': 0.9, '石家庄': 0.9, '南昌': 1.0, '宁波': 1.1,
    '温州': 1.1, '无锡': 1.1, '佛山': 1.1,
    '东莞': 1.1, '珠海': 1.3, '惠州': 1.0, '中山': 1.0,
  };

  /** 根据城市名获取消费水平乘数 */
  static getCityCostMultiplier(city: string): number {
    if (!city) return 1.0;
    // 精确匹配
    if (TourGuideAgent.CITY_COST_TIERS[city]) {
      return TourGuideAgent.CITY_COST_TIERS[city];
    }
    // 模糊匹配（城市名前缀）
    for (const key of Object.keys(TourGuideAgent.CITY_COST_TIERS)) {
      if (city.startsWith(key) || key.startsWith(city)) {
        return TourGuideAgent.CITY_COST_TIERS[key];
      }
    }
    return 1.0; // 默认
  }

  /** 判断当前计划是否为本地游（目的地 = 用户常住城市） */
  private isLocalTrip(): boolean {
    if (!this.userCity || !this.plan.city) return false;
    return this.plan.city.includes(this.userCity) || this.userCity.includes(this.plan.city);
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
    // 优先匹配"改成/改为"等变更关键词后的新数字
    const budgetChangePattern = /(?:预算|花费|花销|费用).*?(?:改成|改为|换成|调整为|变成|变到|改到|降到|提到|调到|设为|设成)[^\d]{0,5}(\d+)\s*(?:元|块|万)?/;
    const budgetChangeMatch: RegExpMatchArray | null = input.match(budgetChangePattern);
    if (budgetChangeMatch) {
      return { action: 'set_budget', amount: budgetChangeMatch[1] };
    }
    // 回退：简单的"预算5000"模式（[^\d]{0,5}允许"是/大概/大约"等中间词）
    const budgetPattern = /(?:预算|花费|花销|费用)[^\d]{0,5}(\d+)\s*(?:元|块|万)?/;
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

    // 提取日期并标准化（支持"7月20日""后天""明天"等）
    let date: string | undefined = undefined;
    // 相对日期：明天/后天/大后天
    const relMatch = input.match(/(大?后天|明天)/);
    if (relMatch) {
      const today: Date = new Date();
      const offset: number = relMatch[1] === '明天' ? 1 : (relMatch[1] === '后天' ? 2 : 3);
      const target: Date = new Date(today.getFullYear(), today.getMonth(), today.getDate() + offset);
      date = `${target.getFullYear()}-${String(target.getMonth() + 1).padStart(2, '0')}-${String(target.getDate()).padStart(2, '0')}`;
    } else {
      const dateMatch = input.match(/(\d{1,2}月\d{1,2}[日号]|\d{4}-\d{2}-\d{2})/);
      if (dateMatch) date = this.normalizeDate(dateMatch[1]);
    }

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
    const collected: ToolCall[] = [];

    // ── 1. 收集城市定位意图 ──
    const geocodeIntent: ToolCall | undefined = this.detectGeocodeIntent(input);
    if (geocodeIntent) {
      Logger.info(TAG, 'Geocode intent detected: %{public}s', geocodeIntent.city ?? '');
      collected.push(geocodeIntent);
    }

    // ── 2. 收集跨城交通意图（显式关键词） ──
    const transportIntent: ToolCall | undefined = this.detectTransportIntent(input);
    if (transportIntent) {
      Logger.info(TAG, 'Transport intent detected: %{public}s→%{public}s',
        transportIntent.from ?? '', transportIntent.to ?? '');
      collected.push(transportIntent);
    }

    // ── 3. 隐式交通：有目的地 + "从X出发/来/走" → 自动补交通搜索 ──
    // 修复: 不依赖 geocodeIntent，城市已定位时也用 this.plan.city 作为目的地
    if (!transportIntent) {
      const destCity: string = geocodeIntent?.city || this.plan.city;
      if (destCity) {
        const implicitTransport: ToolCall | undefined = this.detectImplicitTransport(input, destCity);
        if (implicitTransport) {
          Logger.info(TAG, 'Implicit transport detected: %{public}s→%{public}s',
            implicitTransport.from ?? '', implicitTransport.to ?? '');
          collected.push(implicitTransport);
        }
      }
    }

    // ── 4. 如果收集到了确定性工具，合并返回 ──
    if (collected.length > 0) {
      // 保存用户原始输入，供 askAiNextStep 包含上下文（"三天"等）
      this.lastUserInput = input;
      const parts: string[] = [];
      for (const tc of collected) {
        if (tc.action === 'geocode_city') parts.push('定位' + (tc.city || ''));
        else if (tc.action === 'search_transport') parts.push('查' + (tc.from || '') + '→' + (tc.to || '') + '交通');
        else parts.push(tc.action);
      }
      return { text: '正在' + parts.join('，') + '…', toolCalls: collected };
    }

    // 如果是新规划请求，重置计划对象（保持新引用以触发 UI 刷新）
    if (this.isNewTripRequest(input) && this.plan.status === 'complete') {
      this.plan = createEmptyPlan();
      Logger.info(TAG, 'Reset plan for new trip request');
    }

    // 确定性修改意图检测：绕过 AI 工具选择，直接准备工具调用
    const modIntent: ToolCall | undefined = this.detectModificationIntent(input);
    // set_budget 无需 dailyPlans 即可执行；其他操作需要已有计划
    if (modIntent && (modIntent.action === 'set_budget' || this.plan.dailyPlans.length > 0)) {
      Logger.info(TAG, 'Modification intent detected: %{public}s', modIntent.action);
      // 仍然发送给 AI 获取对话文本
      const userMsg: string = '用户: ' + input;
      const reply: ClaudeReply = await this.claude.chatConversation(userMsg, this.getSystemPrompt());
      const text: string = reply.text || '好的，马上更新！';
      // AI 文本 + 确定性工具调用
      return { text: this.stripJson(text), toolCalls: [modIntent] };
    }

    const userMsg: string = '用户: ' + input;
    const reply: ClaudeReply = await this.claude.chatConversation(userMsg, this.getSystemPrompt());
    const text: string = reply.text || '抱歉，我暂时无法回复。';
    let toolCalls: ToolCall[] = this.parseToolCalls(text);
    // AI没输出工具但提到了城市名 → 自动补geocode
    if (toolCalls.length === 0) {
      const cityHint = this.detectGeocodeIntent(text);
      if (cityHint) {
        toolCalls = [cityHint];
        Logger.info(TAG, 'Post-AI geocode detected from AI text: %{public}s', cityHint.city || '');
      }
    }
    return { text: this.stripJson(text), toolCalls: toolCalls };
  }

  /** 隐式交通检测：无显式交通关键词但上下文暗示需要查交通
   *  例如："从武汉出发" + 目的地"成都" → search_transport 武汉→成都 */
  private detectImplicitTransport(input: string, destCity: string): ToolCall | undefined {
    // 必须包含出发含义且无交通关键词（有交通关键词走 detectTransportIntent）
    if (!/从.{2,8}(?:出发|来|走|过去|过来|那边)/.test(input)) return undefined;

    // 提取出发城市
    const m = input.match(/从\s*([^\s,，。去到出发来走过]{2,8})\s*(?:出发|来|走|过去|过来|那边)?/);
    if (!m) return undefined;
    let from: string = m[1].replace(/[市省]$/, '');
    if (from.length < 2 || from === destCity) return undefined;

    // 提取日期
    let date: string | undefined = undefined;
    // "明天" → 实际日期
    const relativeMatch = input.match(/(明天|后天|大后天)/);
    if (relativeMatch) {
      const today: Date = new Date();
      const offset: number = relativeMatch[1] === '明天' ? 1 : (relativeMatch[1] === '后天' ? 2 : 3);
      const target: Date = new Date(today.getFullYear(), today.getMonth(), today.getDate() + offset);
      date = `${target.getFullYear()}-${String(target.getMonth() + 1).padStart(2, '0')}-${String(target.getDate()).padStart(2, '0')}`;
    } else {
      // "7月20日"等
      const dm = input.match(/(\d{1,2}月\d{1,2}[日号])/);
      if (dm) date = dm[1];
    }

    const tc: ToolCall = { action: 'search_transport', from: from, to: destCity };
    if (date) tc.date = this.normalizeDate(date);
    return tc;
  }

  /** 执行单个工具，返回 ToolResult（修改 this.plan 作为副作用） */
  async executeOneTool(action: string, params: Record<string, string>): Promise<ToolResult> {
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
        // 用户指定区域（有 lat/lng）→ 周边搜索；否则全城文字搜索
        // keywords 用于缩小范围（如"春熙路"），没有时默认搜"酒店|宾馆|民宿"
        const hLat: number = parseFloat(params['lat'] ?? '0');
        const hLng: number = parseFloat(params['lng'] ?? '0');
        const hKw: string = params['keywords'] ?? '';
        let pois: PoiResult[];
        if (hLat !== 0 && hLng !== 0) {
          // 有坐标 → 周边搜索；有关键词时加到搜索词里
          const catStr: string = hKw ? `${hKw}|酒店|宾馆|民宿` : '酒店|宾馆|民宿';
          pois = await AmapSearchService.getInstance().searchPoiByCategory(catStr, hLat, hLng, 5000);
        } else {
          // 全城文字搜索；有关键词时精准匹配（如"春熙路 酒店"）
          const textStr: string = hKw ? `${hKw} 酒店` : '酒店|宾馆|民宿';
          pois = await AmapSearchService.getInstance().searchPoiByText(textStr, this.plan.city);
        }
        const top5: PoiResult[] = pois.slice(0, 5);
        markers = top5.map((p: PoiResult): MapMarker => ({
          name: p.name, lat: p.latitude, lng: p.longitude, type: '酒店',
          poiId: p.id, address: p.address
        }));
        resultText = pois.length > 0
          ? `${this.plan.city}酒店(top5)：\n` + top5.map((p, i) =>
              `${i + 1}. ${p.name} | ${p.address || ''} | 坐标(${p.latitude.toFixed(4)},${p.longitude.toFixed(4)})${p.distance > 0 ? ' | ' + p.distance + 'm' : ''}`).join('\n')
              + `\n用户选定酒店后请用 search_and_add 添加：{"action":"search_and_add","keywords":"酒店名","dayIndex":"0"}`
          : `未找到${this.plan.city}酒店。`;
        break;
      }
      case 'search_poi': {
        if (this.plan.cityLat === 0) {
          return { action, params, text: '需要先定位城市（请先调用 geocode_city）。', mapCenter: undefined, markers: undefined };
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
          return { action, params, text: '需要先定位城市（请先调用 geocode_city）。', mapCenter: undefined, markers: undefined };
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
          const cm: number = TourGuideAgent.getCityCostMultiplier(this.plan.city);
          if (poiType.includes('酒店') || poiType.includes('宾馆') || poiType.includes('民宿')) autoCost = Math.round(300 * cm);
          else if (poiType.includes('餐厅') || poiType.includes('美食') || poiType.includes('小吃')) autoCost = Math.round(80 * cm);
          else if (autoTimeSlot.includes('餐')) autoCost = Math.round(80 * cm);
          else if (poiType.includes('购物') || poiType.includes('商场')) autoCost = Math.round(100 * cm);
          else if (poiType.includes('景点') || poiType.includes('公园')) autoCost = Math.round(60 * cm);
          else if (poiType.includes('咖啡') || poiType.includes('茶')) autoCost = Math.round(40 * cm);
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
          // 非本地人第一天：从到达站（火车站/机场）出发，优先用车站在线坐标
          if (nd === 0 && !this.isLocalTrip() && this.plan.transportToCity && this.plan.cityLat !== 0) {
            const transportLabel: string = getTransportLabel(this.plan.transportToCity.type);
            const stationName: string = this.plan.transportToCity.toStation ||
              this.plan.transportToCity.number || transportLabel;
            // 优先使用车站 geocode 坐标，兜底用城市中心
            const arrLat: number = this.plan.transportToCity.stationLat ?? this.plan.cityLat;
            const arrLng: number = this.plan.transportToCity.stationLng ?? this.plan.cityLng;
            basePois.push({
              name: `到达${stationName}`,
              lat: arrLat, lng: arrLng,
              type: '交通到达', timeSlot: '到达', duration: '', note: ''
            });
          }
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
        // 城市物价系数
        const costMul: number = TourGuideAgent.getCityCostMultiplier(this.plan.city);
        // 估算各 POI 花费（始终重新估算，确保校准生效）
        for (const day of this.plan.dailyPlans) {
          for (const poi of day.pois) {
            // 跳过起终点标记（出发/返回/入住），这些不是实际消费项
            if (poi.timeSlot === '出发' || poi.timeSlot === '返回' || poi.timeSlot === '入住' || poi.timeSlot === '到达') continue;
            const t: string = poi.type || '';
            if (t.includes('酒店') || t.includes('住宿')) {
              // 本地人不需要酒店花费
              poi.estimatedCost = this.isLocalTrip() ? 0 : Math.round((this.plan.hotel ? 300 : 200) * costMul);
            } else if (t.includes('餐厅') || t.includes('美食') || t.includes('小吃') || t.includes('咖啡')) {
              poi.estimatedCost = Math.round(80 * costMul);
            } else if (poi.timeSlot.includes('餐')) {
              poi.estimatedCost = Math.round(80 * costMul);
            } else if (t.includes('交通') || t.includes('飞机') || t.includes('高铁') || t.includes('火车')) {
              // 本地人不需要跨城交通花费
              poi.estimatedCost = this.isLocalTrip() ? 0 : Math.round((t.includes('飞机') ? 800 : (t.includes('高铁') ? 500 : 200)) * costMul);
            } else if (t.includes('景点') || t.includes('公园') || t.includes('风景') || t.includes('博物馆')) {
              poi.estimatedCost = Math.round(60 * costMul);
            } else if (t.includes('购物') || t.includes('商场')) {
              poi.estimatedCost = Math.round(100 * costMul);
            }
          }
        }
        // 估算跨城交通 + 酒店（本地人跳过）
        if (!this.isLocalTrip()) {
          if (this.plan.transportToCity) {
            if (!this.plan.transportToCity.cost || this.plan.transportToCity.cost <= 0) {
              const tt: string = this.plan.transportToCity.type;
              this.plan.transportToCity.cost = tt === 'flight' ? 800 : (tt === 'high_speed_rail' ? 500 : (tt === 'train' ? 200 : 100));
            }
          }
          if (this.plan.transportBack) {
            if (!this.plan.transportBack.cost || this.plan.transportBack.cost <= 0) {
              const tb: string = this.plan.transportBack.type;
              this.plan.transportBack.cost = tb === 'flight' ? 800 : (tb === 'high_speed_rail' ? 500 : (tb === 'train' ? 200 : 100));
            }
          }
          // 估算酒店总花费：优先 plan.hotel.estimatedCost，兜底从 dailyPlans 找
          let hotelCost: number = 0;
          if (this.plan.hotel) {
            this.plan.hotel.estimatedCost = Math.round(this.plan.days * 300 * costMul);
            hotelCost = this.plan.hotel.estimatedCost;
          } else {
            for (const day of this.plan.dailyPlans) {
              for (const poi of day.pois) {
                if (poi.type.includes('酒店') || poi.type.includes('住宿')) {
                  hotelCost = Math.round(this.plan.days * 300 * costMul);
                  break;
                }
              }
              if (hotelCost > 0) break;
            }
            if (hotelCost > 0) {
              this.plan.hotel = {
                name: '酒店', lat: this.plan.cityLat, lng: this.plan.cityLng,
                type: '酒店住宿', timeSlot: '入住', duration: '全程', note: '',
                estimatedCost: hotelCost,
              };
            }
          }
        } else {
          // 本地人：清除交通和酒店花费
          if (this.plan.transportToCity) this.plan.transportToCity.cost = 0;
          if (this.plan.transportBack) this.plan.transportBack.cost = 0;
          if (this.plan.hotel) this.plan.hotel.estimatedCost = 0;
        }
        const br = getBudgetBreakdown(this.plan);
        const totalBudget: number = this.plan.totalBudget ?? 0;
        const over: boolean = br.total > totalBudget;
        const cityNote: string = costMul > 1.3
          ? `\n\n📌 ${this.plan.city}消费水平较高（×${costMul.toFixed(1)}），以上为当地参考价。`
          : (costMul < 0.95 ? `\n\n📌 ${this.plan.city}消费水平较低，性价比不错！` : '');
        resultText = `📊 预算概览（总预算 ¥${totalBudget}）\n` +
          `🏨 住宿: ¥${br.hotel}\n` +
          `🍽️ 餐饮: ¥${br.food}\n` +
          `🚄 交通: ¥${br.transport}\n` +
          `🎫 景点: ¥${br.attractions}\n` +
          `${br.shopping > 0 ? '🛍️ 购物: ¥' + br.shopping + '\n' : ''}` +
          `💰 预估总计: ¥${br.total}` +
          (over ? `\n\n⚠️ 超出预算 ¥${br.total - totalBudget}！建议减少部分项目或选择经济型选项。` :
           `\n\n✅ 预算内，还剩 ¥${totalBudget - br.total}。`) +
          cityNote;
        break;
      }
      case 'search_transport': {
        const stFrom: string = params['from'] ?? '';
        const stTo: string = params['to'] ?? '';
        const stDate: string = params['date'] ?? '';
        if (!stFrom || !stTo) {
          resultText = '请提供出发城市和到达城市。';
          break;
        }

        // 标准化日期为 YYYY-MM-DD（API 需要此格式）
        const normalizedDate: string = this.normalizeDate(stDate);

        // 多数据源并发查询
        const allPromises: Object[] = await Promise.all([
          TransportSearchService.getInstance().searchAll(stFrom, stTo, normalizedDate),
          AmapSearchService.getInstance().searchIntercityTransport(stFrom, stTo, normalizedDate || undefined),
        ]);
        const webXmlResults: TransportTicketOption[] = allPromises[0] as TransportTicketOption[];
        const amapResults: import('../services/map/AmapSearchService').IntercityTransportOption[] =
          allPromises[1] as import('../services/map/AmapSearchService').IntercityTransportOption[];

        // 合并 WebXml → IntercityTransportOption
        const webXmlOptions: import('../services/map/AmapSearchService').IntercityTransportOption[] =
          webXmlResults.map((t: TransportTicketOption) => ({
            type: t.type,
            trip: t.tripNo || t.type,
            fromStation: t.fromStation || stFrom,
            toStation: t.toStation || stTo,
            departureTime: t.departureTime || '',
            arrivalTime: t.arrivalTime || '',
            duration: t.duration || 0,
            distance: 0,
            price: t.price || 0,
            note: t.note || t.seatTypes || '',
          } as import('../services/map/AmapSearchService').IntercityTransportOption));

        // 合并 + 去重（高德结果排前面，更可靠；WebXml 补充航班）
        const allOptions: import('../services/map/AmapSearchService').IntercityTransportOption[] = [];
        const seenTrips: Set<string> = new Set();
        const addOpt = (opt: import('../services/map/AmapSearchService').IntercityTransportOption): void => {
          const key: string = `${opt.trip}|${opt.fromStation}|${opt.toStation}`;
          if (key.length > 3 && !seenTrips.has(key)) {
            seenTrips.add(key);
            allOptions.push(opt);
          }
        };
        for (const o of amapResults) addOpt(o);
        for (const o of webXmlOptions) addOpt(o);

        if (allOptions.length > 0) {
          transportOptions = allOptions;
          const detailsStr: string = allOptions.slice(0, 8).map((o, i) =>
            `${i + 1}. ${getTransportEmoji(o.type)} ${o.trip || getTransportLabel(o.type)} ${o.fromStation}${o.departureTime ? ' ' + o.departureTime : ''}→${o.toStation}${o.arrivalTime ? ' ' + o.arrivalTime : ''}${o.price > 0 ? ' ¥' + o.price : ''}`
          ).join('\n');
          const hasFlight: boolean = allOptions.some(o => o.type === 'flight');
          const srcLabel: string = hasFlight ? '（含航班）' : '';
          resultText = `${stFrom}→${stTo}${stDate ? '（' + stDate + '）' : ''}查到${allOptions.length}个方案${srcLabel}：\n${detailsStr}`;
          Logger.info(TAG, 'Transport search: %{public}d options (%{public}d Amap + %{public}d WebXml)',
            allOptions.length, amapResults.length, webXmlOptions.length);
        } else {
          // 所有数据源均无结果 → 诚实告知，不编造
          resultText = `暂未查到${stFrom}到${stTo}${stDate ? '（' + stDate + '）' : ''}的实时方案。建议到12306或携程App查询实时票价和时刻。`;
          Logger.info(TAG, 'Transport search: no results from any source for %{public}s→%{public}s', stFrom, stTo);
        }
        markers = undefined;
        break;
      }
      case 'set_transport': {
        const tType: string = params['type'] ?? '';
        const tFrom: string = params['from'] ?? '';
        const tTo: string = params['to'] ?? '';
        const tFromStation: string = params['fromStation'] ?? '';
        const tToStation: string = params['toStation'] ?? '';
        const tDep: string = params['departureTime'] ?? '';
        const tArr: string = params['arrivalTime'] ?? '';
        const tNum: string = params['number'] ?? '';
        const tCost: number = parseInt(params['cost'] ?? '0');
        if (!tType || !tFrom || !tTo) {
          resultText = '请提供交通方式、出发城市和到达城市。';
          break;
        }
        // 尝试对到达站做 geocode，拿到车站真实坐标
        let stationLat: number | undefined = undefined;
        let stationLng: number | undefined = undefined;
        if (tToStation) {
          try {
            const stationLoc: LatLng | null = await AmapSearchService.getInstance().geocodeAddress(tToStation, tTo);
            if (stationLoc) {
              stationLat = stationLoc.latitude;
              stationLng = stationLoc.longitude;
              Logger.info(TAG, 'Station geocoded: %{public}s → (%{public}.4f, %{public}.4f)',
                tToStation, stationLat, stationLng);
            }
          } catch (_e) { /* ignore */ }
        }
        const transport: InterCityTransport = {
          type: tType, from: tFrom, to: tTo,
          fromStation: tFromStation || undefined,
          toStation: tToStation || undefined,
          stationLat: stationLat,
          stationLng: stationLng,
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

    // 兜底：任何工具都不应返回空白
    if (!resultText || resultText.trim().length === 0) {
      resultText = `工具 ${action} 执行完毕（无详细结果）。`;
      Logger.warn(TAG, 'Tool %{public}s returned empty resultText, using fallback', action);
    }
    return { action, params, text: resultText, mapCenter, markers, transportOptions };
  }

  /** ToolCall 转为 params Record */
  toParams(tc: ToolCall): Record<string, string> {
    const p: Record<string, string> = {};
    if (tc.keywords) p['keywords'] = tc.keywords;
    if (tc.city) p['city'] = tc.city;
    if (tc.hotel) p['hotel'] = tc.hotel;
    if (tc.hotelLat) p['hotelLat'] = tc.hotelLat;
    if (tc.hotelLng) p['hotelLng'] = tc.hotelLng;
    if (tc.days) p['days'] = tc.days;
    if (tc.dayIndex) p['dayIndex'] = tc.dayIndex;
    if (tc.poiIndex) p['poiIndex'] = tc.poiIndex;
    if (tc.name) p['name'] = tc.name;
    if (tc.lat) p['lat'] = tc.lat;
    if (tc.lng) p['lng'] = tc.lng;
    if (tc.type) p['type'] = tc.type;
    if (tc.timeSlot) p['timeSlot'] = tc.timeSlot;
    if (tc.note) p['note'] = tc.note;
    if (tc.mode) p['mode'] = tc.mode;
    if (tc.from) p['from'] = tc.from;
    if (tc.to) p['to'] = tc.to;
    if (tc.fromStation) p['fromStation'] = tc.fromStation;
    if (tc.toStation) p['toStation'] = tc.toStation;
    if (tc.departureTime) p['departureTime'] = tc.departureTime;
    if (tc.arrivalTime) p['arrivalTime'] = tc.arrivalTime;
    if (tc.number) p['number'] = tc.number;
    if (tc.amount) p['amount'] = tc.amount;
    if (tc.cost) p['cost'] = tc.cost;
    if (tc.date) p['date'] = tc.date;
    return p;
  }

  /** 检查这批工具是否修改了计划 */
  private wasPlanModified(toolCalls: ToolCall[]): boolean {
    if (this.plan.dailyPlans.length === 0) return false;
    for (const tc of toolCalls) {
      if (tc.action === 'make_plan' || tc.action === 'add_poi_to_day' ||
          tc.action === 'remove_poi_from_day' || tc.action === 'search_and_add' ||
          tc.action === 'estimate_costs' || tc.action === 'set_transport' ||
          tc.action === 'set_budget') return true;
    }
    return false;
  }

  /** 合并多个 ToolResult 为单个 AgentResponse */
  private mergeResults(results: ToolResult[]): AgentResponse {
    // 合并 text
    const text: string = results.map(r => `[${r.action}] ${r.text}`).join('\n');
    // mapCenter: geocode 优先，否则第一个有值的
    let mapCenter: LatLng | undefined = undefined;
    for (const r of results) {
      if (r.mapCenter) {
        if (r.action === 'geocode_city') { mapCenter = r.mapCenter; break; }
        if (!mapCenter) mapCenter = r.mapCenter;
      }
    }
    // markers: 合并所有，按 name 去重
    const seen: Set<string> = new Set();
    const markers: MapMarker[] = [];
    for (const r of results) {
      if (r.markers) {
        for (const m of r.markers) {
          const key: string = `${m.name}|${m.lat}|${m.lng}`;
          if (!seen.has(key)) { seen.add(key); markers.push(m); }
        }
      }
    }
    // transportOptions: 合并
    let transportOptions: import('../services/map/AmapSearchService').IntercityTransportOption[] | undefined = undefined;
    for (const r of results) {
      if (r.transportOptions && r.transportOptions.length > 0) {
        if (!transportOptions) transportOptions = [];
        transportOptions.push(...r.transportOptions);
      }
    }

    return {
      text, toolCalls: [],
      mapCenter: mapCenter || undefined,
      markers: markers.length > 0 ? markers : undefined,
      transportOptions: transportOptions,
    };
  }

  /** 批量执行工具 — geocode 先执行，其余并行，合并结果
   *  @param onPhase geocode 阶段完成后回调，用于 UI 立即更新地图中心 */
  async executeToolsAndContinue(
    toolCalls: ToolCall[],
    onPhase?: (phase: string, partial: AgentResponse) => void
  ): Promise<AgentResponse> {
    if (toolCalls.length === 0) return { text: '', toolCalls: [] };

    // 分离 geocode 和其他工具
    const geoCalls: ToolCall[] = toolCalls.filter(tc => tc.action === 'geocode_city');
    const otherCalls: ToolCall[] = toolCalls.filter(tc => tc.action !== 'geocode_city');

    // 写工具：会修改 this.plan，必须串行执行避免竞态
    const WRITE_ACTIONS: Set<string> = new Set([
      'search_and_add', 'add_poi_to_day', 'remove_poi_from_day',
      'make_plan', 'set_budget', 'set_transport', 'estimate_costs'
    ]);
    const readOnly: ToolCall[] = otherCalls.filter(tc => !WRITE_ACTIONS.has(tc.action));
    const writeTools: ToolCall[] = otherCalls.filter(tc => WRITE_ACTIONS.has(tc.action));

    const results: ToolResult[] = [];

    // 安全执行单个工具 — 异常不传播
    const safeExec = async (tc: ToolCall): Promise<ToolResult> => {
      try {
        return await this.executeOneTool(tc.action, this.toParams(tc));
      } catch (e) {
        Logger.error(TAG, 'Tool %{public}s CRASHED: %{public}s', tc.action, JSON.stringify(e));
        return { action: tc.action, params: this.toParams(tc),
          text: `⚠️ 工具 ${tc.action} 执行异常，已跳过。请用其他方式重试。`,
          mapCenter: undefined, markers: undefined };
      }
    };

    // Phase 1: geocode 先执行（城市坐标是其他搜索的前置依赖）
    for (const gc of geoCalls) {
      results.push(await safeExec(gc));
    }

    // ✅ geocode 完成 → 立即回调，UI 可以移动地图中心
    if (geoCalls.length > 0 && onPhase) {
      onPhase('geocode_done', this.mergeResults(results));
    }

    // Phase 2a: 只读工具并行执行（search_hotels, search_poi, search_transport等）
    if (readOnly.length > 0) {
      const parallelResults: ToolResult[] = await Promise.all(
        readOnly.map(tc => safeExec(tc))
      );
      results.push(...parallelResults);
    }

    // Phase 2b: 写工具串行执行（search_and_add, make_plan等会改 this.plan，不能并发）
    for (const wt of writeTools) {
      results.push(await safeExec(wt));
    }

    // 保存结果供 askAiNextStep 使用
    this.lastToolResults = results;

    // 合并结果
    const resp: AgentResponse = this.mergeResults(results);

    // 自动串联：make_plan 或 set_budget 后自动估算花费（不管有没有行程）
    const hasMakePlan: boolean = toolCalls.some(tc => tc.action === 'make_plan');
    const hasSetBudget: boolean = toolCalls.some(tc => tc.action === 'set_budget');
    if (hasMakePlan || hasSetBudget) {
      resp.toolCalls.push({ action: 'estimate_costs' });
    }

    // 修改计划的操作返回深拷贝 plan
    // set_budget 始终返回计划（即使无 dailyPlans），确保预算值传播到页面
    if (toolCalls.some(tc => tc.action === 'set_budget') || this.wasPlanModified(toolCalls)) {
      resp.plan = JSON.parse(JSON.stringify(this.plan)) as TourPlan;
    }

    return resp;
  }

  /** 工具执行后向 AI 请求下一步（在 UI 更新之后调用，不阻塞地图刷新） */
  async askAiNextStep(results: ToolResult[]): Promise<AgentResponse> {
    const summary: string = results.map(r => `[${r.action}] ${r.text}`).join('\n');
    let planCtx: string = `当前计划：城市=${this.plan.city}(${this.plan.cityLat.toFixed(2)},${this.plan.cityLng.toFixed(2)}) 酒店=${this.plan.hotel?.name || '未选'} 天数=${this.plan.days}`;
    // 本地人模式标记：目的地 = 用户常住城市
    if (this.isLocalTrip()) {
      planCtx += ` [本地游：用户常住${this.userCity}，无需酒店和跨城交通]`;
    }
    if (this.plan.totalBudget) planCtx += ` 总预算=¥${this.plan.totalBudget}`;
    if (this.plan.transportToCity) planCtx += ` 到达交通=${getTransportLabel(this.plan.transportToCity.type)}${this.plan.transportToCity.from}→${this.plan.transportToCity.to}` +
      (this.plan.transportToCity.cost && this.plan.transportToCity.cost > 0 ? ` ¥${this.plan.transportToCity.cost}` : '');
    if (this.plan.transportBack) planCtx += ` 返程交通=${getTransportLabel(this.plan.transportBack.type)}${this.plan.transportBack.from}→${this.plan.transportBack.to}` +
      (this.plan.transportBack.cost && this.plan.transportBack.cost > 0 ? ` ¥${this.plan.transportBack.cost}` : '');
    if (this.plan.dailyPlans.length > 0) {
      planCtx += '\n每日行程：';
      for (const d of this.plan.dailyPlans) {
        planCtx += `\n  ${d.label}: ` + d.pois.map((p, i) => `[${i}]${p.name}(${p.type},${p.timeSlot})`).join(' → ');
      }
    }
    // 带上用户原始输入（确定性检测绕过AI时很重要，保留"三天"等上下文）
    const userCtx: string = this.lastUserInput ? `\n用户原始输入：${this.lastUserInput}\n` : '';
    if (this.lastUserInput) this.lastUserInput = ''; // 用完清掉
    const followMsg: string = `工具执行结果：\n${summary}\n\n${planCtx}${userCtx}\n请基于此继续与用户对话。如果任务还没完成，继续下一步。如果搜索失败，换个关键词重试。`;
    const reply: ClaudeReply = await this.claude.chatConversation(followMsg, this.getSystemPrompt());
    const resultText2: string = reply.text || '收到，请继续。';
    let nextTools: ToolCall[] = this.parseToolCalls(resultText2);
    // 如果没有工具调用且回复很短，重试一次
    if (nextTools.length === 0 && resultText2.length < 20) {
      const retryReply: ClaudeReply = await this.claude.chatConversation(
        '请继续完成任务，下一步做什么？', this.getSystemPrompt());
      const retryText: string = retryReply.text || '';
      nextTools = this.parseToolCalls(retryText);
      return { text: this.stripJson(retryText || resultText2), toolCalls: nextTools };
    }
    return { text: this.stripJson(resultText2), toolCalls: nextTools };
  }

  /** 标准化日期格式为 YYYY-MM-DD */
  private normalizeDate(date: string): string {
    if (!date) return '';
    // 已经是 YYYY-MM-DD 格式
    if (/^\d{4}-\d{2}-\d{2}$/.test(date)) return date;
    // "7月20日" / "07月20日" → 转为 YYYY-MM-DD
    const m = date.match(/(\d{1,2})月(\d{1,2})[日号]?/);
    if (m) {
      const today: Date = new Date();
      const year: number = today.getFullYear();
      const month: string = String(parseInt(m[1])).padStart(2, '0');
      const day: string = String(parseInt(m[2])).padStart(2, '0');
      return `${year}-${month}-${day}`;
    }
    return date; // 无法解析则原样返回
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

  /** 解析 AI 回复中的工具调用 — 支持数组和单对象两种格式 */
  private parseToolCalls(text: string): ToolCall[] {
    const idx: number = text.indexOf('---JSON---');
    let jsonStr: string = '';
    if (idx >= 0) {
      jsonStr = text.substring(idx + 10).trim();
    } else {
      // 兼容旧格式：匹配单个 {...} 或数组 [...]
      const arrMatch = text.match(/\[[\s\S]*"action"[\s\S]*\]/);
      if (arrMatch) {
        jsonStr = arrMatch[0];
      } else {
        const m = text.match(/\{[\s\S]*"action"[\s\S]*\}/);
        if (m) jsonStr = m[0];
      }
    }
    if (!jsonStr) return [];

    try {
      const parsed: Object = JSON.parse(jsonStr) as Object;
      if (Array.isArray(parsed)) {
        return (parsed as Record<string, string>[])
          .map((obj) => this.objToToolCall(obj))
          .filter((tc) => tc !== null) as ToolCall[];
      } else {
        const tc = this.objToToolCall(parsed as Record<string, string>);
        return tc ? [tc] : [];
      }
    } catch (_e) { /* ignore */ }
    return [];
  }

  /** 将 JSON 对象转为 ToolCall */
  private objToToolCall(obj: Record<string, string>): ToolCall | null {
    if (!obj['action']) return null;
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
    if (obj['fromStation']) tc.fromStation = obj['fromStation'];
    if (obj['toStation']) tc.toStation = obj['toStation'];
    if (obj['departureTime']) tc.departureTime = obj['departureTime'];
    if (obj['arrivalTime']) tc.arrivalTime = obj['arrivalTime'];
    if (obj['number']) tc.number = obj['number'];
    // 预算
    if (obj['amount']) tc.amount = obj['amount'];
    if (obj['cost']) tc.cost = obj['cost'];
    if (obj['date']) tc.date = obj['date'];
    return tc;
  }

  private stripJson(text: string): string {
    const idx: number = text.indexOf('---JSON---');
    if (idx >= 0) return text.substring(0, idx).trim();
    // 去掉末尾的 JSON 块（数组或对象）
    return text.replace(/\n*\[?\{[\s\S]*"action"[\s\S]*\}[\s\S]*$/, '').trim();
  }
}
