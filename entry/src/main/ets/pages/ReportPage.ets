/**
 * 行程报告页面
 * 日报/周报，含行为统计 + 活动摘要
 */
import { Logger } from '../common/Logger';
import { getTheme } from '../common/Theme';
import { Footprint } from '../model/Footprint';
import { ActivitySegment } from '../model/ActivitySegment';
import { Dao } from '../database/Dao';
import { ACTIVITY_LABELS } from '../common/Constants';
import { getDayKey } from '../common/LocationUtils';
import { ClaudeService, ClaudeReply } from '../services/ClaudeService';

const TAG = 'ReportPage';

interface DailyStats {
  dayKey: string;
  label: string;
  footprintCount: number;
  segments: ActivitySegment[];
  topActivity: string;
  topPlace: string;
}

@Component
export struct ReportContent {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  onTabChange: (index: number) => void = () => {};
  @State todayStats: DailyStats | null = null;
  @State weekStats: DailyStats[] = [];
  @State totalFootprints: number = 0;
  @State totalSegments: number = 0;
  @State isLoading: boolean = true;
  @State aiSummary: string = '';
  @State isSummaryLoading: boolean = false;

  private dao: Dao = Dao.getInstance();
  private summaryAi: ClaudeService = new ClaudeService();
  private summaryRequestId: number = 0;

  aboutToAppear(): void {
    Logger.info(TAG, 'ReportPage aboutToAppear');
    this.loadReport();
  }

  async loadReport(): Promise<void> {
    try {
      const today: string = getDayKey(Date.now());
      const totalFp: number = await this.dao.getFootprintCount();
      const totalAct: number = await this.dao.queryActivityCount();

      // 今日统计
      const todayFpCount: number = await this.dao.queryFootprintCountByDay(today);
      const todaySegments: ActivitySegment[] = await this.dao.queryActivitySegmentsByDay(today);

      let topActivity: string = '暂无';
      let topPlace: string = '暂无';
      if (todaySegments.length > 0) {
        topActivity = ACTIVITY_LABELS[todaySegments[0].activityType] || todaySegments[0].activityType;
        topPlace = todaySegments[0].poiName || '未知';
      }

      this.todayStats = {
        dayKey: today,
        label: this.formatDayLabel(today),
        footprintCount: todayFpCount,
        segments: todaySegments,
        topActivity: topActivity,
        topPlace: topPlace
      };

      // 本周统计（最近7天）
      const dayKeys: string[] = await this.dao.queryDistinctDays(7);
      const weekStatsList: DailyStats[] = [];
      for (let i = 0; i < dayKeys.length; i++) {
        const dk: string = dayKeys[i];
        const count: number = await this.dao.queryFootprintCountByDay(dk);
        const segs: ActivitySegment[] = await this.dao.queryActivitySegmentsByDay(dk);
        let ta: string = '—';
        let tp: string = '—';
        if (segs.length > 0) {
          ta = ACTIVITY_LABELS[segs[0].activityType] || segs[0].activityType;
          tp = segs[0].poiName || '—';
        }
        weekStatsList.push({
          dayKey: dk, label: this.formatShortDay(dk),
          footprintCount: count, segments: segs,
          topActivity: ta, topPlace: tp
        });
      }

      this.weekStats = weekStatsList;
      this.totalFootprints = totalFp;
      this.totalSegments = totalAct;
      this.aiSummary = this.buildLocalSummary();
      this.isLoading = false;
      this.generateAiSummary();
    } catch (err) {
      this.aiSummary = '报告数据读取失败，请稍后重试。';
      this.isLoading = false;
    }
  }

