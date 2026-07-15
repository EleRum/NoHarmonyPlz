/**
 * Footprint Map Page
 * Data-first: show footprints on open, switch when map ready
 * Uses IMapService/MapJsBridge for cross-platform map operations
 */
import { Logger } from '../common/Logger';
import router from '@ohos.router';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { MapWebView } from '../services/map/MapWebView';
import { geoLocationManager } from '@kit.LocationKit';
import { checkServicesStatus, isAllServicesReady, ServiceStatus } from '../common/DeviceCheckUtils';
import { GpsNetworkDialog } from '../common/GpsNetworkDialog';
import { UserBasicInfo } from '../model/UserBasicInfo';
import { Footprint } from '../model/Footprint';
import { ActivitySegment } from '../model/ActivitySegment';
import { Dao } from '../database/Dao';
import { formatTimestamp, haversineDistance } from '../common/LocationUtils';
import { ActivityClassifier } from '../services/ActivityClassifier';
import { ACTIVITY_LABELS } from '../common/Constants';
import { ProfileRefreshSignal, RecRefreshSignal, MapMarkerSignal } from '../common/TravelPreferenceTags';
import { TimelineContent } from './TimelinePage';
import { TravelJournalContent } from './TravelJournalPage';
import { TourGuideContent } from './TourGuidePage';
import { ProfileContent } from './ProfilePage';
import { getTheme, isDarkTheme, FONT, RADIUS, SPACE } from '../common/Theme';
import { AgentScheduler } from '../services/AgentScheduler';
import { RecommendationEngine } from '../services/RecommendationEngine';
import { AmapSearchService } from '../services/map/AmapSearchService';
import { Recommendation } from '../model/Recommendation';
import { AiAgent, AgentReply } from '../services/AiAgent';
import { CalibrationService } from '../services/CalibrationService';
import { CalibrationSignal } from '../common/CalibrationSignal';
import { IMapService, MapEventCallbacks } from '../services/map/IMapService';
import { MapJsBridge } from '../services/map/MapJsBridge';
import {
  LatLng, LatLngBounds, MarkerIconStyle, MapInitConfig,
  DirectionMode, NavRoute, NavStep, PoiResult
} from '../services/map/MapTypes';

const TAG = 'MapPage';
const DEFAULT_CENTER: LatLng = { latitude: 39.9042, longitude: 116.3974 };

const ROUTE_COLORS: string[] = [
  '#3B82F6', '#10B981', '#F59E0B',
  '#EF4444', '#8B5CF6', '#EC4899', '#06B6D4',
];

const SPEED_GRADIENT: Array<[number, string]> = [
  [0, '#10B981'],
  [1.5, '#84CC16'],
  [3.0, '#F59E0B'],
  [5.0, '#F97316'],
  [8.0, '#EF4444'],
];

function speedColor(speedMs: number): string {
  if (speedMs <= 0) return SPEED_GRADIENT[0][1];
  for (let i = SPEED_GRADIENT.length - 1; i >= 0; i--) {
    if (speedMs >= SPEED_GRADIENT[i][0]) return SPEED_GRADIENT[i][1];
  }
  return SPEED_GRADIENT[0][1];
}

interface DayRoute {
  dayKey: string;
  footprints: Footprint[];
  totalDistance: number;
  startTime: number;
  endTime: number;
}

interface SegmentCalibrationInfo {
  segmentStartTime: number;
  segmentEndTime: number;
  dayKey: string;
  activityTag: string;
  poiName: string;
}

interface ChatBubble {
  role: 'user' | 'ai';
  content: string;
}

@Entry
@Component
export struct MapPage {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  private mapService: IMapService | null = null;
  @State mapCenter: LatLng = DEFAULT_CENTER;
  @State mapZoom: number = 15;
  @State isMapReady: boolean = false;
  @State locationReady: boolean = false;
  @State footprintCount: number = 0;
  @State currentTab: number = 0;
  @State footprints: Footprint[] = [];
  @State segments: ActivitySegment[] = [];
  @State dayRoutes: DayRoute[] = [];
  @State todayDistance: number = 0;
  @State todayDuration: number = 0;
  @State selectedDayIndex: number = 0;
  @State isViewingToday: boolean = true;
  @State selectedWaypoint: Footprint | null = null;
  @State showBubble: boolean = false;
  @State bubbleX: number = 0;
  @State bubbleY: number = 0;
  private markerMap: Record<string, Footprint> = {};
  private markerPositions: Record<string, LatLng> = {};
  private segmentInfoMap: Record<string, SegmentCalibrationInfo> = {};  // 段校准信息，按位置键索引
  private liveMarker: string | null = null;
  private liveTail: string | null = null;
  private liveTrailSegments: string[] = [];  // GPS 轨迹红线片段
  private dayPolylines: string[] = [];
  private dayPoiMarkers: string[][] = [];
  private daySegMarkers: string[][] = [];
  private segMarkers: string[] = [];
  @State showRecMarkers: boolean = false;
  @State showRecPicker: boolean = false;
  @State showChat: boolean = false;
  @State chatInput: string = '';
  @State chatMessages: ChatBubble[] = [
    { role: 'ai', content: '你好！我是足迹助手，可以帮你修正活动类型、查询数据。试试说"帮助"。' }
  ];
  @State isAiThinking: boolean = false;
  @State chatScrollHeight: number = 200;
  private chatDragStartH: number = 0;
  private chatScroller: Scroller = new Scroller();
  @State timelineRefreshKey: number = 0;
  // ─── 导航状态 ───
  @State showNavigation: boolean = false;
  @State navSearchQuery: string = '';
  @State navSearchResults: PoiResult[] = [];
  @State navIsSearching: boolean = false;
  @State navRoute: NavRoute | null = null;
  @State navMode: DirectionMode = DirectionMode.DRIVING;
  @State navIsCalculating: boolean = false;
  @State navSelectedStepIndex: number = -1;
  @State navOriginLat: number = 0;
  @State navOriginLng: number = 0;
  @State navOriginName: string = '当前位置';
  // ─── Settings 页面刷新信号 ───
  @State settingsProfileRefreshKey: number = 0;
  private lastKnownProfileRefreshCounter: number = 0;
  private lastKnownRecRefreshCounter: number = 0;
  private lastKnownMapMarkerCounter: number = 0;
  private lastThemeDark: boolean = false;
  private navRoutePolylineId: string = '';
  private navStartMarkerId: string = '';
  private navEndMarkerId: string = '';
  private lastProcessedCalTs: number = 0;
  private calPoller: number | null = null;
  private aiAgent: AiAgent | null = null;
  // ─── GPS/网络检测弹窗 ───
  private dialogController: CustomDialogController | null = null;
  private serviceDialogDismissed: boolean = false;
  // ─── 用户信息（供 AI agent 上下文使用）───
  private agentUserName: string = '';
  private agentUserCity: string = '';
  private agentUserPrefs: string = '';

  private getAiAgent(): AiAgent {
    if (!this.aiAgent) this.aiAgent = new AiAgent(this.dao);
    return this.aiAgent;
  }
  private recMarkers: string[] = [];
  private recDataMap: Record<string, Recommendation> = {};
  private recGroupMap: Record<string, Recommendation[]> = {};
  private positionDotStyle: MarkerIconStyle = { color: '#3B82F6', size: 27 };
  private recDotStyle: MarkerIconStyle = { color: '#FFB800', size: 36 };
  private dao: Dao = Dao.getInstance();

  /** 每次绘制后同步所有元素的可见性 */
  syncDayVisibility(): void {
    // 确保只有当前选中天的路线和标记可见
    for (let i = 0; i < this.dayPolylines.length; i++) {
      if (this.dayPolylines[i].length === 0) continue;
      try { if (this.mapService) this.mapService.setPolylineVisible(this.dayPolylines[i], i === this.selectedDayIndex); } catch (e) {}
    }
    for (let i = 0; i < this.dayPoiMarkers.length; i++) {
      for (const m of this.dayPoiMarkers[i]) {
        try { if (this.mapService) this.mapService.setMarkerVisible(m, i === this.selectedDayIndex); } catch (e) {}
      }
    }
    for (let i = 0; i < this.daySegMarkers.length; i++) {
      for (const m of this.daySegMarkers[i]) {
        try { if (this.mapService) this.mapService.setMarkerVisible(m, i === this.selectedDayIndex); } catch (e) {}
      }
    }
  }

  /** 切换历史天/今天时，显隐实时元素 + 今日限定内容 */
  toggleLiveElements(visible: boolean): void {
    const ms = this.mapService;
    if (this.liveMarker && ms) {
      try { ms.setMarkerVisible(this.liveMarker, visible); } catch (e) {}
    }
    if (this.liveTail && ms) {
      try { ms.setPolylineVisible(this.liveTail, visible); } catch (e) {}
    }
    for (const id of this.liveTrailSegments) {
      try { if (ms) ms.setPolylineVisible(id, visible); } catch (e) {}
    }
    for (const m of this.segMarkers) {
      try { if (ms) ms.setMarkerVisible(m, visible); } catch (e) {}
    }
    for (const m of this.recMarkers) {
      try { if (ms) ms.setMarkerVisible(m, visible); } catch (e) {}
    }
  }

