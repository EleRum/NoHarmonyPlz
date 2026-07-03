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
const REFRESH_INTERVAL_MS: number = 5 * 60 * 1000;
const MIN_REFRESH_INTERVAL_MS: number = 60 * 1000;  // 最少 1 分钟间隔

export class AgentScheduler {
  private static instance: AgentScheduler | null = null;
  private engine: RecommendationEngine;
  private timerId: number = -1;
  private dao: Dao;
  private lastLat: number = 0;
  private lastLng: number = 0;
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

  updateLocation(lat: number, lng: number): void {
    this.lastLat = lat;
    this.lastLng = lng;
    // 限频：距离上次刷新不足 1 分钟时跳过
    const now: number = Date.now();
    if (now - this.lastRefreshTime < MIN_REFRESH_INTERVAL_MS) return;
    this.refresh();
  }

  /**
   * 手动触发刷新
   */
  async refresh(): Promise<void> {
    if (this.lastLat === 0 && this.lastLng === 0) return;
    this.lastRefreshTime = Date.now();

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

      // 清除旧推荐，存新的（确保位置变化后旧城市推荐不残留）
      await this.dao.deleteAllRecommendations();
      for (const rec of recs) {
        await this.dao.insertRecommendation(rec);
      }
      if (recs.length > 0) {
        Logger.info(TAG,
          'Refreshed: %{public}d recommendations for [%{public}s]',
          recs.length, context);
        // 清缓存以重新学习
        this.engine.clearCache();
      }
    } catch (e) {
      Logger.warn(TAG, 'refresh failed');
    }
  }
}
