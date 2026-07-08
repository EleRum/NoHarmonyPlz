/**
 * 导游页 — 全屏地图 + AI 导游规划
 * AI 一步步收集信息、搜酒店、规划每日行程、生成路线图
 */
import { webview } from '@kit.ArkWeb';
import { MapWebView } from '../services/map/MapWebView';
import { Logger } from '../common/Logger';
import { TourGuideAgent, AgentResponse, ToolCall } from '../services/TourGuideAgent';
import { AmapSearchService } from '../services/map/AmapSearchService';
import { MapEventCallbacks } from '../services/map/IMapService';
import { MapJsBridge } from '../services/map/MapJsBridge';
import {
  LatLng, MapInitConfig, NavRoute, DirectionMode
} from '../services/map/MapTypes';
import { TourPlan, TourDay } from '../model/TourPlan';

const TAG = 'TourGuidePage';
const DEFAULT_CENTER: LatLng = { latitude: 39.9042, longitude: 116.3974 };

interface ChatBubble {
  role: 'user' | 'ai';
  content: string;
}

const ROUTE_COLORS: string[] = ['#3B82F6', '#10B981', '#F59E0B', '#EF4444', '#8B5CF6', '#EC4899', '#06B6D4'];

@Component
export struct TourGuideContent {
  private mapService: MapJsBridge | null = null;
  private agent: TourGuideAgent = new TourGuideAgent();
  @State mapCenter: LatLng = DEFAULT_CENTER;
  @State mapZoom: number = 12;
  @State isMapReady: boolean = false;
  @State chatInput: string = '';
  @State chatMessages: ChatBubble[] = [];
  @State isAiThinking: boolean = false;
  @State plan: TourPlan | null = null;
  @State selectedDayIndex: number = 0;
  private dayPolylines: string[] = [];
  private dayMarkers: string[][] = [];
  private pendingToolCall: ToolCall | null = null;

