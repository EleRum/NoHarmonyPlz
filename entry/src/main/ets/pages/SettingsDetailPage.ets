/**
 * 设置子页面 — 根据路由参数展示 AI设置 / 推荐设置 / 关于
 */
import router from '@ohos.router';
import { Logger } from '../common/Logger';
import { getTheme } from '../common/Theme';
import { ClaudeService } from '../services/ClaudeService';
import { Dao } from '../database/Dao';
import { UserBasicInfo } from '../model/UserBasicInfo';
import { MapMarkerSignal } from '../common/TravelPreferenceTags';

const TAG = 'SettingsDetailPage';

type AiProvider = 'claude' | 'deepseek' | 'pangu';

interface ProviderOption {
  key: AiProvider; label: string; desc: string; prefixHint: string;
  defaultEndpoint: string; defaultModel: string;
}

const PROVIDER_OPTIONS: ProviderOption[] = [
  {
    key: 'deepseek', label: 'DeepSeek', desc: '便宜好用', prefixHint: 'sk-xxx…',
    defaultEndpoint: 'https://api.deepseek.com/chat/completions', defaultModel: 'deepseek-chat'
  },
  {
    key: 'claude', label: 'Claude', desc: '更聪明', prefixHint: 'sk-ant-xxx…',
    defaultEndpoint: 'https://api.anthropic.com/v1/messages', defaultModel: 'claude-sonnet-4-6-20250514'
  },
  {
    key: 'pangu', label: '华为盘古', desc: '国产大模型', prefixHint: 'Bearer Token',
    defaultEndpoint: 'https://api.modelarts-maas.com/v2/chat/completions', defaultModel: 'openpangu-2.0-flash'
  },
];

@Entry
@Component
export struct SettingsDetailPage {
  @StorageLink('theme_is_dark') themeMode: string = 'light';
  @State section: string = '';
  @State title: string = '';
  // AI
  @State apiKey: string = '';
  @State hasKey: boolean = false;
  @State providerName: string = '';
  @State selectedProvider: AiProvider = 'deepseek';
  @State customEndpoint: string = '';
  @State customModel: string = '';
  @State showKey: boolean = false;
  @State isSaving: boolean = false;
  // Rec
  @State recEnabled: boolean = true;
  @State showMapMarkers: boolean = true;
  // Toast
  @State toastMsg: string = '';
  @State toastVisible: boolean = false;

  private claude: ClaudeService = new ClaudeService();
  private dao: Dao = Dao.getInstance();

  aboutToAppear(): void {
    try {
      const p = router.getParams() as Record<string, Object>;
      if (p) {
        this.section = (p['section'] as string) || 'ai';
      }
    } catch (e) { /* ignore */ }

    if (this.section === 'ai') {
      this.title = 'AI 设置';
      this.loadKey();
    } else if (this.section === 'rec') {
      this.title = '推荐设置';
      this.loadRecSetting();
    } else {
      this.title = '关于';
    }
  }

  async loadKey(): Promise<void> {
    await this.claude.loadApiKey();
    this.hasKey = this.claude.hasKey;
    this.providerName = this.claude.providerName;
    const p = this.claude.providerType;
    if (p === 'claude' || p === 'deepseek' || p === 'pangu') this.selectedProvider = p;
    if (this.hasKey) this.apiKey = '••••••••••••••••••••';
    this.refreshProviderFields();
  }

  refreshProviderFields(): void {
    const ep = this.claude.getEndpoint(this.selectedProvider);
    const m = this.claude.getModel(this.selectedProvider);
    const def = PROVIDER_OPTIONS.find(o => o.key === this.selectedProvider)!;
    this.customEndpoint = (ep !== def.defaultEndpoint) ? ep : '';
    this.customModel = (m !== def.defaultModel) ? m : '';
  }

  getDefault(): ProviderOption {
    return PROVIDER_OPTIONS.find(o => o.key === this.selectedProvider)!;
  }

  onChangeProvider(provider: AiProvider): void {
    this.selectedProvider = provider;
    this.refreshProviderFields();
  }

  showToast(msg: string): void {
    this.toastMsg = msg; this.toastVisible = true;
    setTimeout(() => { this.toastVisible = false; }, 2200);
  }

