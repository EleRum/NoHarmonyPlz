/**
 * 数据库抽象接口
 * 统一封装 SQLite 数据库操作，HarmonyOS 和 Android 各自实现
 */

/** 数据库值类型 */
export type ValueType = string | number | boolean | null | Uint8Array;

/** 键值对容器 */
export type ValuesBucket = Record<string, ValueType>;

/**
 * 结果集接口 - 平台无关的行迭代器
 * 参考 Android Cursor / HarmonyOS ResultSet 设计
 */
export interface IResultSet {
  /** 移动到下一行，没有更多行时返回 false */
  goToNextRow(): boolean;

  /** 获取指定列索引的字符串值 */
  getString(columnIndex: number): string;

  /** 获取指定列索引的长整数值 */
  getLong(columnIndex: number): number;

  /** 获取指定列索引的浮点数值 */
  getDouble(columnIndex: number): number;

  /** 获取指定列索引的二进制值 */
  getBlob(columnIndex: number): Uint8Array;

  /** 指定列索引的值是否为 null */
  isNull(columnIndex: number): boolean;

  /** 获取列数 */
  columnCount: number;

  /** 获取行数据为 ValuesBucket（用于 fromResultSet 模式） */
  getRow(): ValuesBucket;

  /** 关闭结果集，释放资源 */
  close(): void;
}

/**
 * 数据库提供者接口
 * 所有平台需要实现此接口以提供 SQLite 数据库能力
 */
export interface IDatabase {
  /**
   * 打开或创建数据库
   * @param name 数据库文件名
   */
  open(name: string): Promise<void>;

  /**
   * 执行非查询 SQL（INSERT/UPDATE/DELETE/CREATE/ALTER 等）
   * @param sql SQL 语句
   * @param bindArgs 绑定参数
   */
  executeSql(sql: string, bindArgs?: ValueType[]): Promise<void>;

  /**
   * 执行查询 SQL（SELECT）
   * @param sql SQL 语句
   * @param bindArgs 绑定参数
   * @returns 结果集
   */
  querySql(sql: string, bindArgs?: ValueType[]): Promise<IResultSet>;

  /**
   * 插入一行数据
   * @param table 表名
   * @param values 列值
   * @returns 插入的行 ID，失败返回 -1
   */
  insert(table: string, values: ValuesBucket): Promise<number>;

  /**
   * 更新符合条件的行
   * @param table 表名
   * @param values 要更新的列值
   * @param whereClause WHERE 子句（不含 WHERE 关键字），如 "id = ?"
   * @param whereArgs WHERE 子句绑定参数
   * @returns 受影响的行数
   */
  update(table: string, values: ValuesBucket, whereClause: string, whereArgs?: ValueType[]): Promise<number>;

  /**
   * 删除符合条件的行
   * @param table 表名
   * @param whereClause WHERE 子句（不含 WHERE 关键字），如 "id = ?"
   * @param whereArgs WHERE 子句绑定参数
   * @returns 受影响的行数
   */
  delete(table: string, whereClause: string, whereArgs?: ValueType[]): Promise<number>;

  /**
   * 关闭数据库
   */
  close(): Promise<void>;
}