  aboutToAppear(): void {
    this.chatMessages = [
      { role: 'ai', content: '你好！我是小途 🗺️\n想规划一次旅行吗？告诉我目的地和天数，我帮你安排！比如"想去成都玩3天"。' }
    ];
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

  /** 自动执行工具调用并继续对话 */
  async autoExecuteTool(toolCall: ToolCall): Promise<void> {
    const params: Record<string, string> = {};
    if (toolCall.keywords) params['keywords'] = toolCall.keywords;
    if (toolCall.city) params['city'] = toolCall.city;
    if (toolCall.hotel) params['hotel'] = toolCall.hotel;
    if (toolCall.hotelLat) params['hotelLat'] = toolCall.hotelLat;
    if (toolCall.hotelLng) params['hotelLng'] = toolCall.hotelLng;

    const resp: AgentResponse = await this.agent.executeToolAndContinue(toolCall.action, params);

    // 替换占位消息
    if (this.chatMessages.length > 0) {
      const last = this.chatMessages[this.chatMessages.length - 1];
      if (last.content.includes('🔍')) {
        this.chatMessages = this.chatMessages.slice(0, -1);
      }
    }
    this.chatMessages.push({ role: 'ai', content: resp.text });

    // 每步地图更新
    if (this.isMapReady && this.mapService) {
      // 移动地图
      if (resp.mapCenter) {
        this.mapCenter = resp.mapCenter;
        this.mapService.moveCamera(resp.mapCenter, 13);
      }
      // 添加标记（酒店/POI）
      if (resp.markers && resp.markers.length > 0) {
        this.showMarkersOnMap(resp.markers);
      }
    }

    // 完整计划
    if (resp.plan && resp.plan.dailyPlans.length > 0) {
      this.plan = resp.plan;
      this.clearCurrentMarkers();
      this.drawPlanOnMap(resp.plan);
    }

    // 继续下一工具
    if (resp.toolCall) {
      this.chatMessages.push({ role: 'ai', content: '🔍 ' + resp.toolCall.action + '...' });
      await this.autoExecuteTool(resp.toolCall);
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
        clickable: false,
        zIndex: 70,
      });
      this.tempMarkerIds.push(id);
    }
  }

  clearCurrentMarkers(): void {
    if (!this.mapService) return;
    for (const id of this.tempMarkerIds) {
      try { this.mapService.removeMarker(id); } catch (_e) { /* ignore */ }
    }
    this.tempMarkerIds = [];
  }

  /** 在地图上绘制计划路线 */
  async drawPlanOnMap(plan: TourPlan): Promise<void> {
    const ms = this.mapService;
    if (!ms || !this.isMapReady) return;

    // 清除旧路线
    this.clearPlanOverlays();

    // 移动地图到城市
    if (plan.cityLat && plan.cityLng) {
      ms.moveCamera({ latitude: plan.cityLat, longitude: plan.cityLng }, 12);
      this.mapCenter = { latitude: plan.cityLat, longitude: plan.cityLng };
    }

    // 为每天计算并绘制路线
    for (let d: number = 0; d < plan.dailyPlans.length; d++) {
      const day: TourDay = plan.dailyPlans[d];
      const color: string = ROUTE_COLORS[d % ROUTE_COLORS.length];
      const markers: string[] = [];

      // 添加 POI 标记
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
      }

      // 如果已有路线数据，直接绘制
      if (day.route && day.route.path.length > 0) {
        const polyId: string = ms.addPolyline({
          points: day.route.path,
          color: color,
          width: 6,
          zIndex: 50,
          clickable: false,
        });
        this.dayPolylines.push(polyId);
      } else if (day.pois.length >= 2) {
        // 计算路线：串联所有 POI
        const allPts: LatLng[] = [];
        for (let pi: number = 0; pi < day.pois.length - 1; pi++) {
          const a = day.pois[pi];
          const b = day.pois[pi + 1];
          try {
            const route: NavRoute | null = await AmapSearchService.getInstance().directionRouteRest(
              a.lat, a.lng, b.lat, b.lng, DirectionMode.DRIVING
            );
            if (route && route.path.length > 0) {
              for (const pt of route.path) allPts.push(pt);
            }
          } catch (_e) { /* ignore */ }
        }
        if (allPts.length > 0) {
          day.route = { distance: 0, duration: 0, path: allPts, steps: [], origin: '', destination: '' } as NavRoute;
          const polyId: string = ms.addPolyline({
            points: allPts, color: color, width: 6, zIndex: 50, clickable: false,
          });
          this.dayPolylines.push(polyId);
        }
      }
      this.dayMarkers.push(markers);
    }

    // 默认显示第一天
    this.selectedDayIndex = 0;
    this.syncDayVisibility();
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
            Text('地图加载中...').fontSize(13).fontColor('#666').margin({ top: 8 })
          }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor('#F5F5F5')
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
                })
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
              .fontSize(13).fontWeight(FontWeight.Bold).margin({ bottom: 4 })
            Scroll() {
              Row() {
                ForEach(this.plan.dailyPlans[this.selectedDayIndex].pois, (poi: import('../model/TourPlan').TourPoiItem) => {
                  Column() {
                    Text(this.poiEmoji(poi.type)).fontSize(20)
                    Text(poi.name).fontSize(9).fontColor('#666').maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(poi.timeSlot).fontSize(8).fontColor('#999')
                  }
                  .width(72).padding(4).alignItems(HorizontalAlign.Center)
                })
              }
            }.scrollable(ScrollDirection.Horizontal).height(64)
          }
          .width('90%').padding(8)
          .backgroundColor('#CCFFFFFF').borderRadius(12)
          .position({ x: '5%', y: 40 }).zIndex(10)
        }
      }
      .width('100%').layoutWeight(1)

      // AI 聊天面板
      Column() {
        Row() {
          Text('🤖 小途 · 旅游规划师').fontSize(13).fontWeight(FontWeight.Bold)
          Blank()
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
                  Text(bubble.content).fontSize(12).fontColor('#333')
                    .padding(8).backgroundColor('#F0FDF4').borderRadius(10)
                    .maxLines(25).constraintSize({ maxWidth: '85%' })
                  Blank()
                }
              }.width('100%').margin({ bottom: 6 })
            })
          }
        }.height(160).margin({ bottom: 4 })

        Row() {
          TextInput({ placeholder: '告诉小途你的旅行计划...', text: this.chatInput })
            .fontSize(13).height(34).layoutWeight(1)
            .backgroundColor('#F5F5F5').borderRadius(17).padding({ left: 12, right: 12 })
            .onChange((v: string) => { this.chatInput = v; })
          Button('发送')
            .fontSize(12).height(34).padding({ left: 12, right: 12 })
            .backgroundColor('#10B981').borderRadius(17)
            .onClick(() => { this.sendMessage(); })
        }.width('100%')
      }
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor('#FFFFFF')
      .border({ width: { top: 0.5 }, color: '#E8E8E8' })
    }
    .width('100%').height('100%')
  }
}
