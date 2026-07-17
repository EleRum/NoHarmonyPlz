/**
 * 导游 AI Agent — 对话式旅游规划师
 * 每步工具执行后立即返回地图标记数据，实现渐进式可视化
 */
import { ClaudeService, ClaudeReply } from './ClaudeService';
import { AmapSearchService } from './map/AmapSearchService';
import { TransportSearchService, TicketOption as TransportTicketOption } from './map/TransportSearchService';
import { StationCodeService } from './map/StationCodeService';
import { PoiResult, LatLng, NavRoute, DirectionMode } from './map/MapTypes';
import { TourPlan, TourDay, TourPoiItem, InterCityTransport, createEmptyPlan, getBudgetBreakdown, getTransportEmoji, getTransportLabel, isMarkerPoi, formatClockTime, DEFAULT_DAY_START_MIN, DEFAULT_DAY_END_MIN, MEAL_WINDOWS, MealWindow } from '../model/TourPlan';
import { Logger } from '../common/Logger';
import { haversineDistance } from '../common/LocationUtils';

const TAG = 'TourGuideAgent';

const SYSTEM_PROMPT: string = `你是小途，资深旅游规划师。今天是${new Date().getFullYear()}年${new Date().getMonth() + 1}月${new Date().getDate()}日。

## 风格
口语化，像朋友聊天。一次只问1个问题。给出具体建议。

## 关键信息清单 — 缺一不可！
这些信息**只能由用户给出，禁止你替用户决定**。用户说了就记住，不要重复问。
1. 目的地 — 用户想去哪个城市
2. 出发地 — 用户从哪个城市出发
3. 出发时间 — 哪天出发
4. 游玩天数 — 玩几天
5. 经费预算 — 预算多少

**任何一个缺失 → 先问用户！补齐之前禁止跳到下一步！**

## 工作流程
**每步都要等用户回应，不要连续跳步！**
1. 用户说想去某城市 → geocode_city 定位 → 问出发地和出发时间
2. 出发地+日期已知 → search_transport 查交通
3. 交通搞定 → 问经费预算（用户说出数字才 set_budget！）
4. 天数+交通+预算齐 → 问用户是否创建行程 → 用户同意 → make_plan
5. 计划创建后 → 等用户指定景点 → search_and_add
6. 用户说调整起止时间 → set_day_bounds

## 工具调用格式（不按此格式系统无法识别！）
**回复末尾必须严格按以下格式：**
---JSON---
{"action":"xxx","param":"value"}

或数组（多个工具并行）：
---JSON---
[{"action":"xxx"},{"action":"yyy"}]

**格式要求：**
- ---JSON--- 前后各空一行
- JSON 必须合法（双引号、无尾逗号）
- JSON 必须在最后，后面不能再有文字
- 错误示例: ---JSON---（缺空行） {"action":"xx",}（尾逗号）
- 正确示例: 你的回复文字...
          ---JSON---
          {"action":"geocode_city","city":"成都"}

- **如果你回复了文字但没带 ---JSON---，对话就卡住了！必须步步带工具！**

## 规则（必须遵守！）
- **最重要的规则：每次回复末尾都必须带 ---JSON--- 工具调用！**
  * 只有纯粹闲聊（打招呼、道谢）才不加
- **严禁擅自决定！你是建议者，用户是决策者！**
  * set_budget 只能由用户说出金额后调用，禁止自己编预算！
  * search_hotels 只能由用户说"帮我找酒店"后调用，禁止主动搜！
  * make_plan 只能在 5 项信息全齐 + 用户同意后调用！
  * 用户没提酒店 → 交通确认后主动问是否需要找酒店
- **用户明确要求的才执行**
  * 用户说"第X天去A、B、C" → 一条 search_and_add，keywords="A,B,C"（逗号分隔，顺序=用户说的顺序，禁止拆成多条！）
  * 用户说"推荐几个景点" → 文字列出，不自动加

## 添加景点序列格式（极其重要！顺序全靠这个！）
- 多个景点必须合并成一条 search_and_add，用逗号或顿号分隔 keywords
- 示例: {"action":"search_and_add","keywords":"天安门,故宫,颐和园","dayIndex":"0","timeSlot":"上午"}
- 禁止拆成多条并行调用的 search_and_add！拆了顺序全乱！
- 逗号顺序 = 用户提到的顺序 = 最终游览顺序 = 绝不能乱！

## 修改/替换行程（极其重要！不删旧的会重复！）
- 用户说"不去X了，改成Y"、"把X换成Y"、"第X天的A换成B" → 必须两步：先删旧的，再加新的！
- 正确做法：一条数组包含 remove + search_and_add
  [{"action":"remove_poi_from_day","dayIndex":"0","poiIndex":"2"},{"action":"search_and_add","keywords":"天坛","dayIndex":"0","timeSlot":"上午"}]
- 错误做法：只调 search_and_add 不加 remove → 旧行程还在，和新的重复！
- "不去X了" → 只调 remove_poi_from_day，不要调 search_and_add
- 如果不知道 poiIndex，先看当前计划里的 poi 列表推算（第0个=第一个景点，跳过标记POI）
- geocode_city 只需一次，城市换了才重新geocode
- 工具调用失败 → 换个参数重试，别停下来聊天
- 每次回复末尾给 2-3 个快捷选项

## 预算管理
- 问用户预算 → 等用户说出数字 → 才调 set_budget
- 格式: {"action":"set_budget","amount":"5000"}，amount 是纯数字
- 用户没说预算 → 就当没预算，不要猜！

## 酒店
- 交通确认后 → 主动问用户"需要帮你找酒店吗？偏好哪个区域？"
- 用户说需要 → 问区域偏好 → search_hotels → 等用户选定 → 通过 search_and_add 添加
- 用户说不需要/本地有住处 → 跳过酒店，不追问
- 目的地=用户常住城市（本地人模式）→ 不问酒店
- 选定后全程住同一家

## 跨城交通（严格分两步！禁止同时搜去程和返程！）
**第一步 — 只查去程：**
- 出发地+目的地已知 → search_transport 查去程
- 展示去程方案 → 等用户选定 → set_transport 记录去程
**第二步 — 才查返程（去程选定之后！）：**
- 去程选好后 → 问"哪天返程？"→ 等用户答 → search_transport 查返程
- **返程一定要等用户选定去程之后再调！否则选项列表会被覆盖！**
- 返程: {"action":"search_transport","from":"成都","to":"北京","date":"7月25日"}
- 展示返程方案 → 等用户选定 → set_transport 记录返程
**规则：**
- 没日期 → 系统默认5天后
- 禁止编造车次/时间/价格！
- **禁止去程和返程放在同一个数组里并行调用！**
- **交通搜索结果里有🔍12306诊断时，你的回复第一行必须原样照抄诊断，一字不改！**

## 本地人模式
- 目的地 = 用户常住城市 → 无跨城交通、无酒店
- 专注推荐景点美食

## 上下文备忘录（每次对话自动附带，不要忽略！）
- system prompt 末尾会自动附带"当前行程状态"备忘录
- 备忘录里的信息都是已确认的，以此为唯一依据，不要凭记忆猜测
- 酒店名、车次号、时间、预算等以备忘录为准
- 未确认的会标"未确认"，需要时主动询问用户`;

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
  budget?: string;  // 兼容: AI 有时用 budget 代替 amount
  cost?: string;
  date?: string;
  // 日边界
  dayStartHour?: string;
  dayEndHour?: string;
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

