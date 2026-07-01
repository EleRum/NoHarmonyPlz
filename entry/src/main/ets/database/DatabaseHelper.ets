/**
 * 数据库初始化助手
 * 单例模式，通过平台抽象层管理数据库的创建和升级
 */
import { Logger } from '../common/Logger';
import { PlatformBridge } from '../platform/PlatformBridge';
import { IDatabase } from '../platform/database/IDatabase';
import {
  DB_NAME,
  TABLE_FOOTPRINT,
  TABLE_ACTIVITY_SEGMENT,
  TABLE_USER_PROFILE,
  TABLE_RECOMMENDATION
} from '../common/Constants';

const TAG = 'DatabaseHelper';

export class DatabaseHelper {
  private static instance: DatabaseHelper | null = null;
  private db: IDatabase | null = null;

  static getInstance(): DatabaseHelper {
    if (!DatabaseHelper.instance) {
      DatabaseHelper.instance = new DatabaseHelper();
    }
    return DatabaseHelper.instance;
  }

  getDatabase(): IDatabase | null {
    return this.db;
  }

  async initialize(): Promise<void> {
    if (this.db) {
      return;
    }

    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      this.db = bridge.database;
      await this.db.open(DB_NAME);
      Logger.info(TAG, 'Database opened successfully');

      // 检查并创建表
      await this.createTables();
    } catch (err) {
      Logger.error(TAG, 'Failed to open database: %{public}s', JSON.stringify(err));
    }
  }

  private async createTables(): Promise<void> {
    if (!this.db) {
      return;
    }

    const createFootprintSQL: string = `
      CREATE TABLE IF NOT EXISTS ${TABLE_FOOTPRINT} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        accuracy REAL DEFAULT 0,
        timestamp INTEGER NOT NULL,
        poi_name TEXT DEFAULT '',
        poi_type TEXT DEFAULT '',
        stay_duration INTEGER DEFAULT 0,
        activity_tag TEXT DEFAULT '',
        source TEXT DEFAULT 'gps',
        photo_id TEXT DEFAULT '',
        speed REAL DEFAULT 0,
        day_key TEXT DEFAULT ''
      )
    `;

    const createActivitySegmentSQL: string = `
      CREATE TABLE IF NOT EXISTS ${TABLE_ACTIVITY_SEGMENT} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day_key TEXT DEFAULT '',
        start_time INTEGER NOT NULL,
        end_time INTEGER DEFAULT 0,
        activity_type TEXT DEFAULT '',
        poi_name TEXT DEFAULT '',
        latitude REAL DEFAULT 0,
        longitude REAL DEFAULT 0,
        photo_count INTEGER DEFAULT 0,
        summary TEXT DEFAULT ''
      )
    `;

    const createUserProfileSQL: string = `
      CREATE TABLE IF NOT EXISTS ${TABLE_USER_PROFILE} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        preference_key TEXT NOT NULL,
        preference_value TEXT DEFAULT '',
        confidence REAL DEFAULT 0,
        update_time INTEGER DEFAULT 0
      )
    `;

    const createRecommendationSQL: string = `
      CREATE TABLE IF NOT EXISTS ${TABLE_RECOMMENDATION} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        place_name TEXT DEFAULT '',
        place_type TEXT DEFAULT '',
        latitude REAL DEFAULT 0,
        longitude REAL DEFAULT 0,
        reason TEXT DEFAULT '',
        trigger_context TEXT DEFAULT '',
        is_accepted INTEGER DEFAULT 0,
        timestamp INTEGER DEFAULT 0
      )
    `;

    try {
      await this.db.executeSql(createFootprintSQL);
      await this.db.executeSql(createActivitySegmentSQL);
      await this.db.executeSql(createUserProfileSQL);
      await this.db.executeSql(createRecommendationSQL);

      // 创建索引
      await this.db.executeSql(
        `CREATE INDEX IF NOT EXISTS idx_footprint_timestamp ON ${TABLE_FOOTPRINT}(timestamp)`
      );
      await this.db.executeSql(
        `CREATE INDEX IF NOT EXISTS idx_footprint_day_key ON ${TABLE_FOOTPRINT}(day_key)`
      );
      await this.db.executeSql(
        `CREATE INDEX IF NOT EXISTS idx_activity_segment_day ON ${TABLE_ACTIVITY_SEGMENT}(day_key)`
      );

      Logger.info(TAG, 'All tables created successfully');
    } catch (err) {
      Logger.error(TAG, 'Failed to create tables: %{public}s', JSON.stringify(err));
    }
  }

  async close(): Promise<void> {
    if (this.db) {
      try {
        await this.db.close();
        this.db = null;
        Logger.info(TAG, 'Database closed');
      } catch (err) {
        Logger.error(TAG, 'Error closing database: %{public}s', JSON.stringify(err));
      }
    }
  }
}
