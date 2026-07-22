/**
 * 导游页 — 全屏地图 + AI 导游规划
 * AI 一步步收集信息、搜酒店、规划每日行程、生成路线图
 */
import { webview } from '@kit.ArkWeb';
import router from '@ohos.router';
import { getTheme, isDarkTheme } from '../common/Theme';

import { MapWebView } from '../services/map/MapWebView';
import { Logger } from '../common/Logger';
import { TourGuideAgent, AgentResponse, ToolCall } from '../services/TourGuideAgent';
import { AmapSearchService } from '../services/map/AmapSearchService';
import { MapEventCallbacks } from '../services/map/IMapService';
import { MapJsBridge } from '../services/map/MapJsBridge';
import {
  LatLng, MapInitConfig, NavRoute, DirectionMode, PoiResult
} from '../services/map/MapTypes';
import { TourPlan, TourDay, InterCityTransport, getBudgetBreakdown, getTransportEmoji, getTransportLabel, migrateTourPlan, formatClockTime, isMarkerPoi } from '../model/TourPlan';
import { IntercityTransportOption } from '../services/map/AmapSearchService';
import { UserBasicInfo } from '../model/UserBasicInfo';
import { Dao } from '../database/Dao';

const TAG = 'TourGuidePage';
const DEFAULT_CENTER: LatLng = { latitude: 39.9042, longitude: 116.3974 };

interface ChatBubble {
  role: 'user' | 'ai';
  content: string;
}

interface TourHistoryItem {
  id: string;
  title: string;
  date: string;
  fingerprint?: string;
}

const ROUTE_COLORS: string[] = ['#3B82F6', '#10B981', '#F59E0B', '#EF4444', '#8B5CF6', '#EC4899', '#06B6D4'];
const HISTORY_KEY: string = 'tour_history';
const MAX_HISTORY: number = 20;

async function saveToHistory(plan: TourPlan | null, messages: ChatBubble[]): Promise<void> {
  if (messages.length <= 1) return;
  try {
    const dao = Dao.getInstance();
    const raw = await dao.queryUserProfile(HISTORY_KEY);
    let list: TourHistoryItem[] = [];
    if (raw && raw.preferenceValue) {
      try { list = JSON.parse(raw.preferenceValue) as TourHistoryItem[]; } catch (_e) { list = []; }
    }
    const firstUser = messages.find(m => m.role === 'user');
    const title = firstUser ? firstUser.content.substring(0, 20) : '未命名对话';
    // 用消息内容指纹去重，不是用标题
    const msgFingerprint = JSON.stringify(messages.slice(0, 3));
    for (let i = list.length - 1; i >= 0; i--) {
      if (list[i].fingerprint === msgFingerprint) {
        // 完全重复，不存
        return;
      }
    }
    const id = Date.now().toString();
    list.unshift({ id, title, date: new Date().toLocaleDateString(), fingerprint: msgFingerprint });
    if (list.length > MAX_HISTORY) list = list.slice(0, MAX_HISTORY);
    await dao.upsertUserProfile(HISTORY_KEY, JSON.stringify(list), 1);
    await dao.upsertUserProfile('tour_history_' + id, JSON.stringify({ plan, messages }), 1);
  } catch (_e) { /* ignore */ }
}

async function loadHistoryList(): Promise<TourHistoryItem[]> {
  try {
    const dao = Dao.getInstance();
    const raw = await dao.queryUserProfile(HISTORY_KEY);
    if (raw && raw.preferenceValue) return JSON.parse(raw.preferenceValue) as TourHistoryItem[];
  } catch (_e) { /* ignore */ }
  return [];
}

// 模块级持久化：翻页/退出不丢失
class PlanState {
  plan: TourPlan | null = null;
  messages: ChatBubble[] = [];
}
const g_agent: TourGuideAgent = new TourGuideAgent();
const g_planState: PlanState = new PlanState();

@Component
export struct TourGuideContent {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  private mapService: MapJsBridge | null = null;
  private agent: TourGuideAgent = g_agent;
  @State mapCenter: LatLng = DEFAULT_CENTER;
  @State mapZoom: number = 12;
  @State isMapReady: boolean = false;
  @State chatInput: string = '';
  @State chatMessages: ChatBubble[] = [];
  @State isAiThinking: boolean = false;
  @State plan: TourPlan | null = null;
  @State selectedDayIndex: number = 0;
  @State showPoiDetail: boolean = false;
  @State poiDetailName: string = '';
  @State poiDetailAddr: string = '';
  @State poiDetailInfo: string = '';
  @State quickReplies: string[] = [];
  @State transportOptions: IntercityTransportOption[] = [];
  @State chatScrollHeight: number = 160;
  @State showHistory: boolean = false;
  @State historyList: TourHistoryItem[] = [];
  @State isStopping: boolean = false;
  private stopRequested: boolean = false;
  private chatDragStartH: number = 0;
  private chatScroller: Scroller = new Scroller();
  private quickReplyPoiData: PoiResult[] = [];
  private dayPolylines: string[] = [];
  private dayMarkers: string[][] = [];
  private pendingToolCall: ToolCall | null = null;
  private markerPoiMap: Record<string, PoiResult> = {};
  private lastThemeDark: boolean = false;
  private themePoller: number | null = null;
  /** 防并发：重复调用 drawPlanOnMap 时丢弃旧的异步路线计算结果 */
  private drawGeneration: number = 0;

  async aboutToAppear(): Promise<void> {
    // 从内存恢复
    this.plan = g_planState.plan;
    this.chatMessages = g_planState.messages;

    // 如果内存没有，从数据库恢复
    if (!this.plan) {
      try {
        const dao = Dao.getInstance();
        const saved = await dao.queryUserProfile('tour_plan');
        if (saved && saved.preferenceValue) {
          this.plan = migrateTourPlan(JSON.parse(saved.preferenceValue) as TourPlan);
          g_planState.plan = this.plan;
        }
        const savedChat = await dao.queryUserProfile('tour_chat');
        if (savedChat && savedChat.preferenceValue) {
          this.chatMessages = JSON.parse(savedChat.preferenceValue) as ChatBubble[];
          g_planState.messages = this.chatMessages;
        }
      } catch (_e) { /* ignore */ }
    }

    // 同步恢复的计划到 agent，防止 agent/UI 两套 plan 不同步导致预算丢失
    if (this.plan) {
      this.agent.setPlan(JSON.parse(JSON.stringify(this.plan)) as TourPlan);
    }

    // 加载用户偏好到"小途"agent（软引导，不强制）
    try {
      const dao = Dao.getInstance();
      const userInfo: UserBasicInfo | null = await dao.queryUserBasicInfo();
      if (userInfo) {
        this.agent.setUserContext(
          userInfo.username || '',
          userInfo.city || '',
          userInfo.getPreferenceTags()
        );
        Logger.info(TAG, 'User context set for TourGuideAgent');
      }
    } catch (_e) { /* ignore */ }

    if (this.chatMessages.length === 0) {
      this.chatMessages = [
        { role: 'ai', content: '你好！我是小途 🗺️\n想规划一次旅行吗？告诉我目的地和天数，我帮你安排！比如"想去成都玩3天"。' }
      ];
    }

    // 轮询检测深色模式变化 → 切换地图样式
    this.lastThemeDark = isDarkTheme();
    this.themePoller = setInterval(() => {
      const darkNow: boolean = isDarkTheme();
      if (darkNow !== this.lastThemeDark && this.mapService) {
        this.lastThemeDark = darkNow;
        try {
          this.mapService.setMapStyle(darkNow ? 'amap://styles/dark' : 'amap://styles/light');
          this.mapService.setDarkMode(darkNow);
          Logger.info(TAG, 'Tour map style switched to %{public}s', darkNow ? 'dark' : 'light');
        } catch (e) {}
      }
    }, 2000);
  }

