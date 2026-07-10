/**
 * 推荐全页 — 独立路由页面
 */
import { Logger } from '../common/Logger';
import router from '@ohos.router';
import { Recommendation } from '../model/Recommendation';
import { Dao } from '../database/Dao';
import { AgentScheduler } from '../services/AgentScheduler';
import { RecRefreshSignal } from '../common/TravelPreferenceTags';
import { getTheme, FONT, RADIUS, SPACE } from '../common/Theme';

const TAG = 'RecommendPage';

@Entry
@Component
export struct RecommendPage {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  @State recommendations: Recommendation[] = [];
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;

  private dao: Dao = Dao.getInstance();

  aboutToAppear(): void {
    Logger.info(TAG, 'RecommendPage aboutToAppear');
    this.loadRecommendations();
  }

  async loadRecommendations(): Promise<void> {
    this.isLoading = true;
    try {
      this.recommendations = await this.dao.queryRecentRecommendations(20);
    } catch (e) {
      Logger.warn(TAG, 'Failed to load recommendations');
    }
    this.isLoading = false;
  }

  async onRefresh(): Promise<void> {
    if (this.isRefreshing) return;
    this.isRefreshing = true;
    try {
      await AgentScheduler.getInstance().requestRefresh();
      await this.loadRecommendations();
      // 延时确保 DB 写入完成后再通知地图刷新
      setTimeout(() => { RecRefreshSignal.fire(); }, 600);
      Logger.info(TAG, 'Refresh done, %{public}d recs', this.recommendations.length);
    } catch (e) {
      Logger.warn(TAG, 'Refresh failed');
    }
    this.isRefreshing = false;
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('← 返回')
          .fontSize(FONT.body).fontColor(getTheme().primary)
          .onClick(() => { router.back(); })
        Blank()
        Text('💡 附近推荐').fontSize(FONT.heading).fontWeight(FontWeight.Bold)
          .fontColor(getTheme().textPrimary)
        Blank()
        Text(this.isRefreshing ? '⏳' : '🔄')
          .fontSize(18)
          .onClick(() => { this.onRefresh(); })
      }
      .width('100%').padding({ left: SPACE.lg, right: SPACE.lg, top: SPACE.md, bottom: SPACE.md })
      .backgroundColor(getTheme().surface)

      Divider().color(getTheme().divider).height(0.5)

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(36).height(36)
          Text('加载中…').fontSize(FONT.caption).fontColor(getTheme().textSecondary).margin({ top: SPACE.md })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.recommendations.length === 0) {
        Column() {
          Text('🤖').fontSize(48)
          Text('暂无推荐').fontSize(FONT.subheading).fontColor(getTheme().textSecondary).margin({ top: SPACE.sm })
          Text('Agent 正在学习您的出行习惯').fontSize(FONT.caption).fontColor(getTheme().textTertiary).margin({ top: SPACE.xs })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.recommendations, (rec: Recommendation) => {
              Column() {
                Row() {
                  if (this.getPhotoUrl(rec)) {
                    Image(this.getPhotoUrl(rec))
                      .width(64).height(64)
                      .borderRadius(RADIUS.sm)
                      .objectFit(ImageFit.Cover)
                      .margin({ right: SPACE.md })
                  }
                  Column() {
                    Row() {
                      Text(this.emojiForType(rec.placeType)).fontSize(16).margin({ right: 4 })
                      Text(rec.placeName)
                        .fontSize(FONT.subheading).fontWeight(FontWeight.Medium)
                        .fontColor(getTheme().textPrimary).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                    }
                    .width('100%')
                    Text(rec.reason || '附近热门选择')
                      .fontSize(FONT.caption).fontColor(getTheme().textSecondary)
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 2 })
                    if (this.getRating(rec)) {
                      Text(this.getRating(rec))
                        .fontSize(FONT.label).fontColor('#F59E0B')
                        .margin({ top: 2 })
                    }
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('›').fontSize(18).fontColor(getTheme().textTertiary)
                }
                .width('100%')
              }
              .width('100%').padding(SPACE.md)
              .backgroundColor(getTheme().surface)
              .borderRadius(RADIUS.md)
              .margin({ left: SPACE.lg, right: SPACE.lg, top: SPACE.sm, bottom: SPACE.sm })
              .onClick(() => {
                router.pushUrl({
                  url: 'pages/WaypointDetailPage',
                  params: {
                    poiName: rec.placeName, latitude: rec.latitude, longitude: rec.longitude,
                    activityTag: rec.placeType, timestamp: rec.timestamp,
                    stayDuration: 0, speed: 0, photoList: '',
                    isRecommendation: true, recReason: rec.reason || ''
                  }
                });
              })
            })
          }
          .width('100%').padding({ top: SPACE.sm, bottom: SPACE.xxl })
        }
        .layoutWeight(1).scrollBar(BarState.Off)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(getTheme().pageBg)
  }

  getPhotoUrl(rec: Recommendation): string {
    try {
      if (rec.enrichmentJson && rec.enrichmentJson.length > 0) {
        const data: Record<string, Object> = JSON.parse(rec.enrichmentJson) as Record<string, Object>;
        const url: string = (data['photoUrl'] as string) || '';
        if (url.length > 10) return url;
      }
    } catch (e) { /* ignore */ }
    return '';
  }

  getRating(rec: Recommendation): string {
    try {
      if (rec.enrichmentJson && rec.enrichmentJson.length > 0) {
        const data: Record<string, Object> = JSON.parse(rec.enrichmentJson) as Record<string, Object>;
        const rating: number = data['rating'] as number || 0;
        if (rating > 0) return rating.toFixed(1) + '⭐';
      }
    } catch (e) { /* ignore */ }
    return '';
  }

  emojiForType(type: string): string {
    const m: Record<string, string> = {
      'dining':'🍽️','shopping':'🛍️','sports':'🏃','leisure':'🎠',
      'travel':'✈️','work':'💼','home':'🏠','commute':'🚇'
    };
    return m[type] || '📍';
  }
}
