/**
 * 照片扫描服务
 * 从系统相册读取带 GPS 位置的照片 → 生成足迹点
 * 跨平台：通过 PlatformBridge 的 IPhotoAccess 访问相册
 */
import { Logger } from '../common/Logger';
import { Footprint } from '../model/Footprint';
import { Dao } from '../database/Dao';
import { APP_TAG } from '../common/Constants';
import { getDayKey } from '../common/LocationUtils';
import { PlatformBridge } from '../platform/PlatformBridge';
import { PhotoInfo } from '../platform/photo/IPhotoAccess';

const TAG = 'PhotoService';

export class PhotoService {
  private static instance: PhotoService | null = null;

  static getInstance(): PhotoService {
    if (!PhotoService.instance) {
      PhotoService.instance = new PhotoService();
    }
    return PhotoService.instance;
  }

  /**
   * 扫描相册中带 GPS 位置的照片，生成足迹点
   * 重复扫描时跳过已处理的照片（按 URI + timestamp 去重）
   */
  async scanPhotos(): Promise<number> {
    Logger.info(TAG, 'Scanning photos for GPS data...');
    let addedCount: number = 0;

    try {
      const bridge = PlatformBridge.getInstance();
      const photos: PhotoInfo[] = await bridge.photo.scanPhotos();

      Logger.info(TAG, 'Found %{public}d photos with GPS', photos.length);

      const dao: Dao = Dao.getInstance();

      for (const photo of photos) {
        try {
          // 去重：跳过已处理的照片（按 URI + timestamp 窗口）
          const existing: Footprint[] =
            await dao.queryFootprintsByTimeRange(photo.dateAdded - 1000, photo.dateAdded + 1000);
          const dup: boolean = existing.some(
            (f: Footprint) => f.photoId === photo.uri && f.source === 'photo'
          );
          if (dup) {
            continue;
          }

          const fp: Footprint = new Footprint();
          fp.latitude = photo.latitude;
          fp.longitude = photo.longitude;
          fp.accuracy = 10;
          fp.timestamp = photo.dateAdded;
          fp.source = 'photo';
          fp.photoId = photo.uri;
          fp.speed = 0;
          fp.dayKey = getDayKey(photo.dateAdded);
          fp.poiName = '';

          await dao.insertFootprint(fp);
          addedCount++;
        } catch (e) {
          // 跳过异常照片
        }
      }

      Logger.info(TAG, 'Photo scan complete: %{public}d new photo footprints', addedCount);
    } catch (err) {
      Logger.error(TAG, 'Photo scan failed: %{public}s', JSON.stringify(err));
    }

    return addedCount;
  }
}
