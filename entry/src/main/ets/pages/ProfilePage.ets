/**
 * 我的页 — 个人资料 + 设置 合并
 */
import { Logger } from '../common/Logger';
import router from '@ohos.router';
import { getTheme, isDarkTheme, toggleTheme, FONT, RADIUS, SPACE } from '../common/Theme';
import { Dao } from '../database/Dao';
import { UserBasicInfo } from '../model/UserBasicInfo';
import { SettingsContent } from './SettingsPage';
import { ProfileRefreshSignal } from '../common/TravelPreferenceTags';

const TAG = 'ProfilePage';

@Component
export struct ProfileContent {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  @State profileName: string = '';
  @State profileSummary: string = '';
  @State profileRefreshKey: number = 0;
  private dao: Dao = Dao.getInstance();
  private lastRefreshCounter: number = 0;

  private pollTimer: number | null = null;

  aboutToAppear(): void {
    this.loadProfile();
    // 轮询刷新信号（用户从资料页返回时刷新）
    this.pollTimer = setInterval(() => {
      if (ProfileRefreshSignal.counter !== this.lastRefreshCounter) {
        this.lastRefreshCounter = ProfileRefreshSignal.counter;
        this.loadProfile();
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }

  async loadProfile(): Promise<void> {
    try {
      const info: UserBasicInfo | null = await this.dao.queryUserBasicInfo();
      if (info && info.hasBasicInfo()) {
        this.profileName = info.username || '未命名';
        const parts: string[] = [];
        if (info.age > 0) parts.push(`${info.age}岁`);
        if (info.city.length > 0) parts.push(info.city);
        this.profileSummary = parts.join(' · ');
      } else {
        this.profileName = '';
        this.profileSummary = '';
      }
    } catch (e) {
      // ignore
    }
  }

  editProfile(): void {
    router.pushUrl({
      url: 'pages/UserProfilePage'
    }).catch((err: Error) => {
      Logger.error(TAG, 'Failed to navigate: %{public}s', err.message);
    });
  }

  build() {
    Column() {
      // 个人资料卡片（紧凑）
      Row() {
        Column() {
          Text(this.profileName ? this.profileName.charAt(0).toUpperCase() : '👤')
            .fontSize(18)
            .fontColor('#FFFFFF')
        }
        .width(40).height(40)
        .borderRadius(20)
        .backgroundColor(getTheme().primary)
        .justifyContent(FlexAlign.Center)
        .margin({ right: SPACE.md })

        Column() {
          if (this.profileName) {
            Text(this.profileName)
              .fontSize(FONT.subheading)
              .fontWeight(FontWeight.Medium)
              .fontColor(getTheme().textPrimary)
            if (this.profileSummary) {
              Text(this.profileSummary)
                .fontSize(FONT.caption)
                .fontColor(getTheme().textSecondary)
            }
          } else {
            Text('未设置个人资料')
              .fontSize(FONT.body)
              .fontColor(getTheme().textSecondary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('编辑 ›')
          .fontSize(FONT.caption)
          .fontColor(getTheme().primary)
          .onClick(() => { this.editProfile(); })
      }
      .width('100%')
      .padding({ left: SPACE.lg, right: SPACE.lg, top: SPACE.md, bottom: SPACE.md })
      .backgroundColor(getTheme().surface)

      // 深色模式开关 + 推荐开关
      Row() {
        Text(isDarkTheme() ? '🌙 深色模式' : '☀️ 浅色模式')
          .fontSize(FONT.caption)
          .fontColor(getTheme().textSecondary)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: isDarkTheme() })
          .onChange((isOn: boolean) => { toggleTheme(); })
          .height(28)
      }
      .width('100%')
      .padding({ left: SPACE.lg, right: SPACE.lg, top: SPACE.sm, bottom: SPACE.sm })
      .backgroundColor(getTheme().surface)

      Divider().color(getTheme().divider).height(0.5)
        .margin({ left: SPACE.lg, right: SPACE.lg })

      // 设置内容（占据剩余空间，自带 Scroll）
      SettingsContent({ profileRefreshKey: this.profileRefreshKey })
        .layoutWeight(1)
    }
    .width('100%').height('100%')
    .backgroundColor(getTheme().pageBg)
  }
}
