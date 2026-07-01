/**
 * 数据访问层
 * 封装所有数据库 CRUD 操作，通过平台抽象的 IDatabase 接口
 * 使用纯 SQL 语句，确保 HarmonyOS / Android 双平台兼容
 */
import { Logger } from '../common/Logger';
import { DatabaseHelper } from './DatabaseHelper';
import { IDatabase, IResultSet, ValueType, ValuesBucket } from '../platform/database/IDatabase';
import { Footprint } from '../model/Footprint';
import { ActivitySegment } from '../model/ActivitySegment';
import { UserProfile } from '../model/UserProfile';
import { Recommendation } from '../model/Recommendation';
import {
  TABLE_FOOTPRINT,
  TABLE_ACTIVITY_SEGMENT,
  TABLE_USER_PROFILE,
  TABLE_RECOMMENDATION,
  APP_TAG
} from '../common/Constants';

const TAG = 'Dao';

export class Dao {
  private static instance: Dao | null = null;
  private helper: DatabaseHelper;

  private constructor() {
    this.helper = DatabaseHelper.getInstance();
  }

  static getInstance(): Dao {
    if (!Dao.instance) {
      Dao.instance = new Dao();
    }
    return Dao.instance;
  }

  private getDb(): IDatabase | null {
    return this.helper.getDatabase();
  }

  // ════════════════════════════════════════════════════════
  //  通用辅助方法
  // ════════════════════════════════════════════════════════

  /** 将 IResultSet 的所有行转换为 Footprint 列表 */
  private collectFootprints(rs: IResultSet, closeAfter: boolean = true): Footprint[] {
    const list: Footprint[] = [];
    while (rs.goToNextRow()) {
      list.push(Footprint.fromResultSet(rs.getRow()));
    }
    if (closeAfter) {
      rs.close();
    }
    return list;
  }

  /** 将 IResultSet 的所有行转换为 ActivitySegment 列表 */
  private collectSegments(rs: IResultSet, closeAfter: boolean = true): ActivitySegment[] {
    const list: ActivitySegment[] = [];
    while (rs.goToNextRow()) {
      list.push(ActivitySegment.fromResultSet(rs.getRow()));
    }
    if (closeAfter) {
      rs.close();
    }
    return list;
  }

  /** 将 IResultSet 的所有行转换为 Recommendation 列表 */
  private collectRecommendations(rs: IResultSet, closeAfter: boolean = true): Recommendation[] {
    const list: Recommendation[] = [];
    while (rs.goToNextRow()) {
      list.push(Recommendation.fromResultSet(rs.getRow()));
    }
    if (closeAfter) {
      rs.close();
    }
    return list;
  }

  // ════════════════════════════════════════════════════════
  //  Footprint CRUD
  // ════════════════════════════════════════════════════════

  async insertFootprint(fp: Footprint): Promise<number> {
    const db = this.getDb();
    if (!db) {
      Logger.error(TAG, 'insertFootprint: db is null');
      return -1;
    }
    try {
      const rowId = await db.insert(TABLE_FOOTPRINT, fp.toValuesBucket());
      Logger.info(TAG, 'insertFootprint success, rowId=%{public}d', rowId);
      return rowId;
    } catch (err) {
      Logger.error(TAG, 'insertFootprint failed: %{public}s', JSON.stringify(err));
      return -1;
    }
  }

