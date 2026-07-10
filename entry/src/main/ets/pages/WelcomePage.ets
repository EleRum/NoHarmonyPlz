/**
 * 首次启动欢迎页
 * 引导用户进入个人资料填写流程
 */
import router from '@ohos.router';
import { Logger } from '../common/Logger';

const TAG = 'WelcomePage';

@Entry
@Component
export struct WelcomePage {

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
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .margin({ top: 16 })

        Text('记录每一天的足迹，发现生活轨迹')
          .fontSize(15)
          .fontColor('#888')
          .margin({ top: 8 })

        // 分割线
        Divider()
          .width(40)
          .height(2)
          .color('#3B82F6')
          .margin({ top: 24, bottom: 24 })

        // 功能简介
        Column() {
          this.FeatureRow('📍', '自动记录出行轨迹与活动类型')
          this.FeatureRow('🤖', 'AI 助手帮你修正分类、推荐周边')
          this.FeatureRow('📊', '行程报告，看见生活的样子')
          this.FeatureRow('🧭', '智能旅游规划，说走就走')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      // 下方按钮区
      Column() {
        Button('开始使用')
          .fontSize(17)
          .fontColor('#FFFFFF')
          .backgroundColor('#3B82F6')
          .borderRadius(24)
          .height(50)
          .width('80%')
          .shadow({ radius: 8, color: '#403B82F6', offsetY: 4 })
          .onClick(() => { this.goToProfile(); })

        Text('首次使用需填写基本信息')
          .fontSize(11)
          .fontColor('#CCC')
          .margin({ top: 12, bottom: 32 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  FeatureRow(emoji: string, text: string) {
    Row() {
      Text(emoji)
        .fontSize(20)
        .width(32)
      Text(text)
        .fontSize(14)
        .fontColor('#555')
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ top: 10, bottom: 10 })
  }
}