  aboutToDisappear(): void {
    if (this.themePoller) {
      clearInterval(this.themePoller);
      this.themePoller = null;
    }
  }

  private saveState(): void {
    g_planState.plan = this.plan;
    g_planState.messages = this.chatMessages;
    // 持久化到数据库，杀进程后也能恢复
    try {
      const dao = Dao.getInstance();
      if (this.plan && (this.plan.dailyPlans.length > 0 || (this.plan.totalBudget && this.plan.totalBudget > 0))) {
        dao.upsertUserProfile('tour_plan', JSON.stringify(this.plan), 1);
      }
      if (this.chatMessages.length > 0) {
        dao.upsertUserProfile('tour_chat', JSON.stringify(this.chatMessages), 1);
      }
    } catch (_e) { /* ignore */ }
  }

  /** WebView 就绪 */
  onWebViewReady(controller: webview.WebviewController): void {
    if (this.mapService) { this.mapService.setController(controller); return; }
    const bridge = new MapJsBridge();
    bridge.setController(controller);
    this.mapService = bridge;
    const callbacks: MapEventCallbacks = {
      onMapReady: (_err: Error | null): void => {
        this.isMapReady = true;
        Logger.info(TAG, 'Tour map ready');
        if (isDarkTheme() && this.mapService) {
          this.mapService.setMapStyle('amap://styles/dark');
          this.mapService.setDarkMode(true);
        }
        if (this.plan && this.plan.dailyPlans.length > 0) {
          this.drawPlanOnMap(this.plan);
        }
      },
      onMarkerClick: (id: string, _lat: number, _lng: number, _title: string): void => {
        this.showPoiPopup(id);
      }
    };
    bridge.setEventCallbacks(callbacks);
    bridge.initialize({
      lng: this.mapCenter.longitude, lat: this.mapCenter.latitude,
      zoom: this.mapZoom, apiKey: 'bb0c1640992e6c7f2b1467498d8ae848'
    } as MapInitConfig);

    // 兜底：若 JS 侧 auto-init 的 mapReady 早于 javaScriptProxy 注册，
    // setEventCallbacks 的回调收不到，这里补发一次
    bridge.onMapReady((_err: Error | null): void => {
      if (!this.isMapReady) {
        this.isMapReady = true;
        Logger.info(TAG, 'Tour map ready via fallback');
        if (isDarkTheme() && this.mapService) {
          this.mapService.setMapStyle('amap://styles/dark');
          this.mapService.setDarkMode(true);
        }
        if (this.plan && this.plan.dailyPlans.length > 0) {
          this.drawPlanOnMap(this.plan);
        }
      }
    });
  }

  /** 发送消息 */
  async sendMessage(): Promise<void> {
    const input: string = this.chatInput.trim();
    if (!input || this.isAiThinking) return;

    this.stopRequested = false;
    this.isStopping = false;
    this.chatMessages.push({ role: 'user', content: input });
    this.chatInput = '';
    this.chatScroller.scrollEdge(Edge.Bottom);
    this.quickReplies = [];
    this.saveState();
    this.isAiThinking = true;

    try {
      const resp: AgentResponse = await this.agent.process(input);

      // 优先使用 AI 生成的快捷回复
      let aiQuickReplies: string[] = resp.quickReplies || [];
      for (const tc of resp.toolCalls) {
        if (tc.quickReplies && tc.quickReplies.length > 0) {
          aiQuickReplies = tc.quickReplies;
          break;
        }
      }
      if (aiQuickReplies.length > 0) this.quickReplies = aiQuickReplies;

      if (resp.toolCalls.length > 0) {
        const toolNames: string = resp.toolCalls.map(tc => tc.action).join('+');
        this.chatMessages.push({
          role: 'ai',
          content: resp.text + `\n\n🔍 ${toolNames}...`
        });
        this.chatScroller.scrollEdge(Edge.Bottom);
        await this.autoExecuteTools(resp.toolCalls);
      } else {
        this.chatMessages.push({ role: 'ai', content: resp.text });
        this.chatScroller.scrollEdge(Edge.Bottom);
        if (resp.plan) {
          this.plan = resp.plan;
          this.drawPlanOnMap(resp.plan);
        }
      }
    } catch (_e) {
      // 清理占位
      if (this.chatMessages.length > 0) {
        const last: ChatBubble = this.chatMessages[this.chatMessages.length - 1];
        if (last.content.includes('🔍')) {
          this.chatMessages = this.chatMessages.slice(0, -1);
        }
      }
      this.chatMessages.push({ role: 'ai', content: '抱歉，出错了。请再试一次。' });
      this.chatScroller.scrollEdge(Edge.Bottom);
    } finally {
      this.saveState();
      this.isAiThinking = false;
      // 强制每次对话后重绘地图，确保地图始终反映当前 plan
      if (this.plan && this.plan.dailyPlans.length > 0 && this.isMapReady && this.mapService) {
        this.drawPlanOnMap(this.plan); // 异步绘制，不阻塞UI
      }
    }
  }

