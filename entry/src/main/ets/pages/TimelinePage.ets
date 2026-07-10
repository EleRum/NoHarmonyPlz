/**
 * 时间线页面
 * 按天聚合：地点 + 行为标签 + 时间
 */
import { Logger } from '../common/Logger';
import { getTheme } from '../common/Theme';
import router from '@ohos.router';
import { Footprint } from '../model/Footprint';
import { ActivitySegment } from '../model/ActivitySegment';
import { Dao } from '../database/Dao';
import { ActivityType, ACTIVITY_LABELS } from '../common/Constants';
import { formatTimestamp, getDayKey } from '../common/LocationUtils';
import { CalibrationService } from '../services/CalibrationService';
import { SegmentCalibration } from '../model/SegmentCalibration';
import { CalibrationSignal } from '../common/CalibrationSignal';

const TAG = 'TimelinePage';

interface DayGroup {
  dayKey: string;
  label: string;
  segments: ActivitySegment[];
  footprintCount: number;
}

@Component
export struct TimelineContent {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  onTabChange: (index: number) => void = () => {};
  segments: ActivitySegment[] = [];
  @State days: DayGroup[] = [];
  @State isLoading: boolean = true;
  @State calibratedStartTimes: Record<string, Set<number>> = {};  // dayKey -> set of calibrated startTimes

  private dao: Dao = Dao.getInstance();
  private calService: CalibrationService = CalibrationService.getInstance();
  private lastProcessedCalTs: number = 0;
  private calPoller: number | null = null;

  aboutToAppear(): void {
    Logger.info(TAG, 'TimelinePage aboutToAppear');
    this.loadTimeline();
    // 轮询校准变更信号，确保校准后时间线立即可见（不依赖页面切换）
    this.calPoller = setInterval(() => {
      const result = CalibrationSignal.consume(this.lastProcessedCalTs);
      if (result.hasNew) {
        this.lastProcessedCalTs = result.newTs;
        Logger.info(TAG, 'Calibration signal detected, reloading timeline');
        this.loadTimeline();
      }
    }, 2000);
  }

  aboutToDisappear(): void {
    if (this.calPoller) {
      clearInterval(this.calPoller);
      this.calPoller = null;
    }
  }

  async loadTimeline(): Promise<void> {
    try {
      // 使用父组件传入的 segments，立即显示，避免 DB 竞态
      const segByDay: Record<string, ActivitySegment[]> = {};
      for (const s of this.segments) {
        const dk: string = s.dayKey || 'unknown';
        if (!segByDay[dk]) segByDay[dk] = [];
        segByDay[dk].push(s);
      }

      // 合并 DB 中的 footprint 天（用于计数）
      const dayKeys: string[] = await this.dao.queryDistinctDays(30);
      const allDays: Set<string> = new Set(dayKeys);
      for (const dk of Object.keys(segByDay)) { allDays.add(dk); }

      // 加载校准信息并按天合并
      const calMap: Record<string, Set<number>> = {};
      const groups: DayGroup[] = [];
      for (const dk of allDays) {
        const segs: ActivitySegment[] = segByDay[dk] || [];
        // 对该天的段应用校准覆盖
        await this.calService.applyCalibrations(segs, dk);
        const count: number = await this.dao.queryFootprintCountByDay(dk);

        // 记录已校准的 startTime
        const calSet: Set<number> = new Set<number>();
        try {
          const cals: SegmentCalibration[] = await this.calService.getCalibrationsByDay(dk);
          for (const cal of cals) {
            calSet.add(cal.segmentStartTime);
          }
        } catch (e) { /* ignore */ }
        calMap[dk] = calSet;

        groups.push({
          dayKey: dk,
          label: this.formatDayLabel(dk),
          segments: segs,
          footprintCount: count
        });
      }

      this.calibratedStartTimes = calMap;
      this.days = groups;
      this.isLoading = false;
      Logger.info(TAG, 'Timeline loaded: %{public}d days', groups.length);
    } catch (err) {
      this.isLoading = false;
    }
  }

  formatDayLabel(dayKey: string): string {
    // YYYYMMDD → "6月23日 周一"
    if (dayKey.length < 8) return dayKey;
    const month: string = parseInt(dayKey.substring(4, 6)).toString();
    const day: string = parseInt(dayKey.substring(6, 8)).toString();
    const weekdays: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    const y: number = parseInt(dayKey.substring(0, 4));
    const m: number = parseInt(dayKey.substring(4, 6)) - 1;
    const d: number = parseInt(dayKey.substring(6, 8));
    const wd: number = new Date(y, m, d).getDay();
    return `${month}月${day}日 周${weekdays[wd]}`;
  }

  isSegCalibrated(dayKey: string, startTime: number): boolean {
    const calSet: Set<number> | undefined = this.calibratedStartTimes[dayKey];
    return calSet ? calSet.has(startTime) : false;
  }

