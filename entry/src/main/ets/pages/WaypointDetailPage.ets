/**
 * 路径点详情页
 * 从地图 marker 点击进入，展示位置、活动、照片等完整信息
 * 照片支持：真实相册照片（URI）或 Mock 文字描述
 */
import router from '@ohos.router';
import { ACTIVITY_LABELS } from '../common/Constants';
import { formatTimestamp } from '../common/LocationUtils';

const TAG = 'WaypointDetail';

interface DetailParams {
  poiName: string;
  latitude: number;
  longitude: number;
  activityTag: string;
  timestamp: number;
  stayDuration: number;
  speed: number;
  photoList: PhotoItem[];
  isRecommendation: boolean;
  recReason: string;
}

interface PhotoItem {
  uri: string;
  isReal: boolean; // true = 设备照片, false = mock 描述
}

function parseParams(): DetailParams {
  const p = router.getParams() as Record<string, Object>;
  const photosRaw: string | undefined = p?.['photoList'] as string | undefined;
  const photoItems: PhotoItem[] = [];
  if (photosRaw && photosRaw.length > 0) {
    const parts: string[] = photosRaw.split('|').filter(s => s.length > 0);
    for (const s of parts) {
      photoItems.push({
        uri: s,
        isReal: s.startsWith('file://') || s.startsWith('datashare://')
      });
    }
  }
  return {
    poiName: (p?.['poiName'] as string) || '未知地点',
    latitude: (p?.['latitude'] as number) || 0,
    longitude: (p?.['longitude'] as number) || 0,
    activityTag: (p?.['activityTag'] as string) || '',
    timestamp: (p?.['timestamp'] as number) || 0,
    stayDuration: (p?.['stayDuration'] as number) || 0,
    speed: (p?.['speed'] as number) || 0,
    photoList: photoItems,
    isRecommendation: (p?.['isRecommendation'] as boolean) || false,
    recReason: (p?.['recReason'] as string) || ''
  };
}

function stayFmt(ms: number): string {
  if (ms <= 0) return '路过';
  const mins: number = Math.floor(ms / 60000);
  if (mins < 60) return `${mins} 分钟`;
  const hrs: number = Math.floor(mins / 60);
  const rem: number = mins % 60;
  return rem > 0 ? `${hrs} 小时 ${rem} 分钟` : `${hrs} 小时`;
}

function speedFmt(ms: number): string {
  if (ms <= 0) return '—';
  const kmh: number = ms * 3.6;
  return `${kmh.toFixed(1)} km/h`;
}

function activityIcon(tag: string): string {
  const m: Record<string, string> = {
    'sports':'🏃','commute':'🚇','work':'💼','dining':'🍽️',
    'shopping':'🛍️','home':'🏠','leisure':'🎠','travel':'✈️'
  };
  return m[tag] || '📍';
}

@Entry
@Component
struct WaypointDetailPage {
  private data: DetailParams = parseParams();
  @State currentIndex: number = 0;