  /** 批量执行工具调用并继续对话
   *  geocode 完成后立即移动地图（不等其余工具），其余工具完成后追加标记
   *  第二阶段：询问 AI 下一步 → 链式调用下一批 */
  async autoExecuteTools(toolCalls: ToolCall[]): Promise<void> {
    if (toolCalls.length === 0) return;
    const primaryAction: string = toolCalls[0].action;
    try {
      // 第一阶段：批量执行工具（geocode 优先 + 其余并行）
      // geocode 完成后立即回调 → 地图中心先跳，不等搜索
      let geoMoved: boolean = false;
      const resp: AgentResponse = await this.agent.executeToolsAndContinue(toolCalls,
        (phase: string, partial: AgentResponse) => {
          if (phase === 'geocode_done' && this.isMapReady && this.mapService) {
            if (partial.mapCenter) {
              this.mapCenter = partial.mapCenter;
              this.mapService.moveCamera(partial.mapCenter, 13);
              geoMoved = true;
            }
            if (partial.markers && partial.markers.length > 0) {
              this.showMarkersOnMap(partial.markers);
            }
            Logger.info(TAG, 'Map updated after geocode phase');
          }
        });

      // 全部工具完成 → 完整地图更新
      if (resp.plan && (resp.plan.dailyPlans.length > 0 || toolCalls.some(tc => tc.action === 'set_budget'))) {
        this.plan = resp.plan;
        this.saveState();
        if (resp.plan.dailyPlans.length > 0) {
          // 不清空临时标记！酒店搜索结果等应保持可见，等用户选定加入计划后自然更新
          this.drawPlanOnMap(resp.plan); // 异步绘制：标记立即显示，路线后台计算
        }
      }
      if (this.isMapReady && this.mapService) {
        // 如果 geocode 回调已经移过了且新的 mapCenter 相同，跳过
        if (resp.mapCenter && !geoMoved) {
          this.mapCenter = resp.mapCenter;
          this.mapService.moveCamera(resp.mapCenter, 13);
        } else if (resp.mapCenter && geoMoved &&
                   (resp.mapCenter.latitude !== this.mapCenter.latitude ||
                    resp.mapCenter.longitude !== this.mapCenter.longitude)) {
          this.mapCenter = resp.mapCenter;
          this.mapService.moveCamera(resp.mapCenter, 13);
        }
        if (resp.markers && resp.markers.length > 0) {
          this.showMarkersOnMap(resp.markers);
        }
        if (resp.transportOptions && resp.transportOptions.length > 0) {
          this.transportOptions = resp.transportOptions;
        }
        // 只在 AI 没给快捷回复时用硬编码兜底
        if (this.quickReplies.length === 0) {
          this.updateQuickReplies(resp.markers || [], primaryAction);
        }
      }

      // 第二阶段：询问 AI 下一步
      try {
        const results: import('../services/TourGuideAgent').ToolResult[] = this.agent.getLastToolResults();
        const aiResp: AgentResponse = await this.agent.askAiNextStep(results);

        // 替换占位消息并显示 AI 回复
        if (this.chatMessages.length > 0) {
          const last = this.chatMessages[this.chatMessages.length - 1];
          if (last.content.includes('🔍')) {
            this.chatMessages = this.chatMessages.slice(0, -1);
          }
        }
        // 对于信息性工具，显示工具执行结果（预算概览等）
        const infoActions: string[] = ['estimate_costs', 'set_budget'];
        if (toolCalls.some(tc => infoActions.indexOf(tc.action) >= 0) && resp.text && resp.text.length > 0) {
          this.chatMessages.push({ role: 'ai', content: resp.text });
          this.chatScroller.scrollEdge(Edge.Bottom);
        }
        // 如果有意义的回复才添加
        if (aiResp.text && aiResp.text.length > 2 && aiResp.text !== '收到，请继续。') {
          this.chatMessages.push({ role: 'ai', content: aiResp.text });
          this.chatScroller.scrollEdge(Edge.Bottom);
        }
        this.saveState();

        // AI 生成的快捷回复
        let aiQr: string[] = aiResp.quickReplies || [];
        for (const tc of [...aiResp.toolCalls, ...resp.toolCalls]) {
          if (tc.quickReplies && tc.quickReplies.length > 0) { aiQr = tc.quickReplies; break; }
        }
        if (aiQr.length > 0) this.quickReplies = aiQr;

        // 链式调用：AI 返回的 + 系统自动串联的，合并成新批次
        if (!this.stopRequested) {
          const chainTools: ToolCall[] = [...aiResp.toolCalls, ...resp.toolCalls];
          if (chainTools.length > 0) {
            const chainNames: string = chainTools.map(tc => tc.action).join('+');
            this.chatMessages.push({ role: 'ai', content: '🔍 ' + chainNames + '...' });
            this.chatScroller.scrollEdge(Edge.Bottom);
            await this.autoExecuteTools(chainTools);
          }
        }
      } catch (_e) {
        // Phase 2 失败不丢 Phase 1 的结果，只去掉 🔍 占位
        if (this.chatMessages.length > 0) {
          const last = this.chatMessages[this.chatMessages.length - 1];
          if (last.content.includes('🔍')) {
            this.chatMessages = this.chatMessages.slice(0, -1);
          }
        }
        Logger.warn(TAG, 'askAiNextStep failed, keeping phase1 result');
      }
    } catch (e) {
      Logger.error(TAG, 'autoExecuteTools failed for %{public}s: %{public}s',
        primaryAction, JSON.stringify(e));
      // 去掉占位消息
      if (this.chatMessages.length > 0) {
        const last = this.chatMessages[this.chatMessages.length - 1];
        if (last.content.includes('🔍')) {
          this.chatMessages = this.chatMessages.slice(0, -1);
        }
      }
      const errNames: string = toolCalls.map(tc => tc.action).join('+');
      this.chatMessages.push({ role: 'ai', content: '😅 ' + errNames + '执行出错，请再试一次。' });
      this.chatScroller.scrollEdge(Edge.Bottom);
    }
  }

  private tempMarkerIds: string[] = [];

  showMarkersOnMap(markers: import('../services/TourGuideAgent').MapMarker[]): void {
    if (!this.mapService) return;
    for (const m of markers) {
      const emoji: string = m.type.includes('酒店') ? '🏨' :
        (m.type.includes('美食') || m.type.includes('餐厅') ? '🍽️' : '📍');
      const id: string = this.mapService.addMarker({
        position: { latitude: m.lat, longitude: m.lng },
        iconStyle: { color: '#10B981', size: 20, text: emoji },
        title: m.name,
        snippet: m.type,
        clickable: true,
        zIndex: 70,
      });
      this.tempMarkerIds.push(id);
      this.markerPoiMap[id] = { name: m.name, type: m.type, latitude: m.lat, longitude: m.lng,
        address: m.address || '', distance: 0, tel: '', id: m.poiId || '' } as PoiResult;
    }
  }