/** timeFeasibilityCheck 返回类型 */
interface FeasibilityResult {
  feasible: boolean;
  startMin: number;
  endMin: number;
  warnings: string[];
}

/** findChronologicalPosition 用的索引条目 */
interface ChronoIndexEntry {
  idx: number;
  startMin: number;
  rank: number;
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

  /** 从 TourPlan 生成结构化状态摘要，注入每次 AI 调用的 system prompt。
   *  对话长了也不丢失已确认信息（酒店/交通/预算/日程）。 */
  private buildContextMemo(): string {
    const p: TourPlan = this.plan;
    if (!p.city || p.cityLat === 0) return ''; // 还没开始规划

    const lines: string[] = [];
    lines.push('\n## 当前行程状态（已确认，每次对话都带）');

    // 基础信息
    const basics: string[] = [];
    basics.push('目的地: ' + p.city);
    if (this.userCity) basics.push('出发: ' + this.userCity);
    if (p.days > 0) basics.push('天数: ' + p.days + '天');
    if (p.totalBudget) basics.push('预算: ' + p.totalBudget + '元');
    lines.push(basics.join(' | '));

    // 酒店
    if (p.hotel) {
      lines.push('酒店: ' + p.hotel.name + (p.hotel.note ? '(' + p.hotel.note + ')' : '') + ' [已确认]');
    } else {
      lines.push('酒店: 未确认');
    }

    // 去程交通
    const t1: InterCityTransport | undefined = p.transportToCity;
    if (t1 && t1.from) {
      const t1Label: string = getTransportLabel(t1.type);
      lines.push('去程: ' + t1Label + (t1.number || '') + ' ' + t1.from + '→' + t1.to +
        (t1.departureTime ? ' ' + t1.departureTime : '') +
        (t1.cost ? ' ¥' + t1.cost : '') + ' [已确认]');
    } else {
      lines.push('去程: 未确认');
    }

    // 返程交通
    const t2: InterCityTransport | undefined = p.transportBack;
    if (t2 && t2.from) {
      const t2Label: string = getTransportLabel(t2.type);
      lines.push('返程: ' + t2Label + (t2.number || '') + ' ' + t2.from + '→' + t2.to +
        (t2.departureTime ? ' ' + t2.departureTime : '') +
        (t2.cost ? ' ¥' + t2.cost : '') + ' [已确认]');
    } else {
      lines.push('返程: 未确认');
    }

    // 每天行程摘要
    const dayCount: number = Math.max(p.days, p.dailyPlans.length);
    for (let d: number = 0; d < dayCount; d++) {
      const day: TourDay | undefined = d < p.dailyPlans.length ? p.dailyPlans[d] : undefined;
      if (!day) {
        lines.push('第' + (d + 1) + '天: 未安排');
        continue;
      }
      const names: string[] = [];
      for (let i: number = 0; i < day.pois.length; i++) {
        const poi: TourPoiItem = day.pois[i];
        if (isMarkerPoi(poi)) continue;
        // 截断长名称
        const shortName: string = poi.name.length > 8 ? poi.name.substring(0, 8) + '..' : poi.name;
        names.push(shortName);
      }
      if (names.length === 0) {
        lines.push('第' + (d + 1) + '天: 未安排');
      } else {
        lines.push('第' + (d + 1) + '天(' + names.length + '个): ' + names.join(' → '));
      }
    }

    return lines.join('\n');
  }

