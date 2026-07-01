/**
 * HarmonyOS 原生定位实现
 * 包装 @kit.LocationKit (geoLocationManager) 模块，实现 ILocationProvider 接口
 */
import { geoLocationManager } from '@kit.LocationKit';
import { Logger } from '../../common/Logger';
import { ILocationProvider, GeoLocation, GeoAddress, LocationCallback } from './ILocationProvider';

const TAG = 'HarmonyLocation';

export class HarmonyLocationProvider implements ILocationProvider {
  private _tracking: boolean = false;
  private _callback: LocationCallback | null = null;

  startTracking(callback: LocationCallback): void {
    if (this._tracking) {
      Logger.warn(TAG, 'Already tracking');
      return;
    }
    this._callback = callback;
    this._tracking = true;

    try {
      const requestInfo: geoLocationManager.LocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.ACCURACY,
        scenario: geoLocationManager.LocationRequestScenario.TRAJECTORY_TRACKING,
        timeInterval: 1,
        distanceInterval: 0
      };

      geoLocationManager.on('locationChange', requestInfo, (location: geoLocationManager.Location): void => {
        if (!this._tracking || !this._callback) {
          return;
        }
        this._callback({
          latitude: location.latitude,
          longitude: location.longitude,
          accuracy: location.accuracy,
          speed: location.speed ?? 0,
          timestamp: location.timeStamp ?? Date.now()
        });
      });

      Logger.info(TAG, 'Location tracking started');
    } catch (e) {
      Logger.error(TAG, 'Failed to start tracking: %{public}s', JSON.stringify(e));
      this._tracking = false;
    }
  }

  stopTracking(): void {
    this._tracking = false;
    this._callback = null;
    try {
      geoLocationManager.off('locationChange');
    } catch (e) {
      // ignore
    }
    Logger.info(TAG, 'Location tracking stopped');
  }

  isTracking(): boolean {
    return this._tracking;
  }

  async reverseGeocode(latitude: number, longitude: number): Promise<GeoAddress | null> {
    try {
      const request: geoLocationManager.ReverseGeoCodeRequest = {
        latitude: latitude,
        longitude: longitude,
        maxItems: 1
      };
      const addresses = await geoLocationManager.getAddressesFromLocation(request);
      if (addresses && addresses.length > 0) {
        const addr = addresses[0];
        const parts: string[] = [];
        if (addr.administrativeArea) parts.push(addr.administrativeArea);
        if (addr.subAdministrativeArea) parts.push(addr.subAdministrativeArea);
        if (addr.locality) parts.push(addr.locality);
        if (addr.placeName) parts.unshift(addr.placeName);

        return {
          placeName: parts.join(', ') || addr.placeName || `${latitude.toFixed(6)}, ${longitude.toFixed(6)}`,
          address: parts.join(', '),
          city: addr.locality ?? addr.administrativeArea,
          district: addr.subAdministrativeArea
        };
      }
    } catch (e) {
      Logger.warn(TAG, 'Reverse geocode failed: %{public}s', JSON.stringify(e));
    }
    return null;
  }
}