  build() {
    Column() {
      // 顶栏
      Row() {
        Button() { Text('← 返回').fontSize(15).fontColor('#3B82F6') }
          .backgroundColor(Color.Transparent)
          .onClick(() => { router.back(); })
        Text('路径点详情').fontSize(17).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.Center)
        Row().width(60)
      }
      .width('100%').height(48).padding({ left: 12, right: 12 })
      .backgroundColor('#FFFFFF')

      Scroll() {
        Column() {
          // ── 照片轮播 ──
          if (this.data.photoList.length > 0) {
            Swiper() {
              ForEach(this.data.photoList, (item: PhotoItem, idx: number) => {
                Column() {
                  if (item.isReal) {
                    // 真实设备照片 → Image 组件加载
                    Image(item.uri)
                      .width('100%').height(200)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(12)
                  } else {
                    // Mock 文字描述 → 占位卡片
                    Column() {
                      Text('📷').fontSize(48)
                      Text(item.uri).fontSize(14).fontColor('#555').margin({ top: 8 })
                    }
                    .width('100%').height(200)
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor('#F0F2F5')
                    .borderRadius(12)
                  }
                }.padding(16)
              })
            }
            .width('100%').height(220)
            .indicator(this.data.photoList.length > 1 ? true : false)
          } else {
            Column() {
              Text('📭').fontSize(40)
              Text('此处没有拍照').fontSize(13).fontColor('#BBB').margin({ top: 6 })
            }
            .width('100%').height(140).justifyContent(FlexAlign.Center)
            .backgroundColor('#F8F9FA').borderRadius(12)
          }

          // ── 地点信息 ──
          Column() {
            Row() {
              Text(activityIcon(this.data.activityTag)).fontSize(28).margin({ right: 12 })
              Column() {
                Text(this.data.poiName).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#222')
                if (this.data.activityTag) {
                  Text(ACTIVITY_LABELS[this.data.activityTag] || this.data.activityTag)
                    .fontSize(12).fontColor('#3B82F6')
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .backgroundColor('#EBF3FF').borderRadius(8)
                    .margin({ top: 4 })
                }
              }.alignItems(HorizontalAlign.Start)
            }.width('100%')

            Divider().margin({ top: 14, bottom: 14 })

            if (this.data.isRecommendation) {
              // 推荐门店：显示推荐理由，不显示活动指标
              Column() {
                Text('💡 推荐理由')
                  .fontSize(11).fontColor('#999')
                Text(this.data.recReason || '附近热门选择')
                  .fontSize(14).fontColor('#333').fontWeight(FontWeight.Medium)
                  .margin({ top: 4 })
              }.width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 10 })
              Row() {
                this.InfoItem('📍 纬度', this.data.latitude.toFixed(6))
                this.InfoItem('📍 经度', this.data.longitude.toFixed(6))
              }.width('100%')
            } else {
              Row() {
                this.InfoItem('🕐 时间', formatTimestamp(this.data.timestamp))
                this.InfoItem('⏱️ 停留', stayFmt(this.data.stayDuration))
              }.width('100%')
              Row() {
                this.InfoItem('📍 纬度', this.data.latitude.toFixed(6))
                this.InfoItem('📍 经度', this.data.longitude.toFixed(6))
              }.width('100%').margin({ top: 10 })
              Row() {
                this.InfoItem('🏃 移动速度', speedFmt(this.data.speed))
                this.InfoItem('📸 照片数', `${this.data.photoList.length}`)
              }.width('100%').margin({ top: 10 })
            }
          }
          .padding(20).backgroundColor('#FFFFFF')
          .borderRadius(12).width('100%')
          .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
          .margin({ top: 12 })

          // ── 照片清单 ──
          if (this.data.photoList.length > 0) {
            Text(`📸 全部照片 (${this.data.photoList.length})`)
              .fontSize(15).fontWeight(FontWeight.Medium)
              .width('100%').margin({ top: 20, bottom: 8 })

            Grid() {
              ForEach(this.data.photoList, (item: PhotoItem, idx: number) => {
                GridItem() {
                  Column() {
                    if (item.isReal) {
                      Image(item.uri)
                        .width('100%').height(80)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(8)
                    } else {
                      Column() {
                        Text('📷').fontSize(28)
                        Text(item.uri).fontSize(10).fontColor('#666')
                          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .margin({ top: 4 }).textAlign(TextAlign.Center)
                      }
                      .width('100%').padding(8)
                      .backgroundColor('#F5F6F8').borderRadius(10)
                      .alignItems(HorizontalAlign.Center)
                    }
                  }
                  .width('100%')
                  .onClick(() => { this.currentIndex = idx; })
                }
              })
            }
            .columnsTemplate('1fr 1fr 1fr').rowsGap(8).columnsGap(8)
            .width('100%')
          }
        }
        .width('100%').padding(16)
      }
      .width('100%').layoutWeight(1).backgroundColor('#F5F6F8')

    }
    .width('100%').height('100%')
  }

  @Builder
  InfoItem(label: string, value: string) {
    Column() {
      Text(label).fontSize(11).fontColor('#999')
      Text(value).fontSize(14).fontColor('#333').fontWeight(FontWeight.Medium).margin({ top: 2 })
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }
}
