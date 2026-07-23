/**
 * 活动片段模型
 * 对应 activity_segment 表
 */
import { ValuesBucket } from '../platform/database/IDatabase';

export class ActivitySegment {
  id: number = 0;
  dayKey: string = '';
  startTime: number = 0;
  endTime: number = 0;
  activityType: string = '';
  poiName: string = '';
  latitude: number = 0;
  longitude: number = 0;
  photoCount: number = 0;
  summary: string = '';

  static fromResultSet(row: ValuesBucket): ActivitySegment {
    const seg = new ActivitySegment();
    seg.id = row['id'] as number ?? 0;
    seg.dayKey = row['day_key'] as string ?? '';
    seg.startTime = row['start_time'] as number ?? 0;
    seg.endTime = row['end_time'] as number ?? 0;
    seg.activityType = row['activity_type'] as string ?? '';
    seg.poiName = row['poi_name'] as string ?? '';
    seg.latitude = row['latitude'] as number ?? 0;
    seg.longitude = row['longitude'] as number ?? 0;
    seg.photoCount = row['photo_count'] as number ?? 0;
    seg.summary = row['summary'] as string ?? '';
    return seg;
  }

  toValuesBucket(): ValuesBucket {
    return {
      'day_key': this.dayKey,
      'start_time': this.startTime,
      'end_time': this.endTime,
      'activity_type': this.activityType,
      'poi_name': this.poiName,
      'latitude': this.latitude,
      'longitude': this.longitude,
      'photo_count': this.photoCount,
      'summary': this.summary
    };
  }
}
