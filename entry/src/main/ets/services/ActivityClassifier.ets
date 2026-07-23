/**
 * 行为分类器 (位置+历史感知版)
 * 优先匹配用户在同区域的历史行为，其次地理位置上下文，最后才看时段
 */
import { Footprint } from '../model/Footprint';
import { ActivitySegment } from '../model/ActivitySegment';
import { ActivityType } from '../common/Constants';

interface ClassifyResult {
  type: string;
  confidence: number;
  reason: string;
}

// 附近范围阈值（米）
const NEARBY_RADIUS_M: number = 200;

export class ActivityClassifier {

  // POI 类型关键词映射
  private static readonly POI_RULES: Array<[string[], string]> = [
    [['餐厅', '饭店', '火锅', '面馆', '小吃', '咖啡', '奶茶', 'Starbucks', '海底捞', '食堂'], ActivityType.DINING],
    [['商场', '购物', '超市', '百货', '银泰', '盒马', 'ZARA'], ActivityType.SHOPPING],
    [['公司', '软件园', '科技园', '大厦', '办公楼'], ActivityType.WORK],
    [['公园', '健身房', '体育馆', '操场', '绿道', '步道'], ActivityType.SPORTS],
    [['地铁', '公交', '车站', '机场', '火车站'], ActivityType.COMMUTE],
    [['电影院', 'KTV', '博物馆', '美术馆', '景区'], ActivityType.LEISURE],
    [['酒店', '机场', '火车站', '景点'], ActivityType.TRAVEL],
    [['家', '小区', '公寓', '住宅', '都汇'], ActivityType.HOME],
  ];

  /**
   * 两点间近似距离 (米)
   */
  private static approxDistM(lat1: number, lng1: number, lat2: number, lng2: number): number {
    const dLat: number = (lat1 - lat2) * 111320;
    const dLng: number = (lng1 - lng2) * 111320 * Math.cos((lat1 + lat2) / 2 * Math.PI / 180);
    return Math.sqrt(dLat * dLat + dLng * dLng);
  }

  /**
   * 从位置变化推算实际移动速度 (m/s)，弥补模拟器 GPS 无 speed 字段
   */
  private static computeSpeeds(sorted: Footprint[]): number[] {
    const n: number = sorted.length;
    const speeds: number[] = new Array<number>(n).fill(0);
    for (let i = 1; i < n; i++) {
      const dt: number = (sorted[i].timestamp - sorted[i - 1].timestamp) / 1000;
      if (dt <= 0) continue;
      const dist: number = ActivityClassifier.approxDistM(
        sorted[i - 1].latitude, sorted[i - 1].longitude,
        sorted[i].latitude, sorted[i].longitude
      );
      speeds[i] = dist / dt;
      // 平滑：前一个点也取较大值
      if (speeds[i] > speeds[i - 1]) speeds[i - 1] = speeds[i];
    }
    // 取 GPS speed 和计算 speed 中的较大值
    for (let i = 0; i < n; i++) {
      if (sorted[i].speed > speeds[i]) speeds[i] = sorted[i].speed;
    }
    return speeds;
  }

  /**
   * 预计算每个点是否处于"移动中"（前后5分钟内有实际移动）
   */
  private static buildMotionMask(sorted: Footprint[], speeds: number[]): boolean[] {
    const MOVE_WINDOW_MS: number = 10 * 60000;
    const n: number = sorted.length;
    const mask: boolean[] = new Array<boolean>(n).fill(false);
    if (n === 0) return mask;

    let right: number = 0;
    let movingCount: number = 0;

    for (let left = 0; left < n; left++) {
      while (right < n && sorted[right].timestamp - sorted[left].timestamp <= MOVE_WINDOW_MS) {
        if (speeds[right] > 0.5) movingCount++;
        right++;
      }
      mask[left] = movingCount > 0;
      if (speeds[left] > 0.5) movingCount = Math.max(0, movingCount - 1);
    }

    right = n - 1;
    movingCount = 0;
    for (let left = n - 1; left >= 0; left--) {
      while (right >= 0 && sorted[left].timestamp - sorted[right].timestamp <= MOVE_WINDOW_MS) {
        if (speeds[right] > 0.5) movingCount++;
        right--;
      }
      if (movingCount > 0) mask[left] = true;
      if (speeds[left] > 0.5) movingCount = Math.max(0, movingCount - 1);
    }

    return mask;
  }

