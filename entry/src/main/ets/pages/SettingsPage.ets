/**
 * 设置页面 — 设置入口（三个子页面通过路由跳转）
 */
import { Logger } from '../common/Logger';
import router from '@ohos.router';
import { ClaudeService } from '../services/ClaudeService';
import { Dao } from '../database/Dao';
import { UserBasicInfo } from '../model/UserBasicInfo';
import { getTheme } from '../common/Theme';
import { ProfileRefreshSignal } from '../common/TravelPreferenceTags';

const TAG = 'SettingsPage';

@Component
export struct SettingsContent {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  onTabChange: (index: number) => void = () => {};
  @Prop @Watch('onProfileRefresh') profileRefreshKey: number = 0;
  @State profileName: string = '';
  @State profileSummary: string = '';

  private dao: Dao = Dao.getInstance();
  private claude: ClaudeService = new ClaudeService();

  aboutToAppear(): void {
    Logger.info(TAG, 'SettingsPage aboutToAppear');
    this.loadProfile();
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
    } catch (e) { Logger.warn(TAG, 'Failed to load profile'); }
  }

  onProfileRefresh(): void { this.loadProfile(); }

  navTo(section: string): void {
    router.pushUrl({ url: 'pages/SettingsDetailPage', params: { section: section } })
      .catch((err: Error) => { Logger.error(TAG, 'navTo failed: %{public}s', err.message); });
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          this.OptionBar('🤖', 'AI 设置', '配置大模型 API Key', () => { this.navTo('ai'); })
          Column() {}.height(8)
          this.OptionBar('🔔', '推荐设置', '后台刷新、地图标记', () => { this.navTo('rec'); })
          Column() {}.height(8)
          this.OptionBar('📱', '关于', '足迹地图 v2.0.3', () => { this.navTo('about'); })
        }
        .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 20 })
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor(getTheme(this.themeMode).pageBg)
  }

  @Builder
  OptionBar(icon: string, title: string, subtitle: string, action: () => void) {
    Row() {
      Text(icon).fontSize(22).margin({ right: 12 })
      Column() {
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
        Text(subtitle).fontSize(12).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(20).fontColor(getTheme(this.themeMode).textTertiary)
    }
    .width('100%').padding(16).backgroundColor(getTheme(this.themeMode).surface).borderRadius(12)
    .shadow({ radius: 2, color: '#08000000', offsetY: 1 })
    .onClick(action)
  }
}
