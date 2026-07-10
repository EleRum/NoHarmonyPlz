/**
 * GPS & 网络检测提醒弹窗
 * 使用标准 @CustomDialog 模式，检测到服务未开启时引导用户前往系统设置
 */
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const TAG = 'GpsNetworkDialog';

@CustomDialog
export struct GpsNetworkDialog {
  /** CustomDialog 控制器（由框架注入） */
  controller: CustomDialogController;
  /** GPS 定位是否开启 */
  locationEnabled: boolean = true;
  /** 网络是否已连接 */
  networkConnected: boolean = true;
  /** 页面上下文（用于跳转系统设置） */
  context?: common.UIAbilityContext;

  /**
   * 根据未开启的服务类型，跳转到对应的系统设置页面
   */
  private openSystemSettings(): void {
    if (!this.context) {
      Logger.warn(TAG, 'Context not available, cannot open settings');
      this.controller.close();
      return;
    }

    try {
      let wantAction: string;

      if (!this.locationEnabled && this.networkConnected) {
        // 仅 GPS 未开启 → 跳转位置设置
        wantAction = 'ohos.settings.action.LOCATION_SOURCE_SETTINGS';
        Logger.info(TAG, 'Opening location settings');
      } else {
        // 网络未开启（或两者都未开启）→ 跳转无线网络设置
        wantAction = 'ohos.settings.action.WIRELESS_SETTINGS';
        Logger.info(TAG, 'Opening wireless settings');
      }

      this.context.startAbility({
        action: wantAction
      }).then(() => {
        Logger.info(TAG, 'Settings opened successfully');
      }).catch((err: Error) => {
        Logger.error(TAG, 'Failed to open settings: %{public}s', err.message);
      });
    } catch (e) {
      Logger.error(TAG, 'Error opening settings: %{public}s', JSON.stringify(e));
    }

    this.controller.close();
  }

  build() {
    Column() {
      // ── 标题区 ──
      Row() {
        Text('⚠️')
          .fontSize(24)
          .margin({ right: 8 })
        Text('服务检查')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
      }
      .width('100%')
      .margin({ bottom: 20 })

      // ── 状态列表 ──
      Column() {
        // GPS 状态行
        this.StatusRow(
          '📍',
          'GPS 定位',
          this.locationEnabled ? '已开启' : '未开启',
          this.locationEnabled ? '#10B981' : '#EF4444'
        )

        Divider()
          .strokeWidth(0.5)
          .color('#F0F0F0')
          .margin({ top: 12, bottom: 12 })

        // 网络状态行
        this.StatusRow(
          '🌐',
          '网络连接',
          this.networkConnected ? '已连接' : '未连接',
          this.networkConnected ? '#10B981' : '#EF4444'
        )
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#F9FAFB')
      .borderRadius(12)
      .margin({ bottom: 16 })

      // ── 提示文字 ──
      Text(this.getSubtitle())
        .fontSize(13)
        .fontColor('#666666')
        .lineHeight(20)
        .width('100%')
        .margin({ bottom: 20 })

      // ── 按钮区 ──
      Row() {
        // 稍后再说
        Button('稍后再说')
          .fontSize(14)
          .fontColor('#999999')
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .height(42)
          .borderRadius(21)
          .border({ width: 1, color: '#E0E0E0' })
          .onClick(() => {
            this.controller.close();
          })

        Blank().width(12)

        // 前往设置
        Button('前往设置')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#3B82F6')
          .layoutWeight(1)
          .height(42)
          .borderRadius(21)
          .onClick(() => {
            this.openSystemSettings();
          })
      }
      .width('100%')
    }
    .padding({ top: 24, left: 20, right: 20, bottom: 20 })
    .borderRadius(16)
    .backgroundColor('#FFFFFF')
    .width('85%')
  }

  /**
   * 单条服务状态行
   */
  @Builder
  StatusRow(icon: string, label: string, stateText: string, stateColor: string) {
    Row() {
      Text(icon)
        .fontSize(20)
        .margin({ right: 10 })

      Text(label)
        .fontSize(15)
        .fontColor('#333333')
        .fontWeight(FontWeight.Medium)
        .layoutWeight(1)

      Text(stateText)
        .fontSize(14)
        .fontColor(stateColor)
        .fontWeight(FontWeight.Medium)

      // 状态指示圆点
      Circle({ width: 8, height: 8 })
        .fill(stateColor)
        .margin({ left: 6 })
    }
    .width('100%')
    .height(36)
  }

  /**
   * 根据未开启的服务生成提示文字
   */
  private getSubtitle(): string {
    const issues: string[] = [];

    if (!this.locationEnabled) {
      issues.push('GPS 定位');
    }
    if (!this.networkConnected) {
      issues.push('网络连接');
    }

    const prefix: string = issues.join('和');
    return `${prefix}未开启，将影响足迹记录、地图加载和智能推荐功能。请前往系统设置开启相关服务。`;
  }
}
