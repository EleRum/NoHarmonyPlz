/**
 * 段校准模型
 * 对应 segment_calibration 表 — 存储用户/AI对活动段的修正
 * 独立于 activity_segment 表，确保重新分类时校准不丢失
 * 使用时间范围重叠匹配，容忍分类边界漂移
 */
import { ValuesBucket } from '../platform/database/IDatabase';

export class SegmentCalibration {
  id: number = 0;
  dayKey: string = '';
  segmentStartTime: number = 0;
  segmentEndTime: number = 0;     // 段结束时间，用于时间范围重叠匹配
  calibratedType: string = '';
  calibratedPoiName: string = '';
  calibrationSource: string = 'manual';  // 'manual' | 'ai_agent'
  calibratedAt: number = 0;
  isDeleted: number = 0;               // 1 = 用户删除了此段

  static fromResultSet(row: ValuesBucket): SegmentCalibration {
    const cal = new SegmentCalibration();
    cal.id = row['id'] as number ?? 0;
    cal.dayKey = row['day_key'] as string ?? '';
    cal.segmentStartTime = row['segment_start_time'] as number ?? 0;
    cal.segmentEndTime = row['segment_end_time'] as number ?? 0;
    cal.calibratedType = row['calibrated_type'] as string ?? '';
    cal.calibratedPoiName = row['calibrated_poi_name'] as string ?? '';
    cal.calibrationSource = row['calibration_source'] as string ?? 'manual';
    cal.calibratedAt = row['calibrated_at'] as number ?? 0;
    cal.isDeleted = row['is_deleted'] as number ?? 0;
    return cal;
  }

  toValuesBucket(): ValuesBucket {
    return {
      'day_key': this.dayKey,
      'segment_start_time': this.segmentStartTime,
      'segment_end_time': this.segmentEndTime,
      'calibrated_type': this.calibratedType,
      'calibrated_poi_name': this.calibratedPoiName,
      'calibration_source': this.calibrationSource,
      'calibrated_at': this.calibratedAt,
      'is_deleted': this.isDeleted
    };
  }
}
