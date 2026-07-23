/**
 * Android 平台相册访问实现
 * Android 端自动扫描系统相册需要原生 MediaStore API，暂不可用。
 * 返回空数组，由上层 PhotoService 优雅降级。
 */
import { IPhotoAccess, PhotoInfo } from './IPhotoAccess';
import { Logger } from '../../common/Logger';

const TAG: string = 'AndroidPhoto';

export class AndroidPhotoAccess implements IPhotoAccess {
  async scanPhotos(): Promise<PhotoInfo[]> {
    Logger.warn(TAG, 'Auto photo scan not available on Android (requires MediaStore NAPI). Returning empty.');
    return [];
  }
}