  /** 切换推荐门店标记显隐 */
  async toggleRecMarkers(): Promise<void> {
    const ms = this.mapService;
    if (!ms) return;
    if (this.showRecMarkers) {
      for (const m of this.recMarkers) {
        try { ms.setMarkerVisible(m, false); } catch (e) {}
      }
      this.showRecMarkers = false;
      return;
    }
    for (const m of this.recMarkers) {
      try { ms.setMarkerVisible(m, false); } catch (e) {}
    }
    try {
      const recs: Recommendation[] = await this.dao.queryRecentRecommendations(20);
      const posGroup: Record<string, Recommendation[]> = {};
      for (const r of recs) {
        if (!r.placeName || r.placeName.length === 0) continue;
        const posKey: string = `${r.latitude.toFixed(6)},${r.longitude.toFixed(6)}`;
        if (!posGroup[posKey]) posGroup[posKey] = [];
        posGroup[posKey].push(r);
      }
      this.recGroupMap = posGroup;
      for (const posKey of Object.keys(posGroup)) {
        const group: Recommendation[] = posGroup[posKey];
        const first: Recommendation = group[0];
        this.recDataMap[posKey] = first;
        const countLabel: string = group.length > 1 ? ` (${group.length}家)` : '';
        const typeEmoji: string = this.activityEmoji(first.placeType || '');
        const markerId: string = ms.addMarker({
          position: { latitude: first.latitude, longitude: first.longitude },
          iconStyle: this.recDotStyle,
          title: '⭐ ' + first.placeName + countLabel,
          snippet: (first.reason || '') + ' | ' + (typeEmoji + ' ' + (this.activityLabel(first.placeType) || first.placeType)),
          clickable: true,
          zIndex: 26
        });
        this.recMarkers.push(markerId);
        this.markerPositions[markerId] = { latitude: first.latitude, longitude: first.longitude };
      }
    } catch (e) { /* ignore */ }
    this.showRecMarkers = true;
  }

  /** 推荐标记点击 → 同位置多家时弹出选择 */
  goRecDetail(markerId: string): void {
    try {
      const pos: LatLng | undefined = this.markerPositions[markerId];
      if (!pos) return;
      const key: string = `${pos.latitude.toFixed(6)},${pos.longitude.toFixed(6)}`;
      const group: Recommendation[] = this.recGroupMap[key] || [];
      if (group.length > 1) {
        this.pickerGroup = group;
        this.showRecPicker = true;
        return;
      }
      const rec: Recommendation | undefined = this.recDataMap[key];
      if (rec) this.openRecDetail(rec);
    } catch (e) {}
  }

  private pickerGroup: Recommendation[] = [];

  openRecDetail(rec: Recommendation): void {
    this.showRecPicker = false;
    router.pushUrl({
      url: 'pages/WaypointDetailPage',
      params: {
        poiName: rec.placeName,
        latitude: rec.latitude,
        longitude: rec.longitude,
        activityTag: rec.placeType,
        timestamp: rec.timestamp,
        stayDuration: 0,
        speed: 0,
        photoList: '',
        isRecommendation: true,
        recReason: rec.reason || '附近热门选择'
      }
    });
  }

  aboutToAppear(): void {
    Logger.info(TAG, 'MapPage aboutToAppear');
    this.loadAllData();
    this.requestLocation();
    // 首次启动检测：无用户资料时进入欢迎引导流程
    this.checkFirstLaunch();
    // 检测 GPS 和网络状态，未开启时弹窗提醒
    this.checkAndShowServiceDialog();
    // 加载用户基础信息，供 AI agent 上下文使用
    this.loadUserInfoForAgent();
    // 启动校准轮询：每2秒检查 WaypointDetailPage 是否发出了校准变更信号
    // 使用模块级变量，不依赖 AppStorage / onPageShow / @Watch（跨版本保证生效）
    this.calPoller = setInterval(() => {
      const result = CalibrationSignal.consume(this.lastProcessedCalTs);
      if (result.hasNew) {
        this.lastProcessedCalTs = result.newTs;
        Logger.info(TAG, 'Calibration poller detected change (ts=%{public}d), refreshing markers', result.newTs);
        this.refreshCalibrationsAndRedraw();
      }
      // 弹窗显示期间，定时重检服务状态（用户可能去设置开启了服务后返回）
      if (this.dialogController !== null && !this.serviceDialogDismissed) {
        this.recheckServicesForDialog();
      }
      // 检测用户资料是否被修改，通知 SettingsPage 刷新
      if (ProfileRefreshSignal.counter !== this.lastKnownProfileRefreshCounter) {
        this.lastKnownProfileRefreshCounter = ProfileRefreshSignal.counter;
        this.settingsProfileRefreshKey++;
      }
      // 检测推荐是否被刷新，更新地图标记
      if (RecRefreshSignal.counter !== this.lastKnownRecRefreshCounter) {
        this.lastKnownRecRefreshCounter = RecRefreshSignal.counter;
        this.refreshMapMarkers();
      }
      // 检测地图标记显隐开关变化
      if (MapMarkerSignal.counter !== this.lastKnownMapMarkerCounter) {
        this.lastKnownMapMarkerCounter = MapMarkerSignal.counter;
        this.applyMapMarkerSetting();
      }
      // 检测深色模式变化 → 切换高德地图样式
      const darkNow: boolean = isDarkTheme();
      if (darkNow !== this.lastThemeDark && this.mapService) {
        this.lastThemeDark = darkNow;
        try {
          this.mapService.setMapStyle(darkNow ? 'amap://styles/dark' : 'amap://styles/light');
          this.mapService.setDarkMode(darkNow);
          Logger.info(TAG, 'Map style switched to %{public}s', darkNow ? 'dark' : 'light');
        } catch (e) {}
      }
    }, 2000);
  }

  aboutToDisappear(): void {
    if (this.calPoller) {
      clearInterval(this.calPoller);
      this.calPoller = null;
    }
    if (this.dialogController) {
      this.dialogController.close();
      this.dialogController = null;
    }
  }

  async loadAllData(): Promise<void> {
    try {
      this.footprints = await this.dao.queryAllFootprintsUnlimited();
      this.footprintCount = this.footprints.length;
      this.segments = await this.dao.queryAllActivitySegments(200);
      // 对已加载的所有段应用校准覆盖（确保地图标记立即反映用户/AI修正）
      await this.applyCalibrationsToAllSegments();
      this.buildDayRoutes();
      if (this.dayRoutes.length > 0) {
        const tKey: string = new Date().toISOString().slice(0, 10).replace(/-/g, '');
        this.isViewingToday = (this.dayRoutes[this.selectedDayIndex].dayKey === tKey);
      }
      Logger.info(TAG, 'Loaded %{public}d footprints, %{public}d routes',
        this.footprintCount, this.dayRoutes.length);
      if (this.isMapReady && this.dayRoutes.length > 0) {
        this.drawOnMap();
        this.drawSegmentMarkers();
        this.syncDayVisibility();
        this.toggleLiveElements(this.isViewingToday);
      }
    } catch (err) { /* ignore */ }
  }

