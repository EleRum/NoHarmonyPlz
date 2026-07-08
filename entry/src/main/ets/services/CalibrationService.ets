/**
 * 校准服务 — 管理活动段的用户/AI修正
 * 校准记录存储在独立的 segment_calibration 表，
 * 确保自动重新分类不会覆盖用户的校准修改。
 */
import { Dao } from '../database/Dao';
import { ActivitySegment } from '../model/ActivitySegment';
import { SegmentCalibration } from '../model/SegmentCalibration';
import { CalibrationSource } from '../common/Constants';
import { Logger } from '../common/Logger';

const TAG = 'CalibrationService';

export class CalibrationService {
  private static instance: CalibrationService | null = null;
  private dao: Dao;

  private constructor() {
    this.dao = Dao.getInstance();
  }

  static getInstance(): CalibrationService {
    if (!CalibrationService.instance) {
      CalibrationService.instance = new CalibrationService();
    }
    return CalibrationService.instance;
  }

  /**
   * 校准活动类型
   * @param endTime 段的结束时间，用于时间范围重叠匹配
   */
  async calibrateType(dayKey: string, startTime: number, newType: string,
                      source: string = CalibrationSource.MANUAL, endTime: number = 0): Promise<void> {
    if (!dayKey || startTime <= 0 || !newType) return;

    try {
      const cal = new SegmentCalibration();
      cal.dayKey = dayKey;
      cal.segmentStartTime = startTime;
      cal.segmentEndTime = endTime;
      cal.calibratedType = newType;
      cal.calibrationSource = source;
      cal.calibratedAt = Date.now();

      // 保留已有的 POI 校准
      const existing = await this.dao.queryCalibrationsByDay(dayKey);
      for (const e of existing) {
        if (Math.abs(e.segmentStartTime - startTime) < 60000 && e.calibratedPoiName) {
          cal.calibratedPoiName = e.calibratedPoiName;
          break;
        }
      }

      await this.dao.upsertSegmentCalibration(cal);
      Logger.info(TAG, 'calibrateType: day=%{public}s start=%{public}d end=%{public}d type=%{public}s source=%{public}s',
        dayKey, startTime, endTime, newType, source);
    } catch (err) {
      Logger.error(TAG, 'calibrateType failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 校准 POI 名称
   * @param endTime 段的结束时间，用于时间范围重叠匹配
   */
  async calibratePoiName(dayKey: string, startTime: number, newName: string,
                          source: string = CalibrationSource.MANUAL, endTime: number = 0): Promise<void> {
    if (!dayKey || startTime <= 0 || !newName) return;

    try {
      const cal = new SegmentCalibration();
      cal.dayKey = dayKey;
      cal.segmentStartTime = startTime;
      cal.segmentEndTime = endTime;
      cal.calibratedPoiName = newName;
      cal.calibrationSource = source;
      cal.calibratedAt = Date.now();

      // 保留已有的类型校准
      const existing = await this.dao.queryCalibrationsByDay(dayKey);
      for (const e of existing) {
        if (Math.abs(e.segmentStartTime - startTime) < 60000 && e.calibratedType) {
          cal.calibratedType = e.calibratedType;
          break;
        }
      }

      await this.dao.upsertSegmentCalibration(cal);
      Logger.info(TAG, 'calibratePoiName: day=%{public}s start=%{public}d end=%{public}d name=%{public}s source=%{public}s',
        dayKey, startTime, endTime, newName, source);
    } catch (err) {
      Logger.error(TAG, 'calibratePoiName failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 同时校准类型和POI名称
   */
  async calibrateBoth(dayKey: string, startTime: number, newType: string, newPoi: string,
                      source: string = CalibrationSource.MANUAL, endTime: number = 0): Promise<void> {
    if (!dayKey || startTime <= 0) return;

    try {
      const cal = new SegmentCalibration();
      cal.dayKey = dayKey;
      cal.segmentStartTime = startTime;
      cal.segmentEndTime = endTime;
      cal.calibratedType = newType;
      cal.calibratedPoiName = newPoi;
      cal.calibrationSource = source;
      cal.calibratedAt = Date.now();

      await this.dao.upsertSegmentCalibration(cal);
      Logger.info(TAG, 'calibrateBoth: day=%{public}s start=%{public}d end=%{public}d type=%{public}s poi=%{public}s',
        dayKey, startTime, endTime, newType, newPoi);
    } catch (err) {
      Logger.error(TAG, 'calibrateBoth failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 标记段为已删除（软删除：在校准表中记录，applyCalibrations 时过滤掉）
   */
  async deleteSegment(dayKey: string, startTime: number, endTime: number,
                      source: string = CalibrationSource.MANUAL): Promise<void> {
    if (!dayKey || startTime <= 0) return;

    try {
      const cal = new SegmentCalibration();
      cal.dayKey = dayKey;
      cal.segmentStartTime = startTime;
      cal.segmentEndTime = endTime;
      cal.isDeleted = 1;
      cal.calibrationSource = source;
      cal.calibratedAt = Date.now();

      await this.dao.upsertSegmentCalibration(cal);
      Logger.info(TAG, 'deleteSegment: day=%{public}s start=%{public}d', dayKey, startTime);

      // 同时直接从 activity_segment 表中删除该段
      const segs = await this.dao.queryActivitySegmentsByDay(dayKey);
      for (const seg of segs) {
        if (Math.abs(seg.startTime - startTime) < 60000) {
          await this.dao.deleteActivitySegmentById(seg.id);
          Logger.info(TAG, 'deleteSegment: removed segment id=%{public}d from DB', seg.id);
          break;
        }
      }
    } catch (err) {
      Logger.error(TAG, 'deleteSegment failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 删除某条校准记录（按 startTime ±1分钟容差匹配）
   */
  async removeCalibration(dayKey: string, startTime: number): Promise<void> {
    if (!dayKey || startTime <= 0) return;

    try {
      await this.dao.deleteSegmentCalibration(dayKey, startTime);
      Logger.info(TAG, 'removeCalibration: day=%{public}s start=%{public}d', dayKey, startTime);
    } catch (err) {
      Logger.error(TAG, 'removeCalibration failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 将校准记录合并到活动段数组中
   * 使用时间范围重叠匹配（而非精确 startTime 匹配），
   * 容忍分类器每次重新生成时段的边界漂移。
   * 重叠阈值：段与校准记录的时间重叠 ≥ 50%。
   *
   * @param segments 原始活动段列表
   * @param dayKey 日期键
   * @returns 合并校准后的活动段数组
   */
  async applyCalibrations(segments: ActivitySegment[], dayKey: string): Promise<ActivitySegment[]> {
    if (segments.length === 0 || !dayKey) return segments;

    try {
      const calibrations = await this.dao.queryCalibrationsByDay(dayKey);
      if (calibrations.length === 0) return segments;

      // 先处理删除标记：收集应删除的段索引
      const deletedIndices: Set<number> = new Set<number>();
      for (const cal of calibrations) {
        if (cal.isDeleted !== 1) continue;
        for (let i = 0; i < segments.length; i++) {
          const seg = segments[i];
          if (Math.abs(seg.startTime - cal.segmentStartTime) < 60000) {
            deletedIndices.add(i);
          }
        }
      }

      let matched = 0;
      for (const cal of calibrations) {
        if (cal.isDeleted === 1) continue; // 删除记录跳过类型匹配
        // 对每条校准记录，找时间重叠度最高的段
        const calStart: number = cal.segmentStartTime;
        const calEnd: number = cal.segmentEndTime || calStart;
        let bestSeg: ActivitySegment | null = null;
        let bestOverlap: number = 0;

        for (const seg of segments) {
          const overlapStart: number = Math.max(calStart, seg.startTime);
          const overlapEnd: number = Math.min(calEnd, seg.endTime || seg.startTime);
          if (overlapStart >= overlapEnd) continue;
          const overlap: number = overlapEnd - overlapStart;
          if (overlap > bestOverlap) {
            bestOverlap = overlap;
            bestSeg = seg;
          }
        }

        if (bestSeg && bestOverlap > 0) {
          if (cal.calibratedType) {
            bestSeg.activityType = cal.calibratedType;
            bestSeg.summary = `${cal.calibratedType} · ${Math.round((bestSeg.endTime - bestSeg.startTime) / 60000)}分钟`;
          }
          if (cal.calibratedPoiName) {
            bestSeg.poiName = cal.calibratedPoiName;
          }
          matched++;
        }
      }

      // 过滤掉被标记为删除的段
      let result: ActivitySegment[];
      if (deletedIndices.size > 0) {
        result = segments.filter((_seg: ActivitySegment, idx: number) => !deletedIndices.has(idx));
        Logger.info(TAG, 'applyCalibrations: %{public}d segments, %{public}d deleted, %{public}d calibrations matched',
          segments.length, deletedIndices.size, matched);
      } else {
        result = segments;
        Logger.info(TAG, 'applyCalibrations: %{public}d/%{public}d calibrations matched to %{public}d segments',
          matched, calibrations.length, segments.length);
      }
      return result;
    } catch (err) {
      Logger.error(TAG, 'applyCalibrations failed: %{public}s', JSON.stringify(err));
    }

    return segments;
  }

  /**
   * 查询某天的所有校准记录
   */
  async getCalibrationsByDay(dayKey: string): Promise<SegmentCalibration[]> {
    return await this.dao.queryCalibrationsByDay(dayKey);
  }

  /**
   * 判断某个段是否已被校准
   */
  isSegmentCalibrated(seg: ActivitySegment, calibrations: SegmentCalibration[]): boolean {
    for (const cal of calibrations) {
      if (cal.segmentStartTime === seg.startTime && cal.dayKey === seg.dayKey) {
        return !!(cal.calibratedType || cal.calibratedPoiName);
      }
    }
    return false;
  }
}
