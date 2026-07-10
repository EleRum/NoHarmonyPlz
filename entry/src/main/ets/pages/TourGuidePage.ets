/**
 * 导游页 — 全屏地图 + AI 导游规划
 * AI 一步步收集信息、搜酒店、规划每日行程、生成路线图
 */
import { webview } from '@kit.ArkWeb';
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
import { TourPlan, TourDay } from '../model/TourPlan';
import { UserBasicInfo } from '../model/UserBasicInfo';
import { Dao } from '../database/Dao';

const TAG = 'TourGuidePage';
const DEFAULT_CENTER: LatLng = { latitude: 39.9042, longitude: 116.3974 };

interface ChatBubble {
  role: 'user' | 'ai';
  content: string;
}

const ROUTE_COLORS: string[] = ['#3B82F6', '#10B981', '#F59E0B', '#EF4444', '#8B5CF6', '#EC4899', '#06B6D4'];

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
  private quickReplyPoiData: PoiResult[] = [];
  private dayPolylines: string[] = [];
  private dayMarkers: string[][] = [];
  private pendingToolCall: ToolCall | null = null;
  private markerPoiMap: Record<string, PoiResult> = {};

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
          this.plan = JSON.parse(saved.preferenceValue) as TourPlan;
          g_planState.plan = this.plan;
        }
        const savedChat = await dao.queryUserProfile('tour_chat');
        if (savedChat && savedChat.preferenceValue) {
          this.chatMessages = JSON.parse(savedChat.preferenceValue) as ChatBubble[];
          g_planState.messages = this.chatMessages;
        }
      } catch (_e) { /* ignore */ }
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
  }

  private saveState(): void {
    g_planState.plan = this.plan;
    g_planState.messages = this.chatMessages;
    // 持久化到数据库，杀进程后也能恢复
    try {
      const dao = Dao.getInstance();
      if (this.plan && this.plan.dailyPlans.length > 0) {
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
        // 从持久状态恢复计划时，重新绘制地图
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
  }

  /** 发送消息 */
  async sendMessage(): Promise<void> {
    const input: string = this.chatInput.trim();
    if (!input || this.isAiThinking) return;

    this.chatMessages.push({ role: 'user', content: input });
    this.chatInput = '';
    this.quickReplies = [];
    this.saveState();
    this.isAiThinking = true;

    try {
      const resp: AgentResponse = await this.agent.process(input);

      if (resp.toolCall) {
        // AI 需要执行工具 → 显示提示，自动执行，再继续
        this.chatMessages.push({
          role: 'ai',
          content: resp.text + '\n\n🔍 正在查找...'
        });
        await this.autoExecuteTool(resp.toolCall);
      } else {
        this.chatMessages.push({ role: 'ai', content: resp.text });
        if (resp.plan) {
          this.plan = resp.plan;
          this.drawPlanOnMap(resp.plan);
        }
      }
    } catch (_e) {
      this.chatMessages.push({ role: 'ai', content: '抱歉，出错了。请再试一次。' });
    }
    this.isAiThinking = false;
  }

  /** 自动执行工具调用并继续对话
   *  第一阶段：执行工具 → 立即更新地图（不等待 AI）
   *  第二阶段：询问 AI 下一步 → 继续链式调用 */
  async autoExecuteTool(toolCall: ToolCall): Promise<void> {
    try {
      const params: Record<string, string> = {};
      if (toolCall.keywords) params['keywords'] = toolCall.keywords;
      if (toolCall.city) params['city'] = toolCall.city;
      if (toolCall.hotel) params['hotel'] = toolCall.hotel;
      if (toolCall.hotelLat) params['hotelLat'] = toolCall.hotelLat;
      if (toolCall.hotelLng) params['hotelLng'] = toolCall.hotelLng;
      if (toolCall.days) params['days'] = toolCall.days;
      if (toolCall.dayIndex) params['dayIndex'] = toolCall.dayIndex;
      if (toolCall.poiIndex) params['poiIndex'] = toolCall.poiIndex;
      if (toolCall.name) params['name'] = toolCall.name;
      if (toolCall.lat) params['lat'] = toolCall.lat;
      if (toolCall.lng) params['lng'] = toolCall.lng;
      if (toolCall.type) params['type'] = toolCall.type;
      if (toolCall.timeSlot) params['timeSlot'] = toolCall.timeSlot;
      if (toolCall.note) params['note'] = toolCall.note;
      if (toolCall.mode) params['mode'] = toolCall.mode;

      // 第一阶段：执行工具（快速，不等待 AI）
      const resp: AgentResponse = await this.agent.executeToolAndContinue(toolCall.action, params);

      // 立即更新地图 — 不等 AI 回复
      if (resp.plan && resp.plan.dailyPlans.length > 0) {
        this.plan = resp.plan;
        this.saveState();
        this.clearCurrentMarkers();
        this.drawPlanOnMap(resp.plan);
      }
      if (this.isMapReady && this.mapService) {
        if (resp.mapCenter) {
          this.mapCenter = resp.mapCenter;
          this.mapService.moveCamera(resp.mapCenter, 13);
        }
        if (resp.markers && resp.markers.length > 0) {
          this.showMarkersOnMap(resp.markers);
        }
        this.updateQuickReplies(resp.markers || [], toolCall.action);
      }

      // 第二阶段：询问 AI 下一步（可能较慢，但不阻塞地图更新）
      const aiResp = await this.agent.askAiNextStep(toolCall.action, resp.text);
      const nextTool: ToolCall | undefined = aiResp.toolCall;

      // 替换占位消息并显示 AI 回复
      if (this.chatMessages.length > 0) {
        const last = this.chatMessages[this.chatMessages.length - 1];
        if (last.content.includes('🔍')) {
          this.chatMessages = this.chatMessages.slice(0, -1);
        }
      }
      this.chatMessages.push({ role: 'ai', content: aiResp.text });

      // 继续下一工具
      if (nextTool) {
        this.chatMessages.push({ role: 'ai', content: '🔍 ' + nextTool.action + '...' });
        await this.autoExecuteTool(nextTool);
      }
    } catch (e) {
      Logger.error(TAG, 'autoExecuteTool failed for %{public}s: %{public}s',
        toolCall.action, JSON.stringify(e));
      this.chatMessages.push({ role: 'ai', content: '😅 ' + toolCall.action + '执行出错，请再试一次。' });
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
      this.quickReplies = ['加景点', '加美食', '改酒店', '删景点'];
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

  /** 点击快捷回复 */
  onQuickReply(reply: string): void {
    if (reply === '🔄 换一批') {
      this.chatInput = '换一批';
      this.sendMessage();
      return;
    }
    this.chatInput = reply;
    this.sendMessage();
  }

  private drawGeneration: number = 0;

  /** 在地图上绘制计划路线
   *  标记立即显示，路线在后台计算完成后更新 */
  async drawPlanOnMap(plan: TourPlan): Promise<void> {
    const ms = this.mapService;
    if (!ms || !this.isMapReady) return;

    // 递增代数，使之前未完成的 Phase 2 失效
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
        const emoji: string = this.poiEmoji(poi.type);
        const markerId: string = ms.addMarker({
          position: { latitude: poi.lat, longitude: poi.lng },
          iconStyle: { color: color, size: 20, text: emoji },
          title: poi.name,
          snippet: poi.timeSlot,
          clickable: true,
          zIndex: 60,
        });
        markers.push(markerId);
        this.markerPoiMap[markerId] = {
          name: poi.name, type: poi.type, latitude: poi.lat, longitude: poi.lng,
          address: poi.note || '', distance: 0, tel: '', id: ''
        } as PoiResult;
      }
      this.dayMarkers.push(markers);

      if (day.route && day.route.path.length > 0) {
        const polyId: string = ms.addPolyline({
          points: day.route.path, color: color, width: 6, zIndex: 50, clickable: false,
        });
        this.dayPolylines.push(polyId);
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
      // 检查代数：如果期间有新绘制启动，放弃本次结果
      if (gen !== this.drawGeneration) return;
      if (allPts.length > 0) {
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
    if (type.includes('景点') || type.includes('公园') || type.includes('风景')) return '🏛️';
    if (type.includes('购物') || type.includes('商场')) return '🛍️';
    if (type.includes('咖啡') || type.includes('茶')) return '☕';
    return '📍';
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

        if (!this.isMapReady) {
          Column() {
            LoadingProgress().width(32).height(32).color('#10B981')
            Text('地图加载中...').fontSize(13).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 8 })
          }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor(getTheme(this.themeMode).surfaceSecondary)
        }

        // 日选择器（有计划时显示）
        if (this.plan && this.plan.dailyPlans.length > 0) {
          Row() {
            Scroll() {
              Row() {
                ForEach(this.plan.dailyPlans, (day: TourDay, idx: number) => {
                  Text(day.label || `第${idx + 1}天`)
                    .fontSize(12).fontColor(idx === this.selectedDayIndex ? '#FFF' : '#666')
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .backgroundColor(idx === this.selectedDayIndex ? '#10B981' : '#FFFFFF')
                    .borderRadius(12)
                    .onClick(() => { this.selectDay(idx); })
                }, (day: TourDay, idx: number): string => `${idx}_${day.label}`)
              }
            }.scrollable(ScrollDirection.Horizontal)
          }
          .width('100%').padding({ left: 8, right: 8, top: 8 })
          .position({ x: 0, y: 0 }).zIndex(10)
        }

        // 行程卡片
        if (this.plan && this.plan.dailyPlans.length > 0) {
          Column() {
            Text(this.plan.dailyPlans[this.selectedDayIndex].label + ' 行程')
              .fontSize(13).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary).margin({ bottom: 4 })
            Scroll() {
              Row() {
                ForEach(this.plan.dailyPlans[this.selectedDayIndex].pois, (poi: import('../model/TourPlan').TourPoiItem, pidx: number) => {
                  Column() {
                    Text(this.poiEmoji(poi.type)).fontSize(20)
                    Text(poi.name).fontSize(9).fontColor(getTheme(this.themeMode).textSecondary).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(poi.timeSlot).fontSize(8).fontColor(getTheme(this.themeMode).textSecondary)
                  }
                  .width(72).padding(4).alignItems(HorizontalAlign.Center)
                }, (poi: import('../model/TourPlan').TourPoiItem, pidx: number): string => `${pidx}_${poi.name}_${poi.timeSlot}`)
              }
            }.scrollable(ScrollDirection.Horizontal).height(64)
          }
          .width('90%').padding(8)
          .backgroundColor('#CCFFFFFF').borderRadius(12)
          .position({ x: '5%', y: 40 }).zIndex(10)
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
      }
      .width('100%').layoutWeight(1)

      // AI 聊天面板
      Column() {
        Row() {
          Text('🤖 小途 · 旅游规划师').fontSize(13).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
          Blank()
          Button('清空').fontSize(11).fontColor('#FFFFFF').height(24).padding({ left: 8, right: 8 })
            .backgroundColor('#FF5252').borderRadius(10)
            .onClick(() => {
              this.agent.reset();
              this.plan = null;
              this.chatMessages = [
                { role: 'ai', content: '你好！我是小途 🗺️\n想规划一次旅行吗？告诉我目的地和天数，我帮你安排！比如"想去成都玩3天"。' }
              ];
              this.saveState();
              try { Dao.getInstance().upsertUserProfile('tour_plan', '', 0); } catch (_e) { /* ignore */ }
              try { Dao.getInstance().upsertUserProfile('tour_chat', '', 0); } catch (_e) { /* ignore */ }
              this.clearPlanOverlays();
              this.clearCurrentMarkers();
              this.quickReplies = [];
              this.selectedDayIndex = 0;
            })
          if (this.isAiThinking) {
            LoadingProgress().width(14).height(14).color('#10B981')
          }
        }.width('100%').margin({ bottom: 4 })

        Scroll() {
          Column() {
            ForEach(this.chatMessages, (bubble: ChatBubble) => {
              Row() {
                if (bubble.role === 'user') {
                  Blank()
                  Text(bubble.content).fontSize(12).fontColor('#FFFFFF')
                    .padding(8).backgroundColor('#10B981').borderRadius(10)
                    .maxLines(20).constraintSize({ maxWidth: '80%' })
                } else {
                  Text(bubble.content).fontSize(12).fontColor(getTheme(this.themeMode).textPrimary)
                    .padding(8).backgroundColor(isDarkTheme() ? '#1A2E24' : '#F0FDF4').borderRadius(10)
                    .maxLines(25).constraintSize({ maxWidth: '85%' })
                  Blank()
                }
              }.width('100%').margin({ bottom: 6 })
            })
          }
        }.height(160).margin({ bottom: 4 })

        if (this.quickReplies.length > 0) {
          Scroll() {
            Row() {
              ForEach(this.quickReplies, (label: string) => {
                Text(label)
                  .fontSize(12).fontColor('#10B981')
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .backgroundColor(isDarkTheme() ? '#1A2E24' : '#F0FDF4').borderRadius(14)
                  .border({ width: 1, color: '#10B98140' })
                  .margin({ right: 6 })
                  .onClick(() => { this.onQuickReply(label); })
              })
            }.padding({ left: 4, right: 4 })
          }.scrollable(ScrollDirection.Horizontal).height(36).margin({ bottom: 6 })
        }

        Row() {
          TextInput({ placeholder: '告诉小途你的旅行计划...', text: this.chatInput })
            .fontSize(13).height(34).layoutWeight(1)
            .backgroundColor(getTheme(this.themeMode).surfaceSecondary).borderRadius(17).padding({ left: 12, right: 12 })
            .onChange((v: string) => { this.chatInput = v; })
          Button('发送')
            .fontSize(12).height(34).padding({ left: 12, right: 12 })
            .backgroundColor('#10B981').borderRadius(17)
            .onClick(() => { this.sendMessage(); })
        }.width('100%')
      }
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor(getTheme(this.themeMode).surface)
      .border({ width: { top: 0.5 }, color: '#E8E8E8' })
    }
    .width('100%').height('100%')
  }
}
