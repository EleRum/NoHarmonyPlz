/**
 * GPS & 网络检测提醒弹窗
 * 使用标准 @CustomDialog 模式，检测到服务未开启时引导用户前往系统设置
 */
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';
import { getTheme, FONT, RADIUS, SPACE } from './Theme';

const TAG = 'GpsNetworkDialog';

@CustomDialog
export struct GpsNetworkDialog {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
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
          .fontSize(FONT.title)
          .margin({ right: SPACE.sm })
        Text('服务检查')
          .fontSize(FONT.heading)
          .fontWeight(FontWeight.Bold)
          .fontColor(getTheme(this.themeMode).textPrimary)
      }
      .width('100%')
      .margin({ bottom: SPACE.xl })

      // ── 状态列表 ──
      Column() {
        this.StatusRow(
          '📍',
          'GPS 定位',
          this.locationEnabled ? '已开启' : '未开启',
          this.locationEnabled ? getTheme(this.themeMode).success : getTheme(this.themeMode).danger
        )

        Divider()
          .strokeWidth(0.5)
          .color(getTheme(this.themeMode).divider)
          .margin({ top: SPACE.md, bottom: SPACE.md })

        this.StatusRow(
          '🌐',
          '网络连接',
          this.networkConnected ? '已连接' : '未连接',
          this.networkConnected ? getTheme(this.themeMode).success : getTheme(this.themeMode).danger
        )
      }
      .width('100%')
      .padding(SPACE.lg)
      .backgroundColor(getTheme(this.themeMode).surfaceSecondary)
      .borderRadius(RADIUS.md)
      .margin({ bottom: SPACE.lg })

      // ── 提示文字 ──
      Text(this.getSubtitle())
        .fontSize(FONT.caption)
        .fontColor(getTheme(this.themeMode).textSecondary)
        .lineHeight(20)
        .width('100%')
        .margin({ bottom: SPACE.xl })

      // ── 按钮区 ──
      Row() {
        Button('稍后再说')
          .fontSize(FONT.body)
          .fontColor(getTheme(this.themeMode).textSecondary)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .height(42)
          .borderRadius(RADIUS.pill)
          .border({ width: 1, color: getTheme(this.themeMode).border })
          .onClick(() => {
            this.controller.close();
          })

        Blank().width(SPACE.md)

        Button('前往设置')
          .fontSize(FONT.body)
          .fontColor('#FFFFFF')
          .backgroundColor(getTheme(this.themeMode).primary)
          .layoutWeight(1)
          .height(42)
          .borderRadius(RADIUS.pill)
          .onClick(() => {
            this.openSystemSettings();
          })
      }
      .width('100%')
    }
    .padding({ top: SPACE.xxl, left: SPACE.xl, right: SPACE.xl, bottom: SPACE.xl })
    .borderRadius(RADIUS.lg)
    .backgroundColor(getTheme(this.themeMode).surface)
    .width('85%')
  }

  /**
   * 单条服务状态行
   */
  @Builder
  StatusRow(icon: string, label: string, stateText: string, stateColor: string) {
    Row() {
      Text(icon)
        .fontSize(FONT.title)
        .margin({ right: SPACE.sm })

      Text(label)
        .fontSize(FONT.subheading)
        .fontColor(getTheme(this.themeMode).textPrimary)
        .fontWeight(FontWeight.Medium)
        .layoutWeight(1)

      Text(stateText)
        .fontSize(FONT.body)
        .fontColor(stateColor)
        .fontWeight(FontWeight.Medium)

      Circle({ width: 8, height: 8 })
        .fill(stateColor)
        .margin({ left: SPACE.xs })
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
