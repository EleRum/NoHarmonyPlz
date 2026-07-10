/**
 * 用户基础信息编辑页面
 * 设置用户名、年龄、城市、性别、旅行偏好
 */
import { Logger } from '../common/Logger';
import router from '@ohos.router';
import { geoLocationManager } from '@kit.LocationKit';
import { Dao } from '../database/Dao';
import { UserBasicInfo } from '../model/UserBasicInfo';
import { TRAVEL_PREFERENCE_OPTIONS, ProfileRefreshSignal } from '../common/TravelPreferenceTags';

const TAG = 'UserProfilePage';

@Entry
@Component
export struct UserProfilePage {
  @State username: string = '';
  @State age: string = '';
  @State city: string = '';
  @State gender: string = '';
  @State selectedPreferences: string[] = [];
  @State isSaving: boolean = false;
  @State toastMsg: string = '';
  @State toastVisible: boolean = false;
  @State isLocating: boolean = false;
  /** 是否为首次引导模式（仅用户名必填） */
  private isOnboarding: boolean = false;

  private dao: Dao = Dao.getInstance();
  private existingInfo: UserBasicInfo | null = null;

  aboutToAppear(): void {
    Logger.info(TAG, 'UserProfilePage aboutToAppear');
    // 读取路由参数，判断是否为引导模式
    try {
      const params: Record<string, Object> = router.getParams() as Record<string, Object>;
      if (params && params['isOnboarding'] === true) {
        this.isOnboarding = true;
      }
    } catch (e) {
      // ignore
    }
    this.loadExisting();
  }

  async loadExisting(): Promise<void> {
    try {
      this.existingInfo = await this.dao.queryUserBasicInfo();
      if (this.existingInfo) {
        this.username = this.existingInfo.username;
        this.age = this.existingInfo.age > 0 ? this.existingInfo.age.toString() : '';
        this.city = this.existingInfo.city;
        this.gender = this.existingInfo.gender;
        this.selectedPreferences = this.existingInfo.getPreferenceTags();
        Logger.info(TAG, 'Loaded existing profile: %{public}s', this.username);
      }
    } catch (e) {
      Logger.error(TAG, 'Failed to load profile: %{public}s', JSON.stringify(e));
    }
  }

  private showToast(msg: string): void {
    this.toastMsg = msg;
    this.toastVisible = true;
    setTimeout(() => { this.toastVisible = false; }, 2000);
  }

  /** 自动获取当前位置的城市名 */
  async autoLocateCity(): Promise<void> {
    this.isLocating = true;
    try {
      const last: geoLocationManager.Location | undefined = geoLocationManager.getLastLocation();
      if (last && last.latitude && last.longitude) {
        const request: geoLocationManager.ReverseGeoCodeRequest = {
          latitude: last.latitude,
          longitude: last.longitude,
          maxItems: 1
        };
        const addresses = await geoLocationManager.getAddressesFromLocation(request);
        if (addresses && addresses.length > 0) {
          const addr = addresses[0];
          this.city = addr.locality ?? addr.administrativeArea ?? '';
          if (this.city.length > 0) {
            this.showToast('已自动获取城市');
          }
        }
      }
      if (!this.city) {
        this.showToast('无法获取城市，请手动输入');
      }
    } catch (e) {
      Logger.error(TAG, 'Auto locate failed: %{public}s', JSON.stringify(e));
      this.showToast('定位失败，请手动输入');
    } finally {
      this.isLocating = false;
    }
  }

  /** 切换性别选择 */
  selectGender(g: string): void {
    this.gender = this.gender === g ? '' : g;
  }

  /** 切换旅行偏好标签 */
  togglePreference(tag: string): void {
    const idx: number = this.selectedPreferences.indexOf(tag);
    if (idx >= 0) {
      this.selectedPreferences.splice(idx, 1);
    } else {
      this.selectedPreferences.push(tag);
    }
  }