  getActivityEmoji(type: string): string {
    const map: Record<string, string> = {
      'home': '🏠', 'work': '💼', 'dining': '🍽️', 'shopping': '🛍️',
      'sports': '🏃', 'commute': '🚇', 'leisure': '🎠', 'travel': '✈️'
    };
    return map[type] || '📍';
  }

  build() {
    Column() {
      if (this.isLoading) {
        Column() {
          LoadingProgress().width(36).height(36)
          Text('加载中...').fontSize(14).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 12 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.days.length === 0) {
        // 空状态
        Column() {
          Text('📭').fontSize(56).margin({ bottom: 12 })
          Text('还没有足迹记录').fontSize(17).fontColor(getTheme(this.themeMode).textPrimary)
          Text('开启后台定位后，您的出行记录会自动出现在这里')
            .fontSize(13).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 6 }).textAlign(TextAlign.Center)
            .padding({ left: 40, right: 40 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        // 时间线列表
        List() {
          ForEach(this.days, (dayGroup: DayGroup) => {
            ListItem() {
              Column() {
                // 日期头部
                Row() {
                  Text(dayGroup.label)
                    .fontSize(16).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
                  Text(` · ${dayGroup.footprintCount}个足迹点`)
                    .fontSize(13).fontColor(getTheme(this.themeMode).textSecondary)
                }
                .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })
                .backgroundColor(getTheme(this.themeMode).surfaceSecondary)

                // 当天活动列表
                if (dayGroup.segments.length > 0) {
                  ForEach(dayGroup.segments, (seg: ActivitySegment) => {
                    Row() {
                      // 时间轴点
                      Column() {
                        Text(this.getActivityEmoji(seg.activityType))
                          .fontSize(22)
                      }
                      .width(40).height(40).borderRadius(20)
                      .backgroundColor(getTheme(this.themeMode).primaryLight).justifyContent(FlexAlign.Center)
                      .margin({ right: 12 })

                      // 活动信息
                      Column() {
                        Text(seg.poiName || (ACTIVITY_LABELS[seg.activityType] || seg.activityType))
                          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

                        Row() {
                          Text(ACTIVITY_LABELS[seg.activityType] || seg.activityType)
                            .fontSize(12).fontColor('#4A90D9')
                            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                            .backgroundColor(getTheme(this.themeMode).primaryLight).borderRadius(4)

                          // 校准标记
                          if (this.isSegCalibrated(dayGroup.dayKey, seg.startTime)) {
                            Text('✅').fontSize(10).margin({ left: 4 })
                          }

                          Text(` ${formatTimestamp(seg.startTime)} - ${formatTimestamp(seg.endTime)}`)
                            .fontSize(12).fontColor(getTheme(this.themeMode).textSecondary).margin({ left: 6 })

                          if (seg.photoCount > 0) {
                            Text(` 📷${seg.photoCount}`).fontSize(12).fontColor(getTheme(this.themeMode).textSecondary).margin({ left: 6 })
                          }
                        }.margin({ top: 4 })
                      }
                      .alignItems(HorizontalAlign.Start).layoutWeight(1)

                      Text('›').fontSize(18).fontColor(getTheme(this.themeMode).textTertiary)
                    }
                    .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
                    .alignItems(VerticalAlign.Center)
                    .border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
                    .onClick(() => {
                      const calSet: Set<number> | undefined = this.calibratedStartTimes[dayGroup.dayKey];
                      const isCal: boolean = calSet ? calSet.has(seg.startTime) : false;
                      router.pushUrl({
                        url: 'pages/WaypointDetailPage',
                        params: {
                          poiName: seg.poiName || (ACTIVITY_LABELS[seg.activityType] || seg.activityType),
                          latitude: seg.latitude,
                          longitude: seg.longitude,
                          activityTag: seg.activityType,
                          timestamp: seg.startTime,
                          stayDuration: seg.endTime - seg.startTime,
                          speed: 0,
                          photoList: '',
                          segmentStartTime: seg.startTime,
                          segmentEndTime: seg.endTime,
                          dayKey: seg.dayKey
                        }
                      });
                    })
                  })
                } else {
                  // 当天无活动片段
                  Text('仅有位置记录，暂无识别出的活动')
                    .fontSize(12).fontColor(getTheme(this.themeMode).textTertiary)
                    .padding({ left: 16, top: 8, bottom: 12 })
                    .width('100%')
                }
              }
              .width('100%')
            }
          })
        }
        .width('100%').layoutWeight(1)
        .divider({ strokeWidth: 0, color: 'transparent' })
      }

    }
    .width('100%').height('100%').backgroundColor(getTheme(this.themeMode).pageBg)
  }
}
