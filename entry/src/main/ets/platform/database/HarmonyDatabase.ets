/**
 * HarmonyOS 原生数据库实现
 * 包装 @kit.ArkData (relationalStore) 模块，实现 IDatabase 接口
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../../common/Logger';
import { IDatabase, IResultSet, ValueType, ValuesBucket } from './IDatabase';

const TAG = 'HarmonyDB';
const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'Footprint.db',
  securityLevel: relationalStore.SecurityLevel.S1
};

export class HarmonyDatabase implements IDatabase {
  private store: relationalStore.RdbStore | null = null;
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  async open(name: string): Promise<void> {
    if (this.store) return;
    STORE_CONFIG.name = name;
    this.store = await relationalStore.getRdbStore(this.context, STORE_CONFIG);
    Logger.info(TAG, 'Database opened: %{public}s', name);
  }

  async executeSql(sql: string, bindArgs?: ValueType[]): Promise<void> {
    this.ensureOpen();
    await this.store!.executeSql(sql, bindArgs ?? []);
  }

  async querySql(sql: string, bindArgs?: ValueType[]): Promise<IResultSet> {
    this.ensureOpen();
    const rs = await this.store!.querySql(sql, bindArgs ?? []);
    return new HarmonyResultSet(rs);
  }

  async insert(table: string, values: ValuesBucket): Promise<number> {
    this.ensureOpen();
    const rowId = await this.store!.insert(table, values as relationalStore.ValuesBucket);
    return rowId;
  }

  async update(table: string, values: ValuesBucket, whereClause: string,
    whereArgs?: ValueType[]): Promise<number> {
    this.ensureOpen();
    // 使用 executeSql 方式实现 update，避免 predicates 兼容问题
    const setClauses: string[] = [];
    const args: ValueType[] = [];
    const keys = Object.keys(values);
    for (const key of keys) {
      setClauses.push(`${key} = ?`);
      args.push(values[key]);
    }
    const whereArgList = whereArgs ?? [];
    for (const a of whereArgList) {
      args.push(a);
    }
    // 计算占位符数量
    const placeholders = whereClause.split('?').length - 1;
    const actualWhereArgs = args.slice(args.length - placeholders);
    const sqlArgs = args;

    try {
      const sql = `UPDATE ${table} SET ${setClauses.join(', ')} WHERE ${whereClause}`;
      await this.store!.executeSql(sql, sqlArgs);
      // 获取受影响行数
      const changes = await this.getChanges();
      return changes;
    } catch (e) {
      Logger.error(TAG, 'update failed: %{public}s', JSON.stringify(e));
      return 0;
    }
  }

  async delete(table: string, whereClause: string, whereArgs?: ValueType[]): Promise<number> {
    this.ensureOpen();
    try {
      const sql = `DELETE FROM ${table} WHERE ${whereClause}`;
      await this.store!.executeSql(sql, whereArgs ?? []);
      const changes = await this.getChanges();
      return changes;
    } catch (e) {
      Logger.error(TAG, 'delete failed: %{public}s', JSON.stringify(e));
      return 0;
    }
  }

  private async getChanges(): Promise<number> {
    try {
      const rs = await this.store!.querySql('SELECT changes() AS cnt');
      if (rs.goToFirstRow()) {
        return rs.getLong(rs.getColumnIndex('cnt'));
      }
      rs.close();
    } catch (e) {
      // fallback
    }
    return 0;
  }

  async close(): Promise<void> {
    if (this.store) {
      this.store.close();
      this.store = null;
      Logger.info(TAG, 'Database closed');
    }
  }

  private ensureOpen(): void {
    if (!this.store) {
      throw new Error('Database not opened. Call open() first.');
    }
  }
}

/** HarmonyOS ResultSet → IResultSet 适配器 */
class HarmonyResultSet implements IResultSet {
  private rs: relationalStore.ResultSet;

  constructor(rs: relationalStore.ResultSet) {
    this.rs = rs;
  }

  get columnCount(): number {
    return this.rs.columnCount;
  }

  goToNextRow(): boolean {
    return this.rs.goToNextRow();
  }

  getString(columnIndex: number): string {
    return this.rs.getString(columnIndex);
  }

  getLong(columnIndex: number): number {
    return this.rs.getLong(columnIndex);
  }

  getDouble(columnIndex: number): number {
    return this.rs.getDouble(columnIndex);
  }

  getBlob(columnIndex: number): Uint8Array {
    return this.rs.getBlob(columnIndex);
  }

  isNull(columnIndex: number): boolean {
    return this.rs.isColumnNull(columnIndex);
  }

  getRow(): ValuesBucket {
    // 直接使用原生 getRow() 保留正确的列类型
    return this.rs.getRow() as ValuesBucket;
  }

  close(): void {
    this.rs.close();
  }
}
