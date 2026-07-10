/**
 * 路径点详情页
 * 从地图 marker 点击进入，展示位置、活动、照片等完整信息
 * 照片支持：真实相册照片（URI）或 Mock 文字描述
 * 支持校准活动段类型和POI名称
 */
import router from '@ohos.router';
import { ACTIVITY_LABELS, ActivityType, CalibrationSource } from '../common/Constants';
import { formatTimestamp } from '../common/LocationUtils';
import { CalibrationService } from '../services/CalibrationService';
import { SegmentCalibration } from '../model/SegmentCalibration';
import { ActivitySegment } from '../model/ActivitySegment';
import { Dao } from '../database/Dao';
import { CalibrationSignal } from '../common/CalibrationSignal';
import { Logger } from '../common/Logger';
import { getTheme, isDarkTheme } from '../common/Theme';

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
  segmentStartTime: number;  // 活动段的 startTime（用于校准定位）
  segmentEndTime: number;    // 活动段的 endTime（用于时间范围重叠匹配）
  dayKey: string;            // 日期键
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
        isReal: s.startsWith('file://') || s.startsWith('datashare://') || s.startsWith('http')
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
    recReason: (p?.['recReason'] as string) || '',
    segmentStartTime: (p?.['segmentStartTime'] as number) || 0,
    segmentEndTime: (p?.['segmentEndTime'] as number) || 0,
    dayKey: (p?.['dayKey'] as string) || ''
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
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  private data: DetailParams = parseParams();
  @State currentIndex: number = 0;
  @State isCalibrated: boolean = false;
  @State showEditSheet: boolean = false;
  @State showDeleteConfirm: boolean = false;
  @State showRenameInput: boolean = false;
  @State showTypeConfirm: boolean = false;
  @State pendingType: string = '';
  @State pendingTypeLabel: string = '';
  @State calService: CalibrationService = CalibrationService.getInstance();
  @State displayActivityTag: string = this.data.activityTag;
  @State displayPoiName: string = this.data.poiName;
  @State editPoiName: string = this.data.poiName;

  aboutToAppear(): void {
    this.checkCalibration();
  }

  async checkCalibration(): Promise<void> {
    if (!this.data.segmentStartTime || !this.data.dayKey) return;
    try {
      const cals: SegmentCalibration[] = await this.calService.getCalibrationsByDay(this.data.dayKey);
      for (const cal of cals) {
        if (cal.segmentStartTime === this.data.segmentStartTime) {
          this.isCalibrated = !!(cal.calibratedType || cal.calibratedPoiName);
          // 如果已校准，使用校准值更新显示
          if (cal.calibratedType) {
            this.displayActivityTag = cal.calibratedType;
          }
          if (cal.calibratedPoiName) {
            this.displayPoiName = cal.calibratedPoiName;
          }
          return;
        }
      }
      this.isCalibrated = false;
    } catch (e) {
      // ignore
    }
  }

  async doCalibrateType(newType: string): Promise<void> {
    if (!this.data.segmentStartTime || !this.data.dayKey) return;
    try {
      // 1. 写入校准表（独立保留，不惧重新分类覆盖）
      //    使用原始 startTime/endTime 作为校准时间范围
      await this.calService.calibrateType(
        this.data.dayKey, this.data.segmentStartTime, newType, CalibrationSource.MANUAL,
        this.data.segmentEndTime
      );

      // 2. 直接更新 activity_segment 表中的段
      //    用时间重叠匹配找段（因为可能在用户浏览期间被分类器重建，startTime 已漂移）
      const dao: Dao = Dao.getInstance();
      const segs: ActivitySegment[] = await dao.queryActivitySegmentsByDay(this.data.dayKey);
      let bestSeg: ActivitySegment | null = null;
      let bestDist: number = Number.MAX_VALUE;

      for (const seg of segs) {
        // 时间范围重叠检测
        const overlapStart: number = Math.max(this.data.segmentStartTime, seg.startTime);
        const overlapEnd: number = Math.min(this.data.segmentEndTime || this.data.segmentStartTime,
          seg.endTime || seg.startTime);
        if (overlapStart < overlapEnd) {
          // 有重叠，取startTime差异最小的段
          const dist: number = Math.abs(seg.startTime - this.data.segmentStartTime);
          if (dist < bestDist) {
            bestDist = dist;
            bestSeg = seg;
          }
        }
      }

      if (bestSeg) {
        bestSeg.activityType = newType;
        bestSeg.summary = `${newType} · ${Math.round((bestSeg.endTime - bestSeg.startTime) / 60000)}分钟`;
        await dao.updateActivitySegment(bestSeg);
        Logger.info(TAG, 'Segment id=%{public}d updated: type=%{public}s (startTime diff=%{public}d ms)',
          bestSeg.id, newType, bestDist);
      } else {
        Logger.warn(TAG, 'No overlapping segment found for calibration (day=%{public}s, range=%{public}d–%{public}d)',
          this.data.dayKey, this.data.segmentStartTime, this.data.segmentEndTime);
      }

      this.displayActivityTag = newType;
      this.isCalibrated = true;
      this.showEditSheet = false;
      CalibrationSignal.fire();
    } catch (e) {
      Logger.error(TAG, 'doCalibrateType failed: %{public}s', JSON.stringify(e));
    }
  }

  async doResetCalibration(): Promise<void> {
    if (!this.data.segmentStartTime || !this.data.dayKey) return;
    try {
      await this.calService.removeCalibration(this.data.dayKey, this.data.segmentStartTime);
      this.isCalibrated = false;
      this.showEditSheet = false;
      CalibrationSignal.fire();
    } catch (e) {
      Logger.error(TAG, 'doResetCalibration failed: %{public}s', JSON.stringify(e));
    }
  }

  async doCalibratePoiName(): Promise<void> {
    if (!this.data.segmentStartTime || !this.data.dayKey || !this.editPoiName) return;
    try {
      // 写入校准表
      await this.calService.calibratePoiName(
        this.data.dayKey, this.data.segmentStartTime, this.editPoiName,
        CalibrationSource.MANUAL, this.data.segmentEndTime
      );
      // 直接更新段表中的 POI 名称
      const dao: Dao = Dao.getInstance();
      const segs: ActivitySegment[] = await dao.queryActivitySegmentsByDay(this.data.dayKey);
      for (const seg of segs) {
        if (Math.abs(seg.startTime - this.data.segmentStartTime) < 60000) {
          seg.poiName = this.editPoiName;
          await dao.updateActivitySegment(seg);
          break;
        }
      }
      this.displayPoiName = this.editPoiName;
      this.isCalibrated = true;
      CalibrationSignal.fire();
      Logger.info(TAG, 'POI name calibrated: %{public}s', this.editPoiName);
    } catch (e) {
      Logger.error(TAG, 'doCalibratePoiName failed: %{public}s', JSON.stringify(e));
    }
  }

  async doDeleteSegment(): Promise<void> {
    if (!this.data.segmentStartTime || !this.data.dayKey) return;
    try {
      await this.calService.deleteSegment(
        this.data.dayKey, this.data.segmentStartTime, this.data.segmentEndTime,
        CalibrationSource.MANUAL
      );
      CalibrationSignal.fire();
      this.showEditSheet = false;
      // 删除后返回上一页
      router.back();
    } catch (e) {
      Logger.error(TAG, 'doDeleteSegment failed: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Button() { Text('← 返回').fontSize(15).fontColor('#3B82F6') }
          .backgroundColor(Color.Transparent)
          .onClick(() => { router.back(); })
        Text('路径点详情').fontSize(17).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
          .layoutWeight(1).textAlign(TextAlign.Center)
        // 编辑按钮 — 始终显示，无 segmentStartTime 时用 timestamp 作为锚点
        Button() { Text(this.isCalibrated ? '✏️ 已校准' : '✏️ 编辑').fontSize(12).fontColor('#3B82F6') }
          .backgroundColor(getTheme(this.themeMode).primaryLight).borderRadius(12).height(28).padding({ left: 10, right: 10 })
          .onClick(() => {
            // 如果没有段锚点，用足迹时间戳作为校准锚点
            if (!this.data.segmentStartTime) {
              this.data.segmentStartTime = this.data.timestamp;
              this.data.segmentEndTime = this.data.timestamp + this.data.stayDuration;
            }
            this.showEditSheet = true;
          })
      }
      .width('100%').height(48).padding({ left: 12, right: 12 })
      .backgroundColor(getTheme(this.themeMode).surface)

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
                      Text(item.uri).fontSize(14).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 8 })
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
              Text('此处没有拍照').fontSize(13).fontColor(getTheme(this.themeMode).textTertiary).margin({ top: 6 })
            }
            .width('100%').height(140).justifyContent(FlexAlign.Center)
            .backgroundColor(getTheme(this.themeMode).surfaceSecondary).borderRadius(12)
          }

          // ── 地点信息 ──
          Column() {
            Row() {
              Text(activityIcon(this.displayActivityTag)).fontSize(28).margin({ right: 12 })
              Column() {
                Text(this.displayPoiName).fontSize(20).fontWeight(FontWeight.Bold).fontColor(getTheme(this.themeMode).textPrimary)
                Row() {
                if (this.displayActivityTag) {
                  Text(ACTIVITY_LABELS[this.displayActivityTag] || this.displayActivityTag)
                    .fontSize(12).fontColor('#3B82F6')
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .backgroundColor(getTheme(this.themeMode).primaryLight).borderRadius(8)
                }
                if (this.isCalibrated) {
                  Text('✅ 已校准')
                    .fontSize(10).fontColor('#10B981')
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor('#ECFDF5').borderRadius(8)
                    .margin({ left: 6 })
                }
              }.margin({ top: 4 })
              }.alignItems(HorizontalAlign.Start)
            }.width('100%')

            Divider().margin({ top: 14, bottom: 14 })

            if (this.data.isRecommendation) {
              // 推荐门店：显示推荐理由，不显示活动指标
              Column() {
                Text('💡 推荐理由')
                  .fontSize(11).fontColor(getTheme(this.themeMode).textSecondary)
                Text(this.data.recReason || '附近热门选择')
                  .fontSize(14).fontColor(getTheme(this.themeMode).textPrimary).fontWeight(FontWeight.Medium)
                  .margin({ top: 4 }).maxLines(10)
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
          .padding(20).backgroundColor(getTheme(this.themeMode).surface)
          .borderRadius(12).width('100%')
          .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
          .margin({ top: 12 })

          // ── 照片清单 ──
          if (this.data.photoList.length > 0) {
            Text(`📸 全部照片 (${this.data.photoList.length})`).fontColor(getTheme(this.themeMode).textPrimary)
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
                        Text(item.uri).fontSize(10).fontColor(getTheme(this.themeMode).textSecondary)
                          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .margin({ top: 4 }).textAlign(TextAlign.Center)
                      }
                      .width('100%').padding(8)
                      .backgroundColor(getTheme(this.themeMode).pageBg).borderRadius(10)
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
      .width('100%').layoutWeight(1).backgroundColor(getTheme(this.themeMode).pageBg)

      // ── 校准编辑面板 ──
      if (this.showEditSheet) {
        Column() {
          // 遮罩
          Column().width('100%').layoutWeight(1)
            .onClick(() => { this.showEditSheet = false; })

          // 底部面板
          Column() {
            Text('校准活动段').fontSize(16).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
              .width('100%').textAlign(TextAlign.Center).padding({ top: 16, bottom: 12 })

            // ── 修改活动类型（两行）──
            Row() {
              ForEach(this.getTypeOptions().slice(0, 4), (opt: TypeOption) => {
                Column() {
                  Text(opt.icon).fontSize(22)
                  Text(opt.label).fontSize(10).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 2 })
                }
                .layoutWeight(1).padding({ top: 10, bottom: 10 })
                .backgroundColor(opt.type === this.displayActivityTag ? getTheme(this.themeMode).primaryLight : getTheme(this.themeMode).surfaceSecondary)
                .border({ width: 1, color: opt.type === this.displayActivityTag ? getTheme(this.themeMode).primary : getTheme(this.themeMode).border })
                .borderRadius(10).margin({ left: 2, right: 2 })
                .onClick(() => {
                  this.pendingType = opt.type;
                  this.pendingTypeLabel = opt.label;
                  this.showTypeConfirm = true;
                })
              })
            }.width('100%').margin({ bottom: 6 })

            Row() {
              ForEach(this.getTypeOptions().slice(4, 8), (opt: TypeOption) => {
                Column() {
                  Text(opt.icon).fontSize(22)
                  Text(opt.label).fontSize(10).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 2 })
                }
                .layoutWeight(1).padding({ top: 10, bottom: 10 })
                .backgroundColor(opt.type === this.displayActivityTag ? getTheme(this.themeMode).primaryLight : getTheme(this.themeMode).surfaceSecondary)
                .border({ width: 1, color: opt.type === this.displayActivityTag ? getTheme(this.themeMode).primary : getTheme(this.themeMode).border })
                .borderRadius(10).margin({ left: 2, right: 2 })
                .onClick(() => {
                  this.pendingType = opt.type;
                  this.pendingTypeLabel = opt.label;
                  this.showTypeConfirm = true;
                })
              })
            }.width('100%')

            // ── 分隔 ──
            Text('').height(1).width('100%').backgroundColor('#EEE').margin({ top: 14, bottom: 14 })

            // ── 更多操作 ──
            this.CalActionBtn('✏️ 修改地点名称', getTheme(this.themeMode).primary, getTheme(this.themeMode).primaryLight, () => {
              this.editPoiName = this.displayPoiName;
              this.showRenameInput = true;
            })

            this.CalActionBtn('🗑️ 删除此活动段', '#EF4444', isDarkTheme() ? '#2A1515' : '#FEF2F2', () => {
              this.showDeleteConfirm = true;
            })

            if (this.isCalibrated) {
              this.CalActionBtn('🔄 恢复 AI 分类', '#F59E0B', isDarkTheme() ? '#2A2010' : '#FFFBEB', () => {
                this.doResetCalibration();
              })
            }

            this.CalActionBtn('关闭', getTheme(this.themeMode).textSecondary, isDarkTheme() ? '#3A3A3C' : '#F0F0F0', () => {
              this.showEditSheet = false;
            })
          }
          .width('100%').backgroundColor(getTheme(this.themeMode).surface)
          .borderRadius({ topLeft: 16, topRight: 16 })
          .padding({ left: 20, right: 20, bottom: 32 })
          .shadow({ radius: 12, color: '#30000000', offsetY: -4 })
        }
        .width('100%').height('100%')
        .position({ x: 0, y: 0 })
        .backgroundColor('#80000000')
      }

      // ── 活动类型修改确认 ──
      if (this.showTypeConfirm) {
        Column() {
          Column().width('100%').layoutWeight(1)
            .onClick(() => { this.showTypeConfirm = false; })
          Column() {
            Text('确认修改活动类型？').fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor(getTheme(this.themeMode).textPrimary).margin({ bottom: 16 })
            Row() {
              Text('从').fontSize(13).fontColor(getTheme(this.themeMode).textSecondary)
              Text(ACTIVITY_LABELS[this.displayActivityTag] || this.displayActivityTag).fontSize(15).fontWeight(FontWeight.Medium)
                .fontColor(getTheme(this.themeMode).textPrimary).margin({ left: 6, right: 6 })
              Text('→').fontSize(13).fontColor(getTheme(this.themeMode).textSecondary).margin({ right: 6 })
              Text(this.pendingTypeLabel).fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor(getTheme(this.themeMode).primary)
            }.margin({ bottom: 20 })
            Row() {
              Button('返回重选').fontSize(14).fontColor(getTheme(this.themeMode).textSecondary)
                .backgroundColor(getTheme(this.themeMode).surfaceSecondary).borderRadius(8).height(40).layoutWeight(1)
                .onClick(() => { this.showTypeConfirm = false; })
              Blank().width(12)
              Button('确认修改').fontSize(14).fontColor('#FFFFFF')
                .backgroundColor(getTheme(this.themeMode).primary).borderRadius(8).height(40).layoutWeight(1)
                .onClick(() => {
                  this.showTypeConfirm = false;
                  this.doCalibrateType(this.pendingType);
                })
            }.width('100%')
          }
          .width('100%').backgroundColor(getTheme(this.themeMode).surface)
          .borderRadius({ topLeft: 16, topRight: 16 })
          .padding(20).shadow({ radius: 12, color: '#30000000', offsetY: -4 })
        }
        .width('100%').height('100%')
        .position({ x: 0, y: 0 }).backgroundColor('#80000000')
      }

      // ── 地点名称修改弹窗 ──
      if (this.showRenameInput) {
        Column() {
          Column().width('100%').layoutWeight(1)
            .onClick(() => { this.showRenameInput = false; })
          Column() {
            Text('修改地点名称').fontSize(16).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
              .width('100%').textAlign(TextAlign.Center).padding({ top: 16, bottom: 12 })
            TextInput({ placeholder: '输入新名称', text: this.editPoiName })
              .fontSize(14).placeholderColor(getTheme(this.themeMode).textTertiary).height(44).width('100%')
              .backgroundColor(getTheme(this.themeMode).pageBg).borderRadius(8)
              .onChange((value: string) => { this.editPoiName = value; })
            Row() {
              Button('取消').fontSize(14).fontColor(getTheme(this.themeMode).textSecondary)
                .backgroundColor('#F0F0F0').borderRadius(8).height(40).layoutWeight(1)
                .margin({ right: 8 })
                .onClick(() => { this.showRenameInput = false; })
              Button('确定').fontSize(14).fontColor('#FFFFFF')
                .backgroundColor(getTheme(this.themeMode).primary).borderRadius(8).height(40).layoutWeight(1)
                .margin({ left: 8 })
                .onClick(() => {
                  this.showRenameInput = false;
                  this.doCalibratePoiName();
                })
            }
            .width('100%').margin({ top: 12 })
          }
          .width('100%').backgroundColor(getTheme(this.themeMode).surface)
          .borderRadius({ topLeft: 16, topRight: 16 })
          .padding({ left: 24, right: 24, bottom: 32 })
          .shadow({ radius: 12, color: '#30000000', offsetY: -4 })
        }
        .width('100%').height('100%')
        .position({ x: 0, y: 0 })
        .backgroundColor('#80000000')
      }

      // ── 删除确认弹窗 ──
      if (this.showDeleteConfirm) {
        Column() {
          Column().width('100%').layoutWeight(1)
            .onClick(() => { this.showDeleteConfirm = false; })
          Column() {
            Text('⚠️ 确认删除').fontSize(16).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
              .width('100%').textAlign(TextAlign.Center).padding({ top: 20, bottom: 8 })
            Text('删除后该活动段将从时间线和地图中移除。\nAI 重新分类时也不会再出现。')
              .fontSize(13).fontColor(getTheme(this.themeMode).textSecondary).textAlign(TextAlign.Center)
              .padding({ left: 16, right: 16 }).margin({ bottom: 12 })
            Row() {
              Button('取消').fontSize(14).fontColor(getTheme(this.themeMode).textSecondary)
                .backgroundColor('#F0F0F0').borderRadius(8).height(40).layoutWeight(1)
                .margin({ right: 8 })
                .onClick(() => { this.showDeleteConfirm = false; })
              Button('确认删除').fontSize(14).fontColor('#FFFFFF')
                .backgroundColor('#EF4444').borderRadius(8).height(40).layoutWeight(1)
                .margin({ left: 8 })
                .onClick(() => {
                  this.showDeleteConfirm = false;
                  this.doDeleteSegment();
                })
            }
            .width('100%')
          }
          .width('100%').backgroundColor(getTheme(this.themeMode).surface)
          .borderRadius({ topLeft: 16, topRight: 16 })
          .padding({ left: 24, right: 24, bottom: 32 })
          .shadow({ radius: 12, color: '#30000000', offsetY: -4 })
        }
        .width('100%').height('100%')
        .position({ x: 0, y: 0 })
        .backgroundColor('#80000000')
      }

    }
    .width('100%').height('100%')
  }

  getTypeOptions(): TypeOption[] {
    return [
      { type: 'dining', label: '餐饮', icon: '🍽️' },
      { type: 'shopping', label: '购物', icon: '🛍️' },
      { type: 'sports', label: '运动', icon: '🏃' },
      { type: 'work', label: '工作', icon: '💼' },
      { type: 'home', label: '居家', icon: '🏠' },
      { type: 'commute', label: '通勤', icon: '🚇' },
      { type: 'leisure', label: '休闲', icon: '🎠' },
      { type: 'travel', label: '出行', icon: '✈️' },
    ];
  }

  @Builder
  CalActionBtn(text: string, color: string, bg: string, action: () => void) {
    Button() { Text(text).fontSize(13).fontColor(color) }
      .backgroundColor(bg).borderRadius(8).height(40).width('100%')
      .margin({ top: 8 })
      .onClick(action)
  }

  @Builder
  InfoItem(label: string, value: string) {
    Column() {
      Text(label).fontSize(11).fontColor(getTheme(this.themeMode).textSecondary)
      Text(value).fontSize(14).fontColor(getTheme(this.themeMode).textPrimary).fontWeight(FontWeight.Medium).margin({ top: 2 })
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }
}

interface TypeOption {
  type: string;
  label: string;
  icon: string;
}