  /** 是否选择了某个偏好 */
  isPreferenceSelected(tag: string): boolean {
    return this.selectedPreferences.indexOf(tag) >= 0;
  }

  async saveProfile(): Promise<void> {
    // 引导模式下只需用户名，正常模式需用户名或城市
    if (this.isOnboarding && this.username.trim().length === 0) {
      this.showToast('请输入你的昵称');
      return;
    }
    if (!this.isOnboarding && this.username.trim().length === 0 && this.city.trim().length === 0) {
      this.showToast('请至少填写用户名或城市');
      return;
    }

    this.isSaving = true;
    try {
      const info: UserBasicInfo = this.existingInfo ?? new UserBasicInfo();
      info.username = this.username.trim();
      info.age = parseInt(this.age) || 0;
      info.city = this.city.trim();
      info.gender = this.gender;
      info.setPreferenceTags(this.selectedPreferences);

      await this.dao.upsertUserBasicInfo(info);
      Logger.info(TAG, 'Profile saved: %{public}s', info.username);
      ProfileRefreshSignal.fire(); // 通知 SettingsPage 刷新

      if (this.isOnboarding) {
        // 引导模式 → 直接进入主页面
        this.showToast('欢迎加入！🎉');
        setTimeout(() => {
          router.replaceUrl({ url: 'pages/MapPage' });
        }, 800);
      } else {
        this.showToast('保存成功 ✅');
        setTimeout(() => { router.back(); }, 600);
      }
    } catch (e) {
      Logger.error(TAG, 'Failed to save profile: %{public}s', JSON.stringify(e));
      this.showToast('保存失败，请重试');
    } finally {
      this.isSaving = false;
    }
  }