  async showPoiPopup(markerId: string): Promise<void> {
    const poi = this.markerPoiMap[markerId];
    if (!poi) return;
    this.poiDetailName = poi.name;
    this.poiDetailAddr = poi.address || '';
    this.poiDetailInfo = '';
    this.showPoiDetail = true;

    // 尝试获取详情（评分、电话等）
    if (poi.id && poi.id.length > 0) {
      try {
        const detail = await AmapSearchService.getInstance().getPoiDetail(poi.id);
        if (detail) {
          const bizExt = detail['biz_ext'] as Record<string, Object> | undefined;
          const deepInfo = detail['deep_info'] as Record<string, Object> | undefined;
          const parts: string[] = [];
          if (bizExt) {
            const rating = bizExt['rating'] as string ?? '';
            if (rating && rating.length > 0) parts.push('⭐' + rating);
            const cost = bizExt['cost'] as string ?? '';
            if (cost && cost.length > 0) parts.push('💰人均' + cost);
          }
          const tel = (detail['tel'] as string) ?? '';
          if (tel && tel.length > 0) parts.push('📞' + tel);
          this.poiDetailInfo = parts.join('  ');
        }
      } catch (_e) { /* ignore */ }
    }
  }

  clearCurrentMarkers(): void {
    if (!this.mapService) return;
    for (const id of this.tempMarkerIds) {
      try { this.mapService.removeMarker(id); } catch (_e) { /* ignore */ }
    }
    this.tempMarkerIds = [];
  }

  /** 根据当前状态生成快捷回复 */
  updateQuickReplies(markers: import('../services/TourGuideAgent').MapMarker[], action: string): void {
    // 每次新消息都清除旧快捷回复，确保不残留
    this.quickReplies = [];

    // 城市定位后 → 主动引导交通和预算
    if (action === 'geocode_city') {
      this.quickReplies = ['🚄查车次', '🚄高铁', '✈️飞机', '设预算'];
      return;
    }

    // 搜索结果 → 显示前几个选项 + 换一批
    if (action === 'search_hotels' || action === 'search_poi' || action === 'search_and_add') {
      for (let i: number = 0; i < markers.length && i < 5; i++) {
        this.quickReplies.push(markers[i].name);
      }
      if (this.quickReplies.length > 0) this.quickReplies.push('🔄 换一批');
      return;
    }

    // 计划刚生成 → 引导添加景点
    if (action === 'make_plan' && this.plan && this.plan.dailyPlans.length > 0) {
      this.quickReplies = ['加景点', '加美食', '设预算', '改酒店', '删景点'];
      return;
    }

    // 预算设置后 → 引导估算
    if (action === 'set_budget') {
      this.quickReplies = ['估算花费', '加景点', '加美食', '看看行程'];
      return;
    }

    // 估算花费后
    if (action === 'estimate_costs') {
      this.quickReplies = ['加景点', '削预算', '看看行程'];
      return;
    }

    // 交通设置后
    if (action === 'set_transport') {
      this.quickReplies = ['设预算', '搜酒店', '加景点'];
      return;
    }

    // 添加完一个 POI 后 → 继续操作
    if (action === 'search_and_add') {
      this.quickReplies = ['再加一个', '换交通方式', '看看行程'];
      return;
    }

    // 其他情况 → 通用操作
    if (this.plan && this.plan.dailyPlans.length > 0) {
      this.quickReplies = ['加景点', '加美食', '看看行程'];
    }
  }

  /** 选中交通方案 → 填入聊天并发送 */
  /** 选中交通方案 → 直接记录，不经过AI */
  async selectTransportOption(opt: IntercityTransportOption): Promise<void> {
    this.transportOptions = [];
    const label: string = getTransportLabel(opt.type);
    // 直接构造 toolCall 并执行
    const toolCall: ToolCall = {
      action: 'set_transport',
      type: opt.type,
      from: opt.fromStation || '',
      to: opt.toStation || '',
      fromStation: opt.fromStation || '',
      toStation: opt.toStation || '',
      departureTime: opt.departureTime || '',
      arrivalTime: opt.arrivalTime || '',
      number: opt.trip || '',
      cost: opt.price > 0 ? opt.price.toString() : '',
    };
    // 显示确认消息
    const confirmText: string = `已选择 ${getTransportEmoji(opt.type)} ${opt.trip || label} ${opt.fromStation}${opt.departureTime ? ' ' + opt.departureTime : ''} → ${opt.toStation}${opt.arrivalTime ? ' ' + opt.arrivalTime : ''}${opt.price > 0 ? ' ¥' + opt.price : ''}`;
    this.chatMessages.push({ role: 'user', content: confirmText });
    this.chatScroller.scrollEdge(Edge.Bottom);
    this.isAiThinking = true;
    try {
      await this.autoExecuteTools([toolCall]);
    } catch (_e) {
      this.chatMessages.push({ role: 'ai', content: '记录交通方案失败，请重试。' });
      this.chatScroller.scrollEdge(Edge.Bottom);
    } finally {
      this.isAiThinking = false;
    }
  }

  /** 点击快捷回复 */
  onQuickReply(reply: string): void {
    if (reply === '🔄 换一批') {
      this.chatInput = '换一批';
      this.sendMessage();
      return;
    }
    if (reply === '🚄查车次') {
      // 直接触发搜索：用当前计划城市作为目的地，让AI问出发城市
      const dest: string = this.plan?.city || '';
      if (dest) {
        // 如果有 plan.transportToCity.from，直接查
        const fromCity: string = this.plan?.transportToCity?.from || '';
        if (fromCity) {
          // 已知出发城市 → 让系统检测到交通意图
          this.chatInput = `${fromCity}到${dest}高铁`;
        } else {
          this.chatInput = `怎么去${dest}`;
        }
      } else {
        this.chatInput = '查车次';
      }
      this.sendMessage();
      return;
    }
    this.chatInput = reply;
    this.sendMessage();
  }

