/**
 * 首次启动欢迎页
 * 引导用户进入个人资料填写流程
 */
import router from '@ohos.router';
import { Logger } from '../common/Logger';
import { getTheme, FONT, RADIUS, SPACE } from '../common/Theme';

const TAG = 'WelcomePage';

@Entry
@Component
export struct WelcomePage {
  @StorageLink('theme_is_dark') themeMode: string = 'light';

  aboutToAppear(): void {
    Logger.info(TAG, 'WelcomePage aboutToAppear');
  }

  goToProfile(): void {
    router.replaceUrl({
      url: 'pages/UserProfilePage',
      params: { isOnboarding: true }
    }).catch((err: Error) => {
      Logger.error(TAG, 'Failed to navigate: %{public}s', err.message);
    });
  }

  build() {
    Column() {
      // 上方留白
      Blank()

      // 中央内容
      Column() {
        // Logo
        Text('🗺️')
          .fontSize(72)

        Text('足迹地图')
          .fontSize(FONT.hero)
          .fontWeight(FontWeight.Bold)
          .fontColor(getTheme(this.themeMode).textPrimary)
          .margin({ top: SPACE.lg })

        Text('记录每一天的足迹，发现生活轨迹')
          .fontSize(FONT.subheading)
          .fontColor(getTheme(this.themeMode).textSecondary)
          .margin({ top: SPACE.sm })

        Divider()
          .width(40)
          .height(2)
          .color(getTheme(this.themeMode).primary)
          .margin({ top: SPACE.xxl, bottom: SPACE.xxl })

        // 功能简介
        Column() {
          this.FeatureRow('📍', '自动记录出行轨迹与活动类型')
          this.FeatureRow('🤖', 'AI 助手帮你修正分类、推荐周边')
          this.FeatureRow('📊', '行程报告，看见生活的样子')
          this.FeatureRow('🧭', '智能旅游规划，说走就走')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: SPACE.xl, right: SPACE.xl })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      // 下方按钮区
      Column() {
        Button('开始使用')
          .fontSize(17)
          .fontColor('#FFFFFF')
          .backgroundColor(getTheme(this.themeMode).primary)
          .borderRadius(RADIUS.pill)
          .height(50)
          .width('80%')
          .shadow({ radius: 8, color: getTheme(this.themeMode).primary + '40', offsetY: 4 })
          .onClick(() => { this.goToProfile(); })

        Text('首次使用需填写基本信息')
          .fontSize(FONT.label)
          .fontColor(getTheme(this.themeMode).textTertiary)
          .margin({ top: SPACE.md, bottom: SPACE.xxxl })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(getTheme(this.themeMode).surface)
  }

  @Builder
  FeatureRow(emoji: string, text: string) {
    Row() {
      Text(emoji)
        .fontSize(20)
        .width(32)
      Text(text)
        .fontSize(FONT.body)
        .fontColor(getTheme(this.themeMode).textPrimary)
        .margin({ left: SPACE.sm })
    }
    .width('100%')
    .margin({ top: SPACE.sm, bottom: SPACE.sm })
  }
}
