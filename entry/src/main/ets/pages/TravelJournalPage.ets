/**
 * 行程页 — 时间线 + 报告 合并
 */
import { getTheme, FONT, RADIUS, SPACE } from '../common/Theme';
import { ActivitySegment } from '../model/ActivitySegment';
import { TimelineContent } from './TimelinePage';
import { ReportContent } from './ReportPage';

@Component
export struct TravelJournalContent {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  @State activeTab: number = 0;
  segments: ActivitySegment[] = [];

  build() {
    Column() {
      Row() {
        this.SegmentBtn('📅 时间线', 0)
        this.SegmentBtn('📊 报告', 1)
      }
      .width('100%')
      .padding({ left: SPACE.lg, right: SPACE.lg, top: SPACE.md, bottom: SPACE.md })
      .backgroundColor(getTheme(this.themeMode).surface)

      Divider().color(getTheme(this.themeMode).divider).height(0.5)

      if (this.activeTab === 0) {
        TimelineContent({ segments: this.segments })
      } else {
        ReportContent()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(getTheme(this.themeMode).pageBg)
  }

  @Builder
  SegmentBtn(text: string, idx: number) {
    Text(text)
      .fontSize(FONT.body)
      .fontColor(idx === this.activeTab ? getTheme(this.themeMode).surface : getTheme(this.themeMode).textSecondary)
      .fontWeight(idx === this.activeTab ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: SPACE.lg, right: SPACE.lg, top: SPACE.sm, bottom: SPACE.sm })
      .borderRadius(RADIUS.pill)
      .backgroundColor(idx === this.activeTab ? getTheme(this.themeMode).primary : Color.Transparent)
      .margin({ right: SPACE.sm })
      .onClick(() => { this.activeTab = idx; })
  }
}
