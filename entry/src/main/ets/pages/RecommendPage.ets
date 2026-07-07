/**
 * 今日推荐页面
 * 基于当下情境的主动推荐卡片
 */
import { Logger } from '../common/Logger';
import router from '@ohos.router';
import { Recommendation } from '../model/Recommendation';
import { Dao } from '../database/Dao';
import { AgentScheduler } from '../services/AgentScheduler';

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
  @State lastRefreshText: string = '';
  @State isRefreshing: boolean = false;

  private dao: Dao = Dao.getInstance();

  aboutToAppear(): void {
    Logger.info(TAG, 'RecommendPage aboutToAppear');
    this.loadRecommendations();
  }

  /** 手动刷新（点击刷新按钮或切换到 tab 时调用） */
  async onRefresh(): Promise<void> {
    if (this.isRefreshing) return;
    this.isRefreshing = true;
    try {
      await AgentScheduler.getInstance().requestRefresh();
      await this.loadRecommendations();
      const now: Date = new Date();
      this.lastRefreshText = `${now.getHours().toString().padStart(2,'0')}:${now.getMinutes().toString().padStart(2,'0')} 已刷新`;
    } catch (e) {
      Logger.warn(TAG, 'Manual refresh failed');
    } finally {
      this.isRefreshing = false;
    }
  }

  /**
   * 外部调用：切换到推荐 tab 时触发刷新
   */
  onTabActivated(): void {
    Logger.info(TAG, 'Recommend tab activated, triggering refresh');
    this.onRefresh();
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

  getCardColor(type: string): string {
    if (!type) return '#3B82F6';
    // type 是上下文标签 (breakfast/lunch/dinner/night/daily) 或活动类型
    if (type.includes('breakfast') || type.includes('lunch') || type.includes('dinner') || type.includes('night')) return '#FF6B35';
    if (type.includes('afternoon')) return '#E91E63';
    if (type.includes('daily')) return '#2196F3';
    const m: Record<string, string> = {
      'dining':'#FF6B35', 'shopping':'#E91E63', 'sports':'#4CAF50',
      'leisure':'#2196F3', 'travel':'#9C27B0'
    };
    return m[type] || '#FF6B35';
  }

  getTypeEmoji(type: string): string {
    if (!type) return '📍';
    if (type.includes('breakfast') || type.includes('lunch') || type.includes('dinner') || type.includes('night')) return '🍽️';
    if (type.includes('afternoon') || type.includes('tea')) return '☕';
    const map: Record<string, string> = {
      'dining':'🍽️', 'shopping':'🛍️', 'sports':'🏃', 'leisure':'🎠', 'travel':'✈️',
      'daily':'📍', 'cafe':'☕', 'park':'🌳', 'movie':'🎬'
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
        if (this.lastRefreshText.length > 0) {
          Text(this.lastRefreshText)
            .fontSize(11).fontColor('#999')
            .margin({ right: 6 })
        }
        Button() { Text(this.isRefreshing ? '⏳' : '🔄').fontSize(18) }
          .backgroundColor(Color.Transparent).width(36).height(36)
          .enabled(!this.isRefreshing)
          .onClick(() => { this.onRefresh(); })
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
                // ── 照片或 emoji 头图 ──
                if (this.hasPhoto(rec)) {
                  Image(this.parsePhotoUrl(rec.enrichmentJson))
                    .width('100%').height(140)
                    .objectFit(ImageFit.Cover).borderRadius({ topLeft: 12, topRight: 12 })
                } else {
                  Column() {
                    Text(this.getTypeEmoji(rec.placeType)).fontSize(40)
                    Text(rec.placeName.substring(0, 4)).fontSize(13).fontColor('#FFF').margin({ top: 4 }).opacity(0.9)
                  }
                  .width('100%').height(110)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(this.getCardColor(rec.placeType))
                  .borderRadius({ topLeft: 12, topRight: 12 })
                }
                // ── 信息区 ──
                Row() {
                  Text(this.getTypeEmoji(rec.placeType)).fontSize(28).margin({ right: 12 })
                  Column() {
                    Text(rec.placeName || '推荐地点')
                      .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#222')
                    Text(rec.reason || '根据您的偏好推荐')
                      .fontSize(13).fontColor('#666').margin({ top: 3 }).maxLines(2)
                    if (rec.enrichmentJson.length > 0) {
                      this.BuildEnrichment(
                        this.parseEnrichmentRating(rec.enrichmentJson),
                        this.parseEnrichmentReviewCount(rec.enrichmentJson),
                        this.parseEnrichmentPopularItems(rec.enrichmentJson),
                        this.parseEnrichmentSource(rec.enrichmentJson)
                      )
                    }
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                }
                .width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
              }
              .width('100%').backgroundColor('#FFFFFF').borderRadius(12)
              .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
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
                    recReason: this.buildDetailReason(rec)
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

  private buildDetailReason(rec: Recommendation): string {
    let r: string = rec.reason || '';
    const rating: number = this.parseEnrichmentRating(rec.enrichmentJson);
    const items: string = this.parseEnrichmentPopularItems(rec.enrichmentJson);
    const source: string = this.parseEnrichmentSource(rec.enrichmentJson);
    if (rating > 0) r += `\n⭐ ${rating.toFixed(1)} 分`;
    if (items.length > 0) r += `\n🔥 推荐：${items}`;
    if (source === 'dianping') r += '\n📱 来源：大众点评';
    else if (source === 'meituan') r += '\n📱 来源：美团';
    return r;
  }

  private hasPhoto(rec: Recommendation): boolean {
    const url: string = this.parsePhotoUrl(rec.enrichmentJson);
    if (url.length === 0) return false;
    if (!url.startsWith('http')) return false;
    // 过滤数据库残留的旧静态地图 URL
    // 排除已知不可靠的 URL 模式
    // Amap 照片 URL 来自 `place/around` 的 photos[0].url，直接可用
    return true;
    return true;
  }

  private parsePhotoUrl(json: string): string {
    try {
      const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      return (obj['photoUrl'] as string) || '';
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