  async saveKey(): Promise<void> {
    const raw = this.apiKey.trim();
    if (raw.length === 0 || raw.startsWith('••••')) { this.showToast(raw.startsWith('••••') ? '密钥未修改' : '请输入密钥'); return; }
    const detected = ClaudeService.detectProvider(raw);
    let provider: AiProvider;
    if (detected !== 'none') { provider = detected as AiProvider; this.selectedProvider = provider; }
    else { provider = this.selectedProvider; }
    this.isSaving = true;
    try {
      await this.claude.setApiKey(raw, provider);
      const ep = this.customEndpoint.trim();
      const m = this.customModel.trim();
      await this.claude.setProviderConfig(provider, ep.length > 0 ? ep : this.getDefault().defaultEndpoint, m.length > 0 ? m : this.getDefault().defaultModel);
      this.hasKey = true; this.providerName = this.claude.providerName; this.showKey = false;
      this.showToast('密钥已保存 ✅');
    } catch (e) { this.showToast('保存失败，请重试'); }
    finally { this.isSaving = false; }
  }

  async clearKey(): Promise<void> {
    await this.claude.setApiKey(''); this.apiKey = ''; this.hasKey = false; this.providerName = '';
    this.showToast('密钥已清除');
  }

  async loadRecSetting(): Promise<void> {
    const p1 = await this.dao.queryUserProfile('recommendation_enabled');
    if (p1 && p1.preferenceValue === 'false') this.recEnabled = false;
    const p2 = await this.dao.queryUserProfile('map_markers_enabled');
    if (p2 && p2.preferenceValue === 'false') this.showMapMarkers = false;
  }

