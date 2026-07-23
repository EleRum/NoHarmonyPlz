/**
 * 跨平台文件 I/O 接口
 * 用于数据库持久化、配置文件读写等
 */
export interface IFileProvider {
  /** 读取文件全部内容 */
  readFile(path: string): Promise<Uint8Array | null>;

  /** 写入文件（覆盖） */
  writeFile(path: string, data: Uint8Array): Promise<void>;

  /** 删除文件 */
  deleteFile(path: string): Promise<void>;

  /** 文件是否存在 */
  fileExists(path: string): Promise<boolean>;

  /** 读取文本文件 */
  readTextFile(path: string): Promise<string | null>;

  /** 写入文本文件 */
  writeTextFile(path: string, text: string): Promise<void>;
}