  /** 在地图上绘制计划路线
   *  标记立即显示，路线在后台计算完成后更新 */
  async drawPlanOnMap(plan: TourPlan): Promise<void> {
    const ms = this.mapService;
    if (!ms || !this.isMapReady) return;

    // 防并发：递增代数，旧调用的异步路线结果将被丢弃
    const gen: number = ++this.drawGeneration;

    // 清除旧路线
    this.clearPlanOverlays();

    // 移动地图到城市
    if (plan.cityLat && plan.cityLng) {
      ms.moveCamera({ latitude: plan.cityLat, longitude: plan.cityLng }, 12);
      this.mapCenter = { latitude: plan.cityLat, longitude: plan.cityLng };
    }

    // 第一阶段：立即添加所有 POI 标记
    for (let d: number = 0; d < plan.dailyPlans.length; d++) {
      const day: TourDay = plan.dailyPlans[d];
      const color: string = ROUTE_COLORS[d % ROUTE_COLORS.length];
      const markers: string[] = [];

      for (const poi of day.pois) {
        // 跳过无效坐标（但酒店允许0,0兜底用城市中心）
        if ((poi.lat === 0 && poi.lng === 0) && !poi.type.includes('酒店')) continue;
        let lat: number = poi.lat;
        let lng: number = poi.lng;
        // 酒店坐标为0时用城市中心兜底
        if (lat === 0 && lng === 0 && poi.type.includes('酒店')) {
          lat = plan.cityLat || 39.9;
          lng = plan.cityLng || 116.4;
        }
        const emoji: string = this.poiEmoji(poi.type);
        const markerId: string = ms.addMarker({
          position: { latitude: lat, longitude: lng },
          iconStyle: { color: color, size: 20, text: emoji },
          title: poi.name,
          snippet: poi.timeSlot,
          clickable: true,
          zIndex: 60,
        });
        markers.push(markerId);
        this.markerPoiMap[markerId] = {
          name: poi.name, type: poi.type, latitude: lat, longitude: lng,
          address: poi.note || '', distance: 0, tel: '', id: ''
        } as PoiResult;
      }
      this.dayMarkers.push(markers);

      if (day.route && day.route.path.length > 0) {
        const polyId: string = ms.addPolyline({
          points: day.route.path, color: color, width: 6, zIndex: 50, clickable: false,
        });
        this.dayPolylines.push(polyId);
      } else if (day.pois.length >= 2) {
        // 兜底：没路线时画POI间直线(跳过0,0)
        const pts: LatLng[] = [];
        for (const p of day.pois) {
          if (p.lat !== 0 || p.lng !== 0) {
            pts.push({ latitude: p.lat, longitude: p.lng } as LatLng);
          }
        }
        if (pts.length >= 2) {
          const polyId: string = ms.addPolyline({
            points: pts, color: color, width: 4, zIndex: 49, clickable: false,
          });
          this.dayPolylines.push(polyId);
        } else {
          this.dayPolylines.push('');
        }
      } else {
        this.dayPolylines.push('');
      }
    }

    this.selectedDayIndex = 0;
    this.syncDayVisibility();

    // 第二阶段：后台计算缺失的路线
    for (let d: number = 0; d < plan.dailyPlans.length; d++) {
      const day: TourDay = plan.dailyPlans[d];
      if ((day.route && day.route.path.length > 0) || day.pois.length < 2) continue;

      const color: string = ROUTE_COLORS[d % ROUTE_COLORS.length];
      const allPts: LatLng[] = [];
      for (let pi: number = 0; pi < day.pois.length - 1; pi++) {
        const a = day.pois[pi];
        const b = day.pois[pi + 1];
        let route: NavRoute | null = null;
        for (let retry: number = 0; retry < 5; retry++) {
          try {
            route = await AmapSearchService.getInstance().directionRouteRest(
              a.lat, a.lng, b.lat, b.lng, DirectionMode.DRIVING
            );
            if (route && route.path.length > 0) break;
          } catch (_e) { /* ignore */ }
        }
        if (route && route.path.length > 0) {
          for (const pt of route.path) allPts.push(pt);
        } else {
          const fallbackA: LatLng = { latitude: a.lat, longitude: a.lng };
          const fallbackB: LatLng = { latitude: b.lat, longitude: b.lng };
          allPts.push(fallbackA);
          allPts.push(fallbackB);
        }
      }
      if (allPts.length > 0) {
        // 防并发：如果已有更新的 drawPlanOnMap 调用，丢弃本次异步结果
        if (gen !== this.drawGeneration) return;
        day.route = { distance: 0, duration: 0, path: allPts, steps: [], origin: '', destination: '' } as NavRoute;
        if (this.dayPolylines[d] && this.dayPolylines[d].length > 0) {
          try { ms.removePolyline(this.dayPolylines[d]); } catch (_e) { /* ignore */ }
        }
        const polyId: string = ms.addPolyline({
          points: allPts, color: color, width: 6, zIndex: 50, clickable: false,
        });
        this.dayPolylines[d] = polyId;
        try { ms.setPolylineVisible(polyId, d === this.selectedDayIndex); } catch (_e) { /* ignore */ }
      }
    }
  }

  /** 切换显示日 */
  selectDay(index: number): void {
    this.selectedDayIndex = index;
    this.syncDayVisibility();
  }

  syncDayVisibility(): void {
    const ms = this.mapService;
    if (!ms) return;
    for (let i: number = 0; i < this.dayPolylines.length; i++) {
      try { ms.setPolylineVisible(this.dayPolylines[i], i === this.selectedDayIndex); } catch (_e) { /* ignore */ }
    }
    for (let i: number = 0; i < this.dayMarkers.length; i++) {
      for (const m of this.dayMarkers[i]) {
        try { ms.setMarkerVisible(m, i === this.selectedDayIndex); } catch (_e) { /* ignore */ }
      }
    }
  }

  clearPlanOverlays(): void {
    const ms = this.mapService;
    if (!ms) return;
    for (const id of this.dayPolylines) {
      try { ms.removePolyline(id); } catch (_e) { /* ignore */ }
    }
    for (const arr of this.dayMarkers) {
      for (const id of arr) {
        try { ms.removeMarker(id); } catch (_e) { /* ignore */ }
      }
    }
    this.dayPolylines = [];
    this.dayMarkers = [];
  }

  poiEmoji(type: string): string {
    if (type.includes('酒店') || type.includes('住宿')) return '🏨';
    if (type.includes('餐厅') || type.includes('美食') || type.includes('小吃')) return '🍽️';
    if (type.includes('景点') || type.includes('公园') || type.includes('风景') || type.includes('博物馆')) return '🏛️';
    if (type.includes('购物') || type.includes('商场')) return '🛍️';
    if (type.includes('咖啡') || type.includes('茶')) return '☕';
    if (type.includes('飞机') || type.includes('✈️')) return '✈️';
    if (type.includes('高铁') || type.includes('🚄')) return '🚄';
    if (type.includes('火车') || type.includes('🚂')) return '🚂';
    if (type.includes('大巴') || type.includes('🚌')) return '🚌';
    if (type.includes('交通')) return '🚗';
    return '📍';
  }

  /** 格式化 POI 时间显示：优先用 plannedStartMin/plannedEndMin，降级到 timeSlot */
  private formatPoiTime(poi: import('../model/TourPlan').TourPoiItem): string {
    if (poi.plannedStartMin !== undefined && poi.plannedEndMin !== undefined) {
      const start: string = formatClockTime(poi.plannedStartMin);
      const end: string = formatClockTime(poi.plannedEndMin);
      return `${start}-${end}`;
    }
    if (poi.timeSlot && poi.timeSlot.length > 0) {
      return poi.timeSlot;
    }
    return '';
  }

  /** 计算已花费总额 */
  private calcSpentTotal(): number {
    const br = this.plan ? getBudgetBreakdown(this.plan) : null;
    return br ? br.total : 0;
  }

  /** 格式化时长（秒→小时，保留1位小数） */
  private fmtDur(seconds: number): string {
    return (Math.round(seconds / 3600 * 10) / 10).toFixed(1);
  }

