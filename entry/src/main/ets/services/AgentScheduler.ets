/**
 * Agent 调度器
 * 管理推荐任务的定时触发和生命周期
 */
import { Logger } from '../common/Logger';
import { common } from '@kit.AbilityKit';
import { RecommendationEngine } from './RecommendationEngine';
import { Recommendation } from '../model/Recommendation';
import { Dao } from '../database/Dao';
import { APP_TAG } from '../common/Constants';

const TAG = 'AgentScheduler';
const REFRESH_INTERVAL_MS: number = 5 * 60 * 1000;    // 后台定时检查间隔 5 分钟
const MIN_REFRESH_INTERVAL_MS: number = 60 * 1000;     // 最少 1 分钟刷新间隔
const SIGNIFICANT_MOVE_M: number = 500;                 // 位置偏移 > 500m 才自动刷新

export class AgentScheduler {
  private static instance: AgentScheduler | null = null;
  private engine: RecommendationEngine;
  private timerId: number = -1;
  private dao: Dao;
  private lastLat: number = 0;
  private lastLng: number = 0;
  private lastRefreshLat: number = 0;  // 上次刷新时的位置
  private lastRefreshLng: number = 0;
  private running: boolean = false;
  private refreshCycle: number = 0;
  private lastRefreshTime: number = 0;

  private constructor() {
    this.dao = Dao.getInstance();
    this.engine = new RecommendationEngine(this.dao);
  }

  static getInstance(): AgentScheduler {
    if (!AgentScheduler.instance) {
      AgentScheduler.instance = new AgentScheduler();
    }
    return AgentScheduler.instance;
  }

  start(lat: number, lng: number): void {
    this.lastLat = lat;
    this.lastLng = lng;
    this.running = true;

    Logger.info(TAG, 'Agent scheduler started, lat=%{public}.4f lng=%{public}.4f', lat, lng);
    // 清除旧推荐数据（历史版本的 photoUrl 可能已失效导致红色图钉）
    this.dao.deleteAllRecommendations();
    // 不立即 refresh，等待地图就绪后由 MapPage 调用 notifyMapReady()
    this.timerId = setInterval(() => { this.refresh(); }, REFRESH_INTERVAL_MS);
  }

  /**
   * 地图就绪后调用，触发首次刷新
   * @param lat 当前 GPS 纬度
   * @param lng 当前 GPS 经度
   */
  notifyMapReady(lat: number, lng: number): void {
    if (this.running) {
      // 使用 GPS 实时位置覆盖 start() 中的默认值
      if (lat !== 0 && lng !== 0) {
        this.lastLat = lat;
        this.lastLng = lng;
      }
      Logger.info(TAG, 'Map ready, triggering first refresh at lat=%{public}.4f lng=%{public}.4f',
        this.lastLat, this.lastLng);
      this.refresh();
    }
  }

  stop(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.running = false;
    Logger.info(TAG, 'Agent scheduler stopped');
  }

  isRunning(): boolean { return this.running; }

  /** 检查推荐后台刷新是否启用（默认开启） */
  async isEnabled(): Promise<boolean> {
    try {
      const profile = await this.dao.queryUserProfile('recommendation_enabled');
      if (profile && profile.preferenceValue === 'false') {
        return false;
      }
    } catch (e) { /* ignore */ }
    return true;
  }

  updateLocation(lat: number, lng: number): void {
    this.lastLat = lat;
    this.lastLng = lng;
  }

  /** 位置是否发生了显著变化（>500m） */
  private hasSignificantMove(): boolean {
    if (this.lastRefreshLat === 0) return true; // 首次
    const dLat: number = (this.lastLat - this.lastRefreshLat) * 111320;
    const dLng: number = (this.lastLng - this.lastRefreshLng) * 111320 *
      Math.cos((this.lastLat + this.lastRefreshLat) / 2 * Math.PI / 180);
    return Math.sqrt(dLat * dLat + dLng * dLng) > SIGNIFICANT_MOVE_M;
  }

  /**
   * 手动触发刷新（用户点刷新按钮 / 切到推荐 tab）
   */
  async requestRefresh(): Promise<void> {
    if (this.lastLat === 0 && this.lastLng === 0) return;
    this.lastRefreshTime = Date.now();
    this.lastRefreshLat = this.lastLat;
    this.lastRefreshLng = this.lastLng;
    await this.doRefresh();
  }

  /**
   * 内部刷新（自动触发：位置显著变化 / 定时检查）
   */
  private async refresh(): Promise<void> {
    if (this.lastLat === 0 && this.lastLng === 0) return;
    const now: number = Date.now();
    if (now - this.lastRefreshTime < MIN_REFRESH_INTERVAL_MS) return;
    // 检查后台推荐开关
    const enabled: boolean = await this.isEnabled();
    if (!enabled) {
      Logger.info(TAG, 'Recommendation disabled — skipping auto-refresh');
      return;
    }
    if (!this.hasSignificantMove()) {
      Logger.info(TAG, 'Location unchanged — skipping auto-refresh');
      return;
    }
    this.lastRefreshTime = now;
    this.lastRefreshLat = this.lastLat;
    this.lastRefreshLng = this.lastLng;
    await this.doRefresh();
  }

  private async doRefresh(): Promise<void> {
    try {
      const hour: number = new Date().getHours();
      let context: string = 'daily';
      if (hour >= 7 && hour < 10) context = 'breakfast';
      else if (hour >= 11 && hour < 14) context = 'lunch';
      else if (hour >= 14 && hour < 17) context = 'afternoon_tea';
      else if (hour >= 17 && hour < 21) context = 'dinner';
      else if (hour >= 21) context = 'night';

      const doWebSearch: boolean = (this.refreshCycle % 2 === 0);
      this.refreshCycle++;

      const recs: Recommendation[] =
        await this.engine.generateNow(context, this.lastLat, this.lastLng, doWebSearch);

      await this.dao.deleteAllRecommendations();
      for (const rec of recs) {
        await this.dao.insertRecommendation(rec);
      }
      if (recs.length > 0) {
        Logger.info(TAG, 'Refreshed: %{public}d recommendations for [%{public}s] (pos=%{public}.4f,%{public}.4f)',
          recs.length, context, this.lastLat, this.lastLng);
        this.engine.clearCache();
      }
    } catch (e) {
      Logger.warn(TAG, 'refresh failed');
    }
  }
}
