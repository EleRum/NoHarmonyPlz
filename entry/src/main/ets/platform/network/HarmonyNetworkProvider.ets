/**
 * HarmonyOS 原生网络实现
 * 包装 @kit.NetworkKit (http) 模块，实现 INetworkProvider 接口
 */
import { http } from '@kit.NetworkKit';
import { Logger } from '../../common/Logger';
import { INetworkProvider, HttpResponse, HttpRequestOptions } from './INetworkProvider';

const TAG = 'HarmonyNetwork';

export class HarmonyNetworkProvider implements INetworkProvider {
  async request(url: string, options: HttpRequestOptions): Promise<HttpResponse> {
    const req = http.createHttp();
    try {
      const method: http.RequestMethod = options.method === 'POST'
        ? http.RequestMethod.POST
        : http.RequestMethod.GET;

      const reqOptions: http.HttpRequestOptions = {
        method: method,
        header: options.header,
        connectTimeout: options.connectTimeout ?? 15000,
        readTimeout: options.readTimeout ?? 20000
      } as http.HttpRequestOptions;

      if (options.method === 'POST' && options.body) {
        reqOptions.extraData = options.body;
      }

      const resp = await req.request(url, reqOptions);
      return {
        responseCode: resp.responseCode,
        result: typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result)
      };
    } catch (e) {
      Logger.error(TAG, 'Request failed: %{public}s', JSON.stringify(e));
      return { responseCode: -1, result: '' };
    } finally {
      req.destroy();
    }
  }
}
