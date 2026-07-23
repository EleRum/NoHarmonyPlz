/**
 * 足迹点模型
 * 对应 footprint 表
 */
import { ValuesBucket } from '../platform/database/IDatabase';

export interface FootprintRecord {
  id: number;
  latitude: number;
  longitude: number;
  accuracy: number;
  timestamp: number;
  poiName: string;
  poiType: string;
  stayDuration: number;
  activityTag: string;
  source: string;
  photoId: string;
  speed: number;
  dayKey: string;
}

export class Footprint {
  id: number = 0;
  latitude: number = 0;
  longitude: number = 0;
  accuracy: number = 0;
  timestamp: number = 0;
  poiName: string = '';
  poiType: string = '';
  stayDuration: number = 0;
  activityTag: string = '';
  source: string = 'gps';
  photoId: string = '';
  speed: number = 0;
  dayKey: string = '';

  static fromResultSet(row: ValuesBucket): Footprint {
    const fp = new Footprint();
    fp.id = row['id'] as number ?? 0;
    fp.latitude = row['latitude'] as number ?? 0;
    fp.longitude = row['longitude'] as number ?? 0;
    fp.accuracy = row['accuracy'] as number ?? 0;
    fp.timestamp = row['timestamp'] as number ?? 0;
    fp.poiName = row['poi_name'] as string ?? '';
    fp.poiType = row['poi_type'] as string ?? '';
    fp.stayDuration = row['stay_duration'] as number ?? 0;
    fp.activityTag = row['activity_tag'] as string ?? '';
    fp.source = row['source'] as string ?? 'gps';
    fp.photoId = row['photo_id'] as string ?? '';
    fp.speed = row['speed'] as number ?? 0;
    fp.dayKey = row['day_key'] as string ?? '';
    return fp;
  }

  toValuesBucket(): ValuesBucket {
    return {
      'latitude': this.latitude,
      'longitude': this.longitude,
      'accuracy': this.accuracy,
      'timestamp': this.timestamp,
      'poi_name': this.poiName,
      'poi_type': this.poiType,
      'stay_duration': this.stayDuration,
      'activity_tag': this.activityTag,
      'source': this.source,
      'photo_id': this.photoId,
      'speed': this.speed,
      'day_key': this.dayKey
    };
  }
}