  private buildLocalSummary(): string {
    if (this.totalFootprints <= 0 && this.totalSegments <= 0) {
      return '还没有足够的出行数据，开启后台定位后，系统会在这里生成行程摘要。';
    }
    const activeDays: number = this.weekStats.length;
    const topActivity: string = this.todayStats ? this.todayStats.topActivity : '暂无';
    const topPlace: string = this.todayStats ? this.todayStats.topPlace : '暂无';
    return `本周记录${activeDays}个活跃日、${this.totalFootprints}个足迹点、${this.totalSegments}段活动。今日主要活动是${topActivity}，主要地点是${topPlace}。建议继续积累数据后查看更稳定的出行节奏和偏好总结。`;
  }

  private buildAiSummaryPrompt(): string {
    const weekLines: string[] = [];
    for (const day of this.weekStats) {
      weekLines.push(`${day.label}: ${day.footprintCount}个足迹，主要活动${day.topActivity}，地点${day.topPlace}`);
    }
    return `请根据以下出行统计生成一段80字以内的中文报告摘要，只基于数据，不要编造未出现的地点或建议。\n总足迹:${this.totalFootprints}\n活动片段:${this.totalSegments}\n今日:${this.todayStats ? this.todayStats.label + ' ' + this.todayStats.footprintCount + '个足迹 ' + this.todayStats.topActivity + ' ' + this.todayStats.topPlace : '暂无'}\n最近7天:${weekLines.join('；')}`;
  }

  private cleanSummaryText(raw: string): string {
    if (!raw) return '';
    return raw.replace(/---JSON---[\s\S]*$/g, '').replace(/\s+/g, ' ').trim().substring(0, 160);
  }

  async generateAiSummary(): Promise<void> {
    const requestId: number = ++this.summaryRequestId;
    if (this.totalFootprints <= 0 && this.totalSegments <= 0) return;
    this.isSummaryLoading = true;
    try {
      await this.summaryAi.loadApiKey(true);
      if (!this.summaryAi.hasKey) return;
      const reply: ClaudeReply = await this.summaryAi.chatConversation(
        this.buildAiSummaryPrompt(),
        '你是旅行行为分析助手。输出中文自然语言摘要，最多80字，只基于用户统计数据，不要编造。'
      );
      if (requestId !== this.summaryRequestId) return;
      const summary: string = this.cleanSummaryText(reply.text || '');
      if (summary.length > 0 && !summary.includes('请先设置AI密钥')) this.aiSummary = summary;
    } catch (_e) {
      // 保留本地摘要兜底
    } finally {
      if (requestId === this.summaryRequestId) this.isSummaryLoading = false;
    }
  }

  formatDayLabel(dayKey: string): string {
    if (dayKey.length < 8) return dayKey;
    const m: string = parseInt(dayKey.substring(4, 6)).toString();
    const d: string = parseInt(dayKey.substring(6, 8)).toString();
    return `${m}月${d}日`;
  }

  formatShortDay(dayKey: string): string {
    if (dayKey.length < 8) return dayKey;
    const m: string = parseInt(dayKey.substring(4, 6)).toString();
    const d: string = parseInt(dayKey.substring(6, 8)).toString();
    return `${m}/${d}`;
  }