  /** 对所有已加载段按天应用校准覆盖 */
  async applyCalibrationsToAllSegments(): Promise<void> {
    try {
      const calService: CalibrationService = CalibrationService.getInstance();
      // 收集所有 dayKey
      const daySet: Set<string> = new Set<string>();
      for (const seg of this.segments) {
        if (seg.dayKey) daySet.add(seg.dayKey);
      }
      // 按天应用校准
      for (const dk of daySet) {
        await calService.applyCalibrations(this.segments, dk);
      }
      Logger.info(TAG, 'applyCalibrationsToAllSegments: %{public}d days processed', daySet.size);
    } catch (e) {
      Logger.error(TAG, 'applyCalibrationsToAllSegments failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 从其它页返回时刷新校准并重绘标记 */
  async refreshCalibrationsAndRedraw(): Promise<void> {
    try {
      Logger.info(TAG, 'refreshCalibrationsAndRedraw start');
      // 重新查询最新的段数据
      this.segments = await this.dao.queryAllActivitySegments(200);
      Logger.info(TAG, 'Re-queried %{public}d segments from DB', this.segments.length);
      await this.applyCalibrationsToAllSegments();
      // 重建日路线（段数据可能已变）
      this.buildDayRoutes();
      // 重绘标记
      if (this.isMapReady && this.dayRoutes.length > 0) {
        this.clearSegmentMarkers();
        this.drawSegmentMarkers();
        Logger.info(TAG, 'Markers redrawn after calibration refresh');
      } else {
        Logger.warn(TAG, 'Cannot redraw: mapReady=%{public}s routes=%{public}d',
          this.isMapReady ? 'true' : 'false', this.dayRoutes.length);
      }
    } catch (e) {
      Logger.error(TAG, 'refreshCalibrationsAndRedraw failed: %{public}s', JSON.stringify(e));
    }
  }

  buildDayRoutes(): void {
    const groups: Record<string, Footprint[]> = {};
    for (const fp of this.footprints) {
      const dk: string = fp.dayKey || 'unknown';
      if (!groups[dk]) groups[dk] = [];
      groups[dk].push(fp);
    }

    const routes: DayRoute[] = [];
    for (const dk of Object.keys(groups)) {
      const fps: Footprint[] = groups[dk].sort((a, b) => a.timestamp - b.timestamp);
      let dist: number = 0;
      for (let i = 1; i < fps.length; i++) {
        dist += haversineDistance(
          fps[i - 1].latitude, fps[i - 1].longitude,
          fps[i].latitude, fps[i].longitude
        );
      }
      routes.push({
        dayKey: dk, footprints: fps, totalDistance: dist,
        startTime: fps[0].timestamp, endTime: fps[fps.length - 1].timestamp
      });
    }
    routes.sort((a, b) => b.dayKey.localeCompare(a.dayKey));
    this.dayRoutes = routes;

    const todayKey: string = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    const today: DayRoute | undefined = routes.find(r => r.dayKey === todayKey);
    if (today) {
      this.todayDistance = today.totalDistance;
      this.todayDuration = (today.endTime - today.startTime) / 1000;
    }
  }

  requestLocation(): void {
    try {
      this.tryLastLocation();
      const request: geoLocationManager.CurrentLocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.ACCURACY,
        scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
        timeoutMs: 10000, maxAccuracy: 0
      };
      geoLocationManager.getCurrentLocation(request, (err, location) => {
        if (err) {
          Logger.warn(TAG, 'Location error: code=%{public}d, msg=%{public}s',
            err.code, err.message ?? '');
          return;
        }
        if (location && location.latitude && location.longitude) {
          this.mapCenter = { latitude: location.latitude, longitude: location.longitude };
          this.locationReady = true;
          Logger.info(TAG, 'Location acquired: %{public}.4f, %{public}.4f',
            location.latitude, location.longitude);
          if (this.mapService) this.moveCamera();
        } else {
          Logger.warn(TAG, 'Location returned empty coordinates');
        }
      });
    } catch (err) {
      Logger.warn(TAG, 'getCurrentLocation exception');
    }
  }

  tryLastLocation(): void {
    try {
      const last: geoLocationManager.Location | undefined = geoLocationManager.getLastLocation();
      if (last && last.latitude && last.longitude) {
        this.mapCenter = { latitude: last.latitude, longitude: last.longitude };
        this.locationReady = true;
        Logger.info(TAG, 'Last location: %{public}.4f, %{public}.4f',
          last.latitude, last.longitude);
        if (this.mapService) this.moveCamera();
      }
    } catch (e) { /* ignore */ }
  }

  moveCamera(): void {
    const ms = this.mapService;
    if (!ms) return;
    try { ms.moveCamera(this.mapCenter, this.mapZoom); } catch (e) {}
  }

  /** WebView 控制器附加时调用 — 创建 MapJsBridge 并初始化地图 */
  onWebViewReady(controller: webview.WebviewController): void {
    const bridge: MapJsBridge = new MapJsBridge();
    bridge.setController(controller);
    this.mapService = bridge;

    const callbacks: MapEventCallbacks = {
      onMapReady: (_err: Error | null): void => {
        this.isMapReady = true;
        Logger.info(TAG, 'Map ready (JSAPI)');
        // 地图就绪后应用深色模式
        if (isDarkTheme() && this.mapService) {
          setTimeout(() => {
            this.mapService!.setMapStyle('amap://styles/dark');
            this.mapService!.setDarkMode(true);
          }, 1000);
        }
        this.setupGpsTracking();
        this.moveCamera();
        if (this.dayRoutes.length > 0) {
          this.drawOnMap();
          this.drawSegmentMarkers();
          this.syncDayVisibility();
          this.toggleLiveElements(this.isViewingToday);
        }
        // GPS 和地图都就绪后才触发首次推荐
        this.tryStartRecommending();
      },
      onMarkerClick: (id: string, lat: number, lng: number, _title: string): void => {
        this.handleMapMarkerClick(id, lat, lng);
      },
      onMapClick: (lat: number, lng: number): void => {
        if (this.showNavigation) {
          this.navMapClickSelect(lat, lng);
        }
      }
    };
    bridge.setEventCallbacks(callbacks);

    // 在 setEventCallbacks 之后注册，确保 search callbacks 合并而非被覆盖
    AmapSearchService.getInstance().setMapService(bridge);

    bridge.initialize({
      lng: this.mapCenter.longitude,
      lat: this.mapCenter.latitude,
      zoom: this.mapZoom,
      apiKey: 'bb0c1640992e6c7f2b1467498d8ae848'
    } as MapInitConfig);

    bridge.onMapReady((_err: Error | null): void => {
      if (!this.isMapReady) {
        this.isMapReady = true;
        Logger.info(TAG, 'Map ready via fallback');
        if (isDarkTheme() && this.mapService) {
          setTimeout(() => {
            this.mapService!.setMapStyle('amap://styles/dark');
            this.mapService!.setDarkMode(true);
          }, 1000);
        }
        this.setupGpsTracking();
        this.moveCamera();
        if (this.dayRoutes.length > 0) {
          this.drawOnMap();
          this.drawSegmentMarkers();
          this.syncDayVisibility();
          this.toggleLiveElements(this.isViewingToday);
        }
        // GPS 和地图都就绪后才触发首次推荐
        this.tryStartRecommending();
      }
    });
  }

  /** 处理地图标记点击 */
  private lastMarkerClickTime: number = 0;
  private lastMarkerClickKey: string = '';

  handleMapMarkerClick(id: string, lat: number, lng: number): void {
    try {
      const pos: LatLng | undefined = this.markerPositions[id];
      const useLat: number = pos ? pos.latitude : lat;
      const useLng: number = pos ? pos.longitude : lng;
      const key: string = `${useLat.toFixed(6)},${useLng.toFixed(6)}`;

      // 防抖：500ms 内同位置点击忽略
      const now: number = Date.now();
      if (key === this.lastMarkerClickKey && now - this.lastMarkerClickTime < 500) {
        return;
      }
      this.lastMarkerClickTime = now;
      this.lastMarkerClickKey = key;

      if (this.recDataMap[key]) {
        this.goRecDetail(id);
        return;
      }
      const fp: Footprint | undefined = this.markerMap[key];
      if (fp) this.goDetail(fp);
    } catch (e) { /* ignore */ }
  }

  /** 设置 GPS 追踪和动画循环 */
  setupGpsTracking(): void {
    const ms: IMapService | null = this.mapService;
    if (!ms) return;

    let animTarget: LatLng | null = null;
    let animCur: LatLng | null = null;
    let animTimer: number | null = null;

    const todayKey: string = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    let frozenEnd: LatLng | null = null;
    let pendingGps: LatLng | null = null;
    let prevGpsPt: LatLng | null = null;
    let prevGpsMs: number = 0;
    let gpsSpeed: number = 1.4;
    let lastDbTs: number = 0;
    let lastClassifyTs: number = 0;

    const runActivityClassify = async (): Promise<void> => {
      const now2: number = Date.now();
      if (now2 - lastClassifyTs < 30000) return;
      lastClassifyTs = now2;
      try {
        const todayFps: Footprint[] = await this.dao.queryFootprintsByDay(todayKey);
        if (todayFps.length < 3) return;
        const segs: ActivitySegment[] = ActivityClassifier.aggregateSegments(todayFps, this.segments);
        if (segs.length > 0) {
          for (const s of segs) {
            if (!s.poiName || s.poiName.length === 0) {
              const name: string = await RecommendationEngine.lookupPlaceName(s.latitude, s.longitude);
              if (name.length > 0) s.poiName = name;
            }
          }
          // 合并校准记录，确保用户/AI修正不被覆盖
          await CalibrationService.getInstance().applyCalibrations(segs, todayKey);
          await this.dao.deleteActivitySegmentsByDay(todayKey);
          await this.dao.insertActivitySegments(segs);
          Logger.info(TAG, 'Activity classify: %{public}d segments from %{public}d pts',
            segs.length, todayFps.length);
          this.segments = await this.dao.queryAllActivitySegments(200);
          this.timelineRefreshKey++;
          this.clearSegmentMarkers();
          this.drawSegmentMarkers();
        }
      } catch (e) { /* ignore */ }
    };

    const startAnim = (): void => {
      if (animTimer) return;
      let lastMs: number = Date.now();
      animTimer = setInterval(() => {
        if (!animTarget || !animCur || !ms) return;
        const now: number = Date.now();
        const dt: number = Math.min((now - lastMs) / 1000, 0.1);
        lastMs = now;
        const ratePerSec: number = Math.min(0.95, 0.30 + gpsSpeed * 0.04);
        const remain: number = 1 - ratePerSec;
        const t: number = 1 - Math.pow(remain, dt);
        animCur = {
          latitude: animCur.latitude + (animTarget.latitude - animCur.latitude) * t,
          longitude: animCur.longitude + (animTarget.longitude - animCur.longitude) * t
        };

        if (this.liveMarker && this.isViewingToday && ms) {
          try { ms.setMarkerPosition(this.liveMarker, animCur); } catch (e) {}
        }
        if (frozenEnd && this.isViewingToday && ms) {
          const tailPts: LatLng[] = [frozenEnd, animCur];
          if (!this.liveTail) {
            const tailId: string = ms.addPolyline({
              points: tailPts, color: '#FF4444', width: 6,
              zIndex: 21, clickable: false
            });
            this.liveTail = tailId;
          } else {
            ms.setPolylinePoints(this.liveTail, tailPts);
          }
        }
      }, 33);
    };

    const stopAnim = (): void => {
      if (animTimer) { clearInterval(animTimer); animTimer = null; }
    };

    // 创建蓝点标记
    const createBlueDot = (pos: LatLng): void => {
      if (this.liveMarker || !ms) return;
      const markerId: string = ms.addMarker({
        position: pos,
        iconStyle: this.positionDotStyle,
        anchorU: 0.5, anchorV: 0.5,
        zIndex: 30, clickable: false
      });
      this.liveMarker = markerId;
      this.markerPositions[markerId] = pos;
    };

    geoLocationManager.on('locationChange', {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
      timeInterval: 0, distanceInterval: 0, maxAccuracy: 0
    }, (loc: geoLocationManager.Location): void => {
      if (!loc || !loc.latitude || !loc.longitude || !ms) return;

      const gpsPt: LatLng = { latitude: loc.latitude, longitude: loc.longitude };

      if (!this.locationReady) {
        this.mapCenter = gpsPt;
        this.mapZoom = 16;
        try { ms.moveCamera(gpsPt, 16); } catch (e) {}
      }
      this.locationReady = true;
      AgentScheduler.getInstance().updateLocation(gpsPt.latitude, gpsPt.longitude);
      // GPS 定位成功后，如果地图也准备好了，触发首次推荐
      this.tryStartRecommending();

      if (!this.liveMarker) {
        createBlueDot(gpsPt);
      }

      if (frozenEnd && pendingGps && this.isViewingToday &&
          (frozenEnd.latitude !== pendingGps.latitude ||
           frozenEnd.longitude !== pendingGps.longitude)) {
        const segId: string = ms.addPolyline({
          points: [frozenEnd, pendingGps],
          color: '#FF4444', width: 6,
          zIndex: 20, clickable: false
        });
        this.liveTrailSegments.push(segId);
        frozenEnd = pendingGps;
      }
      if (!frozenEnd) frozenEnd = gpsPt;
      pendingGps = gpsPt;

      if (prevGpsPt && prevGpsMs > 0) {
        const dMs: number = Date.now() - prevGpsMs;
        const dLat2: number = gpsPt.latitude - prevGpsPt.latitude;
        const dLng2: number = gpsPt.longitude - prevGpsPt.longitude;
        const distM2: number = Math.sqrt(dLat2*dLat2 + dLng2*dLng2) * 111320;
        if (dMs > 100) gpsSpeed = gpsSpeed * 0.5 + (distM2 / (dMs/1000)) * 0.5;
      }
      prevGpsPt = gpsPt;
      prevGpsMs = Date.now();

      animTarget = gpsPt;
      if (!animCur) animCur = gpsPt;
      startAnim();

      const now: number = Date.now();
      if (now - lastDbTs > 5000) {
        lastDbTs = now;
        const fp: Footprint = new Footprint();
        fp.latitude = loc.latitude;
        fp.longitude = loc.longitude;
        fp.accuracy = loc.accuracy ?? 0;
        fp.timestamp = now;
        fp.speed = loc.speed ?? 0;
        fp.source = 'gps';
        fp.dayKey = todayKey;
        this.dao.insertFootprint(fp);
        this.footprintCount++;
        this.footprints.push(fp);
        runActivityClassify();
      }
    });
  }

  async drawOnMap(): Promise<void> {
    const ms = this.mapService;
    if (!ms || this.dayRoutes.length === 0) return;

    // 清除旧的路线和标记，确保重绘时数据一致
    this.clearDayOverlays();

    try {
      const allPts: LatLng[] = [];
      for (let ri = 0; ri < this.dayRoutes.length; ri++) {
        const route: DayRoute = this.dayRoutes[ri];
        const fps: Footprint[] = route.footprints;
        let polylineId: string = '';
        if (fps.length >= 2) {
          const pts: LatLng[] = [];
          for (const fp of fps) {
            pts.push({ latitude: fp.latitude, longitude: fp.longitude });
          }
          polylineId = ms.addPolyline({
            points: pts, color: ROUTE_COLORS[ri % ROUTE_COLORS.length],
            width: 6, zIndex: 11, clickable: false
          });
          allPts.push(...pts);
        }
        // 始终 push，保持 polyline 与 marker 数组下标一致
        this.dayPolylines.push(polylineId);
        if (polylineId.length > 0 && ri !== this.selectedDayIndex) {
          try { ms.setPolylineVisible(polylineId, false); } catch (e) {}
        }
      }

      for (let ri = 0; ri < this.dayRoutes.length; ri++) {
        const fps: Footprint[] = this.dayRoutes[ri].footprints;
        const markers: string[] = [];
        for (const fp of fps) {
          if (!fp.poiName || fp.poiName.length === 0) continue;
          const posKey: string = `${fp.latitude.toFixed(6)},${fp.longitude.toFixed(6)}`;
          if (this.markerMap[posKey]) continue;
          this.markerMap[posKey] = fp;
          const markerId: string = ms.addMarker({
            position: { latitude: fp.latitude, longitude: fp.longitude },
            title: fp.poiName,
            snippet: fp.activityTag ? this.activityLabel(fp.activityTag) : '',
            clickable: true
          });
          this.markerPositions[markerId] = { latitude: fp.latitude, longitude: fp.longitude };
          markers.push(markerId);
          if (ri !== this.selectedDayIndex) {
            try { ms.setMarkerVisible(markerId, false); } catch (e) {}
          }
        }
        this.dayPoiMarkers.push(markers);
      }

      // 为每天绘制 segment 活动标记（自然生成的活动也显示）
      this.daySegMarkers = [];
      for (let ri = 0; ri < this.dayRoutes.length; ri++) {
        const dk: string = this.dayRoutes[ri].dayKey;
        const segMarkersForDay: string[] = [];
        for (const seg of this.segments) {
          if (seg.dayKey !== dk) continue;
          const segLabel: string = seg.poiName
            ? (this.activityEmoji(seg.activityType) + ' ' + seg.poiName)
            : (this.activityEmoji(seg.activityType) + ' ' + (this.activityLabel(seg.activityType) || '未知活动'));
          const segPosKey: string = `${seg.latitude.toFixed(6)},${seg.longitude.toFixed(6)}`;
          if (this.markerMap[segPosKey]) continue;
          const fpSeg: Footprint = new Footprint();
          fpSeg.latitude = seg.latitude;
          fpSeg.longitude = seg.longitude;
          fpSeg.poiName = seg.poiName || this.activityLabel(seg.activityType);
          fpSeg.activityTag = seg.activityType;
          fpSeg.timestamp = seg.startTime;
          fpSeg.stayDuration = seg.endTime - seg.startTime;
          this.markerMap[segPosKey] = fpSeg;
          const segMarkerId: string = ms.addMarker({
            position: { latitude: seg.latitude, longitude: seg.longitude },
            title: segLabel,
            snippet: seg.summary || '',
            clickable: true
          });
          this.markerPositions[segMarkerId] = { latitude: seg.latitude, longitude: seg.longitude };
          segMarkersForDay.push(segMarkerId);
          if (ri !== this.selectedDayIndex) {
            try { ms.setMarkerVisible(segMarkerId, false); } catch (e) {}
          }
        }
        this.daySegMarkers.push(segMarkersForDay);
      }

      if (allPts.length > 0) {
        this.fitAllRoutes(allPts);
      }

      setTimeout(() => {
        if (this.locationReady && ms) {
          try { ms.moveCamera(this.mapCenter, 16); } catch (e) {}
        }
      }, 1500);
    } catch (err) {
      Logger.warn(TAG, 'drawOnMap error');
    }
  }

  /** 清除日路线覆盖层（polyline + POI marker + segment marker），在重绘前调用 */
  clearDayOverlays(): void {
    const ms = this.mapService;
    // 清除路线折线
    for (const id of this.dayPolylines) {
      if (id.length > 0 && ms) {
        try { ms.removePolyline(id); } catch (e) {}
      }
    }
    this.dayPolylines = [];
    // 清除 POI 标记
    for (const arr of this.dayPoiMarkers) {
      for (const id of arr) {
        if (ms) {
          try { ms.removeMarker(id); } catch (e) {}
        }
      }
    }
    this.dayPoiMarkers = [];
    // 清除 segment 标记
    for (const arr of this.daySegMarkers) {
      for (const id of arr) {
        if (ms) {
          try { ms.removeMarker(id); } catch (e) {}
        }
      }
    }
    this.daySegMarkers = [];
  }

  /** 清除所有 segment 标记，从地图上移除并清空列表 */
  clearSegmentMarkers(): void {
    const ms = this.mapService;
    for (const m of this.segMarkers) {
      if (ms) {
        try { ms.removeMarker(m); } catch (e) {}
      }
    }
    this.segMarkers = [];
    this.segmentInfoMap = {};
  }

  /** 根据两点间距选择导航模式：<2km步行，>=2km驾车 */
  /** 绘制当前选中天的 segment 标记（活动类型标记） */
  drawSegmentMarkers(): void {
    const ms = this.mapService;
    if (!ms) return;

    // 先清除旧标记，防止重复
    this.clearSegmentMarkers();

    // 根据当前选中的天来确定 dayKey
    if (this.selectedDayIndex < 0 || this.selectedDayIndex >= this.dayRoutes.length) return;
    const targetDayKey: string = this.dayRoutes[this.selectedDayIndex].dayKey;

    for (const seg of this.segments) {
      if (seg.dayKey !== targetDayKey) continue;
      const label: string = seg.poiName
        ? (this.activityEmoji(seg.activityType) + ' ' + seg.poiName)
        : (this.activityEmoji(seg.activityType) + ' ' + (this.activityLabel(seg.activityType) || '未知活动'));
      const posKey: string = `${seg.latitude.toFixed(6)},${seg.longitude.toFixed(6)}`;
      // 存储段校准信息（点击时传递给详情页）
      this.segmentInfoMap[posKey] = {
        segmentStartTime: seg.startTime,
        segmentEndTime: seg.endTime,
        dayKey: seg.dayKey,
        activityTag: seg.activityType,
        poiName: seg.poiName || ''
      };
      const fpPlaceholder: Footprint = new Footprint();
      fpPlaceholder.latitude = seg.latitude;
      fpPlaceholder.longitude = seg.longitude;
      fpPlaceholder.poiName = seg.poiName || this.activityLabel(seg.activityType);
      fpPlaceholder.activityTag = seg.activityType;
      fpPlaceholder.timestamp = seg.startTime;
      fpPlaceholder.stayDuration = seg.endTime - seg.startTime;
      this.markerMap[posKey] = fpPlaceholder;
      const markerId: string = ms.addMarker({
        position: { latitude: seg.latitude, longitude: seg.longitude },
        title: label,
        snippet: seg.summary || '',
        clickable: true
      });
      this.markerPositions[markerId] = { latitude: seg.latitude, longitude: seg.longitude };
      this.segMarkers.push(markerId);
    }
  }

  fitAllRoutes(pts: LatLng[]): void {
    const ms = this.mapService;
    if (pts.length === 0 || !ms) return;
    let minLat: number = pts[0].latitude;
    let maxLat: number = pts[0].latitude;
    let minLng: number = pts[0].longitude;
    let maxLng: number = pts[0].longitude;
    for (const p of pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    const pad: number = 0.002;
    const bounds: LatLngBounds = {
      southwest: { latitude: minLat - pad, longitude: minLng - pad },
      northeast: { latitude: maxLat + pad, longitude: maxLng + pad }
    };
    try { ms.moveCameraBounds(bounds, 50); } catch (e) {
      const mid: LatLng = {
        latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2
      };
      try { ms.moveCamera(mid, 15); } catch (e2) {}
    }
  }

  focusOnDayRoute(idx: number): void {
    const ms = this.mapService;
    if (!ms || idx < 0 || idx >= this.dayRoutes.length) return;
    const fps: Footprint[] = this.dayRoutes[idx].footprints;
    if (fps.length === 0) return;
    const pts: LatLng[] = fps.map(
      (f: Footprint): LatLng => ({ latitude: f.latitude, longitude: f.longitude })
    );
    this.fitAllRoutes(pts);
  }

  dismissCard(): void {
    this.showBubble = false;
    this.selectedWaypoint = null;
  }

  goDetail(fp: Footprint): void {
    try {
      // 查找该 footprint 对应的段校准信息
      const posKey: string = `${fp.latitude.toFixed(6)},${fp.longitude.toFixed(6)}`;
      const segInfo: SegmentCalibrationInfo | undefined = this.segmentInfoMap[posKey];

      router.pushUrl({
        url: 'pages/WaypointDetailPage',
        params: {
          poiName: fp.poiName, latitude: fp.latitude, longitude: fp.longitude,
          activityTag: fp.activityTag, timestamp: fp.timestamp,
          stayDuration: fp.stayDuration, speed: fp.speed, photoList: fp.photoId,
          segmentStartTime: segInfo ? segInfo.segmentStartTime : 0,
          segmentEndTime: segInfo ? segInfo.segmentEndTime : 0,
          dayKey: segInfo ? segInfo.dayKey : ''
        }
      });
    } catch (e) {}
  }

  stayStr(fp: Footprint): string {
    const mins: number = Math.floor(fp.stayDuration / 60000);
    if (mins <= 0) return '';
    if (mins < 60) return `${mins} min`;
    const hrs: number = Math.floor(mins / 60);
    const rem: number = mins % 60;
    return rem > 0 ? `${hrs}h ${rem}m` : `${hrs} hr`;
  }

  activityLabel(type: string): string {
    return ACTIVITY_LABELS[type] || type;
  }

  activityEmoji(type: string): string {
    const m: Record<string, string> = {
      'home':'🏠','work':'💼','dining':'🍽️','shopping':'🛍️',
      'sports':'🏃','commute':'🚇','leisure':'🎠','travel':'✈️'
    };
    return m[type] || '📍';
  }

  photoCount(fp: Footprint): number {
    if (!fp.photoId || fp.photoId.length === 0) return 0;
    return fp.photoId.split('|').filter(s => s.length > 0).length;
  }

  photoList(fp: Footprint): string[] {
    if (!fp.photoId || fp.photoId.length === 0) return [];
    return fp.photoId.split('|').filter(s => s.length > 0);
  }

  selectedRoute(): DayRoute | null {
    return this.dayRoutes.length > 0 ? this.dayRoutes[this.selectedDayIndex] : null;
  }

  routeDistStr(): string {
    const r: DayRoute | null = this.selectedRoute();
    if (!r) return '--';
    if (r.totalDistance < 1000) return `${r.totalDistance.toFixed(0)}`;
    return `${(r.totalDistance / 1000).toFixed(2)}`;
  }

  routeDistUnit(): string {
    const r: DayRoute | null = this.selectedRoute();
    if (!r) return '';
    return r.totalDistance < 1000 ? 'm' : 'km';
  }

  routeMinsStr(): string {
    const r: DayRoute | null = this.selectedRoute();
    if (!r) return '--';
    return `${Math.floor((r.endTime - r.startTime) / 60000)}`;
  }

  routePaceStr(): string {
    const r: DayRoute | null = this.selectedRoute();
    if (!r) return '--';
    const distKm: number = r.totalDistance / 1000;
    const durHrs: number = (r.endTime - r.startTime) / 3600000;
    if (durHrs <= 0 || distKm <= 0) return '--';
    return `${((durHrs * 60) / distKm).toFixed(1)}`;
  }

  routePointsStr(): string {
    const r: DayRoute | null = this.selectedRoute();
    if (!r) return '0';
    return `${r.footprints.length}`;
  }

  syncAgentContext(): void {
    const segs: ActivitySegment[] = this.segments || [];
    const todayKey: string = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    const todaySegs: ActivitySegment[] = [];
    for (const s of segs) { if (s.dayKey === todayKey) todaySegs.push(s); }
    const last: ActivitySegment | null = todaySegs.length > 0 ? todaySegs[todaySegs.length - 1] : null;
    const route: DayRoute | null = this.selectedRoute();
    this.getAiAgent().updateContext({
      lastSegmentType: last ? last.activityType : '',
      lastSegmentPoi: last ? last.poiName : '',
      lastSegmentLat: last ? last.latitude : 0,
      lastSegmentLng: last ? last.longitude : 0,
      todayDistance: route ? route.totalDistance : 0,
      todaySegCount: todaySegs.length,
      footprintCount: this.footprintCount,
      userName: this.agentUserName,
      userCity: this.agentUserCity,
      userPreferences: this.agentUserPrefs
    });
  }

  async sendChat(): Promise<void> {
    const msg: string = this.chatInput.trim();
    if (msg.length === 0) return;
    this.chatMessages.push({ role: 'user', content: msg });
    this.chatInput = '';
    this.chatScroller.scrollEdge(Edge.Bottom);

    this.isAiThinking = true;
    this.syncAgentContext();
    const reply: AgentReply = await this.getAiAgent().process(msg);
    this.isAiThinking = false;

    this.chatMessages.push({ role: 'ai', content: reply.text });
    this.chatScroller.scrollEdge(Edge.Bottom);

    if (reply.action === 'refresh_timeline') {
      this.triggerClassify();
    } else if (reply.action === 'show_recs') {
      if (!this.showRecMarkers) this.toggleRecMarkers();
    } else if (reply.action === 'switch_day') {
      this.selectedDayIndex = reply.actionParam || 0;
      this.focusOnDayRoute(this.selectedDayIndex);
    }
  }

  /**
   * GPS 和地图都就绪后，触发首次推荐刷新
   */
  private recommendationStarted: boolean = false;

  tryStartRecommending(): void {
    if (this.recommendationStarted) return;
    if (!this.isMapReady || !this.locationReady) return;
    this.recommendationStarted = true;
    Logger.info(TAG, 'Both map and GPS ready — starting recommendations at lat=%{public}.4f lng=%{public}.4f',
      this.mapCenter.latitude, this.mapCenter.longitude);
    AgentScheduler.getInstance().notifyMapReady(this.mapCenter.latitude, this.mapCenter.longitude);
    // 首次推荐就绪后自动显示地图标记，延时等推荐引擎完成
    setTimeout(() => {
      if (!this.showRecMarkers) this.toggleRecMarkers();
    }, 6000);
  }

  // ─── GPS/网络检测弹窗 ───

  /** 根据设置显隐地图推荐标记 */
  private async applyMapMarkerSetting(): Promise<void> {
    try {
      const p = await this.dao.queryUserProfile('map_markers_enabled');
      const enabled: boolean = !(p && p.preferenceValue === 'false');
      if (enabled && !this.showRecMarkers) {
        // 开关打开但标记未显示 → 显示
        this.toggleRecMarkers();
      } else if (!enabled && this.showRecMarkers) {
        // 开关关闭但标记仍显示 → 隐藏
        if (this.mapService) {
          for (const m of this.recMarkers) {
            try { this.mapService.setMarkerVisible(m, false); } catch (e) {}
          }
        }
        this.showRecMarkers = false;
      }
    } catch (e) { /* ignore */ }
  }

  /** 刷新地图推荐标记（清除旧标记并从 DB 重新加载） */
  private refreshMapMarkers(): void {
    Logger.info(TAG, 'Refreshing map rec markers');
    // 清除旧标记
    if (this.mapService) {
      for (const m of this.recMarkers) {
        try { this.mapService.removeMarker(m); } catch (e) {}
      }
    }
    this.recMarkers = [];
    this.recDataMap = {};
    this.recGroupMap = {};
    this.showRecMarkers = false;
    // 延时等 DB 写入完成后重新加载
    setTimeout(() => { this.toggleRecMarkers(); }, 300);
  }

  /**
   * 首次启动检测：无用户资料时跳转欢迎页
   */
  private async checkFirstLaunch(): Promise<void> {
    try {
      const info: UserBasicInfo | null = await this.dao.queryUserBasicInfo();
      if (!info || info.username.trim().length === 0) {
        Logger.info(TAG, 'First launch detected, navigating to WelcomePage');
        router.replaceUrl({
          url: 'pages/WelcomePage'
        });
      }
    } catch (e) {
      // DB 未就绪或其他错误，静默跳过
    }
  }

  /**
   * 加载用户基础信息，填入 AI agent 上下文（软引导，不强制）
   */
  private async loadUserInfoForAgent(): Promise<void> {
    try {
      const info: UserBasicInfo | null = await this.dao.queryUserBasicInfo();
      if (info) {
        this.agentUserName = info.username || '';
        this.agentUserCity = info.city || '';
        this.agentUserPrefs = info.getPreferenceDisplay();
        Logger.info(TAG, 'User info loaded for agent: %{public}s %{public}s pref=%{public}s',
          this.agentUserName, this.agentUserCity, this.agentUserPrefs);
      }
    } catch (e) {
      // 静默失败，不影响主流程
    }
  }

  /**
   * 检测 GPS 和网络状态，任一项未开启则弹出提醒弹窗
   */
  private async checkAndShowServiceDialog(): Promise<void> {
    try {
      const status: ServiceStatus = await checkServicesStatus();
      if (!isAllServicesReady(status)) {
        this.showServiceAlertDialog(status);
      }
    } catch (e) {
      Logger.warn(TAG, 'Service check failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 定时重检服务状态（弹窗显示期间，用户可能去设置开启服务后返回）
   */
  private async recheckServicesForDialog(): Promise<void> {
    try {
      const status: ServiceStatus = await checkServicesStatus();
      if (isAllServicesReady(status)) {
        // 服务已全部就绪，自动关闭弹窗
        if (this.dialogController) {
          this.dialogController.close();
          this.dialogController = null;
        }
        Logger.info(TAG, 'All services ready, auto-dismissed dialog');
      }
    } catch (e) {
      // 静默重试
    }
  }

  /**
   * 创建并显示服务提醒弹窗
   */
  private showServiceAlertDialog(status: ServiceStatus): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

      this.dialogController = new CustomDialogController({
        builder: GpsNetworkDialog({
          locationEnabled: status.locationEnabled,
          networkConnected: status.networkConnected,
          context: ctx
        }),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        customStyle: true
      });

      this.dialogController.open();
      Logger.info(TAG, 'Service alert dialog opened');
    } catch (e) {
      Logger.error(TAG, 'Failed to show service dialog: %{public}s', JSON.stringify(e));
    }
  }

  switchTab(index: number): void {
    if (index === this.currentTab) return;
    this.currentTab = index;
    if (index === 0) {
      // 切换回地图 tab 时刷新校准
      this.refreshCalibrationsAndRedraw();
    }
  }

  // ─── 导航功能 ───

  /** 切换导航面板 */
  toggleNavigation(): void {
    if (this.showNavigation) {
      this.showNavigation = false;
      this.clearNavigationRoute();
    } else {
      // 设置起点为当前位置
      this.navOriginLat = this.mapCenter.latitude;
      this.navOriginLng = this.mapCenter.longitude;
      this.navOriginName = '当前位置';
      this.navRoute = null;
      this.navSearchQuery = '';
      this.navSearchResults = [];
      this.showNavigation = true;
    }
  }

  /** 地图点击选点（导航模式）— REST API 直连，不依赖 JS Bridge */
  async navMapClickSelect(lat: number, lng: number): Promise<void> {
    const poi: PoiResult = {
      name: '地图选点',
      type: '',
      latitude: lat,
      longitude: lng,
      address: '',
      distance: 0,
      tel: '',
    };

    // REST API 获取地点名称
    try {
      const name: string = await AmapSearchService.getInstance().lookupNearestPlaceRest(lat, lng);
      if (name && name.length > 0) {
        poi.name = name;
      }
    } catch (_e) { /* 使用默认名称 */ }

    this.navSelectDestination(poi);
  }

  /** 搜索目的地 — REST API 直连，不依赖 JS Bridge */
  navSearchDestination(): void {
    const query: string = this.navSearchQuery.trim();
    if (!query || query.length === 0) return;
    this.navIsSearching = true;
    this.navSearchResults = [];

    AmapSearchService.getInstance().nearbySearchRest(
      query, this.mapCenter.latitude, this.mapCenter.longitude, 10000
    ).then((results: PoiResult[]) => {
      this.navSearchResults = results;
      this.navIsSearching = false;
    }).catch(() => {
      this.navIsSearching = false;
    });
  }

  /** 选择目的地并计算路线 — REST API 直连 */
  async navSelectDestination(poi: PoiResult): Promise<void> {
    this.navIsCalculating = true;
    this.navRoute = null;
    this.navSelectedStepIndex = -1;

    try {
      // REST API 路线计算（绕过 JS Bridge）
      const route: NavRoute | null = await AmapSearchService.getInstance().directionRouteRest(
        this.navOriginLat, this.navOriginLng,
        poi.latitude, poi.longitude,
        this.navMode
      );
      this.navRoute = route;
      if (route) {
        // 更新目的地名称
        if (poi.name && poi.name.length > 0) {
          route.destination = poi.name;
        }
        this.drawNavigationRoute(route);
      }
    } catch (e) {
      Logger.warn(TAG, 'Navigation route calculation failed');
    }
    this.navIsCalculating = false;
    this.navSearchResults = [];
    this.navSearchQuery = poi.name;
  }

  /** 在地图上绘制导航路线 */
  drawNavigationRoute(route: NavRoute): void {
    const ms = this.mapService;
    if (!ms) return;

    // 清除之前的导航覆盖物
    this.clearNavigationOverlays();

    // 绘制路线折线
    if (route.path.length > 0) {
      this.navRoutePolylineId = ms.addPolyline({
        points: route.path,
        color: '#10B981',
        width: 8,
        zIndex: 55,
        clickable: false,
      });
    }

    // 起点标记（绿色圆点）
    if (route.path.length > 0) {
      this.navStartMarkerId = ms.addMarker({
        position: route.path[0],
        iconStyle: { color: '#10B981', size: 22 },
        title: '起点',
        zIndex: 60,
      });
    }

    // 终点标记（红色圆点）
    if (route.path.length > 0) {
      const lastIdx: number = route.path.length - 1;
      this.navEndMarkerId = ms.addMarker({
        position: route.path[lastIdx],
        iconStyle: { color: '#EF4444', size: 26 },
        title: route.destination || '目的地',
        zIndex: 60,
      });
    }

    // 适配地图视野
    if (route.path.length > 0) {
      this.fitBounds(route.path);
    }
  }

  /** 适配边界框 */
  private fitBounds(pts: LatLng[]): void {
    if (pts.length === 0) return;
    let minLat: number = 90, maxLat: number = -90, minLng: number = 180, maxLng: number = -180;
    for (const p of pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    const bounds: LatLngBounds = {
      southwest: { latitude: minLat, longitude: minLng },
      northeast: { latitude: maxLat, longitude: maxLng },
    };
    try {
      if (this.mapService) this.mapService.moveCameraBounds(bounds, 60);
    } catch (e) { /* ignore */ }
  }

  /** 清除导航覆盖物（保留路线数据） */
  clearNavigationOverlays(): void {
    const ms = this.mapService;
    if (!ms) return;
    if (this.navRoutePolylineId) {
      try { ms.removePolyline(this.navRoutePolylineId); } catch (e) { /* ignore */ }
      this.navRoutePolylineId = '';
    }
    if (this.navStartMarkerId) {
      try { ms.removeMarker(this.navStartMarkerId); } catch (e) { /* ignore */ }
      this.navStartMarkerId = '';
    }
    if (this.navEndMarkerId) {
      try { ms.removeMarker(this.navEndMarkerId); } catch (e) { /* ignore */ }
      this.navEndMarkerId = '';
    }
  }

  /** 清除导航（UI + 地图） */
  clearNavigationRoute(): void {
    this.clearNavigationOverlays();
    this.navRoute = null;
    this.navSearchResults = [];
    this.navSearchQuery = '';
    this.navSelectedStepIndex = -1;
    this.navIsCalculating = false;
  }

  /** 构建出行方式选择按钮 */
  @Builder
  BuildNavModeBtn(emoji: string, label: string, mode: DirectionMode) {
    Column() {
      Text(emoji).fontSize(18)
      Text(label).fontSize(9).fontColor(this.navMode === mode ? '#FFFFFF' : '#999')
    }
    .layoutWeight(1)
    .padding({ top: 6, bottom: 6 })
    .backgroundColor(this.navMode === mode ? '#10B981' : getTheme(this.themeMode).surfaceSecondary)
    .border({ width: 1, color: this.navMode === mode ? '#10B981' : getTheme(this.themeMode).border })
    .borderRadius(12)
    .onClick(() => { this.navMode = mode; })
  }

  /** 格式化距离显示 */
  formatNavDistance(meters: number): string {
    if (meters < 1000) return Math.floor(meters) + 'm';
    return (meters / 1000).toFixed(1) + 'km';
  }

  /** 格式化时长显示 */
  formatNavDuration(seconds: number): string {
    if (seconds < 60) return Math.floor(seconds) + '秒';
    if (seconds < 3600) return Math.floor(seconds / 60) + '分钟';
    const h: number = Math.floor(seconds / 3600);
    const m: number = Math.floor((seconds % 3600) / 60);
    return h + 'h' + (m > 0 ? m + 'm' : '');
  }

  /** 导航步骤动作图标 */
  navStepActionIcon(action: string): string {
    if (action.includes('left') || action.includes('左转')) return '↰';
    if (action.includes('right') || action.includes('右转')) return '↱';
    if (action.includes('turn_around') || action.includes('掉头')) return '↶';
    if (action.includes('arrive') || action.includes('到达')) return '🏁';
    if (action.includes('transit') || action.includes('bus') || action.includes('地铁') || action.includes('railway')) return '🚌';
    if (action.includes('walking') || action.includes('步行')) return '🚶';
    return '↑';
  }

  private async triggerRecommendRefresh(): Promise<void> {
    try {
      // 直接查询数据库获取最新推荐
      const recs: Recommendation[] = await this.dao.queryRecentRecommendations(20);
      // 这里可以触发 RecommendContent 刷新，但由于是独立的组件，轮询机制会处理
      Logger.info(TAG, 'Recommend tab activated, latest recs: %{public}d', recs.length);
    } catch (e) {
      Logger.warn(TAG, 'Failed to refresh recommendations on tab switch');
    }
  }

  async triggerClassify(): Promise<void> {
    const todayKey: string = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    try {
      const todayFps: Footprint[] = await this.dao.queryFootprintsByDay(todayKey);
      if (todayFps.length < 3) return;
      const segs: ActivitySegment[] = ActivityClassifier.aggregateSegments(todayFps, this.segments);
      if (segs.length > 0) {
        for (const s of segs) {
          if (!s.poiName || s.poiName.length === 0) {
            const name: string = await RecommendationEngine.lookupPlaceName(s.latitude, s.longitude);
            if (name.length > 0) s.poiName = name;
          }
        }
        // 合并校准记录，确保用户/AI修正不被覆盖
        await CalibrationService.getInstance().applyCalibrations(segs, todayKey);
        await this.dao.deleteActivitySegmentsByDay(todayKey);
        await this.dao.insertActivitySegments(segs);
        Logger.info(TAG, 'Manual classify: %{public}d segments from %{public}d pts',
          segs.length, todayFps.length);
        this.segments = await this.dao.queryAllActivitySegments(200);
        this.timelineRefreshKey++;
        this.clearSegmentMarkers();
        this.drawSegmentMarkers();
      }
    } catch (e) { /* ignore */ }
  }

  build() {
    Column() {
      Stack() {
        Stack({ alignContent: Alignment.TopStart }) {
          MapWebView({
            onControllerAttached: (controller: webview.WebviewController): void => {
              this.onWebViewReady(controller);
            }
          })

          Column() {
            Column() {
              Row() {
                ForEach(this.dayRoutes, (route: DayRoute, idx: number) => {
                  Column() {
                    Text(route.dayKey.slice(4, 6) + '/' + route.dayKey.slice(6, 8))
                      .fontSize(12).fontColor(idx === this.selectedDayIndex ? '#FFFFFF' : '#AAA')
                    Text(route.dayKey.slice(0, 4))
                      .fontSize(9).fontColor(idx === this.selectedDayIndex ? '#FFFFFF' : '#CCC')
                    Row() {}.width(24).height(2)
                      .backgroundColor(idx === this.selectedDayIndex ? '#FFFFFF' : Color.Transparent)
                      .borderRadius(1).margin({ top: 2 })
                  }
                  .padding({ top: 6, bottom: 6, left: 10, right: 10 })
                  .backgroundColor(idx === this.selectedDayIndex ? '#3B82F6' : Color.Transparent)
                  .borderRadius(16)
                  .onClick(() => {
                    this.selectedDayIndex = idx;
                    const tKey: string = new Date().toISOString().slice(0, 10).replace(/-/g, '');
                    this.isViewingToday = (route.dayKey === tKey);
                    this.toggleLiveElements(this.isViewingToday);
                    this.syncDayVisibility();
                    if (!this.isViewingToday && this.showRecMarkers) {
                      this.showRecMarkers = false;
                      for (const m of this.recMarkers) {
                        try { if (this.mapService) this.mapService.setMarkerVisible(m, false); } catch (e) {}
                      }
                    }
                    this.clearSegmentMarkers();
                    this.drawSegmentMarkers();
                    this.focusOnDayRoute(idx);
                  })
                })
              }.padding({ left: 8, right: 8 })
              .width('100%').height(36)

              if (this.dayRoutes.length > 0) {
                Row() {
                  Column() {
                    Text(this.routeDistStr()).fontSize(28).fontWeight(FontWeight.Bold).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF')
                    Text(this.routeDistUnit()).fontSize(11).fontColor('#FFFFFF99')
                  }.layoutWeight(1)
                  Column() {
                    Text(this.routeMinsStr()).fontSize(28).fontWeight(FontWeight.Bold).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF')
                    Text('min').fontSize(11).fontColor('#FFFFFF99')
                  }.layoutWeight(1)
                  Column() {
                    Text(this.routePaceStr()).fontSize(28).fontWeight(FontWeight.Bold).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF')
                    Text('pace /km').fontSize(11).fontColor('#FFFFFF99')
                  }.layoutWeight(1)
                  Column() {
                    Text(this.routePointsStr()).fontSize(28).fontWeight(FontWeight.Bold).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF')
                    Text('pts').fontSize(11).fontColor('#FFFFFF99')
                  }.layoutWeight(1)
                }.width('100%').padding({ top: 8, bottom: 8 })
              }
            }
            .padding(12)
            .backgroundColor(isDarkTheme() ? '#CC1A1A1C' : '#99000000')
            .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 16, bottomRight: 16 })
            .width('100%')

            if (!this.isMapReady) {
              Text(this.footprintCount > 0
                ? `P ${this.footprintCount} footprints loaded, map initializing...`
                : 'No footprint data')
                .fontSize(13).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF').padding(8)
                .backgroundColor('#CC3B82F6').borderRadius(8).margin({ top: 8 })
            } else {
              Row() {
                Row() {}.width(8).height(8).borderRadius(4)
                  .backgroundColor('#50C878').margin({ right: 6 })
                Text(`GPS 录制中 · ${this.footprintCount} 个足迹点`)
                  .fontSize(12).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF')
              }
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(isDarkTheme() ? '#CC555555' : '#CC333333').borderRadius(14).margin({ top: 8 })
            }
          }
          .width('100%')

          // 推荐浮钮（右侧）→ 进入推荐全页
          Row() {
            Blank()
            Column() {
              Text('💡').fontSize(20)
              Text('推荐').fontSize(9).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF').margin({ top: 1 })
            }
            .width(48).height(48).borderRadius(24)
            .backgroundColor('#CC3B82F6').justifyContent(FlexAlign.Center)
            .shadow({ radius: 6, color: '#403B82F6', offsetY: 2 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/RecommendPage' });
            })
          }
          .width('100%').padding({ right: 12 }).margin({ top: 120 })

          // AI 聊天浮钮
          Row() {
            Blank()
            Column() {
              Text('💬').fontSize(20)
              Text('AI').fontSize(9).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF').margin({ top: 1 })
            }
            .width(48).height(48).borderRadius(24)
            .backgroundColor('#CC8B5CF6').justifyContent(FlexAlign.Center)
            .shadow({ radius: 6, color: '#408B5CF6', offsetY: 2 })
            .onClick(() => { this.showChat = !this.showChat; this.syncAgentContext(); })
          }
          .width('100%').padding({ right: 12 }).margin({ top: 176 })

          // 导航浮钮
          Row() {
            Blank()
            Column() {
              Text('🧭').fontSize(20)
              Text('导航').fontSize(9).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF').margin({ top: 1 })
            }
            .width(48).height(48).borderRadius(24)
            .backgroundColor('#CC10B981').justifyContent(FlexAlign.Center)
            .shadow({ radius: 6, color: '#4010B981', offsetY: 2 })
            .onClick(() => { this.toggleNavigation(); })
          }
          .width('100%').padding({ right: 12 }).margin({ top: 232 })

          // 刷新推荐浮钮（右下角）
          Row() {
            Blank()
            Column() {
              Text('🔄').fontSize(18)
            }
            .width(42).height(42).borderRadius(21)
            .backgroundColor('#CC666666').justifyContent(FlexAlign.Center)
            .shadow({ radius: 4, color: '#40666666', offsetY: 2 })
            .onClick(() => {
              AgentScheduler.getInstance().requestRefresh();
              setTimeout(() => { this.refreshMapMarkers(); }, 800);
            })
          }
          .width('100%').padding({ right: 12 }).margin({ top: 288 })

          // 推荐选择面板
          if (this.showRecPicker) {
            Column() {
              Column() {}.width('100%').layoutWeight(1)
                .onClick(() => { this.showRecPicker = false; })
              Column() {
                Row() {
                  Text('附近门店').fontSize(16).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
                  Blank()
                  Text('✕').fontSize(18).fontColor(getTheme(this.themeMode).textSecondary)
                    .onClick(() => { this.showRecPicker = false; })
                }.width('100%').margin({ bottom: 10 })
                Scroll() {
                  Column() {
                    ForEach(this.pickerGroup, (rec: Recommendation) => {
                      Row() {
                        Text(this.activityEmoji(rec.placeType) + ' ' + rec.placeName)
                          .fontSize(15).fontColor(getTheme(this.themeMode).textPrimary).layoutWeight(1)
                        Text('›').fontSize(18).fontColor(getTheme(this.themeMode).textTertiary)
                      }
                      .width('100%').padding({ top: 12, bottom: 12 })
                      .border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
                      .onClick(() => { this.openRecDetail(rec); })
                    })
                  }
                }.height(240)
              }
              .padding(16).backgroundColor(getTheme(this.themeMode).surface)
              .borderRadius({ topLeft: 16, topRight: 16 })
              .shadow({ radius: 8, color: '#20000000', offsetY: -2 })
            }
            .width('100%').height('100%')
            .position({ x: 0, y: 0 }).zIndex(100)
          }

          // AI 聊天面板
          if (this.showChat) {
            Column() {
              Column() {}.width('100%').layoutWeight(1)
                .onClick(() => { this.showChat = false; })

              Column() {
                Row() {
                  Text('🤖 足迹助手').fontSize(16).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
                  Blank()
                  Text('✕').fontSize(18).fontColor(getTheme(this.themeMode).textSecondary)
                    .onClick(() => { this.showChat = false; })
                }.width('100%').margin({ bottom: 4 })
                .gesture(
                  PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 3 })
                    .onActionStart(() => {
                      this.chatDragStartH = this.chatScrollHeight;
                    })
                    .onActionUpdate((event: GestureEvent) => {
                      const newH: number = this.chatDragStartH - event.offsetY;
                      this.chatScrollHeight = Math.max(100, Math.min(400, newH));
                    })
                    .onActionEnd(() => {
                      this.chatScrollHeight = Math.max(100, Math.min(400, this.chatScrollHeight));
                    })
                )

                // 拖拽手柄（按住上下拖动调整聊天框高度）
                Row()
                  .width(36).height(5).borderRadius(2.5)
                  .backgroundColor('#C0C0C0')
                  .alignSelf(ItemAlign.Center)
                  .margin({ bottom: 6 })
                  .gesture(
                    PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 3 })
                      .onActionStart(() => {
                        this.chatDragStartH = this.chatScrollHeight;
                      })
                      .onActionUpdate((event: GestureEvent) => {
                        const newH: number = this.chatDragStartH - event.offsetY;
                        this.chatScrollHeight = Math.max(100, Math.min(400, newH));
                      })
                      .onActionEnd(() => {
                        this.chatScrollHeight = Math.max(100, Math.min(400, this.chatScrollHeight));
                      })
                  )

                Scroll(this.chatScroller) {
                  Column() {
                    ForEach(this.chatMessages, (bubble: ChatBubble) => {
                      Row() {
                        if (bubble.role === 'user') {
                          // 用户消息靠右，紫色气泡
                          Blank()
                          Text(bubble.content).fontSize(13).fontColor(isDarkTheme() ? '#E5E5E7' : '#FFFFFF')
                            .padding(10).backgroundColor('#8B5CF6').borderRadius(12)
                            .maxLines(10).constraintSize({ maxWidth: '75%' })
                            .textOverflow({ overflow: TextOverflow.Clip })
                            .border({ width: 0.5, color: '#7C3AED' })
                        } else {
                          // AI 消息靠左，灰色气泡
                          Text(bubble.content).fontSize(13).fontColor(getTheme(this.themeMode).textPrimary)
                            .padding(10).backgroundColor(isDarkTheme() ? '#3A3A3C' : '#F0F2F5').borderRadius(12)
                            .maxLines(10).constraintSize({ maxWidth: '80%' })
                            .textOverflow({ overflow: TextOverflow.Clip })
                          Blank()
                        }
                      }.width('100%').margin({ bottom: 6 })
                    })

                    // AI 思考中指示器
                    if (this.isAiThinking) {
                      Row() {
                        Column() {
                          LoadingProgress()
                            .width(14).height(14).color('#8B5CF6')
                        }
                        .margin({ right: 6 })
                        Text('正在思考…').fontSize(12).fontColor('#8B5CF6')
                        Blank()
                      }
                      .width('100%')
                      .padding({ left: 6, top: 6, bottom: 4 })
                      .backgroundColor(isDarkTheme() ? '#2A2545' : '#F3F0FF')
                      .borderRadius(10)
                      .margin({ bottom: 4 })
                    }
                  }
                }.height(this.chatScrollHeight).margin({ bottom: 8 })

                Row() {
                  TextInput({ placeholder: '输入指令...', text: this.chatInput })
                    .fontSize(13).fontColor(getTheme(this.themeMode).textPrimary).height(36).layoutWeight(1).placeholderColor(getTheme(this.themeMode).textTertiary)
                    .backgroundColor(getTheme(this.themeMode).surfaceSecondary).borderRadius(18).padding({ left: 12, right: 12 })
                    .onChange((v: string) => { this.chatInput = v; })
                  Button('发送')
                    .fontSize(12).height(36).padding({ left: 12, right: 12 })
                    .backgroundColor('#8B5CF6').borderRadius(18)
                    .onClick(() => { this.sendChat(); })
                }.width('100%')
              }
              .padding(12).backgroundColor(getTheme(this.themeMode).surface)
              .borderRadius({ topLeft: 16, topRight: 16 })
              .shadow({ radius: 8, color: '#20000000', offsetY: -2 })
            }
            .width('100%').height('100%')
            .position({ x: 0, y: 0 }).zIndex(101)
          }

          // 导航面板（底部弹出，不阻挡地图交互）
          if (this.showNavigation) {
            Column() {
              Column() {
                // 标题栏
                Row() {
                  Text('🧭 导航').fontSize(16).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
                  Blank()
                  Text('✕').fontSize(18).fontColor(getTheme(this.themeMode).textSecondary)
                    .onClick(() => { this.showNavigation = false; this.clearNavigationRoute(); })
                }.width('100%').margin({ bottom: 8 })

                // 阶段 1: 目的地搜索 + 路线已显示
                if (!this.navRoute) {
                  // 搜索栏
                  Row() {
                    TextInput({ placeholder: '搜索目的地...', text: this.navSearchQuery }).placeholderColor(getTheme(this.themeMode).textTertiary)
                      .fontSize(13).fontColor(getTheme(this.themeMode).textPrimary).height(36).layoutWeight(1)
                      .backgroundColor(getTheme(this.themeMode).surfaceSecondary).borderRadius(18).padding({ left: 12, right: 12 })
                      .onChange((v: string) => { this.navSearchQuery = v; })
                    Button('搜索')
                      .fontSize(12).height(36).padding({ left: 10, right: 10 })
                      .backgroundColor('#10B981').borderRadius(18)
                      .onClick(() => { this.navSearchDestination(); })
                  }.width('100%').margin({ bottom: 6 })

                  // 出行方式选择
                  Row() {
                    this.BuildNavModeBtn('🚗', '驾车', DirectionMode.DRIVING)
                    this.BuildNavModeBtn('🚶', '步行', DirectionMode.WALKING)
                    this.BuildNavModeBtn('🚌', '公交', DirectionMode.TRANSIT)
                    this.BuildNavModeBtn('🚲', '骑行', DirectionMode.BICYCLING)
                  }.width('100%').margin({ bottom: 6 })

                  // 起点信息
                  Row() {
                    Text('📍').fontSize(14)
                    Text(this.navOriginName).fontSize(12).fontColor(getTheme(this.themeMode).textSecondary)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Blank()
                    Text('点击地图选点').fontSize(10).fontColor('#10B981')
                  }.width('100%').padding(8).backgroundColor(isDarkTheme() ? '#1A2E24' : '#F0FDF4').borderRadius(8).margin({ bottom: 6 })

                  // 加载指示器
                  if (this.navIsSearching) {
                    Row() {
                      LoadingProgress().width(14).height(14).color('#10B981')
                      Text('搜索中...').fontSize(12).fontColor('#10B981').margin({ left: 6 })
                      Blank()
                    }.width('100%').padding(6)
                  }

                  // 搜索结果
                  if (this.navSearchResults.length > 0) {
                    Scroll() {
                      Column() {
                        ForEach(this.navSearchResults, (poi: PoiResult) => {
                          Row() {
                            Column() {
                              Text(poi.name).fontSize(14).fontColor(getTheme(this.themeMode).textPrimary).maxLines(1)
                                .textOverflow({ overflow: TextOverflow.Ellipsis })
                              Text(poi.address || '').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).maxLines(1)
                                .textOverflow({ overflow: TextOverflow.Ellipsis })
                            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                            Text(poi.distance > 0 ? (poi.distance < 1000 ? Math.floor(poi.distance) + 'm' : (poi.distance / 1000).toFixed(1) + 'km') : '')
                              .fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).margin({ right: 4 })
                            Text('→').fontSize(18).fontColor(getTheme(this.themeMode).textTertiary)
                          }
                          .width('100%').padding({ top: 10, bottom: 10 })
                          .border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
                          .onClick(() => { this.navSelectDestination(poi); })
                        })
                      }
                    }.height(160).margin({ bottom: 8 })
                  }
                }

                // 阶段 2: 路线已显示
                if (this.navRoute) {
                  if (this.navIsCalculating) {
                    Row() {
                      LoadingProgress().width(14).height(14).color('#10B981')
                      Text('路线计算中...').fontSize(12).fontColor('#10B981').margin({ left: 6 })
                      Blank()
                    }.width('100%').padding({ top: 4, bottom: 8 })
                  }

                  // 路线摘要
                  Row() {
                    Column() {
                      Text(this.formatNavDistance(this.navRoute.distance))
                        .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#10B981')
                      Text('距离').fontSize(10).fontColor(getTheme(this.themeMode).textSecondary)
                    }.layoutWeight(1)
                    Column() {
                      Text(this.formatNavDuration(this.navRoute.duration))
                        .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#10B981')
                      Text('预计时间').fontSize(10).fontColor(getTheme(this.themeMode).textSecondary)
                    }.layoutWeight(1)
                    Column() {
                      Text(this.navRoute.steps.length.toString())
                        .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#10B981')
                      Text('步骤').fontSize(10).fontColor(getTheme(this.themeMode).textSecondary)
                    }.layoutWeight(1)
                  }.width('100%').padding(10).backgroundColor(isDarkTheme() ? '#1A2E24' : '#F0FDF4').borderRadius(10).margin({ bottom: 6 })

                  // 起终点
                  Text('🟢 ' + this.navOriginName + '  →  🔴 ' + (this.navRoute.destination || '目的地'))
                    .fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).width('100%').margin({ bottom: 6 })
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })

                  // 步骤列表
                  Text('导航步骤').fontSize(12).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
                    .width('100%').margin({ bottom: 4 })
                  Scroll() {
                    Column() {
                      ForEach(this.navRoute.steps, (step: NavStep, idx: number) => {
                        Row() {
                          Text(this.navStepActionIcon(step.action)).fontSize(16).width(24)
                          Column() {
                            Text(step.instruction || '继续前行').fontSize(12).fontColor(getTheme(this.themeMode).textPrimary)
                              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                            if (step.road && step.road.length > 0) {
                              Text(step.road).fontSize(10).fontColor(getTheme(this.themeMode).textSecondary)
                            }
                          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                          Text(step.distance > 0 ? (step.distance < 1000 ? Math.floor(step.distance) + 'm' : (step.distance / 1000).toFixed(1) + 'km') : '')
                            .fontSize(10).fontColor(getTheme(this.themeMode).textSecondary)
                        }
                        .width('100%').padding({ top: 6, bottom: 6 })
                        .border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
                        .backgroundColor(this.navSelectedStepIndex === idx ? '#F0FDF4' : Color.Transparent)
                        .borderRadius(6)
                        .onClick(() => { this.navSelectedStepIndex = idx; })
                      })
                    }
                  }.height(150).margin({ bottom: 6 })

                  // 操作按钮
                  Row() {
                    Button('清除路线')
                      .fontSize(12).height(34).layoutWeight(1)
                      .backgroundColor(getTheme(this.themeMode).surfaceSecondary).fontColor(getTheme(this.themeMode).textSecondary).borderRadius(17)
                      .onClick(() => { this.clearNavigationRoute(); })
                    Button('换模式')
                      .fontSize(12).height(34).layoutWeight(1)
                      .backgroundColor(getTheme(this.themeMode).surfaceSecondary).fontColor(getTheme(this.themeMode).textPrimary).borderRadius(17)
                      .onClick(() => { this.navRoute = null; })
                      .margin({ left: 6, right: 6 })
                  }.width('100%')
                }
              }
              .padding(12).backgroundColor(getTheme(this.themeMode).surface)
              .borderRadius({ topLeft: 16, topRight: 16 })
              .shadow({ radius: 8, color: '#20000000', offsetY: -2 })
            }
            .width('100%')
            .position({ x: 0, y: '55%' }).zIndex(102)
          }

        }
        .width('100%').height('100%')

        // 其他 tab 覆盖层
        if (this.currentTab === 1) {
          TravelJournalContent({ segments: this.segments })
        }
        if (this.currentTab === 2) {
          TourGuideContent()
        }
        if (this.currentTab === 3) {
          ProfileContent()
        }
      }
      .width('100%').layoutWeight(1)

      Row() {
        this.BuildTab('🗺️', '地图', 0)
        this.BuildTab('📋', '行程', 1)
        this.BuildTab('🧭', '导游', 2)
        this.BuildTab('👤', '我的', 3)
      }
      .width('100%').height(56)
      .backgroundColor(getTheme(this.themeMode).tabBarBg)
      .borderRadius({ topLeft: RADIUS.xl, topRight: RADIUS.xl })
      .shadow({ radius: 8, color: getTheme(this.themeMode).shadow, offsetY: -2 })
    }
    .width('100%').height('100%')
    .backgroundColor(getTheme(this.themeMode).pageBg)
  }

  @Builder
  BuildTab(icon: string, label: string, idx: number) {
    Column() {
      Text(icon).fontSize(20)
        .opacity(this.currentTab === idx ? 1.0 : 0.4)
      Text(label).fontSize(FONT.label)
        .fontColor(this.currentTab === idx ? getTheme(this.themeMode).primary : getTheme(this.themeMode).textTertiary)
        .fontWeight(this.currentTab === idx ? FontWeight.Medium : FontWeight.Normal)
        .margin({ top: 2 })
      if (this.currentTab === idx) {
        Row().width(20).height(3)
          .backgroundColor(getTheme(this.themeMode).primary)
          .borderRadius(2)
          .margin({ top: 4 })
      }
    }
    .layoutWeight(1).height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => { this.switchTab(idx); })
  }
}