  /**
   * 对单个足迹点分类（需提供历史活动段做位置匹配）
   * @param inMotion 是否处于移动中（短暂停顿时仍视为通勤）
   */
  static classify(fp: Footprint, history: ActivitySegment[], inMotion: boolean = false, calcSpeed: number = 0): ClassifyResult {
    let type: string = ActivityType.COMMUTE;
    let confidence: number = 0.3;
    let reasons: string[] = [];

    // 实际速度取 GPS 上报和位置推算中的较大值
    const realSpeed: number = Math.max(fp.speed, calcSpeed);

    // ── 1. 速度快速判断 ──
    if (realSpeed > 5.0) {
      return { type: ActivityType.SPORTS, confidence: 0.5 + Math.min(0.3, realSpeed / 20),
        reason: `移动速度 ${realSpeed.toFixed(1)} m/s` };
    }
    if (realSpeed > 0.5) {
      return { type: ActivityType.COMMUTE, confidence: 0.4,
        reason: '低速移动' };
    }

    // 移动中的短暂停顿（等红灯等）→ 仍为通勤
    if (inMotion) {
      return { type: ActivityType.COMMUTE, confidence: 0.45,
        reason: '移动中途短暂停顿' };
    }

    // ── 2. 静止：查询历史同区域活动 ──
    const nearbyTypes: Record<string, number> = {};
    for (const seg of history) {
      if (!seg.latitude || !seg.longitude || !seg.activityType) continue;
      const dist: number = ActivityClassifier.approxDistM(
        fp.latitude, fp.longitude, seg.latitude, seg.longitude
      );
      if (dist < NEARBY_RADIUS_M) {
        nearbyTypes[seg.activityType] = (nearbyTypes[seg.activityType] || 0) + 1;
      }
    }

    // 找到最常见的附近历史类型
    let bestType: string = '';
    let bestCount: number = 0;
    for (const t of Object.keys(nearbyTypes)) {
      if (nearbyTypes[t] > bestCount) {
        bestCount = nearbyTypes[t];
        bestType = t;
      }
    }

    if (bestType && bestCount >= 1) {
      type = bestType;
      confidence = 0.5 + Math.min(0.35, bestCount * 0.1);
      reasons.push(`历史同区域: ${bestType} (${bestCount}次)`);
      return { type, confidence, reason: reasons.join('; ') };
    }

    // ── 3. 无历史：POI 关键词匹配 ──
    const poi: string = (fp.poiName || '') + (fp.poiType || '');
    for (const rule of ActivityClassifier.POI_RULES) {
      for (const kw of rule[0]) {
        if (poi.includes(kw)) {
          type = rule[1];
          confidence = 0.55;
          reasons.push(`POI匹配: ${kw}`);
          return { type, confidence, reason: reasons.join('; ') };
        }
      }
    }

    // ── 4. 最后：时段弱推断 ──
    const hour: number = new Date(fp.timestamp).getHours();
    const day: number = new Date(fp.timestamp).getDay();
    const isWeekday: boolean = day >= 1 && day <= 5;

    if (hour >= 12 && hour < 14) {
      type = ActivityType.DINING;
      confidence = 0.35;
      reasons.push('午餐时段');
    } else if (hour >= 17 && hour < 20) {
      type = ActivityType.DINING;
      confidence = 0.35;
      reasons.push('晚餐时段');
    } else if (hour >= 9 && hour <= 18 && isWeekday) {
      type = ActivityType.WORK;
      confidence = 0.35;
      reasons.push('工作日白天');
    } else if (hour >= 23 || hour < 6) {
      type = ActivityType.HOME;
      confidence = 0.4;
      reasons.push('深夜时段');
    } else {
      type = ActivityType.LEISURE;
      confidence = 0.25;
      reasons.push('时段不明');
    }

    return { type, confidence, reason: reasons.join('; ') };
  }