  async queryFootprintsByDay(dayKey: string): Promise<Footprint[]> {
    const db = this.getDb();
    if (!db) return [];

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_FOOTPRINT} WHERE day_key = ? ORDER BY timestamp ASC`,
        [dayKey]
      );
      return this.collectFootprints(rs);
    } catch (err) {
      Logger.error(TAG, 'queryFootprintsByDay failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  async queryAllFootprints(limit: number = 500): Promise<Footprint[]> {
    const db = this.getDb();
    if (!db) return [];

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_FOOTPRINT} ORDER BY timestamp DESC LIMIT ?`,
        [limit]
      );
      return this.collectFootprints(rs);
    } catch (err) {
      Logger.error(TAG, 'queryAllFootprints failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  /** 查询全部足迹，不限制条数，按时间倒序 */
  async queryAllFootprintsUnlimited(): Promise<Footprint[]> {
    const db = this.getDb();
    if (!db) return [];

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_FOOTPRINT} ORDER BY timestamp DESC`
      );
      return this.collectFootprints(rs);
    } catch (err) {
      Logger.error(TAG, 'queryAllFootprintsUnlimited failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  async queryFootprintsByTimeRange(startTime: number, endTime: number): Promise<Footprint[]> {
    const db = this.getDb();
    if (!db) return [];

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_FOOTPRINT} WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp ASC`,
        [startTime, endTime]
      );
      return this.collectFootprints(rs);
    } catch (err) {
      Logger.error(TAG, 'queryFootprintsByTimeRange failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  async getFootprintCount(): Promise<number> {
    const db = this.getDb();
    if (!db) return 0;

    try {
      const rs = await db.querySql(
        `SELECT COUNT(*) AS total FROM ${TABLE_FOOTPRINT}`
      );
      if (rs.goToNextRow()) {
        const count = rs.getLong(0);
        rs.close();
        return count;
      }
      rs.close();
      return 0;
    } catch (err) {
      Logger.error(TAG, 'getFootprintCount failed: %{public}s', JSON.stringify(err));
      return 0;
    }
  }

  async getLastFootprint(): Promise<Footprint | null> {
    const db = this.getDb();
    if (!db) return null;

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_FOOTPRINT} ORDER BY timestamp DESC LIMIT 1`
      );
      if (rs.goToNextRow()) {
        const fp = Footprint.fromResultSet(rs.getRow());
        rs.close();
        return fp;
      }
      rs.close();
      return null;
    } catch (err) {
      Logger.error(TAG, 'getLastFootprint failed: %{public}s', JSON.stringify(err));
      return null;
    }
  }

  async deleteFootprintsOlderThan(timestamp: number): Promise<number> {
    const db = this.getDb();
    if (!db) return 0;

    try {
      const deleted = await db.delete(
        TABLE_FOOTPRINT,
        'timestamp < ?',
        [timestamp]
      );
      Logger.info(TAG, 'deleteFootprintsOlderThan deleted=%{public}d', deleted);
      return deleted;
    } catch (err) {
      Logger.error(TAG, 'deleteFootprintsOlderThan failed: %{public}s', JSON.stringify(err));
      return 0;
    }
  }

  // ════════════════════════════════════════════════════════
  //  ActivitySegment CRUD
  // ════════════════════════════════════════════════════════

  async insertActivitySegment(seg: ActivitySegment): Promise<number> {
    const db = this.getDb();
    if (!db) return -1;

    try {
      return await db.insert(TABLE_ACTIVITY_SEGMENT, seg.toValuesBucket());
    } catch (err) {
      Logger.error(TAG, 'insertActivitySegment failed: %{public}s', JSON.stringify(err));
      return -1;
    }
  }

  async queryActivitySegmentsByDay(dayKey: string): Promise<ActivitySegment[]> {
    const db = this.getDb();
    if (!db) return [];

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_ACTIVITY_SEGMENT} WHERE day_key = ? ORDER BY start_time ASC`,
        [dayKey]
      );
      return this.collectSegments(rs);
    } catch (err) {
      Logger.error(TAG, 'queryActivitySegmentsByDay failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  async queryAllActivitySegments(limit: number = 100): Promise<ActivitySegment[]> {
    const db = this.getDb();
    if (!db) return [];

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_ACTIVITY_SEGMENT} ORDER BY start_time DESC LIMIT ?`,
        [limit]
      );
      return this.collectSegments(rs);
    } catch (err) {
      Logger.error(TAG, 'queryAllActivitySegments failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  async queryDistinctDays(limit: number = 30): Promise<string[]> {
    const db = this.getDb();
    if (!db) return [];

    try {
      const rs = await db.querySql(
        `SELECT DISTINCT day_key FROM ${TABLE_FOOTPRINT} ORDER BY day_key DESC LIMIT ?`,
        [limit]
      );
      const days: string[] = [];
      while (rs.goToNextRow()) {
        const dayKey: string = rs.getString(0);
        if (dayKey) days.push(dayKey);
      }
      rs.close();
      return days;
    } catch (err) {
      Logger.error(TAG, 'queryDistinctDays failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  async queryFootprintCountByDay(dayKey: string): Promise<number> {
    const db = this.getDb();
    if (!db) return 0;

    try {
      const rs = await db.querySql(
        `SELECT COUNT(*) FROM ${TABLE_FOOTPRINT} WHERE day_key = ?`,
        [dayKey]
      );
      if (rs.goToNextRow()) {
        const count = rs.getLong(0);
        rs.close();
        return count;
      }
      rs.close();
      return 0;
    } catch (err) {
      return 0;
    }
  }

  async queryActivityCount(): Promise<number> {
    const db = this.getDb();
    if (!db) return 0;

    try {
      const rs = await db.querySql(
        `SELECT COUNT(*) FROM ${TABLE_ACTIVITY_SEGMENT}`
      );
      if (rs.goToNextRow()) {
        const count = rs.getLong(0);
        rs.close();
        return count;
      }
      rs.close();
      return 0;
    } catch (err) {
      return 0;
    }
  }

  async deleteActivitySegmentsByDay(dayKey: string): Promise<number> {
    const db = this.getDb();
    if (!db) return 0;

    try {
      const deleted = await db.delete(
        TABLE_ACTIVITY_SEGMENT,
        'day_key = ?',
        [dayKey]
      );
      return deleted;
    } catch (err) {
      Logger.error(TAG, 'deleteActivitySegmentsByDay failed: %{public}s', JSON.stringify(err));
      return 0;
    }
  }

  async insertActivitySegments(segs: ActivitySegment[]): Promise<number> {
    const db = this.getDb();
    if (!db) return 0;

    let count = 0;
    for (const seg of segs) {
      try {
        await db.insert(TABLE_ACTIVITY_SEGMENT, seg.toValuesBucket());
        count++;
      } catch (err) {
        Logger.error(TAG, 'insertActivitySegments item failed: %{public}s', JSON.stringify(err));
      }
    }
    return count;
  }

  // ════════════════════════════════════════════════════════
  //  UserProfile CRUD
  // ════════════════════════════════════════════════════════

  async upsertUserProfile(key: string, value: string, confidence: number): Promise<void> {
    const db = this.getDb();
    if (!db) return;

    try {
      // 先查是否存在
      const rs = await db.querySql(
        `SELECT id FROM ${TABLE_USER_PROFILE} WHERE preference_key = ?`,
        [key]
      );
      const exists: boolean = rs.goToNextRow();
      rs.close();

      if (exists) {
        // Update existing
        await db.update(
          TABLE_USER_PROFILE,
          {
            'preference_value': value,
            'confidence': confidence,
            'update_time': Date.now()
          },
          'preference_key = ?',
          [key]
        );
      } else {
        // Insert new
        const up = new UserProfile();
        up.preferenceKey = key;
        up.preferenceValue = value;
        up.confidence = confidence;
        up.updateTime = Date.now();
        await db.insert(TABLE_USER_PROFILE, up.toValuesBucket());
      }
    } catch (err) {
      Logger.error(TAG, 'upsertUserProfile failed: %{public}s', JSON.stringify(err));
    }
  }

  async queryUserProfile(key: string): Promise<UserProfile | null> {
    const db = this.getDb();
    if (!db) return null;

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_USER_PROFILE} WHERE preference_key = ?`,
        [key]
      );
      if (rs.goToNextRow()) {
        const up = UserProfile.fromResultSet(rs.getRow());
        rs.close();
        return up;
      }
      rs.close();
      return null;
    } catch (err) {
      Logger.error(TAG, 'queryUserProfile failed: %{public}s', JSON.stringify(err));
      return null;
    }
  }

  // ════════════════════════════════════════════════════════
  //  Recommendation CRUD
  // ════════════════════════════════════════════════════════

  async deleteAllRecommendations(): Promise<number> {
    const db = this.getDb();
    if (!db) return 0;

    try {
      const deleted = await db.delete(TABLE_RECOMMENDATION, '1 = 1');
      return deleted;
    } catch (err) {
      Logger.error(TAG, 'deleteAllRecommendations failed: %{public}s', JSON.stringify(err));
      return 0;
    }
  }

  async insertRecommendation(rec: Recommendation): Promise<number> {
    const db = this.getDb();
    if (!db) return -1;

    try {
      return await db.insert(TABLE_RECOMMENDATION, rec.toValuesBucket());
    } catch (err) {
      Logger.error(TAG, 'insertRecommendation failed: %{public}s', JSON.stringify(err));
      return -1;
    }
  }

  async queryRecentRecommendations(limit: number = 20): Promise<Recommendation[]> {
    const db = this.getDb();
    if (!db) return [];

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_RECOMMENDATION} ORDER BY timestamp DESC LIMIT ?`,
        [limit]
      );
      return this.collectRecommendations(rs);
    } catch (err) {
      Logger.error(TAG, 'queryRecentRecommendations failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }
}