  /** 计算预算使用比例 */
  private calcBudgetRatio(): number {
    if (!this.plan || !this.plan.totalBudget || this.plan.totalBudget <= 0) return 0;
    return Math.min(1, this.calcSpentTotal() / this.plan.totalBudget);
  }

  buildBudgetBars(): Array<[string, number, string]> {
    if (!this.plan || !this.plan.totalBudget) return [];
    const br = getBudgetBreakdown(this.plan);
    const result: Array<[string, number, string]> = [];
    const all: Array<[string, number, string]> = [
      ['🍽️ 餐饮', br.food, '#FF6B35'],
      ['🚗 交通', br.transport, '#3B82F6'],
      ['🏨 酒店', br.hotel, '#8B5CF6'],
      ['🎫 景点', br.attractions, '#10B981'],
      ['🛍️ 购物', br.shopping, '#F59E0B'],
    ];
    for (let i = 0; i < all.length; i++) {
      if (all[i][1] > 0) result.push(all[i]);
    }
    return result;
  }

  @Builder
  TransportInfoRow(transport: InterCityTransport, label: string) {
    Row() {
      Text(getTransportEmoji(transport.type)).fontSize(14)
      Column() {
        Text(`${label}: ${transport.from} → ${transport.to}`)
          .fontSize(11).fontColor(getTheme(this.themeMode).textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          if (transport.number) {
            Text(transport.number).fontSize(9).fontColor('#3B82F6')
              .margin({ right: 6 })
          }
          if (transport.departureTime) {
            Text(transport.departureTime).fontSize(9).fontColor(getTheme(this.themeMode).textSecondary)
          }
          if (transport.arrivalTime) {
            Text(' → ' + transport.arrivalTime).fontSize(9).fontColor(getTheme(this.themeMode).textSecondary)
          }
          if (transport.cost && transport.cost > 0) {
            Text(`  ¥${transport.cost}`).fontSize(9).fontColor('#F59E0B')
          }
        }
      }
      .alignItems(HorizontalAlign.Start).margin({ left: 6 }).layoutWeight(1)
    }
    .width('100%').margin({ bottom: 2 })
  }

  build() {
    Column() {
      Stack() {
        // 全屏地图
        MapWebView({
          onControllerAttached: (controller: webview.WebviewController): void => {
            this.onWebViewReady(controller);
          }
        })


        // 推荐浮钮 — 查看当前城市周边推荐
        Row() {
          Blank()
          Column() {
            Text('💡').fontSize(18)
            Text('推荐').fontSize(9).fontColor('#FFFFFF').margin({ top: 1 })
          }
          .width(42).height(42).borderRadius(21)
          .backgroundColor('#CC3B82F6').justifyContent(FlexAlign.Center)
          .shadow({ radius: 4, color: '#403B82F6', offsetY: 2 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/RecommendPage' });
          })
        }
        .width('100%').padding({ right: 12 }).margin({ top: 90 })

        if (!this.isMapReady) {
          Column() {
            LoadingProgress().width(32).height(32).color('#8B5CF6')
            Text('地图加载中...').fontSize(13).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 8 })
          }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor(getTheme(this.themeMode).surfaceSecondary)
        }

        // 行程卡片（日选择器 + 行程概览 + 交通 + 预算 — 四合一的紧凑面板）
        if (this.plan && this.plan.dailyPlans.length > 0) {
          Column() {
            // 第一行：日选择器（横滑）
            Scroll() {
              Row() {
                ForEach(this.plan.dailyPlans, (day: TourDay, idx: number) => {
                  Text(day.label || `第${idx + 1}天`)
                    .fontSize(11).fontColor(idx === this.selectedDayIndex ? '#FFF' : '#666')
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .backgroundColor(idx === this.selectedDayIndex ? '#10B981' : '#FFFFFF')
                    .borderRadius(10)
                    .onClick(() => { this.selectDay(idx); })
                }, (day: TourDay, idx: number): string => `${idx}_${day.label}`)
              }
            }.scrollable(ScrollDirection.Horizontal).height(28).margin({ bottom: 4 })

            // 第二行：当天标题 + 交通 + 预算
            Row() {
              Text(this.plan.dailyPlans[this.selectedDayIndex].label + ' 行程')
                .fontSize(13).fontWeight(FontWeight.Bold)
                .fontColor(getTheme(this.themeMode).textPrimary)
              // 交通小标
              if (this.plan.transportToCity) {
                Text(' ' + getTransportEmoji(this.plan.transportToCity.type) + ' ' +
                  (this.plan.transportToCity.number || getTransportLabel(this.plan.transportToCity.type)))
                  .fontSize(9).fontColor('#3B82F6')
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .backgroundColor('#EFF6FF').borderRadius(4)
              }
              Blank()
              // 预算摘要
              if (this.plan.totalBudget && this.plan.totalBudget > 0) {
                Text(`💰 ¥${this.calcSpentTotal()}/¥${this.plan.totalBudget}`)
                  .fontSize(9).fontColor(this.calcSpentTotal() > this.plan.totalBudget! ? '#FF5252' : '#10B981')
              }
            }.width('100%').margin({ bottom: 2 })

            // 进度条（有预算时）
            if (this.plan.totalBudget && this.plan.totalBudget > 0) {
              Row() {
                Row() {}
                  .width(`${(this.calcBudgetRatio() * 100).toFixed(0)}%`).height('100%')
                  .backgroundColor(this.calcBudgetRatio() > 1 ? '#FF5252' : '#10B981')
                  .borderRadius(1)
              }
              .width('100%').height(3).backgroundColor('#E8E8E8').borderRadius(1).margin({ bottom: 4 })

              // 预算分类占比条
              Column() {
                ForEach(this.buildBudgetBars(), (cat: Array<string | number>) => {
                  Row() {
                    Text(cat[0] as string).fontSize(9).fontColor(getTheme(this.themeMode).textSecondary).width(52)
                    Row() {
                      Row() {}
                        .width(`${(cat[1] as number / (this.plan?.totalBudget || 1) * 100).toFixed(0)}%`).height('100%')
                        .backgroundColor(cat[2] as string).borderRadius(1)
                    }
                    .layoutWeight(1).height(8).backgroundColor('#E8E8E8').borderRadius(1).margin({ left: 4, right: 4 })
                    Text(`¥${cat[1]}`).fontSize(9).fontColor(getTheme(this.themeMode).textPrimary).width(36)
                  }
                  .width('100%').margin({ bottom: 2 })
                })
              }.width('100%').margin({ top: 4, bottom: 2 })

            }

            // POI 横滑列表
            Scroll() {
              Row() {
                ForEach(
                  this.plan.dailyPlans[this.selectedDayIndex].pois.filter((p: import('../model/TourPlan').TourPoiItem) =>
                    !isMarkerPoi(p)),
                  (poi: import('../model/TourPlan').TourPoiItem, pidx: number) => {
                  Column() {
                    Text(this.poiEmoji(poi.type)).fontSize(20)
                    Text(poi.name).fontSize(9).fontColor(getTheme(this.themeMode).textSecondary).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.formatPoiTime(poi)).fontSize(8).fontColor(getTheme(this.themeMode).textSecondary)
                    if (poi.estimatedCost && poi.estimatedCost > 0) {
                      Text(`¥${poi.estimatedCost}`).fontSize(8).fontColor('#F59E0B')
                    }
                  }
                  .width(72).padding(4).alignItems(HorizontalAlign.Center)
                }, (poi: import('../model/TourPlan').TourPoiItem, pidx: number): string => `${pidx}_${poi.name}_${poi.timeSlot}`)
              }
            }.scrollable(ScrollDirection.Horizontal).height(64)
          }
          .width('94%').padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .backgroundColor('#CCFFFFFF').borderRadius(12)
          .position({ x: '3%', y: 0 }).zIndex(10)
        }

