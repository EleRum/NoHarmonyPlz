/**
 * 时间线页面
 * 按天聚合：地点 + 行为标签 + 时间
 */
import { Logger } from '../common/Logger';
import router from '@ohos.router';
import { Footprint } from '../model/Footprint';
import { ActivitySegment } from '../model/ActivitySegment';
import { Dao } from '../database/Dao';
import { ActivityType, ACTIVITY_LABELS } from '../common/Constants';
import { formatTimestamp, getDayKey } from '../common/LocationUtils';

const TAG = 'TimelinePage';

interface DayGroup {
  dayKey: string;
  label: string;
  segments: ActivitySegment[];
  footprintCount: number;
}

@Component
export struct TimelineContent {
  onTabChange: (index: number) => void = () => {};
  segments: ActivitySegment[] = [];
  @State days: DayGroup[] = [];
  @State isLoading: boolean = true;

  private dao: Dao = Dao.getInstance();

  aboutToAppear(): void {
    Logger.info(TAG, 'TimelinePage aboutToAppear');
    this.loadTimeline();
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

      const groups: DayGroup[] = [];
      for (const dk of allDays) {
        const segs: ActivitySegment[] = segByDay[dk] || [];
        const count: number = await this.dao.queryFootprintCountByDay(dk);
        groups.push({
          dayKey: dk,
          label: this.formatDayLabel(dk),
          segments: segs,
          footprintCount: count
        });
      }

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

  getActivityEmoji(type: string): string {
    const map: Record<string, string> = {
      'home': '🏠', 'work': '💼', 'dining': '🍽️', 'shopping': '🛍️',
      'sports': '🏃', 'commute': '🚇', 'leisure': '🎠', 'travel': '✈️'
    };
    return map[type] || '📍';
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('←').fontSize(24).fontColor('#3B82F6')
          .width(36).height(36)
          .onClick(() => { this.onTabChange(0); })
        Text('时间线')
          .fontSize(22).fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ top: 16, bottom: 12, left: 16, right: 16 })

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(36).height(36)
          Text('加载中...').fontSize(14).fontColor('#999').margin({ top: 12 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.days.length === 0) {
        // 空状态
        Column() {
          Text('📭').fontSize(56).margin({ bottom: 12 })
          Text('还没有足迹记录').fontSize(17).fontColor('#333')
          Text('开启后台定位后，您的出行记录会自动出现在这里')
            .fontSize(13).fontColor('#999').margin({ top: 6 }).textAlign(TextAlign.Center)
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
                    .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#333')
                  Text(` · ${dayGroup.footprintCount}个足迹点`)
                    .fontSize(13).fontColor('#999')
                }
                .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })
                .backgroundColor('#F5F7FA')

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
                      .backgroundColor('#F0F4FF').justifyContent(FlexAlign.Center)
                      .margin({ right: 12 })

                      // 活动信息
                      Column() {
                        Text(seg.poiName || (ACTIVITY_LABELS[seg.activityType] || seg.activityType))
                          .fontSize(15).fontWeight(FontWeight.Medium).fontColor('#222')
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

                        Row() {
                          Text(ACTIVITY_LABELS[seg.activityType] || seg.activityType)
                            .fontSize(12).fontColor('#4A90D9')
                            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                            .backgroundColor('#EBF3FF').borderRadius(4)

                          Text(` ${formatTimestamp(seg.startTime)} - ${formatTimestamp(seg.endTime)}`)
                            .fontSize(12).fontColor('#999').margin({ left: 6 })

                          if (seg.photoCount > 0) {
                            Text(` 📷${seg.photoCount}`).fontSize(12).fontColor('#999').margin({ left: 6 })
                          }
                        }.margin({ top: 4 })
                      }
                      .alignItems(HorizontalAlign.Start).layoutWeight(1)

                      Text('›').fontSize(18).fontColor('#CCC')
                    }
                    .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
                    .alignItems(VerticalAlign.Center)
                    .border({ width: { bottom: 0.5 }, color: '#F0F0F0' })
                    .onClick(() => {
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
                          photoList: ''
                        }
                      });
                    })
                  })
                } else {
                  // 当天无活动片段
                  Text('仅有位置记录，暂无识别出的活动')
                    .fontSize(12).fontColor('#BBB')
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
    .width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}
