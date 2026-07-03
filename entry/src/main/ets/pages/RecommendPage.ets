/**
 * 今日推荐页面
 * 基于当下情境的主动推荐卡片
 */
import { Logger } from '../common/Logger';
import router from '@ohos.router';
import { Recommendation } from '../model/Recommendation';
import { Dao } from '../database/Dao';

const TAG = 'RecommendPage';

interface EnrichmentRating { rating?: number }
interface EnrichmentReviewCount { reviewCount?: number }
interface EnrichmentPopularItems { popularItems?: string }
interface EnrichmentSource { source?: string }

@Component
export struct RecommendContent {
  onTabChange: (index: number) => void = () => {};
  @State recommendations: Recommendation[] = [];
  @State isLoading: boolean = true;

  private dao: Dao = Dao.getInstance();
  private pollTimer: number = -1;

  aboutToAppear(): void {
    Logger.info(TAG, 'RecommendPage aboutToAppear');
    this.loadRecommendations();
    // 启动 30 秒轮询定时器
    this.startPolling();
  }

  aboutToDisappear(): void {
    // 清除轮询定时器
    this.stopPolling();
  }

  private startPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
    }
    this.pollTimer = setInterval(() => {
      this.loadRecommendations();
    }, 30000); // 30 秒
    Logger.info(TAG, 'Started 30s polling for recommendations');
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
      Logger.info(TAG, 'Stopped recommendation polling');
    }
  }

  /**
   * 外部调用：切换到推荐 tab 时触发刷新
   */
  onTabActivated(): void {
    Logger.info(TAG, 'Recommend tab activated, refreshing');
    this.loadRecommendations();
  }

  async loadRecommendations(): Promise<void> {
    try {
      const recs: Recommendation[] = await this.dao.queryRecentRecommendations(20);
      this.recommendations = recs;
      this.isLoading = false;
    } catch (err) {
      this.isLoading = false;
    }
  }

  formatTime(ts: number): string {
    if (ts <= 0) return '';
    const d: Date = new Date(ts);
    const m: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    const h: string = d.getHours().toString().padStart(2, '0');
    const min: string = d.getMinutes().toString().padStart(2, '0');
    return `${m}/${day} ${h}:${min}`;
  }

  getTypeEmoji(type: string): string {
    const map: Record<string, string> = {
      'dining': '🍽️', 'cafe': '☕', 'shopping': '🛍️',
      'park': '🌳', 'sports': '🏃', 'movie': '🎬',
      'museum': '🏛️', 'scenic': '🏔️'
    };
    return map[type] || '📍';
  }

  build() {
    Column() {
      // 标题
      Row() {
        Text('←').fontSize(24).fontColor('#3B82F6')
          .width(36).height(36)
          .onClick(() => { this.onTabChange(0); })
        Text('今日推荐')
          .fontSize(22).fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
        Blank()
        Text('AI 主动推荐')
          .fontSize(12).fontColor('#999')
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor('#F0F4FF').borderRadius(10)
      }
      .width('100%').padding({ top: 16, bottom: 12, left: 16, right: 16 })

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(36).height(36)
          Text('加载中...').fontSize(14).fontColor('#999').margin({ top: 12 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.recommendations.length === 0) {
        // 空状态 — Agent 学习中
        Column() {
          Text('🤖').fontSize(56).margin({ bottom: 12 })
          Text('Agent 正在学习您的出行习惯').fontSize(17).fontColor('#333')
          Text('积累足够的出行数据后，这里会自动出现个性化推荐')
            .fontSize(13).fontColor('#999').margin({ top: 6 })
            .textAlign(TextAlign.Center).padding({ left: 40, right: 40 })

          // 推荐逻辑说明卡片
          Column() {
            Row() {
              Text('💡').fontSize(16)
              Text('推荐逻辑').fontSize(14).fontWeight(FontWeight.Medium).margin({ left: 6 })
            }.margin({ bottom: 8 })

            Text('• 到达新地点 → 推荐附近热门去处').fontSize(12).fontColor('#666').margin({ bottom: 4 })
            Text('• 用餐时段 → 推荐符合口味的餐厅').fontSize(12).fontColor('#666').margin({ bottom: 4 })
            Text('• 周末好天气 → 推荐户外活动').fontSize(12).fontColor('#666').margin({ bottom: 4 })
            Text('• 购物停留 → 推荐附近咖啡店').fontSize(12).fontColor('#666').margin({ bottom: 4 })
            Text('• 联网搜索大众点评/美团热门去处').fontSize(12).fontColor('#666')
          }
          .width('85%').padding(16).backgroundColor('#F8FAFB').borderRadius(12).margin({ top: 20 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        // 推荐卡片列表
        List() {
          ForEach(this.recommendations, (rec: Recommendation) => {
            ListItem() {
              Column() {
                Row() {
                  Text(this.getTypeEmoji(rec.placeType)).fontSize(28).margin({ right: 12 })
                  Column() {
                    Text(rec.placeName || '推荐地点')
                      .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#222')
                    Text(rec.reason || '根据您的偏好推荐')
                      .fontSize(13).fontColor('#666').margin({ top: 3 }).maxLines(2)
                    // Web 富数据展示（评分/评论/推荐菜）
                    if (rec.enrichmentJson.length > 0) {
                      this.BuildEnrichment(
                        this.parseEnrichmentRating(rec.enrichmentJson),
                        this.parseEnrichmentReviewCount(rec.enrichmentJson),
                        this.parseEnrichmentPopularItems(rec.enrichmentJson),
                        this.parseEnrichmentSource(rec.enrichmentJson)
                      )
                    }
                    Row() {
                      if (rec.triggerContext) {
                        Text(`触发: ${rec.triggerContext}`)
                          .fontSize(11).fontColor('#4A90D9')
                          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                          .backgroundColor('#EBF3FF').borderRadius(4)
                      }
                      if (rec.timestamp > 0) {
                        Text(this.formatTime(rec.timestamp))
                          .fontSize(11).fontColor('#BBB').margin({ left: 8 })
                      }
                    }.margin({ top: 6 })
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)

                  Column() {
                    Text(rec.isAccepted ? '✓' : '')
                      .fontSize(16).fontColor('#50C878')
                  }
                }
              }
              .width('100%').padding(14)
              .onClick(() => {
                router.pushUrl({
                  url: 'pages/WaypointDetailPage',
                  params: {
                    poiName: rec.placeName,
                    latitude: rec.latitude,
                    longitude: rec.longitude,
                    activityTag: rec.placeType,
                    timestamp: rec.timestamp,
                    stayDuration: 0,
                    speed: 0,
                    photoList: '',
                    isRecommendation: true,
                    recReason: rec.reason || '附近热门选择'
                  }
                });
              })
            }
            .margin({ left: 16, right: 16, top: 6, bottom: 6 })
            .borderRadius(12).backgroundColor('#FFFFFF')
            .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
          })
        }
        .width('100%').layoutWeight(1)
      }

    }
    .width('100%').height('100%').backgroundColor('#F5F6F8')
  }

  @Builder
  BuildEnrichment(rating: number, reviewCount: number, popularItems: string, source: string) {
    Row() {
      if (rating > 0) {
        Text(`⭐ ${rating.toFixed(1)}`).fontSize(12).fontColor('#FF8C00')
      }
      if (reviewCount > 0) {
        Text(` · ${reviewCount}条评论`).fontSize(12).fontColor('#FF8C00')
      }
      if (source.length > 0) {
        Text(` · ${this.sourceLabel(source)}`).fontSize(11).fontColor('#AAA')
      }
    }.margin({ top: 3 })

    if (popularItems.length > 0) {
      Text(`推荐: ${popularItems}`).fontSize(11).fontColor('#888').margin({ top: 2 }).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  private parseEnrichmentRating(json: string): number {
    try {
      const data: EnrichmentRating = JSON.parse(json) as EnrichmentRating;
      return data.rating || 0;
    } catch (e) { return 0; }
  }

  private parseEnrichmentReviewCount(json: string): number {
    try {
      const data: EnrichmentReviewCount = JSON.parse(json) as EnrichmentReviewCount;
      return data.reviewCount || 0;
    } catch (e) { return 0; }
  }

  private parseEnrichmentPopularItems(json: string): string {
    try {
      const data: EnrichmentPopularItems = JSON.parse(json) as EnrichmentPopularItems;
      return data.popularItems || '';
    } catch (e) { return ''; }
  }

  private parseEnrichmentSource(json: string): string {
    try {
      const data: EnrichmentSource = JSON.parse(json) as EnrichmentSource;
      return data.source || '';
    } catch (e) { return ''; }
  }

  sourceLabel(source: string): string {
    const map: Record<string, string> = {
      'dianping': '大众点评', 'meituan': '美团',
      'web_general': '网页', 'amap': '高德地图'
    };
    return map[source] || source;
  }
}
