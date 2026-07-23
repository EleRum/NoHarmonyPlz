/**
 * 网络请求抽象接口
 * 统一封装 HTTP 请求，HarmonyOS 和 Android 各自实现
 */

/** HTTP 响应结构 */
export interface HttpResponse {
  /** HTTP 状态码 */
  responseCode: number;
  /** 响应体文本 */
  result: string;
}

/** HTTP 请求选项 */
export interface HttpRequestOptions {
  /** 请求方法 */
  method: 'GET' | 'POST';
  /** 请求头 */
  header?: Record<string, string>;
  /** 请求体（POST 时使用） */
  body?: string;
  /** 连接超时 (ms) */
  connectTimeout?: number;
  /** 读取超时 (ms) */
  readTimeout?: number;
}

/**
 * 网络请求提供者接口
 * 所有平台需要实现此接口以提供 HTTP 通信能力
 */
export interface INetworkProvider {
  /**
   * 发起 HTTP 请求
   * @param url 请求地址
   * @param options 请求选项
   * @returns HTTP 响应
   */
  request(url: string, options: HttpRequestOptions): Promise<HttpResponse>;
}
