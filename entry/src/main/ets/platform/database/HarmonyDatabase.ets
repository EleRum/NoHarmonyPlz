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
    const storeConfig: relationalStore.StoreConfig = {
      name: name,
      securityLevel: STORE_CONFIG.securityLevel
    };
    try {
      this.store = await relationalStore.getRdbStore(this.context, storeConfig);
      Logger.info(TAG, 'Database opened: %{public}s', name);
    } catch (e) {
      this.store = null;
      Logger.error(TAG, 'Database open failed: %{public}s', JSON.stringify(e));
    }
  }

  async executeSql(sql: string, bindArgs?: ValueType[]): Promise<void> {
    if (!this.isOpen()) return;
    try {
      await this.store!.executeSql(sql, bindArgs ?? []);
    } catch (e) {
      Logger.error(TAG, 'executeSql failed: %{public}s', JSON.stringify(e));
    }
  }

  async querySql(sql: string, bindArgs?: ValueType[]): Promise<IResultSet> {
    if (!this.isOpen()) return new EmptyResultSet();
    try {
      const rs = await this.store!.querySql(sql, bindArgs ?? []);
      return new HarmonyResultSet(rs);
    } catch (e) {
      Logger.error(TAG, 'querySql failed: %{public}s', JSON.stringify(e));
      return new EmptyResultSet();
    }
  }

  async insert(table: string, values: ValuesBucket): Promise<number> {
    if (!this.isOpen()) return -1;
    try {
      const rowId = await this.store!.insert(table, values as relationalStore.ValuesBucket);
      return rowId;
    } catch (e) {
      Logger.error(TAG, 'insert failed: %{public}s', JSON.stringify(e));
      return -1;
    }
  }

  async update(table: string, values: ValuesBucket, whereClause: string,
    whereArgs?: ValueType[]): Promise<number> {
    if (!this.isOpen()) return 0;
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
    if (!this.isOpen()) return 0;
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
    if (!this.isOpen()) return 0;
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await this.store!.querySql('SELECT changes() AS cnt');
      if (rs.goToFirstRow()) {
        const idx: number = rs.getColumnIndex('cnt');
        return rs.getLong(idx);
      }
    } catch (e) {
      Logger.warn(TAG, 'getChanges failed: %{public}s', JSON.stringify(e));
    } finally {
      if (rs) {
        try { rs.close(); } catch (_e) { /* ignore */ }
      }
    }
    return 0;
  }

  async close(): Promise<void> {
    if (!this.store) return;
    try {
      this.store.close();
      Logger.info(TAG, 'Database closed');
    } catch (e) {
      Logger.warn(TAG, 'Database close failed: %{public}s', JSON.stringify(e));
    } finally {
      this.store = null;
    }
  }

  private isOpen(): boolean {
    if (!this.store) {
      Logger.warn(TAG, 'Database not opened. Call open() first.');
      return false;
    }
    return true;
  }
}

class EmptyResultSet implements IResultSet {
  get columnCount(): number { return 0; }
  goToNextRow(): boolean { return false; }
  getString(_columnIndex: number): string { return ''; }
  getLong(_columnIndex: number): number { return 0; }
  getDouble(_columnIndex: number): number { return 0; }
  getBlob(_columnIndex: number): Uint8Array { return new Uint8Array(0); }
  isNull(_columnIndex: number): boolean { return true; }
  getRow(): ValuesBucket { return {}; }
  close(): void {}
}

/** HarmonyOS ResultSet → IResultSet 适配器 */
class HarmonyResultSet implements IResultSet {
  private rs: relationalStore.ResultSet;

  constructor(rs: relationalStore.ResultSet) {
    this.rs = rs;
  }

  get columnCount(): number {
    try { return this.rs.columnCount; } catch (_e) { return 0; }
  }

  goToNextRow(): boolean {
    try { return this.rs.goToNextRow(); } catch (_e) { return false; }
  }

  getString(columnIndex: number): string {
    try { return this.rs.getString(columnIndex); } catch (_e) { return ''; }
  }

  getLong(columnIndex: number): number {
    try { return this.rs.getLong(columnIndex); } catch (_e) { return 0; }
  }

  getDouble(columnIndex: number): number {
    try { return this.rs.getDouble(columnIndex); } catch (_e) { return 0; }
  }

  getBlob(columnIndex: number): Uint8Array {
    try { return this.rs.getBlob(columnIndex); } catch (_e) { return new Uint8Array(0); }
  }

  isNull(columnIndex: number): boolean {
    try { return this.rs.isColumnNull(columnIndex); } catch (_e) { return true; }
  }

  getRow(): ValuesBucket {
    try {
      return this.rs.getRow() as ValuesBucket;
    } catch (_e) {
      return {};
    }
  }

  close(): void {
    try { this.rs.close(); } catch (_e) { /* ignore */ }
  }
}