  build() {
    Stack() {
      Column() {
        // ── 标题栏 ──
        Row() {
          if (this.isOnboarding) {
            // 引导模式：无返回按钮
            Text('')
              .fontSize(14).width(50)
          } else {
            Text('← 返回')
              .fontSize(14)
              .fontColor('#3B82F6')
              .onClick(() => { router.back(); })
          }

          Blank()

          Text(this.isOnboarding ? '👋 欢迎加入' : '👤 个人资料')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')

          Blank()

          Text(this.isOnboarding ? '' : '     ')
            .fontSize(14)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

        if (this.isOnboarding) {
          Text('只需填写昵称即可开始，其他信息可稍后补充')
            .fontSize(12).fontColor('#AAA')
            .width('100%').padding({ left: 20, right: 20, top: 8, bottom: 4 })
        }

        Divider().color('#F0F0F0')

        Scroll() {
          Column() {
            // ── 基本信息 ──
            this.SectionTitle('📋 基本信息')

            // 用户名（引导模式下必填）
            Row() {
              Text('用户名')
                .fontSize(13).fontColor('#888')
              if (this.isOnboarding) {
                Text(' *')
                  .fontSize(13).fontColor('#EF4444')
              }
            }
            .margin({ top: 12, bottom: 6 })
            .width('100%')
            TextInput({ placeholder: '请输入你的昵称', text: this.username })
              .fontSize(14).width('100%').height(44)
              .backgroundColor('#F8F9FA').borderRadius(8)
              .padding({ left: 12, right: 12 })
              .onChange((v: string) => { this.username = v; })

            this.FieldSpacer()

            // 年龄
            this.FieldLabel('年龄')
            TextInput({ placeholder: '请输入年龄', text: this.age })
              .type(InputType.Number)
              .fontSize(14).width('100%').height(44)
              .backgroundColor('#F8F9FA').borderRadius(8)
              .padding({ left: 12, right: 12 })
              .onChange((v: string) => { this.age = v; })

            this.FieldSpacer()

            // 居住城市（带自动定位）
            this.FieldLabel('居住城市')
            Row() {
              TextInput({ placeholder: '请输入城市名', text: this.city })
                .fontSize(14).height(44).layoutWeight(1)
                .backgroundColor('#F8F9FA').borderRadius(8)
                .padding({ left: 12, right: 12 })
                .onChange((v: string) => { this.city = v; })
              Text(this.isLocating ? '⏳' : '📍')
                .fontSize(18)
                .margin({ left: 8 })
                .onClick(() => { this.autoLocateCity(); })
            }
            .width('100%')

            this.FieldSpacer()

            // 性别选择
            this.FieldLabel('性别')
            Row() {
              this.GenderChip('男', '👨')
              this.GenderChip('女', '👩')
              this.GenderChip('其他', '🌈')
            }
            .width('100%')

            // ── 旅行偏好 ──
            this.SectionSpacer()
            this.SectionTitle('🏷️ 旅行偏好')
            Text('选择你感兴趣的类型（可多选）')
              .fontSize(12).fontColor('#AAA')
              .margin({ top: 6, bottom: 12 })
              .width('100%')

            // 偏好标签网格（每行 2 个）
            Column() {
              ForEach(TRAVEL_PREFERENCE_OPTIONS, (tag: string, index: number) => {
                if (index % 2 === 0) {
                  Row() {
                    this.PreferenceChip(tag)
                    if (index + 1 < TRAVEL_PREFERENCE_OPTIONS.length) {
                      this.PreferenceChip(TRAVEL_PREFERENCE_OPTIONS[index + 1])
                    }
                  }
                  .width('100%')
                  .margin({ bottom: 8 })
                }
              })
            }
            .width('100%')

            // ── 保存按钮 ──
            this.SectionSpacer()
            Button(this.isSaving ? '保存中…' : (this.isOnboarding ? '🚀 开始使用' : '💾 保存'))
              .fontSize(15).fontColor('#FFFFFF')
              .backgroundColor(this.isSaving ? '#93C5FD' : '#3B82F6')
              .borderRadius(12).height(46).width('100%')
              .enabled(!this.isSaving)
              .onClick(() => { this.saveProfile(); })

            // 底部留白
            Row().width('100%').height(40)
          }
          .width('100%').padding({ left: 20, right: 20 })
        }
        .layoutWeight(1).scrollBar(BarState.Off)
      }
      .width('100%').height('100%').backgroundColor('#F5F6F8')

      // Toast
      if (this.toastVisible) {
        Text(this.toastMsg)
          .fontSize(13).fontColor('#FFFFFF')
          .backgroundColor('#333333CC')
          .borderRadius(20)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .position({ bottom: 80 })
          .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor('#1A1A1A')
      .width('100%')
      .margin({ top: 16 })
  }

  @Builder
  SectionSpacer() {
    Row().width('100%').height(20)
  }

  @Builder
  FieldLabel(label: string) {
    Text(label)
      .fontSize(13).fontColor('#888')
      .margin({ top: 12, bottom: 6 })
      .width('100%')
  }

  @Builder
  FieldSpacer() {
    Row().width('100%').height(8)
  }

  @Builder
  GenderChip(label: string, emoji: string) {
    Column() {
      Text(emoji).fontSize(18)
      Text(label).fontSize(12)
        .fontColor(this.gender === label ? '#FFFFFF' : '#888')
        .margin({ top: 2 })
    }
    .width('30%').height(52).borderRadius(10)
    .backgroundColor(this.gender === label ? '#3B82F6' : '#F0F1F3')
    .justifyContent(FlexAlign.Center)
    .margin({ right: 8 })
    .onClick(() => { this.selectGender(label); })
  }

  @Builder
  PreferenceChip(tag: string) {
    Row() {
      Text(tag)
        .fontSize(13)
        .fontColor(this.isPreferenceSelected(tag) ? '#FFFFFF' : '#666')
        .fontWeight(this.isPreferenceSelected(tag) ? FontWeight.Medium : FontWeight.Normal)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    }
    .borderRadius(20)
    .backgroundColor(this.isPreferenceSelected(tag) ? '#3B82F6' : '#F0F1F3')
    .margin({ right: 8 })
    .layoutWeight(1)
    .onClick(() => { this.togglePreference(tag); })
  }
}