  build() {
    Column() {
      if (this.isLoading) {
        Column() {
          LoadingProgress().width(36).height(36)
          Text('生成报告中...').fontSize(14).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 12 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // ── 总览卡片 ──
            Row() {
              Column() {
                Text(`${this.totalFootprints}`)
                  .fontSize(28).fontWeight(FontWeight.Bold).fontColor('#4A90D9')
                Text('总足迹点').fontSize(12).fontColor(getTheme(this.themeMode).textSecondary)
              }.layoutWeight(1)

              Column() {
                Text(`${this.totalSegments}`)
                  .fontSize(28).fontWeight(FontWeight.Bold).fontColor('#50C878')
                Text('活动片段').fontSize(12).fontColor(getTheme(this.themeMode).textSecondary)
              }.layoutWeight(1)

              Column() {
                Text(`${this.weekStats.length}`)
                  .fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FF6B6B')
                Text('活跃天数').fontSize(12).fontColor(getTheme(this.themeMode).textSecondary)
              }.layoutWeight(1)
            }
            .width('90%').padding(20).backgroundColor(getTheme(this.themeMode).surface)
            .borderRadius(12).margin({ top: 8, bottom: 8 })
            .shadow({ radius: 4, color: '#10000000', offsetY: 2 })

            // ── 今日报告 ──
            Column() {
              Row() {
                Text('📊 今日报告')
                  .fontSize(16).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
              }.width('100%').margin({ bottom: 10 })

              if (this.todayStats) {
                Row() {
                  Column() {
                    Text('足迹点').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary)
                    Text(`${this.todayStats.footprintCount}`)
                      .fontSize(20).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
                  }.layoutWeight(1).alignItems(HorizontalAlign.Center)

                  Column() {
                    Text('主要活动').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary)
                    Text(this.todayStats.topActivity)
                      .fontSize(14).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
                  }.layoutWeight(1).alignItems(HorizontalAlign.Center)

                  Column() {
                    Text('主要地点').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary)
                    Text(this.todayStats.topPlace)
                      .fontSize(14).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.layoutWeight(1).alignItems(HorizontalAlign.Center)
                }
                .width('100%')
              } else {
                Text('暂无今日数据').fontSize(13).fontColor(getTheme(this.themeMode).textTertiary)
              }
            }
            .width('90%').padding(16).backgroundColor(getTheme(this.themeMode).surface)
            .borderRadius(12).margin({ top: 4, bottom: 8 })
            .shadow({ radius: 4, color: '#10000000', offsetY: 2 })

            // ── 本周概览 ──
            Column() {
              Row() {
                Text('📈 本周概览')
                  .fontSize(16).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
              }.width('100%').margin({ bottom: 10 })

              if (this.weekStats.length > 0) {
                ForEach(this.weekStats, (day: DailyStats) => {
                  Row() {
                    Text(day.label).fontSize(13).fontColor(getTheme(this.themeMode).textPrimary).width(48)
                    // 简易进度条
                    Row() {
                      Row() {}.width(`${Math.min(100, day.footprintCount * 5)}%`)
                        .height('100%').backgroundColor('#4A90D9').borderRadius(4)
                    }
                    .width('30%').height(6).backgroundColor('#F0F0F0').borderRadius(4)
                    .margin({ left: 8, right: 8 })

                    Text(`${day.topActivity}`)
                      .fontSize(12).fontColor(getTheme(this.themeMode).textSecondary).layoutWeight(1)
                    Text(`${day.footprintCount}点`).fontSize(12).fontColor(getTheme(this.themeMode).textSecondary)
                  }
                  .width('100%').padding({ top: 6, bottom: 6 })
                  .alignItems(VerticalAlign.Center)
                })
              } else {
                Text('暂无本周数据').fontSize(13).fontColor(getTheme(this.themeMode).textTertiary)
              }
            }
            .width('90%').padding(16).backgroundColor(getTheme(this.themeMode).surface)
            .borderRadius(12).margin({ top: 4, bottom: 8 })
            .shadow({ radius: 4, color: '#10000000', offsetY: 2 })

            // ── AI 摘要 ──
            Column() {
              Row() {
                Text('🤖 AI 摘要').fontSize(16).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
                Blank()
                if (this.isSummaryLoading) {
                  LoadingProgress().width(16).height(16).color('#4A90D9')
                }
              }.width('100%').margin({ bottom: 10 })

              Text(this.aiSummary)
                .fontSize(13).fontColor(getTheme(this.themeMode).textSecondary).lineHeight(20)
            }
            .width('90%').padding(16).backgroundColor(getTheme(this.themeMode).surface)
            .borderRadius(12).margin({ top: 4, bottom: 20 })
            .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
          }
          .width('100%').alignItems(HorizontalAlign.Center)
        }
        .width('100%').layoutWeight(1)
      }

    }
    .width('100%').height('100%').backgroundColor(getTheme(this.themeMode).pageBg)
  }
}
