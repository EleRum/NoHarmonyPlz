/**
 * 后台定位采集服务
 * 持续定位 → 逆地理编码 → 写入数据库
 * 跨平台：通过 PlatformBridge 的 ILocationProvider 获取位置
 */
import { Logger } from '../common/Logger';
import { Footprint } from '../model/Footprint';
import { Dao } from '../database/Dao';
import {
  LOCATION_INTERVAL_SEC,
  MIN_DISTANCE_METERS,
  APP_TAG
} from '../common/Constants';
import { haversineDistance, getDayKey } from '../common/LocationUtils';
import { PlatformBridge } from '../platform/PlatformBridge';
import { GeoLocation } from '../platform/location/ILocationProvider';

const TAG = 'LocationService';

interface LocationRecord {
  lat: number;
  lng: number;
  time: number;
}

export class LocationService {
  private static instance: LocationService | null = null;
  private dao: Dao;
  private lastLocation: LocationRecord | null = null;

  private constructor() {
    this.dao = Dao.getInstance();
  }

  static getInstance(): LocationService {
    if (!LocationService.instance) {
      LocationService.instance = new LocationService();
    }
    return LocationService.instance;
  }

  /**
   * 启动持续定位
   */
  startTracking(): void {
    const bridge = PlatformBridge.getInstance();
    if (bridge.location.isTracking()) {
      Logger.warn(TAG, 'Tracking already started');
      return;
    }

    try {
      bridge.location.startTracking((geoLoc: GeoLocation): void => {
        this.onLocationChanged(geoLoc);
      });
      Logger.info(TAG, 'Location tracking started');
    } catch (err) {
      Logger.error(TAG, 'Failed to start tracking: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 停止定位
   */
  stopTracking(): void {
    const bridge = PlatformBridge.getInstance();
    if (!bridge.location.isTracking()) {
      return;
    }

    try {
      bridge.location.stopTracking();
      Logger.info(TAG, 'Location tracking stopped');
    } catch (err) {
      Logger.error(TAG, 'Failed to stop tracking: %{public}s', JSON.stringify(err));
    }
  }

  isTrackingActive(): boolean {
    return PlatformBridge.getInstance().location.isTracking();
  }

  /**
   * 位置变化回调
   */
  private onLocationChanged(loc: GeoLocation): void {
    const lat: number = loc.latitude;
    const lng: number = loc.longitude;

    if (!lat || !lng) {
      return;
    }

    const now: number = Date.now();

    // 距离过滤
    if (this.lastLocation) {
      const dist: number = haversineDistance(
        this.lastLocation.lat, this.lastLocation.lng,
        lat, lng
      );
      // 移动距离小于阈值，且时间间隔不够，跳过
      if (dist < MIN_DISTANCE_METERS &&
        (now - this.lastLocation.time) < LOCATION_INTERVAL_SEC * 1000) {
        return;
      }
    }

    this.lastLocation = { lat: lat, lng: lng, time: now };

    // 构建足迹记录
    const fp: Footprint = new Footprint();
    fp.latitude = lat;
    fp.longitude = lng;
    fp.accuracy = loc.accuracy;
    fp.timestamp = now;
    fp.speed = loc.speed;
    fp.source = 'gps';
    fp.dayKey = getDayKey(now);

    // 异步写入数据库
    this.dao.insertFootprint(fp).then((): void => {
      Logger.info(TAG,
        'Location recorded: lat=%{public}.4f, lng=%{public}.4f',
        lat, lng);
    });

    // 异步逆地理编码
    this.reverseGeocode(lat, lng);
  }

  /**
   * 逆地理编码获取地点名称
   */
  private async reverseGeocode(lat: number, lng: number): Promise<void> {
    try {
      const bridge = PlatformBridge.getInstance();
      const addr = await bridge.location.reverseGeocode(lat, lng);
      if (addr) {
        Logger.info(TAG, 'Reverse geocode: %{public}s', addr.placeName);
      }
    } catch (err) {
      // 逆地理编码失败不阻塞主流程
      Logger.warn(TAG, 'Reverse geocode failed');
    }
  }
}
