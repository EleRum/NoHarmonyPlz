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
import { UserBasicInfo } from '../model/UserBasicInfo';
import { Recommendation } from '../model/Recommendation';
import { SegmentCalibration } from '../model/SegmentCalibration';
import {
  TABLE_FOOTPRINT,
  TABLE_ACTIVITY_SEGMENT,
  TABLE_USER_PROFILE,
  TABLE_RECOMMENDATION,
  TABLE_SEGMENT_CALIBRATION,
  TABLE_USER_BASIC_INFO,
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

  /** 更新单个 ActivitySegment（适用于非当天的历史段编辑） */
  async updateActivitySegment(seg: ActivitySegment): Promise<void> {
    const db = this.getDb();
    if (!db) return;

    try {
      await db.update(
        TABLE_ACTIVITY_SEGMENT,
        {
          'activity_type': seg.activityType,
          'poi_name': seg.poiName,
          'summary': seg.summary
        },
        'id = ?',
        [seg.id]
      );
    } catch (err) {
      Logger.error(TAG, 'updateActivitySegment failed: %{public}s', JSON.stringify(err));
    }
  }

  // ════════════════════════════════════════════════════════
  //  SegmentCalibration CRUD
  // ════════════════════════════════════════════════════════

  async upsertSegmentCalibration(cal: SegmentCalibration): Promise<void> {
    const db = this.getDb();
    if (!db) return;

    try {
      // 先删再插，实现 upsert（HarmonyOS relationalStore 不支持 ON CONFLICT）
      await db.delete(
        TABLE_SEGMENT_CALIBRATION,
        'day_key = ? AND segment_start_time = ?',
        [cal.dayKey, cal.segmentStartTime]
      );
      await db.insert(TABLE_SEGMENT_CALIBRATION, cal.toValuesBucket());
      Logger.info(TAG, 'upsertSegmentCalibration: day=%{public}s startTime=%{public}d',
        cal.dayKey, cal.segmentStartTime);
    } catch (err) {
      Logger.error(TAG, 'upsertSegmentCalibration failed: %{public}s', JSON.stringify(err));
    }
  }

  async queryCalibrationsByDay(dayKey: string): Promise<SegmentCalibration[]> {
    const db = this.getDb();
    if (!db) return [];

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_SEGMENT_CALIBRATION} WHERE day_key = ?`,
        [dayKey]
      );
      const list: SegmentCalibration[] = [];
      while (rs.goToNextRow()) {
        list.push(SegmentCalibration.fromResultSet(rs.getRow()));
      }
      rs.close();
      return list;
    } catch (err) {
      Logger.error(TAG, 'queryCalibrationsByDay failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  async deleteActivitySegmentById(id: number): Promise<void> {
    const db = this.getDb();
    if (!db) return;

    try {
      await db.delete(TABLE_ACTIVITY_SEGMENT, 'id = ?', [id]);
    } catch (err) {
      Logger.error(TAG, 'deleteActivitySegmentById failed: %{public}s', JSON.stringify(err));
    }
  }

  async deleteSegmentCalibration(dayKey: string, startTime: number): Promise<void> {
    const db = this.getDb();
    if (!db) return;

    try {
      await db.delete(
        TABLE_SEGMENT_CALIBRATION,
        'day_key = ? AND segment_start_time = ?',
        [dayKey, startTime]
      );
      Logger.info(TAG, 'deleteSegmentCalibration: day=%{public}s startTime=%{public}d',
        dayKey, startTime);
    } catch (err) {
      Logger.error(TAG, 'deleteSegmentCalibration failed: %{public}s', JSON.stringify(err));
    }
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
  //  UserBasicInfo CRUD
  // ════════════════════════════════════════════════════════

  /** 保存/更新用户基础信息（单行模式，始终操作 id=1 的行） */
  async upsertUserBasicInfo(info: UserBasicInfo): Promise<void> {
    const db = this.getDb();
    if (!db) return;

    try {
      // 查找是否已有记录
      const rs = await db.querySql(
        `SELECT id FROM ${TABLE_USER_BASIC_INFO} LIMIT 1`
      );
      const exists: boolean = rs.goToNextRow();
      let existingId: number = 0;
      if (exists) {
        existingId = rs.getLong(0);
      }
      rs.close();

      info.updatedAt = Date.now();

      if (exists) {
        // 更新已有行
        await db.update(
          TABLE_USER_BASIC_INFO,
          {
            'username': info.username,
            'age': info.age,
            'city': info.city,
            'gender': info.gender,
            'travel_preferences': info.travelPreferences,
            'updated_at': info.updatedAt
          },
          'id = ?',
          [existingId]
        );
      } else {
        // 插入新行
        info.createdAt = Date.now();
        await db.insert(TABLE_USER_BASIC_INFO, info.toValuesBucket());
      }
      Logger.info(TAG, 'upsertUserBasicInfo success');
    } catch (err) {
      Logger.error(TAG, 'upsertUserBasicInfo failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 查询用户基础信息（单行） */
  async queryUserBasicInfo(): Promise<UserBasicInfo | null> {
    const db = this.getDb();
    if (!db) return null;

    try {
      const rs = await db.querySql(
        `SELECT * FROM ${TABLE_USER_BASIC_INFO} LIMIT 1`
      );
      if (rs.goToNextRow()) {
        const info = UserBasicInfo.fromResultSet(rs.getRow());
        rs.close();
        return info;
      }
      rs.close();
      return null;
    } catch (err) {
      Logger.error(TAG, 'queryUserBasicInfo failed: %{public}s', JSON.stringify(err));
      return null;
    }
  }

  // ════════════════════════════════════════════════════════
  //  Privacy / local data
  // ════════════════════════════════════════════════════════

  async clearAllLocalData(): Promise<number> {
    const db = this.getDb();
    if (!db) return 0;

    const tables: string[] = [
      TABLE_RECOMMENDATION,
      TABLE_SEGMENT_CALIBRATION,
      TABLE_ACTIVITY_SEGMENT,
      TABLE_FOOTPRINT,
      TABLE_USER_PROFILE,
      TABLE_USER_BASIC_INFO
    ];
    let total: number = 0;
    for (const table of tables) {
      try {
        total += await db.delete(table, '1 = 1');
      } catch (err) {
        Logger.error(TAG, 'clearAllLocalData failed for %{public}s: %{public}s', table, JSON.stringify(err));
      }
    }
    Logger.info(TAG, 'clearAllLocalData deleted=%{public}d', total);
    return total;
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
