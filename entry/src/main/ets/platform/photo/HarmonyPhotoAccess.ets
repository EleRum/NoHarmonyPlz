/**
 * HarmonyOS 原生相册访问实现
 * 包装 @kit.MediaLibraryKit (photoAccessHelper) 模块，实现 IPhotoAccess 接口
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { dataSharePredicates } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../../common/Logger';
import { IPhotoAccess, PhotoInfo } from './IPhotoAccess';

const TAG = 'HarmonyPhoto';

interface GpsPosition {
  latitude: number;
  longitude: number;
}

export class HarmonyPhotoAccess implements IPhotoAccess {
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  async scanPhotos(): Promise<PhotoInfo[]> {
    const results: PhotoInfo[] = [];
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const predicates = new dataSharePredicates.DataSharePredicates();
      const fetchOptions: photoAccessHelper.FetchOptions = {
        fetchColumns: [
          photoAccessHelper.PhotoKeys.URI,
          photoAccessHelper.PhotoKeys.DISPLAY_NAME,
          photoAccessHelper.PhotoKeys.DATE_ADDED,
          'position' as string
        ],
        predicates: predicates
      };

      const fetchResult = await helper.getAssets(fetchOptions);
      const count: number = fetchResult.getCount();
      for (let i: number = 0; i < count && results.length < 100; i++) {
        try {
          const asset: photoAccessHelper.PhotoAsset = await fetchResult.getObjectByPosition(i);
          // 直接读取 POSITION 字段
          const positionValue = asset.get('position' as string);
          if (positionValue !== undefined && positionValue !== null) {
            // HarmonyOS PhotoKeys.POSITION 返回 {latitude: number, longitude: number}
            const posObj = positionValue as Object as GpsPosition;
            const lat: number = posObj.latitude ?? 0;
            const lng: number = posObj.longitude ?? 0;
            if (lat !== 0 || lng !== 0) {
              results.push({
                uri: asset.displayName,
                displayName: asset.displayName,
                dateAdded: (asset.get(photoAccessHelper.PhotoKeys.DATE_ADDED) as number) ?? Date.now(),
                latitude: lat,
                longitude: lng
              });
            }
          }
        } catch (e) {
          // 跳过无 GPS 的图片
        }
      }

      fetchResult.close();
      Logger.info(TAG, 'Scanned %{public}d photos with GPS', results.length);
    } catch (e) {
      Logger.warn(TAG, 'Photo scan failed: %{public}s', JSON.stringify(e));
    }
    return results;
  }
}