  /** 获取完整的系统提示（含用户偏好 + 行程上下文备忘录） */
  private getSystemPrompt(): string {
    const memo: string = this.buildContextMemo();
    return SYSTEM_PROMPT + this.userPrefContext + memo;
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
      // 保留完整关键词列表（含逗号/顿号），不截断 — 顺序 = 用户说的顺序
      const kw: string = addMatch[2].trim().replace(/[。！!？?]+$/g, '');
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

    // ── 2. 收集跨城交通意图 ──
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
        // keywords 支持逗号分隔的多关键词 → 序列插入，顺序=用户说的顺序
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
        const saTimeSlotHint: string = params['timeSlot'] ?? '';

        if (saDayIdx < 0 || saDayIdx >= this.plan.dailyPlans.length) {
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

        // 按逗号/顿号拆分关键词 → 序列顺序
        const kwList: string[] = saKw.split(/[,，、]/).map((s: string) => s.trim()).filter((s: string) => s.length > 0);
        const saDay: TourDay = this.plan.dailyPlans[saDayIdx];

        // === Phase 1: 逐个搜索，保持顺序 ===
        const addedPois: TourPoiItem[] = [];
        const allMarkers: MapMarker[] = [];
        const addedNames: string[] = [];
        const failedNames: string[] = [];

        for (let ki: number = 0; ki < kwList.length; ki++) {
          const kw: string = kwList[ki];
          let pois: PoiResult[] = await AmapSearchService.getInstance().searchPoiByText(kw, this.plan.city);
          if (pois.length === 0 && kw.length > 2) {
            const simplified: string[] = this.simplifyKeywords(kw);
            for (const sk of simplified) {
              if (sk === kw) continue;
              pois = await AmapSearchService.getInstance().searchPoiByText(sk, this.plan.city);
              if (pois.length > 0) break;
            }
          }
          if (pois.length === 0) {
            failedNames.push(kw);
            continue;
          }

          const first: PoiResult = pois[0];
          let autoCost: number | undefined = undefined;
          const poiType: string = first.type || '';
          if (first.cost && first.cost.length > 0) {
            autoCost = parseInt(first.cost) || undefined;
          }
          if (!autoCost) {
            const cm: number = TourGuideAgent.getCityCostMultiplier(this.plan.city);
            autoCost = this.estimatePoiCost(poiType, cm);
          }

          const newPoi: TourPoiItem = {
            name: first.name, lat: first.latitude, lng: first.longitude,
            type: first.type || '景点', timeSlot: '',
            duration: '1-2h', note: first.address || '',
            mode: params['mode'] || undefined,
            estimatedCost: autoCost,
            durationMinutes: this.parseDurationMinutes('1-2h'),
          };

          addedPois.push(newPoi);
          addedNames.push(first.name);
          allMarkers.push({
            name: first.name, lat: first.latitude, lng: first.longitude,
            type: kw, poiId: first.id, address: first.address
          });
        }

        if (addedPois.length === 0) {
          resultText = `在${this.plan.city}未找到"${saKw}"，试试换个说法？`;
          break;
        }

        markers = allMarkers.slice(0, 5);

        // === Phase 2: 酒店特殊处理（仅当第一个结果是酒店） ===
        const firstPoi: TourPoiItem = addedPois[0];
        const isHotel: boolean = (firstPoi.type || '').includes('酒店') ||
          (firstPoi.type || '').includes('宾馆') || (firstPoi.type || '').includes('民宿');

        if (isHotel) {
          for (let i: number = 0; i < saDay.pois.length; i++) {
            if (saDay.pois[i].timeSlot === '出发') {
              saDay.pois.splice(i + 1, 0, firstPoi);
              break;
            }
          }
          this.plan.hotel = { name: firstPoi.name, lat: firstPoi.lat, lng: firstPoi.lng,
            type: '酒店住宿', timeSlot: '入住', duration: '全程', note: firstPoi.note || '', durationMinutes: 0 };
          for (const d of this.plan.dailyPlans) {
            let found: boolean = false;
            for (let i: number = 0; i < d.pois.length; i++) {
              if (d.pois[i].timeSlot === '出发') {
                d.pois[i] = { name: firstPoi.name, lat: firstPoi.lat, lng: firstPoi.lng,
                  type: '酒店住宿', timeSlot: '出发', duration: '', note: firstPoi.note || '' };
                found = true;
                break;
              }
            }
            if (!found) {
              d.pois.unshift({
                name: firstPoi.name, lat: firstPoi.lat, lng: firstPoi.lng,
                type: '酒店住宿', timeSlot: '出发', duration: '', note: firstPoi.note || ''
              });
            }
          }
          resultText = `已设全程酒店为"${firstPoi.name}"（所有天已更新）。`;
        } else {
          // === Phase 3: 序列插入（非酒店） ===
          let preferredHour: number = 12;
          if (saTimeSlotHint) {
            const timeMatch: RegExpMatchArray | null = saTimeSlotHint.match(/(\d{1,2}):?(\d{2})?/);
            if (timeMatch) preferredHour = parseInt(timeMatch[1]);
            else if (saTimeSlotHint.includes('早') || saTimeSlotHint.includes('上午')) preferredHour = 9;
            else if (saTimeSlotHint.includes('中') || saTimeSlotHint.includes('午')) preferredHour = 12;
            else if (saTimeSlotHint.includes('下')) preferredHour = 14;
            else if (saTimeSlotHint.includes('晚')) preferredHour = 19;
          }

          const newRank: number = this.getPeriodRankFromHint(saTimeSlotHint);
          const insertIdx: number = this.findChronologicalPosition(saDay, newRank, preferredHour);

          // 整个序列作为一个连续块插入，顺序 = keywords 顺序 = 用户说的顺序
          for (let i: number = addedPois.length - 1; i >= 0; i--) {
            saDay.pois.splice(insertIdx, 0, addedPois[i]);
          }

          // 一次性重算路线 + 时间线
          await this.recalcDayRoute(saDay);

          // 构建结果文本
          const firstStart: number = addedPois[0].plannedStartMin ?? (preferredHour * 60);
          const lastPoi: TourPoiItem = addedPois[addedPois.length - 1];
          const lastEnd: number = lastPoi.plannedEndMin ?? (firstStart + this.getPoiDurationMinutes(lastPoi));
          const totalMin: number = addedPois.reduce((s: number, p: TourPoiItem) => s + this.getPoiDurationMinutes(p), 0);

          const namesStr: string = addedNames.join(' → ');
          resultText = `已将"${namesStr}"添加到${saDay.label}（共${addedPois.length}个，约${totalMin}分钟）`;

          if (failedNames.length > 0) {
            resultText += `\n⚠️未找到: ${failedNames.join('、')}`;
          }

          if (lastEnd > (saDay.dayEndMin ?? DEFAULT_DAY_END_MIN)) {
            resultText += ` ⚠️结束时间 ${formatClockTime(lastEnd)} 超过当天 ${formatClockTime(saDay.dayEndMin ?? DEFAULT_DAY_END_MIN)}`;
          }

          const mealSugs: string[] = this.getMissingMealSuggestions(saDay);
          if (mealSugs.length > 0) {
            resultText += `\n💡${mealSugs.join('；')}`;
          }
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
            // Day 0 外地到达 → 先放行李（其他天不重复）
            if (nd === 0 && !this.isLocalTrip()) {
              basePois.push({
                name: `去${this.plan.hotel.name}放行李`,
                lat: this.plan.hotel.lat, lng: this.plan.hotel.lng,
                type: '酒店入住', timeSlot: '入住', duration: '0.5h', note: ''
              });
            }
            // 每天起点：从酒店出发（终点=当天最后一个景点，不加空"返回"锚点）
            basePois.push({
              name: `${this.plan.hotel.name}出发`,
              lat: this.plan.hotel.lat, lng: this.plan.hotel.lng,
              type: '酒店住宿', timeSlot: '出发', duration: '', note: ''
            });
          }
          this.plan.dailyPlans.push({
            dayIndex: nd, label: `第${nd + 1}天`, pois: basePois, route: null,
            // 第一天有到达交通时，自动用到达时间作为起始时间（不浪费上午）
            dayStartMin: nd === 0 ? this.parseArrivalStartMin() : undefined
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
      case 'set_day_bounds': {
        const sdbDayIdx: number = parseInt(params['dayIndex'] ?? '0');
        if (sdbDayIdx < 0 || sdbDayIdx >= this.plan.dailyPlans.length) {
          resultText = `第${sdbDayIdx + 1}天不存在。`;
          break;
        }
        const startHour: number = parseInt(params['dayStartHour'] ?? '0');
        const endHour: number = parseInt(params['dayEndHour'] ?? '0');
        const sdbDay: TourDay = this.plan.dailyPlans[sdbDayIdx];
        if (startHour > 0 && startHour <= 24) sdbDay.dayStartMin = startHour * 60;
        if (endHour > 0 && endHour <= 24) sdbDay.dayEndMin = endHour * 60;
        this.calculateTimeline(sdbDay);
        await this.recalcDayRoute(sdbDay);
        const dsLabel: string = sdbDay.dayStartMin ? formatClockTime(sdbDay.dayStartMin) : '默认';
        const deLabel: string = sdbDay.dayEndMin ? formatClockTime(sdbDay.dayEndMin) : '默认';
        resultText = `${sdbDay.label}时间已设为 ${dsLabel}-${deLabel}。`;
        break;
      }
      case 'get_weather': {
        resultText = `${params['city'] || this.plan.city}近日天气：晴转多云 20-28°C（参考）。`;
        break;
      }
      case 'set_budget': {
        const budgetStr: string = params['amount'] ?? params['budget'] ?? '';
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
            if (isMarkerPoi(poi)) continue;
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

        // 标准化日期
        const normalizedDate: string = this.normalizeDate(stDate);

        // 先发起高德查询（快速返回，不受12306影响）
        const amapPromise = AmapSearchService.getInstance()
          .searchIntercityTransport(stFrom, stTo, normalizedDate || undefined);

        // 12306 查询加 60 秒超时保护（TLS握手可能需要较长时间）
        const trainTimeout = new Promise<TransportTicketOption[]>((_, reject) =>
          setTimeout(() => reject(new Error('timeout')), 60000));
        let webXmlResults: TransportTicketOption[] = [];
        let trainDiag: string = '';
        try {
          webXmlResults = await Promise.race([
            TransportSearchService.getInstance().searchAll(stFrom, stTo, normalizedDate),
            trainTimeout,
          ]);
        } catch (e) {
          const errMsg: string = JSON.stringify(e);
          if (errMsg.includes('timeout')) {
            trainDiag = '[超时] Promise.race 45s超时，12306未响应';
          } else {
            trainDiag = '[异常] ' + errMsg.substring(0, 80);
          }
          Logger.warn(TAG, '12306 failed: %{public}s', trainDiag);
        }

        // 等高德结果
        const amapResults = await amapPromise;

        const svcDiag: string = TransportSearchService.getInstance().lastDiag;
        if (svcDiag && !trainDiag) {
          trainDiag = svcDiag;
        } else if (!trainDiag) {
          const fromCodes: string[] = StationCodeService.getInstance().getStationCodes(stFrom);
          const toCodes: string[] = StationCodeService.getInstance().getStationCodes(stTo);
          const diagParts: string[] = [];
          if (fromCodes.length === 0) diagParts.push('[车站] 出发城市未匹配');
          if (toCodes.length === 0) diagParts.push('[车站] 到达城市未匹配');
          if (fromCodes.length > 0 && toCodes.length > 0) diagParts.push('[queryG] 返回空(无车次/被拦截)');
          if (!normalizedDate) diagParts.push('[日期] 无法解析');
          trainDiag = diagParts.length > 0 ? diagParts.join(' | ') : '';
        }

        // 12306 → 统一格式
        const webXmlOptions = webXmlResults.map((t: TransportTicketOption) => ({
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

        // 合并 + 去重（12306 结果优先，有票价）
        const allOptions: import('../services/map/AmapSearchService').IntercityTransportOption[] = [];
        const seenTrips: Set<string> = new Set();
        const addOpt = (opt: import('../services/map/AmapSearchService').IntercityTransportOption): void => {
          const key: string = `${opt.trip}|${opt.fromStation}|${opt.toStation}`;
          if (key.length > 3 && !seenTrips.has(key)) {
            seenTrips.add(key);
            allOptions.push(opt);
          }
        };
        for (const o of webXmlOptions) addOpt(o);
        for (const o of amapResults) addOpt(o);

        if (allOptions.length > 0) {
          transportOptions = allOptions;
          const has12306: boolean = webXmlOptions.length > 0;

          const detailsStr: string = allOptions.slice(0, 8).map((o, i) => {
            let priceStr: string = '';
            if (o.price > 0) {
              priceStr = ' ¥' + o.price;
            } else if (has12306 && o.type !== 'flight' && o.type !== 'bus') {
              priceStr = ' [价格待查]';
            }
            return `${i + 1}. ${getTransportEmoji(o.type)} ${o.trip || getTransportLabel(o.type)} ${o.fromStation}${o.departureTime ? ' ' + o.departureTime : ''}→${o.toStation}${o.arrivalTime ? ' ' + o.arrivalTime : ''}${priceStr}`;
          }).join('\n');

          const diagPrefix: string = trainDiag ? '🔍' + trainDiag + '\n\n' : '';
          const srcNote: string = has12306 ? '（12306实时数据）' : '（高德方案）';
          resultText = diagPrefix + `${stFrom}→${stTo}${stDate ? '（' + stDate + '）' : ''}查到${allOptions.length}个方案${srcNote}：\n${detailsStr}`;
          Logger.info(TAG, 'Transport: %{public}d options (%{public}d 12306 + %{public}d Amap) diag=%{public}s',
            allOptions.length, webXmlOptions.length, amapResults.length, trainDiag || 'none');
        } else {
          const diagLine: string = trainDiag ? '🔍' + trainDiag + '\n' : '';
          resultText = diagLine + `暂未查到${stFrom}到${stTo}${stDate ? '（' + stDate + '）' : ''}的实时方案。`;
          Logger.info(TAG, 'Transport: no results for %{public}s→%{public}s', stFrom, stTo);
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
          // 下午到达 → 更新第一天的 dayStartMin，避免从 8:00 开始空等
          if (this.plan.dailyPlans.length > 0) {
            const arrivalMin: number | undefined = this.parseArrivalStartMin();
            if (arrivalMin !== undefined) {
              this.plan.dailyPlans[0].dayStartMin = arrivalMin;
              this.calculateTimeline(this.plan.dailyPlans[0]);
              Logger.info(TAG, 'Day 0 start updated to arrival time: ' + formatClockTime(arrivalMin));
            }
          }
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
          type: poiType, timeSlot: '', duration: '1-2h', note: poiNote,
          durationMinutes: this.parseDurationMinutes('1-2h'),
        };

        const day: TourDay = this.plan.dailyPlans[dayIdx];

        if (insertPos >= 0 && insertPos < day.pois.length) {
          // 指定了 poiIndex → 直接插入（信任调用方）
          day.pois.splice(insertPos, 0, newPoi);
        } else {
          // 按时段顺序定位（和 search_and_add 一致）
          let preferredHour: number = 12;
          if (poiTimeSlot) {
            const tm: RegExpMatchArray | null = poiTimeSlot.match(/(\d{1,2}):?(\d{2})?/);
            if (tm) preferredHour = parseInt(tm[1]);
            else if (poiTimeSlot.includes('早') || poiTimeSlot.includes('上午')) preferredHour = 9;
            else if (poiTimeSlot.includes('中') || poiTimeSlot.includes('午')) preferredHour = 12;
            else if (poiTimeSlot.includes('下')) preferredHour = 14;
            else if (poiTimeSlot.includes('晚')) preferredHour = 19;
          }
          const newRank: number = this.getPeriodRankFromHint(poiTimeSlot);
          const chronoIdx: number = this.findChronologicalPosition(day, newRank, preferredHour);
          day.pois.splice(chronoIdx, 0, newPoi);
        }

        await this.recalcDayRoute(day);

        const needMin: number = this.getPoiDurationMinutes(newPoi);
        const timeDisplay: string = (newPoi.plannedStartMin !== undefined && newPoi.plannedEndMin !== undefined)
          ? ' ' + formatClockTime(newPoi.plannedStartMin) + '-' + formatClockTime(newPoi.plannedEndMin)
          : (poiTimeSlot ? ' ' + poiTimeSlot : '');
        resultText = '已将"' + poiName + '"添加到' + day.label + timeDisplay + '（游玩' + needMin + '分钟）。';
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
    // 兼容: AI 可能用 budget 代替 amount
    if (tc.budget) p['amount'] = tc.budget;
    if (tc.date) p['date'] = tc.date;
    if (tc.dayStartHour) p['dayStartHour'] = tc.dayStartHour;
    if (tc.dayEndHour) p['dayEndHour'] = tc.dayEndHour;
    return p;
  }

  /** 检查这批工具是否修改了计划 */
  private wasPlanModified(toolCalls: ToolCall[]): boolean {
    if (this.plan.dailyPlans.length === 0) return false;
    for (const tc of toolCalls) {
      if (tc.action === 'make_plan' || tc.action === 'add_poi_to_day' ||
          tc.action === 'remove_poi_from_day' || tc.action === 'search_and_add' ||
          tc.action === 'estimate_costs' || tc.action === 'set_transport' ||
          tc.action === 'set_budget' || tc.action === 'set_day_bounds') return true;
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

    // 后台静默重算（所有变更时更新，让 agent 上下文和 UI 看到最新预算）
    if (this.plan.totalBudget && this.wasPlanModified(toolCalls)) {
      this.silentRecalcCosts();
    }
    // 写入操作 → 展示预算概览确认（除去 estimate_costs 本身避免死循环）
    const planChanged: boolean = this.wasPlanModified(toolCalls) &&
      !toolCalls.some(tc => tc.action === 'estimate_costs');
    if (this.plan.totalBudget && planChanged) {
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
    if (this.plan.totalBudget) {
      const br = getBudgetBreakdown(this.plan);
      planCtx += ` 总预算=¥${this.plan.totalBudget} 已预估花费=¥${br.total} 剩余=¥${this.plan.totalBudget - br.total}`;
      if (br.total > this.plan.totalBudget) planCtx += ` ⚠️超预算！`;
    }
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
    // 检查 search_transport 结果中是否有 12306 诊断，有则强行注入（绕过 AI 过滤）
    const transportResult: ToolResult | undefined = results.find(r => r.action === 'search_transport');
    let diagPrefix: string = '';
    if (transportResult) {
      const diagMatch: RegExpMatchArray | null = transportResult.text.match(/🔍(.+?)(?:\n\n|$)/);
      if (diagMatch) {
        diagPrefix = '🔍' + diagMatch[1].trim() + '\n\n';
      }
    }
    return { text: diagPrefix + this.stripJson(resultText2), toolCalls: nextTools };
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

  /** 统一的 POI 费用估算 — 唯一真相来源，search_and_add 和后台重算共用 */
  private estimatePoiCost(poiType: string, cityMultiplier: number): number | undefined {
    if (!poiType) return undefined;
    const t: string = poiType;
    if (t.includes('酒店') || t.includes('宾馆') || t.includes('民宿') || t.includes('住宿'))
      return Math.round(300 * cityMultiplier);
    if (t.includes('餐厅') || t.includes('美食') || t.includes('小吃') || t.includes('咖啡') || t.includes('茶'))
      return Math.round(80 * cityMultiplier);
    if (t.includes('景点') || t.includes('公园') || t.includes('风景') || t.includes('博物馆'))
      return Math.round(60 * cityMultiplier);
    if (t.includes('购物') || t.includes('商场'))
      return Math.round(100 * cityMultiplier);
    if (t.includes('飞机'))
      return Math.round(800 * cityMultiplier);
    if (t.includes('高铁') || t.includes('火车') || t.includes('动车'))
      return Math.round(500 * cityMultiplier);
    if (t.includes('大巴') || t.includes('客车'))
      return Math.round(200 * cityMultiplier);
    return undefined;
  }

  /** 后台静默重算预算 */
  private silentRecalcCosts(): void {
    if (!this.plan.totalBudget) return;
    const cm: number = TourGuideAgent.getCityCostMultiplier(this.plan.city);
    for (const day of this.plan.dailyPlans) {
      for (const poi of day.pois) {
        if (isMarkerPoi(poi)) continue;
        const t: string = poi.type || '';
        if (t.includes('酒店') || t.includes('住宿')) {
          poi.estimatedCost = this.isLocalTrip() ? 0 : Math.round(300 * cm);
        } else if (t.includes('交通') || t.includes('飞机') || t.includes('高铁') || t.includes('火车')) {
          poi.estimatedCost = this.isLocalTrip() ? 0 : (this.estimatePoiCost(t, cm) ?? 0);
        } else if (poi.timeSlot.includes('餐')) {
          poi.estimatedCost = Math.round(80 * cm);
        } else {
          const cost: number | undefined = this.estimatePoiCost(t, cm);
          if (cost !== undefined) poi.estimatedCost = cost;
        }
      }
    }
    if (!this.isLocalTrip()) {
      if (this.plan.transportToCity && (!this.plan.transportToCity.cost || this.plan.transportToCity.cost <= 0)) {
        const tt: string = this.plan.transportToCity.type;
        this.plan.transportToCity.cost = tt === 'flight' ? 800 : (tt === 'high_speed_rail' ? 500 : (tt === 'train' ? 200 : 100));
      }
      if (this.plan.transportBack && (!this.plan.transportBack.cost || this.plan.transportBack.cost <= 0)) {
        const tb: string = this.plan.transportBack.type;
        this.plan.transportBack.cost = tb === 'flight' ? 800 : (tb === 'high_speed_rail' ? 500 : (tb === 'train' ? 200 : 100));
      }
      if (this.plan.hotel && (!this.plan.hotel.estimatedCost || this.plan.hotel.estimatedCost <= 0)) {
        this.plan.hotel.estimatedCost = Math.round(this.plan.days * 300 * cm);
      }
    }
  }

  // ========== 关键词精简 ==========

  /** 逐级精简搜索关键词：去修饰词 → 前缀 → 核心片段 */
  private simplifyKeywords(kw: string): string[] {
    const result: string[] = [];
    // 去修饰词：的/附近/好吃/好玩/怎么/哪里/推荐/必去/网红
    let cleaned: string = kw.replace(/[的之]|附近|好吃|好玩|怎么|哪里|推荐|必去|网红|最有名|出名/g, '');
    if (cleaned !== kw && cleaned.length >= 2) result.push(cleaned);
    // 取前2字
    if (kw.length > 2) result.push(kw.substring(0, 2));
    // 取后2字（有时核心词在后面）
    if (kw.length > 3) {
      const last2: string = kw.substring(kw.length - 2);
      if (!result.includes(last2)) result.push(last2);
    }
    // 取前3字
    if (kw.length > 3) {
      const first3: string = kw.substring(0, 3);
      if (!result.includes(first3)) result.push(first3);
    }
    // 如果清理后还有至少2个字的不同版本
    if (cleaned.length > 3 && cleaned !== kw) {
      result.push(cleaned.substring(0, 2));
      result.push(cleaned.substring(0, 3));
    }
    // 去重
    // 手动去重
    const deduped: string[] = [];
    for (const k of result) { if (k.length >= 2 && deduped.indexOf(k) < 0) deduped.push(k); }
    return deduped;
  }

  // ========== 时间计算工具函数 ==========

  /** plannedStartMin → 时间段权重（0=上午, 1=中午, 2=下午, 3=晚上, 4=未知） */
  private getPeriodRank(startMin: number | undefined): number {
    if (startMin === undefined) return 4;
    if (startMin < 690) return 0;         // 11:30 前 → 上午
    if (startMin < 780) return 1;         // 11:30-13:00 → 中午
    if (startMin < 1080) return 2;        // 13:00-18:00 → 下午
    return 3;                              // 18:00 后 → 晚上
  }

  /** timeSlot hint → 时间段权重 */
  private getPeriodRankFromHint(hint: string): number {
    if (!hint) return 4;
    if (hint.includes('早') || hint.includes('上午')) return 0;
    if (hint.includes('中') || hint.includes('午')) return 1;
    if (hint.includes('下')) return 2;
    if (hint.includes('晚')) return 3;
    return 4;
  }

  /** 按时段顺序找到新 POI 应该插入的位置（索引）。
   *  扫描 day.pois 中非标记 POI，找到第一个 periodRank > newRank 的位置；
   *  同 period 内按 plannedStartMin 排序插入。无 hint 则返回末尾。 */
  private findChronologicalPosition(day: TourDay, newRank: number, preferredHour: number): number {
    // 收集所有非标记 POI 的索引/startMin/periodRank
    const indexed: ChronoIndexEntry[] = [];
    for (let i: number = 0; i < day.pois.length; i++) {
      const p: TourPoiItem = day.pois[i];
      if (isMarkerPoi(p)) {
        continue;
      }
      const sm: number = p.plannedStartMin ?? (this.parseTimeSlotToMin(p.timeSlot) ?? 720);
      const entry: ChronoIndexEntry = { idx: i, startMin: sm, rank: this.getPeriodRank(sm) };
      indexed.push(entry);
    }

    // newRank=4（无提示）→ 插入末尾（返回标记之前）
    let markerIdx: number = day.pois.length;
    for (let m: number = 0; m < day.pois.length; m++) {
      const ts: string = day.pois[m].timeSlot;
      if (ts === '返回' || ts === '出发') {
        markerIdx = m;
        break;
      }
    }
    const fallback: number = markerIdx < day.pois.length ? markerIdx : day.pois.length;
    if (newRank >= 4) {
      return fallback;
    }

    // 找第一个 periodRank > newRank 的 POI，插在它前面
    const targetMin: number = preferredHour * 60;
    let insertIdx: number = fallback;
    for (let j: number = 0; j < indexed.length; j++) {
      const item: ChronoIndexEntry = indexed[j];
      if (item.rank > newRank) {
        insertIdx = item.idx;
        break;
      }
    }

    // 同 period 内：按 startMin 排序，插在比目标时间晚的第一个 POI 前面
    if (insertIdx === fallback) {
      for (let k: number = 0; k < indexed.length; k++) {
        const item: ChronoIndexEntry = indexed[k];
        if (item.rank === newRank && item.startMin >= targetMin) {
          insertIdx = item.idx;
          break;
        }
      }
    }

    return insertIdx;
  }

  /** 从到达交通的 arrivalTime 解析起始分钟数（如 "7月20日 14:30" → 870）。
   *  提前到达则保留缓冲（如 13:00 到 → 13:30 开始），上午到达用默认 8:00。 */
  private parseArrivalStartMin(): number | undefined {
    const t: InterCityTransport | undefined = this.plan.transportToCity;
    if (!t || !t.arrivalTime) return undefined;
    const m: RegExpMatchArray | null = t.arrivalTime.match(/(\d{1,2}):(\d{2})/);
    if (!m) return undefined;
    const hour: number = parseInt(m[1]);
    const min: number = parseInt(m[2]);
    const arrMin: number = hour * 60 + min;
    // 上午/中午到达 → 默认 8:00 开始，时间充裕
    if (arrMin < 780) return undefined; // 13:00 前到达，保持默认
    // 下午到达 → 到达时间 + 30分钟缓冲（出站/放行李）
    return arrMin + 30;
  }

  /** timeSlot 字符串 → 估算分钟数，如 "9:00-10:30" → 540 */
  private parseTimeSlotToMin(ts: string): number | undefined {
    if (!ts) return undefined;
    const m: RegExpMatchArray | null = ts.match(/(\d{1,2}):(\d{2})/);
    if (!m) return undefined;
    return parseInt(m[1]) * 60 + parseInt(m[2]);
  }

  /** 解析停留时间字符串为分钟数 */
  private parseDurationMinutes(dur: string): number {
    if (!dur || dur.length === 0) return 90;
    const hMatch: RegExpMatchArray | null = dur.match(/(\d+(?:\.\d+)?)\s*h/);
    const hMatchCN: RegExpMatchArray | null = dur.match(/(\d+(?:\.\d+)?)\s*小时/);
    const mMatch: RegExpMatchArray | null = dur.match(/(\d+)\s*min/);
    const mMatchCN: RegExpMatchArray | null = dur.match(/(\d+)\s*分钟/);
    let mins: number = 0;
    if (hMatch) mins += parseFloat(hMatch[1]) * 60;
    else if (hMatchCN) mins += parseFloat(hMatchCN[1]) * 60;
    if (mMatch) mins += parseInt(mMatch[1]);
    else if (mMatchCN) mins += parseInt(mMatchCN[1]);
    if (mins === 0) {
      const rangeH = dur.match(/(\d+)\s*-\s*(\d+)\s*h/);
      const rangeHCN = dur.match(/(\d+)\s*-\s*(\d+)\s*小时/);
      if (rangeH) mins = parseInt(rangeH[2]) * 60;
      else if (rangeHCN) mins = parseInt(rangeHCN[2]) * 60;
      else if (dur.includes('半天')) mins = 240;
      else mins = 90;
    }
    return mins;
  }

  /** 获取 POI 的停留时长(分钟)，优先用已解析的字段 */
  private getPoiDurationMinutes(poi: TourPoiItem): number {
    if (poi.durationMinutes && poi.durationMinutes > 0) return poi.durationMinutes;
    const parsed: number = this.parseDurationMinutes(poi.duration);
    poi.durationMinutes = parsed;
    return parsed;
  }

  /** 估算两个坐标间的路程耗时(分钟) — 混合模式 */
  private async estimateTravelMinutes(
    fromLat: number, fromLng: number, toLat: number, toLng: number,
    mode?: string, city?: string
  ): Promise<number> {
    const dist: number = haversineDistance(fromLat, fromLng, toLat, toLng);
    let estMin: number;
    if (mode === 'walking') estMin = Math.ceil(dist / 5000 * 60);
    else if (mode === 'bicycling') estMin = Math.ceil(dist / 15000 * 60);
    else estMin = Math.ceil(dist / 30000 * 60);
    if (estMin < 1) estMin = 1;
    try {
      let dirMode: DirectionMode = DirectionMode.DRIVING;
      if (mode === 'walking') dirMode = DirectionMode.WALKING;
      else if (mode === 'bicycling') dirMode = DirectionMode.BICYCLING;
      else if (mode === 'transit') dirMode = DirectionMode.TRANSIT;
      else dirMode = this.autoMode(fromLat, fromLng, toLat, toLng);
      const route: NavRoute | null = await AmapSearchService.getInstance().directionRouteRest(
        fromLat, fromLng, toLat, toLng, dirMode, city
      );
      if (route && route.duration > 0) return Math.ceil(route.duration / 60);
    } catch (_e) { /* fallback to estimate */ }
    return estMin;
  }

  /** 检查时间段是否与用餐窗口重叠 */
  private checkMealOverlap(startMin: number, endMin: number, poiType: string): string[] {
    const warnings: string[] = [];
    const isFood: boolean = /餐厅|美食|小吃|咖啡|茶|火锅|面馆|烧烤|早餐|午餐|晚餐|食堂|饭店/.test(poiType);
    if (isFood) return warnings;
    for (const mw of MEAL_WINDOWS) {
      if (startMin <= mw.startMin && endMin >= mw.endMin) {
        warnings.push(mw.label + '时段(' + formatClockTime(mw.startMin) + '-' + formatClockTime(mw.endMin) + ')被占用');
      } else if (startMin >= mw.startMin && startMin < mw.endMin) {
        warnings.push('建议在' + mw.label + '前结束(' + formatClockTime(mw.startMin) + ')');
      } else if (endMin > mw.startMin && endMin <= mw.endMin) {
        warnings.push('可能错过' + mw.label + '(' + formatClockTime(mw.startMin) + '-' + formatClockTime(mw.endMin) + ')');
      }
    }
    return warnings;
  }

  /** 获取当天缺餐的建议 */
  private getMissingMealSuggestions(day: TourDay): string[] {
    const suggestions: string[] = [];
    const hasPoiType = (keyword: string): boolean => {
      return day.pois.some((p) => !isMarkerPoi(p) && p.type.includes(keyword));
    };
    for (const mw of MEAL_WINDOWS) {
      const nearMeal: boolean = day.pois.some((p) =>
        !isMarkerPoi(p) && p.plannedStartMin !== undefined &&
        p.plannedStartMin < mw.endMin + 60 && p.plannedEndMin !== undefined &&
        p.plannedEndMin > mw.startMin - 60
      );
      if (!nearMeal) continue;
      if (mw.label === '早餐' && !hasPoiType('早餐') && !hasPoiType('咖啡') && !hasPoiType('早茶'))
        suggestions.push(mw.label + '(' + formatClockTime(mw.startMin) + '-' + formatClockTime(mw.endMin) + ') — 建议安排早餐');
      if (mw.label === '午餐' && !hasPoiType('餐厅') && !hasPoiType('美食') && !hasPoiType('小吃'))
        suggestions.push(mw.label + '(' + formatClockTime(mw.startMin) + '-' + formatClockTime(mw.endMin) + ') — 建议安排午餐');
      if (mw.label === '晚餐' && !hasPoiType('餐厅') && !hasPoiType('美食') && !hasPoiType('火锅') && !hasPoiType('夜市'))
        suggestions.push(mw.label + '(' + formatClockTime(mw.startMin) + '-' + formatClockTime(mw.endMin) + ') — 建议安排晚餐');
    }
    return suggestions;
  }

  private autoMode(lat1: number, lng1: number, lat2: number, lng2: number): DirectionMode {
    const dist: number = haversineDistance(lat1, lng1, lat2, lng2);
    if (dist < 1000) return DirectionMode.WALKING;
    return DirectionMode.DRIVING;
  }

  private detectModeStr(input: string): string | undefined {
    if (/地铁|公交|公交地铁|坐车|公共交通/.test(input)) return 'transit';
    if (/开车|驾车|打车|出租车|自驾/.test(input)) return 'driving';
    if (/走路|步行|徒步/.test(input)) return 'walking';
    if (/骑车|骑行|自行车/.test(input)) return 'bicycling';
    return undefined;
  }

  // ========== 路线重算 + 时间线计算 ==========

  /** 重新计算某一天的路线，并存储每段耗时到 travelToMinutes */
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
        day.pois[pi + 1].travelToMinutes = Math.ceil(route.duration / 60);
      } else {
        allPts.push({ latitude: a.lat, longitude: a.lng } as LatLng);
        allPts.push({ latitude: b.lat, longitude: b.lng } as LatLng);
        const estDist: number = haversineDistance(a.lat, a.lng, b.lat, b.lng);
        day.pois[pi + 1].travelToMinutes = Math.max(1, Math.ceil(estDist / 30000 * 60));
      }
    }
    day.route.path = allPts;
    try { this.calculateTimeline(day); } catch (e) { /* ignore */ }
  }

  /** 核心：计算每天每个 POI 的计划到达/离开时间（分钟 from midnight） */
  /* private */ calculateTimeline(day: TourDay): void {
    if (!day.dayStartMin) day.dayStartMin = DEFAULT_DAY_START_MIN;
    if (!day.dayEndMin) day.dayEndMin = DEFAULT_DAY_END_MIN;

    let currentMin: number = day.dayStartMin;

    for (let i: number = 0; i < day.pois.length; i++) {
      const poi: TourPoiItem = day.pois[i];

      if (isMarkerPoi(poi)) {
        poi.plannedStartMin = currentMin;
        poi.plannedEndMin = currentMin;
        poi.durationMinutes = 0;
        continue;
      }

      if (!poi.durationMinutes || poi.durationMinutes <= 0) {
        poi.durationMinutes = this.parseDurationMinutes(poi.duration);
      }

      if (i === 0) {
        poi.plannedStartMin = currentMin;
        poi.travelToMinutes = 0;
      } else {
        if (!poi.travelToMinutes || poi.travelToMinutes <= 0) {
          const prev: TourPoiItem = day.pois[i - 1];
          poi.travelToMinutes = Math.max(1, Math.ceil(
            haversineDistance(prev.lat, prev.lng, poi.lat, poi.lng) / 30000 * 60
          ));
        }
        let prevEnd: number = day.dayStartMin;
        for (let j: number = i - 1; j >= 0; j--) {
          if (day.pois[j].plannedEndMin !== undefined && day.pois[j].plannedEndMin! > prevEnd) {
            prevEnd = day.pois[j].plannedEndMin!;
            break;
          }
        }
        poi.plannedStartMin = prevEnd + poi.travelToMinutes;
      }

      poi.plannedEndMin = poi.plannedStartMin + poi.durationMinutes;

      poi.timeSlot = formatClockTime(poi.plannedStartMin) + '-' + formatClockTime(poi.plannedEndMin);

      if (poi.plannedEndMin > day.dayEndMin) {
        Logger.warn(TAG, day.label + ' ' + poi.name + ' 结束于 ' + formatClockTime(poi.plannedEndMin) + '，超过当天 ' + formatClockTime(day.dayEndMin));
      }

      currentMin = poi.plannedEndMin;
    }
  }

  /** 时间可行性检查 */
  private timeFeasibilityCheck(
    day: TourDay, newPoi: TourPoiItem, insertAfterIdx: number
  ): FeasibilityResult {
    const warnings: string[] = [];
    if (!day.dayStartMin) day.dayStartMin = DEFAULT_DAY_START_MIN;
    if (!day.dayEndMin) day.dayEndMin = DEFAULT_DAY_END_MIN;

    const needMin: number = this.getPoiDurationMinutes(newPoi);

    let prevEndMin: number = day.dayStartMin;
    let prevLat: number = 0;
    let prevLng: number = 0;
    if (insertAfterIdx >= 0 && insertAfterIdx < day.pois.length) {
      const prev: TourPoiItem = day.pois[insertAfterIdx];
      if (isMarkerPoi(prev)) {
        prevEndMin = day.dayStartMin;  // 标记POI不消耗时间
      } else {
        prevEndMin = prev.plannedEndMin ?? day.dayStartMin;
      }
      prevLat = prev.lat;
      prevLng = prev.lng;
    } else if (day.pois.length > 0) {
      for (let j: number = day.pois.length - 1; j >= 0; j--) {
        if (!isMarkerPoi(day.pois[j]) && day.pois[j].plannedEndMin !== undefined) {
          prevEndMin = day.pois[j].plannedEndMin!;
          prevLat = day.pois[j].lat;
          prevLng = day.pois[j].lng;
          break;
        }
      }
    }

    let nextStartMin: number = day.dayEndMin;
    let nextIdx: number = day.pois.length;
    if (insertAfterIdx >= 0 && insertAfterIdx + 1 < day.pois.length) {
      for (let j: number = insertAfterIdx + 1; j < day.pois.length; j++) {
        if (!isMarkerPoi(day.pois[j]) && day.pois[j].plannedStartMin !== undefined) {
          nextStartMin = day.pois[j].plannedStartMin!;
          nextIdx = j;
          break;
        }
      }
    }

    let travelToNew: number = 20;
    let travelFromNew: number = 20;
    if (prevLat !== 0 && prevLng !== 0 && newPoi.lat !== 0 && newPoi.lng !== 0) {
      const distTo: number = haversineDistance(prevLat, prevLng, newPoi.lat, newPoi.lng);
      travelToNew = Math.max(1, Math.ceil(distTo / 30000 * 60));
      if (nextIdx < day.pois.length) {
        const next: TourPoiItem = day.pois[nextIdx];
        const distFrom: number = haversineDistance(newPoi.lat, newPoi.lng, next.lat, next.lng);
        travelFromNew = Math.max(1, Math.ceil(distFrom / 30000 * 60));
      } else {
        travelFromNew = 0;
      }
    }

    const totalNeed: number = travelToNew + needMin + travelFromNew;
    const gapSize: number = nextStartMin - prevEndMin;

    if (totalNeed > gapSize) {
      const notFeasible: FeasibilityResult = {
        feasible: false, startMin: 0, endMin: 0,
        warnings: ['时间不够: 需要' + totalNeed + '分钟(路程' + (travelToNew + travelFromNew) + 'min + 游玩' + needMin + 'min)，但间隙仅' + gapSize + '分钟']
      };
      return notFeasible;
    }

    const startMin: number = prevEndMin + travelToNew;
    const endMin: number = startMin + needMin;

    const mealWarns: string[] = this.checkMealOverlap(startMin, endMin, newPoi.type);
    for (const w of mealWarns) warnings.push(w);

    if (endMin > day.dayEndMin) {
      warnings.push('结束时间 ' + formatClockTime(endMin) + ' 超过当天 ' + formatClockTime(day.dayEndMin));
    }

    const result: FeasibilityResult = { feasible: true, startMin, endMin, warnings };
    return result;
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
    if (obj['budget']) tc.amount = obj['budget'];  // 兼容 budget→amount
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