  async saveRecSetting(enabled: boolean): Promise<void> {
    this.recEnabled = enabled;
    await this.dao.upsertUserProfile('recommendation_enabled', enabled ? 'true' : 'false', 1);
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回').fontSize(15).fontColor('#3B82F6')
            .onClick(() => { router.back(); })
          Blank()
          Text(this.title).fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor(getTheme(this.themeMode).textPrimary)
          Blank()
          Text('     ').fontSize(15)
        }
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 12 })
        Divider().color(getTheme(this.themeMode).border)

        Scroll() {
          Column() {
            if (this.section === 'ai') { this.BuildAiContent() }
            else if (this.section === 'rec') { this.BuildRecContent() }
            else { this.BuildAboutContent() }
          }
          .width('100%').padding({ left: 16, right: 16, bottom: 20 })
        }
        .layoutWeight(1).scrollBar(BarState.Off)
      }
      .width('100%').height('100%').backgroundColor(getTheme(this.themeMode).pageBg)

      if (this.toastVisible) {
        Text(this.toastMsg).fontSize(13).fontColor('#FFFFFF').backgroundColor('#333333CC')
          .borderRadius(20).padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .position({ bottom: 80 })
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  BuildAiContent() {
    Column() {
      if (this.hasKey) {
        Row() {
          Text('当前服务:').fontSize(13).fontColor(getTheme(this.themeMode).textSecondary)
          Text(this.providerName).fontSize(13).fontColor('#3B82F6').fontWeight(FontWeight.Medium).margin({ left: 6 })
        }
        .width('100%').margin({ bottom: 12 })
      }
      Text('选择服务商').fontSize(13).fontColor(getTheme(this.themeMode).textSecondary).margin({ bottom: 8 }).width('100%')
      Row() {
        ForEach(PROVIDER_OPTIONS, (opt: ProviderOption) => {
          Column() {
            Text(opt.label).fontSize(13)
              .fontColor(this.selectedProvider === opt.key ? '#FFFFFF' : getTheme(this.themeMode).textPrimary)
              .fontWeight(this.selectedProvider === opt.key ? FontWeight.Medium : FontWeight.Normal)
            Text(opt.desc).fontSize(10)
              .fontColor(this.selectedProvider === opt.key ? '#FFFFFFCC' : getTheme(this.themeMode).textSecondary)
              .margin({ top: 2 })
          }
          .width('31%').height(52).borderRadius(8)
          .backgroundColor(this.selectedProvider === opt.key ? '#3B82F6' : getTheme(this.themeMode).surfaceSecondary)
          .border({ width: 1, color: this.selectedProvider === opt.key ? '#3B82F6' : getTheme(this.themeMode).border })
          .justifyContent(FlexAlign.Center)
          .onClick(() => { this.onChangeProvider(opt.key); })
          .margin({ right: 8 })
        })
      }.width('100%').margin({ bottom: 10 })

      TextInput({ placeholder: '输入密钥 ' + this.getDefault().prefixHint, text: this.apiKey })
        .type(this.showKey ? InputType.Normal : InputType.Password)
        .fontSize(14).fontColor(getTheme(this.themeMode).textPrimary).width('100%').height(44).placeholderColor(getTheme(this.themeMode).textTertiary)
        .backgroundColor(getTheme(this.themeMode).surfaceSecondary).borderRadius(8)
        .padding({ left: 12, right: 36 })
        .onChange((v: string) => { this.apiKey = v; })

      Text('⚡ 自定义端点（可选）')
        .fontSize(12).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 10, bottom: 4 }).width('100%')
      TextInput({ placeholder: this.getDefault().defaultEndpoint, text: this.customEndpoint })
        .fontSize(13).fontColor(getTheme(this.themeMode).textPrimary).width('100%').height(40).placeholderColor(getTheme(this.themeMode).textTertiary)
        .backgroundColor(getTheme(this.themeMode).surfaceSecondary).borderRadius(8)
        .padding({ left: 12, right: 12 }).onChange((v: string) => { this.customEndpoint = v; })

      Text('模型名（可选）').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 6, bottom: 4 }).width('100%')
      TextInput({ placeholder: this.getDefault().defaultModel, text: this.customModel })
        .fontSize(13).fontColor(getTheme(this.themeMode).textPrimary).placeholderColor(getTheme(this.themeMode).textTertiary).width('100%').height(40)
        .backgroundColor(getTheme(this.themeMode).surfaceSecondary).borderRadius(8)
        .padding({ left: 12, right: 12 }).onChange((v: string) => { this.customModel = v; })

      Row() {
        Row() {
          Text(this.showKey ? '🙈' : '👁️').fontSize(14)
          Text(this.showKey ? '隐藏' : '显示').fontSize(12).fontColor(getTheme(this.themeMode).textSecondary).margin({ left: 4 })
        }.onClick(() => { this.showKey = !this.showKey; })
        Blank()
        if (this.hasKey) {
          Button('清除密钥').fontSize(12).fontColor('#EF4444').backgroundColor('#FEF2F2').borderRadius(6).height(32)
            .onClick(() => { this.clearKey(); })
        }
        Button(this.isSaving ? '保存中…' : '保存').fontSize(12).fontColor('#FFFFFF')
          .backgroundColor(this.isSaving ? '#93C5FD' : '#3B82F6').borderRadius(6).height(32)
          .enabled(!this.isSaving).onClick(() => { this.saveKey(); }).margin({ left: 8 })
      }.width('100%').margin({ top: 10 })

      Text('🔑 获取密钥').fontSize(13).fontWeight(FontWeight.Medium).fontColor(getTheme(this.themeMode).textPrimary)
        .margin({ top: 12, bottom: 6 }).width('100%')
      Text('Claude: console.anthropic.com → API Keys').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).margin({ bottom: 2 }).width('100%')
      Text('DeepSeek: platform.deepseek.com → API Keys').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).margin({ bottom: 2 }).width('100%')
      Text('华为盘古: console.huaweicloud.com/modelarts → 应用接入 → API Key').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).margin({ bottom: 6 }).width('100%')
      Text('💡 密钥仅保存在本地数据库，不会上传到任何第三方服务器。')
        .fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).maxLines(3).width('100%')
    }
  }

  @Builder
  BuildRecContent() {
    Column() {
      Row() {
        Column() {
          Text('后台自动刷新').fontSize(14).fontColor(getTheme(this.themeMode).textPrimary)
          Text('每5分钟自动更新推荐').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.recEnabled })
          .onChange((isOn: boolean) => { this.saveRecSetting(isOn); })
      }.width('100%').padding(16).backgroundColor(getTheme(this.themeMode).surface).borderRadius(10).margin({ bottom: 8 })

      Row() {
        Column() {
          Text('地图显示推荐标记').fontSize(14).fontColor(getTheme(this.themeMode).textPrimary)
          Text('在地图上显示推荐地点').fontSize(11).fontColor(getTheme(this.themeMode).textSecondary).margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.showMapMarkers })
          .onChange((isOn: boolean) => {
            this.showMapMarkers = isOn;
            this.dao.upsertUserProfile('map_markers_enabled', isOn ? 'true' : 'false', 1);
            MapMarkerSignal.fire();
          })
      }.width('100%').padding(16).backgroundColor(getTheme(this.themeMode).surface).borderRadius(10)
    }
  }

  @Builder
  BuildAboutContent() {
    Column() {
      this.InfoRow('📍', '记录每一天的足迹，发现生活轨迹')
      this.InfoRow('🗺️', '基于高德地图 JSAPI v2.0')
      this.InfoRow('🧠', 'AI 助手"小足"陪你聊天、推荐周边')
    }
    .width('100%').padding(16).backgroundColor(getTheme(this.themeMode).surface).borderRadius(12)
  }

  @Builder
  InfoRow(icon: string, text: string) {
    Row() {
      Text(icon).fontSize(14)
      Text(text).fontSize(12).fontColor(getTheme(this.themeMode).textSecondary).margin({ left: 6 })
    }.margin({ top: 6 })
  }
}