        // POI 详情弹窗
        if (this.showPoiDetail) {
          Column() {
            Row() {
              Text(this.poiDetailName).fontSize(16).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
                .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Button('✕').fontSize(14).width(28).height(28)
                .backgroundColor('#00000000').fontColor(getTheme(this.themeMode).textSecondary)
                .onClick(() => { this.showPoiDetail = false; })
            }.width('100%')

            if (this.poiDetailInfo.length > 0) {
              Text(this.poiDetailInfo).fontSize(13).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 4 })
            }
            if (this.poiDetailAddr.length > 0) {
              Text('📍 ' + this.poiDetailAddr).fontSize(12).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 2 })
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .width('86%').padding(12)
          .backgroundColor(getTheme(this.themeMode).surface).borderRadius(14)
          .shadow({ radius: 8, color: '#20000000', offsetY: 2 })
          .position({ x: '7%', y: '60%' }).zIndex(20)
          .onClick(() => { this.showPoiDetail = false; })
        }

        // 历史对话面板
        if (this.showHistory) {
          Column() {
            Column() {}.width('100%').layoutWeight(1)
              .onClick(() => { this.showHistory = false; })
            Column() {
              Row() {
                Text('📋 历史对话').fontSize(15).fontWeight(FontWeight.Bold)
                  .fontColor(getTheme(this.themeMode).textPrimary)
                Blank()
                Text('✕').fontSize(16).fontColor(getTheme(this.themeMode).textSecondary)
                  .onClick(() => { this.showHistory = false; })
              }.width('100%').margin({ bottom: 10 })
              if (this.historyList.length === 0) {
                Text('暂无历史对话').fontSize(13).fontColor(getTheme(this.themeMode).textSecondary)
              } else {
                Scroll() {
                  Column() {
                    ForEach(this.historyList, (item: TourHistoryItem) => {
                      Row() {
                        Column() {
                          Text(item.title).fontSize(14).fontColor(getTheme(this.themeMode).textPrimary).maxLines(1)
                          Text(item.date).fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 2 })
                        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                        Text('›').fontSize(18).fontColor(getTheme(this.themeMode).textTertiary)
                      }
                      .width('100%').padding({ top: 12, bottom: 12 })
                      .border({ width: { bottom: 0.5 }, color: getTheme(this.themeMode).border })
                      .onClick(async () => {
                        await this.loadFromHistory(item.id);
                        this.showHistory = false;
                      })
                    })
                  }
                }.height(300)
              }
            }
            .padding(16).backgroundColor(getTheme(this.themeMode).surface)
            .borderRadius({ topLeft: 14, topRight: 14 })
            .shadow({ radius: 8, color: '#20000000', offsetY: -2 })
          }
          .width('100%').height('100%')
          .position({ x: 0, y: 0 }).zIndex(200)
          .backgroundColor('#80000000')
        }
      }
      .width('100%').layoutWeight(1)

      // AI 聊天面板
      Column() {
        Row() {
          Text('🤖 小途 · 旅游规划师').fontSize(13).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
          Blank()
          Button('历史').fontSize(11).fontColor('#3B82F6').height(24).padding({ left: 8, right: 8 })
            .backgroundColor('#EBF3FF').borderRadius(10)
            .onClick(async () => {
              this.historyList = await loadHistoryList();
              this.showHistory = true;
            })
          Button('新对话').fontSize(11).fontColor('#FFFFFF').height(24).padding({ left: 8, right: 8 })
            .backgroundColor('#10B981').borderRadius(10).margin({ left: 6 })
            .onClick(async () => {
              await saveToHistory(this.plan, this.chatMessages);
              this.agent.reset();
              this.plan = null;
              this.isAiThinking = false;
              this.selectedDayIndex = 0;
              this.chatMessages = [
                { role: 'ai', content: '你好！我是小途 🗺️\n想规划一次旅行吗？告诉我目的地和天数，我帮你安排！比如"想去成都玩3天"。' }
              ];
              this.saveState();
              try { Dao.getInstance().upsertUserProfile('tour_plan', '', 0); } catch (_e) { /* ignore */ }
              try { Dao.getInstance().upsertUserProfile('tour_chat', '', 0); } catch (_e) { /* ignore */ }
              this.clearPlanOverlays();
              this.clearCurrentMarkers();
              this.quickReplies = [];
              this.transportOptions = [];
              this.selectedDayIndex = 0;
            })
          if (this.isAiThinking) {
            LoadingProgress().width(14).height(14).color('#8B5CF6')
            Button('⏹ 停止').fontSize(10).fontColor('#FF5252').height(22).padding({ left: 6, right: 6 })
              .backgroundColor('#FFF0F0').borderRadius(6).margin({ left: 6 })
              .onClick(() => {
                this.stopRequested = true;
                this.isAiThinking = false;
                this.isStopping = true;
                this.chatMessages.push({ role: 'ai', content: '⏹ 已停止生成。' });
                this.chatScroller.scrollEdge(Edge.Bottom);
              })
          }
        }.width('100%').margin({ bottom: 4 })
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 3 })
            .onActionStart(() => {
              this.chatDragStartH = this.chatScrollHeight;
            })
            .onActionUpdate((event: GestureEvent) => {
              const newH: number = this.chatDragStartH - event.offsetY;
              this.chatScrollHeight = Math.max(80, Math.min(350, newH));
            })
            .onActionEnd(() => {
              this.chatScrollHeight = Math.max(80, Math.min(350, this.chatScrollHeight));
            })
        )

        // 拖拽手柄（视觉提示，按住上下拖动调整聊天框高度）
        Row()
          .width(36).height(5).borderRadius(2.5)
          .backgroundColor('#C0C0C0')
          .alignSelf(ItemAlign.Center)
          .margin({ top: 2, bottom: 2 })

        Scroll(this.chatScroller) {
          Column() {
            ForEach(this.chatMessages, (bubble: ChatBubble) => {
              Row() {
                if (bubble.role === 'user') {
                  Blank()
                  Text(bubble.content).fontSize(12).fontColor('#FFFFFF')
                    .padding(8).backgroundColor('#8B5CF6').borderRadius(10)
                    .maxLines(20).constraintSize({ maxWidth: '80%' })
                } else {
                  Text(bubble.content).fontSize(12).fontColor(getTheme(this.themeMode).textPrimary)
                    .padding(8).backgroundColor(isDarkTheme() ? '#3A3A3C' : '#F0F2F5').borderRadius(10)
                    .maxLines(25).constraintSize({ maxWidth: '85%' })
                  Blank()
                }
              }.width('100%').margin({ bottom: 6 })
            })
          }
        }.height(this.chatScrollHeight).margin({ bottom: 4 })

        if (this.quickReplies.length > 0) {
          Scroll() {
            Row() {
              ForEach(this.quickReplies, (label: string) => {
                Text(label)
                  .fontSize(12).fontColor(getTheme(this.themeMode).textPrimary)
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .backgroundColor(isDarkTheme() ? '#3A3A3C' : '#F0F2F5').borderRadius(14)
                  .margin({ right: 6 })
                  .onClick(() => { this.onQuickReply(label); })
              })
            }.padding({ left: 4, right: 4 })
          }.scrollable(ScrollDirection.Horizontal).height(36).margin({ bottom: 6 })
        }

        // 交通方案选择列表
        if (this.transportOptions.length > 0) {
          Column() {
            Row() {
              Text('🚄 交通方案').fontSize(12).fontWeight(FontWeight.Bold)
                .fontColor(getTheme(this.themeMode).textPrimary)
              Blank()
              Text('✕').fontSize(14).fontColor(getTheme(this.themeMode).textSecondary)
                .onClick(() => { this.transportOptions = []; })
            }.width('100%').margin({ bottom: 4 })
            Scroll() {
              Column() {
                ForEach(this.transportOptions, (opt: IntercityTransportOption, idx: number) => {
                  Column() {
                    Row() {
                      Text(getTransportEmoji(opt.type)).fontSize(18).margin({ right: 8 })
                      Column() {
                        Text(opt.trip || getTransportLabel(opt.type))
                          .fontSize(13).fontWeight(FontWeight.Medium)
                          .fontColor(getTheme(this.themeMode).textPrimary)
                        Row() {
                          Text(opt.fromStation).fontSize(11).fontColor(getTheme(this.themeMode).textSecondary)
                          Text(' → ').fontSize(11).fontColor(getTheme(this.themeMode).textTertiary)
                          Text(opt.toStation).fontSize(11).fontColor(getTheme(this.themeMode).textSecondary)
                        }
                        if (opt.departureTime) {
                          Text(`${opt.departureTime} → ${opt.arrivalTime}`)
                            .fontSize(10).fontColor(getTheme(this.themeMode).textTertiary)
                        }
                      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                      Column() {
                        if (opt.price > 0) {
                          Text(`¥${opt.price}`).fontSize(13).fontWeight(FontWeight.Bold)
                            .fontColor('#F59E0B')
                        }
                        if (opt.duration > 0) {
                          Text(`约${this.fmtDur(opt.duration)}h`)
                            .fontSize(10).fontColor(getTheme(this.themeMode).textSecondary)
                        }
                      }.alignItems(HorizontalAlign.End)
                      Text('›').fontSize(18).fontColor(getTheme(this.themeMode).textTertiary)
                        .margin({ left: 6 })
                    }
                  }
                  .width('100%').padding(8)
                  .backgroundColor(getTheme(this.themeMode).surface)
                  .border({ width: { bottom: 0.5 }, color: getTheme(this.themeMode).border })
                  .onClick(() => {
                    this.selectTransportOption(opt);
                })
                })
              }
            }.height(this.transportOptions.length > 3 ? 180 : (this.transportOptions.length * 60 + 8)).margin({ bottom: 6 })
          }
          .padding(8).backgroundColor(isDarkTheme() ? '#1E2A45' : '#F0F7FF')
          .borderRadius(10).margin({ bottom: 6 })
          .border({ width: 0.5, color: '#3B82F640' })
        }

        Row() {
          TextInput({ placeholder: '告诉小途你的旅行计划...', text: this.chatInput })
            .fontSize(13).fontColor(getTheme(this.themeMode).textPrimary).placeholderColor(getTheme(this.themeMode).textTertiary).height(34).layoutWeight(1)
            .backgroundColor(getTheme(this.themeMode).surfaceSecondary).borderRadius(17).padding({ left: 12, right: 12 })
            .onChange((v: string) => { this.chatInput = v; })
          Button('发送')
            .fontSize(12).height(34).padding({ left: 12, right: 12 })
            .backgroundColor('#8B5CF6').borderRadius(17)
            .onClick(() => { this.sendMessage(); })
        }.width('100%')
      }
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor(getTheme(this.themeMode).surface)
      .border({ width: { top: 0.5 }, color: '#E8E8E8' })
    }
    .width('100%').height('100%')
  }

  async loadFromHistory(id: string): Promise<void> {
    try {
      const dao = Dao.getInstance();
      const raw = await dao.queryUserProfile('tour_history_' + id);
      if (raw && raw.preferenceValue) {
        const saved: Record<string, Object> = JSON.parse(raw.preferenceValue) as Record<string, Object>;
        const savedPlan: TourPlan | null = (saved['plan'] as TourPlan) ?? null;
        const savedChat: ChatBubble[] = (saved['messages'] as ChatBubble[]) ?? [];
        if (savedPlan) {
          this.plan = migrateTourPlan(savedPlan);
          this.agent.setPlan(JSON.parse(JSON.stringify(this.plan)) as TourPlan);
          g_planState.plan = this.plan;
          await dao.upsertUserProfile('tour_plan', JSON.stringify(this.plan), 1);
        }
        if (savedChat.length > 0) {
          this.chatMessages = savedChat;
          g_planState.messages = savedChat;
          await dao.upsertUserProfile('tour_chat', JSON.stringify(savedChat), 1);
        }
        this.isAiThinking = false;
        if (this.isMapReady && this.plan && this.plan.dailyPlans.length > 0) {
          this.drawPlanOnMap(this.plan);
        }
      }
    } catch (e) {
      Logger.error(TAG, 'loadFromHistory failed: %{public}s', JSON.stringify(e));
    }
  }
}
