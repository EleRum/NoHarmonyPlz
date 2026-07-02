/**
 * Footprint Map Page
 * Data-first: show footprints on open, switch when map ready
 * Uses IMapService/MapJsBridge for cross-platform map operations
 */
import { Logger } from '../common/Logger';
import router from '@ohos.router';
import { webview } from '@kit.ArkWeb';
import { MapWebView } from '../services/map/MapWebView';
import { geoLocationManager } from '@kit.LocationKit';
import { Footprint } from '../model/Footprint';
import { ActivitySegment } from '../model/ActivitySegment';
import { Dao } from '../database/Dao';
import { formatTimestamp, haversineDistance } from '../common/LocationUtils';
import { ActivityClassifier } from '../services/ActivityClassifier';
import { ACTIVITY_LABELS } from '../common/Constants';
import { TimelineContent } from './TimelinePage';
import { RecommendContent } from './RecommendPage';
import { ReportContent } from './ReportPage';
import { AgentScheduler } from '../services/AgentScheduler';
import { RecommendationEngine } from '../services/RecommendationEngine';
import { AmapSearchService } from '../services/map/AmapSearchService';
import { Recommendation } from '../model/Recommendation';
import { AiAgent, AgentReply } from '../services/AiAgent';
import { IMapService, MapEventCallbacks } from '../services/map/IMapService';
import { MapJsBridge } from '../services/map/MapJsBridge';
import {
  LatLng, LatLngBounds, MarkerIconStyle, MapInitConfig
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

@Entry
@Component
export struct MapPage {
  private mapService: IMapService | null = null;
  private hasDrawn: boolean = false;
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
  private liveMarker: string | null = null;
  private liveTail: string | null = null;
  private dayPolylines: string[] = [];
  private dayPoiMarkers: string[][] = [];
  private segMarkers: string[] = [];
  @State showRecMarkers: boolean = false;
  @State showRecPicker: boolean = false;
  @State showChat: boolean = false;
  @State chatInput: string = '';
  @State chatMessages: string[] = ['你好！我是足迹助手，可以帮你修正活动类型、查询数据。试试说"帮助"。'];
  @State timelineRefreshKey: number = 0;
  private aiAgent: AiAgent | null = null;

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

  /** 切换历史天/今天时，显隐实时元素 + 今日限定内容 */
  toggleLiveElements(visible: boolean): void {
    const ms = this.mapService;
    if (this.liveMarker && ms) {
      try { ms.setMarkerVisible(this.liveMarker, visible); } catch (e) {}
    }
    if (this.liveTail && ms) {
      try { ms.setPolylineVisible(this.liveTail, visible); } catch (e) {}
    }
    for (let i = 0; i < this.dayPolylines.length; i++) {
      try { if (ms) ms.setPolylineVisible(this.dayPolylines[i], i === this.selectedDayIndex); } catch (e) {}
    }
    for (let i = 0; i < this.dayPoiMarkers.length; i++) {
      for (const m of this.dayPoiMarkers[i]) {
        try { if (ms) ms.setMarkerVisible(m, i === this.selectedDayIndex); } catch (e) {}
      }
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
      const recs: Recommendation[] = await this.dao.queryRecentRecommendations(10);
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
  }

  async loadAllData(): Promise<void> {
    try {
      this.footprints = await this.dao.queryAllFootprintsUnlimited();
      this.footprintCount = this.footprints.length;
      this.segments = await this.dao.queryAllActivitySegments(200);
      this.buildDayRoutes();
      if (this.dayRoutes.length > 0) {
        const tKey: string = new Date().toISOString().slice(0, 10).replace(/-/g, '');
        this.isViewingToday = (this.dayRoutes[this.selectedDayIndex].dayKey === tKey);
      }
      Logger.info(TAG, 'Loaded %{public}d footprints, %{public}d routes',
        this.footprintCount, this.dayRoutes.length);
      if (this.isMapReady && this.dayRoutes.length > 0) {
        this.drawOnMap();
        if (this.isViewingToday) {
          this.drawSegmentMarkers();
        }
      }
    } catch (err) { /* ignore */ }
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
        this.setupGpsTracking();
        this.moveCamera();
        if (this.dayRoutes.length > 0) {
          this.drawOnMap();
        }
      },
      onMarkerClick: (id: string, lat: number, lng: number, _title: string): void => {
        this.handleMapMarkerClick(id, lat, lng);
      },
      onMapClick: (_lat: number, _lng: number): void => {
        // 处理地图点击
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
        this.setupGpsTracking();
        this.moveCamera();
        if (this.dayRoutes.length > 0) {
          this.drawOnMap();
        }
      }
    });
  }

  /** 处理地图标记点击 */
  handleMapMarkerClick(id: string, lat: number, lng: number): void {
    try {
      const pos: LatLng | undefined = this.markerPositions[id];
      const useLat: number = pos ? pos.latitude : lat;
      const useLng: number = pos ? pos.longitude : lng;
      const key: string = `${useLat.toFixed(6)},${useLng.toFixed(6)}`;
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
          await this.dao.deleteActivitySegmentsByDay(todayKey);
          await this.dao.insertActivitySegments(segs);
          Logger.info(TAG, 'Activity classify: %{public}d segments from %{public}d pts',
            segs.length, todayFps.length);
          this.segments = await this.dao.queryAllActivitySegments(200);
          this.timelineRefreshKey++;
          if (this.isViewingToday) {
            this.drawSegmentMarkers();
          }
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

      if (!this.liveMarker) {
        createBlueDot(gpsPt);
      }

      if (frozenEnd && pendingGps && this.isViewingToday &&
          (frozenEnd.latitude !== pendingGps.latitude ||
           frozenEnd.longitude !== pendingGps.longitude)) {
        ms.addPolyline({
          points: [frozenEnd, pendingGps],
          color: '#FF4444', width: 6,
          zIndex: 20, clickable: false
        });
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
    if (this.hasDrawn) return;
    this.hasDrawn = true;
    try {
      const allPts: LatLng[] = [];
      for (let ri = 0; ri < this.dayRoutes.length; ri++) {
        const route: DayRoute = this.dayRoutes[ri];
        const fps: Footprint[] = route.footprints;
        if (fps.length < 2) continue;
        const pts: LatLng[] = [];
        for (const fp of fps) {
          pts.push({ latitude: fp.latitude, longitude: fp.longitude });
        }
        const polylineId: string = ms.addPolyline({
          points: pts, color: ROUTE_COLORS[ri % ROUTE_COLORS.length],
          width: 6, zIndex: 11, clickable: false
        });
        this.dayPolylines.push(polylineId);
        if (ri !== this.selectedDayIndex) {
          try { ms.setPolylineVisible(polylineId, false); } catch (e) {}
        }
        allPts.push(...pts);
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

  drawSegmentMarkers(): void {
    const ms = this.mapService;
    if (!ms) return;

    const todayKey: string = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    for (const seg of this.segments) {
      if (seg.dayKey !== todayKey) continue;
      const label: string = seg.poiName
        ? (this.activityEmoji(seg.activityType) + ' ' + seg.poiName)
        : (this.activityEmoji(seg.activityType) + ' ' + (this.activityLabel(seg.activityType) || '未知活动'));
      const posKey: string = `${seg.latitude.toFixed(6)},${seg.longitude.toFixed(6)}`;
      if (this.markerMap[posKey]) continue;
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
      router.pushUrl({
        url: 'pages/WaypointDetailPage',
        params: {
          poiName: fp.poiName, latitude: fp.latitude, longitude: fp.longitude,
          activityTag: fp.activityTag, timestamp: fp.timestamp,
          stayDuration: fp.stayDuration, speed: fp.speed, photoList: fp.photoId
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
      footprintCount: this.footprintCount
    });
  }

  async sendChat(): Promise<void> {
    const msg: string = this.chatInput.trim();
    if (msg.length === 0) return;
    this.chatMessages.push('👤 ' + msg);
    this.chatInput = '';

    this.syncAgentContext();
    const reply: AgentReply = await this.getAiAgent().process(msg);
    this.chatMessages.push('🤖 ' + reply.text);

    if (reply.action === 'refresh_timeline') {
      this.triggerClassify();
    } else if (reply.action === 'show_recs') {
      if (!this.showRecMarkers) this.toggleRecMarkers();
    } else if (reply.action === 'switch_day') {
      this.selectedDayIndex = reply.actionParam || 0;
      this.focusOnDayRoute(this.selectedDayIndex);
    }
  }

  switchTab(index: number): void {
    if (index === this.currentTab) return;
    this.currentTab = index;
    if (index === 1) {
      this.triggerClassify();
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
        await this.dao.deleteActivitySegmentsByDay(todayKey);
        await this.dao.insertActivitySegments(segs);
        Logger.info(TAG, 'Manual classify: %{public}d segments from %{public}d pts',
          segs.length, todayFps.length);
        this.segments = await this.dao.queryAllActivitySegments(200);
        this.timelineRefreshKey++;
        if (this.isViewingToday) {
          this.drawSegmentMarkers();
        }
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
                    if (!this.isViewingToday && this.showRecMarkers) {
                      this.showRecMarkers = false;
                      for (const m of this.recMarkers) {
                        try { if (this.mapService) this.mapService.setMarkerVisible(m, false); } catch (e) {}
                      }
                    }
                    if (this.isViewingToday) { this.drawSegmentMarkers(); }
                    this.focusOnDayRoute(idx);
                  })
                })
              }.padding({ left: 8, right: 8 })
              .width('100%').height(36)

              if (this.dayRoutes.length > 0) {
                Row() {
                  Column() {
                    Text(this.routeDistStr()).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                    Text(this.routeDistUnit()).fontSize(11).fontColor('#FFFFFF99')
                  }.layoutWeight(1)
                  Column() {
                    Text(this.routeMinsStr()).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                    Text('min').fontSize(11).fontColor('#FFFFFF99')
                  }.layoutWeight(1)
                  Column() {
                    Text(this.routePaceStr()).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                    Text('pace /km').fontSize(11).fontColor('#FFFFFF99')
                  }.layoutWeight(1)
                  Column() {
                    Text(this.routePointsStr()).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                    Text('pts').fontSize(11).fontColor('#FFFFFF99')
                  }.layoutWeight(1)
                }.width('100%').padding({ top: 8, bottom: 8 })
              }
            }
            .padding(12)
            .backgroundColor('#99000000')
            .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 16, bottomRight: 16 })
            .width('100%')

            if (!this.isMapReady) {
              Text(this.footprintCount > 0
                ? `P ${this.footprintCount} footprints loaded, map initializing...`
                : 'No footprint data')
                .fontSize(13).fontColor('#FFFFFF').padding(8)
                .backgroundColor('#CC3B82F6').borderRadius(8).margin({ top: 8 })
            } else {
              Row() {
                Row() {}.width(8).height(8).borderRadius(4)
                  .backgroundColor('#50C878').margin({ right: 6 })
                Text(`GPS 录制中 · ${this.footprintCount} 个足迹点`)
                  .fontSize(12).fontColor('#FFFFFF')
              }
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor('#CC333333').borderRadius(14).margin({ top: 8 })
            }
          }
          .width('100%')

          // 推荐浮钮（右侧）
          Row() {
            Blank()
            Column() {
              Text(this.showRecMarkers ? '📍' : '🔍').fontSize(20)
              Text('推荐').fontSize(9).fontColor('#FFFFFF').margin({ top: 1 })
            }
            .width(48).height(48).borderRadius(24)
            .backgroundColor('#CC3B82F6').justifyContent(FlexAlign.Center)
            .shadow({ radius: 6, color: '#403B82F6', offsetY: 2 })
            .onClick(() => { this.toggleRecMarkers(); })
          }
          .width('100%').padding({ right: 12 }).margin({ top: 120 })

          // AI 聊天浮钮
          Row() {
            Blank()
            Column() {
              Text('💬').fontSize(20)
              Text('AI').fontSize(9).fontColor('#FFFFFF').margin({ top: 1 })
            }
            .width(48).height(48).borderRadius(24)
            .backgroundColor('#CC8B5CF6').justifyContent(FlexAlign.Center)
            .shadow({ radius: 6, color: '#408B5CF6', offsetY: 2 })
            .onClick(() => { this.showChat = !this.showChat; this.syncAgentContext(); })
          }
          .width('100%').padding({ right: 12 }).margin({ top: 176 })

          // 推荐选择面板
          if (this.showRecPicker) {
            Column() {
              Column() {}.width('100%').layoutWeight(1)
                .onClick(() => { this.showRecPicker = false; })
              Column() {
                Row() {
                  Text('附近门店').fontSize(16).fontWeight(FontWeight.Bold)
                  Blank()
                  Text('✕').fontSize(18).fontColor('#999')
                    .onClick(() => { this.showRecPicker = false; })
                }.width('100%').margin({ bottom: 10 })
                Scroll() {
                  Column() {
                    ForEach(this.pickerGroup, (rec: Recommendation) => {
                      Row() {
                        Text(this.activityEmoji(rec.placeType) + ' ' + rec.placeName)
                          .fontSize(15).fontColor('#222').layoutWeight(1)
                        Text('›').fontSize(18).fontColor('#CCC')
                      }
                      .width('100%').padding({ top: 12, bottom: 12 })
                      .border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
                      .onClick(() => { this.openRecDetail(rec); })
                    })
                  }
                }.height(240)
              }
              .padding(16).backgroundColor('#FFFFFF')
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
                  Text('🤖 足迹助手').fontSize(16).fontWeight(FontWeight.Bold)
                  Blank()
                  Text('✕').fontSize(18).fontColor('#999')
                    .onClick(() => { this.showChat = false; })
                }.width('100%').margin({ bottom: 8 })

                Scroll() {
                  Column() {
                    ForEach(this.chatMessages, (msg: string) => {
                      Row() {
                        Text(msg).fontSize(13).fontColor('#333')
                          .padding(10).backgroundColor('#F0F2F5').borderRadius(12)
                          .maxLines(10).textOverflow({ overflow: TextOverflow.Clip })
                      }.width('100%').margin({ bottom: 6 })
                    })
                  }
                }.height(180).margin({ bottom: 8 })

                Row() {
                  TextInput({ placeholder: '输入指令...', text: this.chatInput })
                    .fontSize(13).height(36).layoutWeight(1)
                    .backgroundColor('#F5F5F5').borderRadius(18).padding({ left: 12, right: 12 })
                    .onChange((v: string) => { this.chatInput = v; })
                  Button('发送')
                    .fontSize(12).height(36).padding({ left: 12, right: 12 })
                    .backgroundColor('#8B5CF6').borderRadius(18)
                    .onClick(() => { this.sendChat(); })
                }.width('100%')
              }
              .padding(12).backgroundColor('#FFFFFF')
              .borderRadius({ topLeft: 16, topRight: 16 })
              .shadow({ radius: 8, color: '#20000000', offsetY: -2 })
            }
            .width('100%').height('100%')
            .position({ x: 0, y: 0 }).zIndex(101)
          }
        }
        .width('100%').height('100%')

        // 其他 tab 覆盖层
        if (this.currentTab === 1) {
          TimelineContent({ onTabChange: (idx: number): void => { this.switchTab(idx); }, segments: this.segments })
        }
        if (this.currentTab === 2) {
          RecommendContent({ onTabChange: (idx: number): void => { this.switchTab(idx); } })
        }
        if (this.currentTab === 3) {
          ReportContent({ onTabChange: (idx: number): void => { this.switchTab(idx); } })
        }
      }
      .width('100%').layoutWeight(1)

      Row() {
        this.BuildTab('🏃', '路线', 0)
        this.BuildTab('📅', '时间线', 1)
        this.BuildTab('💡', '推荐', 2)
        this.BuildTab('📊', '报告', 3)
      }
      .width('100%').height(54).backgroundColor('#FFFFFF')
      .border({ width: { top: 0.5 }, color: '#E8E8E8' })
    }
    .width('100%').height('100%')
  }

  @Builder
  BuildTab(icon: string, label: string, idx: number) {
    Column() {
      Text(icon).fontSize(22).opacity(this.currentTab === idx ? 1.0 : 0.35)
      Text(label).fontSize(10)
        .fontColor(this.currentTab === idx ? '#3B82F6' : '#AAA')
        .margin({ top: 2 })
        .fontWeight(this.currentTab === idx ? FontWeight.Medium : FontWeight.Normal)
      Row() {}.width(20).height(2)
        .backgroundColor(this.currentTab === idx ? '#3B82F6' : Color.Transparent)
        .borderRadius(1).margin({ top: 4 })
    }
    .layoutWeight(1).height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.switchTab(idx); })
  }
}
