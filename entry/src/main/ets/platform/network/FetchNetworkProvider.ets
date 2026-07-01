/**
 * 跨平台网络请求实现
 * 使用标准 fetch() API 替代 @kit.NetworkKit (http)
 * HarmonyOS ArkTS 和 Android 均支持 fetch()
 */
import { INetworkProvider, HttpResponse, HttpRequestOptions } from './INetworkProvider';

export class FetchNetworkProvider implements INetworkProvider {
  async request(url: string, options: HttpRequestOptions): Promise<HttpResponse> {
    try {
      const headers: Record<string, string> = {};
      if (options.header) {
        const keys: string[] = Object.keys(options.header);
        for (let i: number = 0; i < keys.length; i++) {
          headers[keys[i]] = options.header[keys[i]];
        }
      }

      const init: RequestInit = {
        method: options.method,
        headers: headers
      };

      if (options.method === 'POST' && options.body) {
        init.body = options.body;
      }

      // 设置超时（如果环境支持 AbortSignal.timeout）
      const timeoutMs: number = options.readTimeout ?? 20000;
      if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
        init.signal = AbortSignal.timeout(timeoutMs);
      }

      const response: Response = await fetch(url, init);
      const text: string = await response.text();

      return {
        responseCode: response.status,
        result: text
      };
    } catch (e) {
      console.error('[FetchNetworkProvider] Request failed:', e);
      return {
        responseCode: -1,
        result: ''
      };
    }
  }
}