  /**
   * 聚合足迹点生成活动片段
   * @param footprints 当日足迹
   * @param history 历史活动段（全部天的，用于位置匹配）
   */
  static aggregateSegments(footprints: Footprint[], history: ActivitySegment[]): ActivitySegment[] {
    if (footprints.length === 0) return [];

    const sorted: Footprint[] = [...footprints].sort((a, b) => a.timestamp - b.timestamp);
    const speeds: number[] = ActivityClassifier.computeSpeeds(sorted);
    const motionMask: boolean[] = ActivityClassifier.buildMotionMask(sorted, speeds);
    const raw: ActivitySegment[] = [];

    // 投票窗口：连续 N 点中多数类型才切换，避免单点抖动
    const VOTE_WINDOW: number = 6;
    let segStart: number = sorted[0].timestamp;
    let segEnd: number = sorted[0].timestamp;
    let segType: string = ActivityClassifier.classify(sorted[0], history, motionMask[0], speeds[0]).type;
    let segLat: number = sorted[0].latitude;
    let segLng: number = sorted[0].longitude;
    let photoCount: number = sorted[0].photoId ? 1 : 0;
    let typeVotes: Record<string, number> = {};
    typeVotes[segType] = 1;

    for (let i = 1; i < sorted.length; i++) {
      const result: ClassifyResult = ActivityClassifier.classify(sorted[i], history, motionMask[i], speeds[i]);
      const timeGap: number = sorted[i].timestamp - segEnd;

      // 滑动窗口投票
      const vt: string = result.type;
      typeVotes[vt] = (typeVotes[vt] || 0) + 1;
      if (i >= VOTE_WINDOW) {
        const oldestType: string = ActivityClassifier.classify(sorted[i - VOTE_WINDOW], history, motionMask[i - VOTE_WINDOW], speeds[i - VOTE_WINDOW]).type;
        typeVotes[oldestType] = Math.max(0, (typeVotes[oldestType] || 1) - 1);
      }
      let majorityType: string = segType;
      let maxVotes: number = 0;
      for (const t of Object.keys(typeVotes)) {
        if (typeVotes[t] > maxVotes) { maxVotes = typeVotes[t]; majorityType = t; }
      }

      // 多数类型变化 或 长时间断档 → 切段
      if (majorityType !== segType || timeGap > 30 * 60000) {
        raw.push(ActivityClassifier.makeSeg(sorted[i - 1].dayKey, segStart, segEnd, segType, segLat, segLng, photoCount, sorted[i - 1].poiName || ''));
        segStart = sorted[i].timestamp;
        segType = majorityType;
        segLat = sorted[i].latitude;
        segLng = sorted[i].longitude;
        photoCount = sorted[i].photoId ? 1 : 0;
      } else {
        photoCount += sorted[i].photoId ? 1 : 0;
      }
      segEnd = sorted[i].timestamp;
    }
    raw.push(ActivityClassifier.makeSeg(sorted[sorted.length - 1].dayKey, segStart, segEnd, segType, segLat, segLng, photoCount, sorted[sorted.length - 1].poiName || ''));

    // ── 后处理：同区域段合并（200m内视为同一地点） ──
    return ActivityClassifier.mergeNearby(raw);
  }

  private static makeSeg(dayKey: string, start: number, end: number, type: string,
                          lat: number, lng: number, photos: number, poi: string): ActivitySegment {
    const seg: ActivitySegment = new ActivitySegment();
    seg.dayKey = dayKey;
    seg.startTime = start;
    seg.endTime = end;
    seg.activityType = type;
    seg.latitude = lat;
    seg.longitude = lng;
    seg.photoCount = photos;
    seg.poiName = poi;
    seg.summary = `${type} · ${Math.round((end - start) / 60000)}分钟`;
    return seg;
  }

  /** 同区域（200m内）的相邻段合并为一个，减少碎片 */
  private static mergeNearby(segs: ActivitySegment[]): ActivitySegment[] {
    if (segs.length <= 1) return segs;

    const result: ActivitySegment[] = [];
    result.push(segs[0]);

    for (let i = 1; i < segs.length; i++) {
      const prev: ActivitySegment = result[result.length - 1];
      const curr: ActivitySegment = segs[i];
      const dist: number = ActivityClassifier.approxDistM(
        prev.latitude, prev.longitude, curr.latitude, curr.longitude
      );

      // 同区域（200m内）→ 合并
      if (dist < 200) {
        prev.endTime = curr.endTime;
        // 取较长段的活动类型
        const prevDur: number = prev.endTime - prev.startTime;
        const currDur: number = curr.endTime - curr.startTime;
        if (currDur > prevDur) {
          prev.activityType = curr.activityType;
          prev.latitude = curr.latitude;
          prev.longitude = curr.longitude;
          prev.poiName = curr.poiName || prev.poiName;
        }
        prev.summary = `${prev.activityType} · ${Math.round((prev.endTime - prev.startTime) / 60000)}分钟`;
      } else {
        result.push(curr);
      }
    }

    // 每段至少30分钟，短段合并到相邻
    const final: ActivitySegment[] = [];
    for (let i = 0; i < result.length; i++) {
      const dur: number = result[i].endTime - result[i].startTime;
      if (dur < 30 * 60000 && final.length > 0) {
        // 合并到前一段
        const last: ActivitySegment = final[final.length - 1];
        last.endTime = result[i].endTime;
        last.summary = `${last.activityType} · ${Math.round((last.endTime - last.startTime) / 60000)}分钟`;
      } else {
        final.push(result[i]);
      }
    }

    return final.length > 0 ? final : result;
  }
}
