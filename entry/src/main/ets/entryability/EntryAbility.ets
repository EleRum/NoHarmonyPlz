/**
 * 足迹地图应用入口（跨平台版本）
 * 初始化平台桥接、数据库、定位、生命周期管理
 * 地图通过 WebView + 高德 JSAPI v2.0 渲染（不再依赖 Amap 原生 SDK）
 */
import { AbilityConstant, ConfigurationConstant, UIAbility, Want, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { PlatformBridge } from '../platform/PlatformBridge';
import { DatabaseHelper } from '../database/DatabaseHelper';
import { Dao } from '../database/Dao';
import { LocationService } from '../services/LocationService';
import { PhotoService } from '../services/PhotoService';
import { AgentScheduler } from '../services/AgentScheduler';
import { MockDataService } from '../services/MockDataService';
import { APP_TAG } from '../common/Constants';
import { Logger } from '../common/Logger';

export default class EntryAbility extends UIAbility {
  private dbHelper: DatabaseHelper = DatabaseHelper.getInstance();
  private locationService: LocationService = LocationService.getInstance();
  private photoService: PhotoService = PhotoService.getInstance();
  private scheduler: AgentScheduler = AgentScheduler.getInstance();
  private dbInitPromise: Promise<void> | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(APP_TAG, 'EntryAbility onCreate');

    try {
      this.context.getApplicationContext().setColorMode(
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
      );
    } catch (err) {
      Logger.error(APP_TAG,
        'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    // ═════════════ ① 初始化平台桥接 + DB + mock 数据 ═════════════
    this.dbInitPromise = PlatformBridge.getInstance().initialize(this.context).then(async (): Promise<void> => {
      Logger.info(APP_TAG, 'PlatformBridge initialized');
      await this.dbHelper.initialize();
      Logger.info(APP_TAG, 'Database initialized');
      await MockDataService.injectIfEmpty(Dao.getInstance());
      Logger.info(APP_TAG, 'Mock data injected — MapPage can now load');
    });

    // ═════════════ ③ 后台服务 ═════════════
    this.dbInitPromise.then(async (): Promise<void> => {
      // 扫描照片
      this.photoService.scanPhotos().then((count: number) => {
        Logger.info(APP_TAG, 'Photo scan added %{public}d photo footprints', count);
      });

      // 启动推荐引擎（初始位置 fallback 到成都）
      let startLat: number = 30.5723;
      let startLng: number = 104.0665;
      this.scheduler.start(startLat, startLng);
      Logger.info(APP_TAG, 'AI Agent scheduler started');

      // 启动后台定位
      this.locationService.startTracking();
      Logger.info(APP_TAG, 'Location service started');
    });
  }

  onDestroy(): void {
    Logger.info(APP_TAG, 'EntryAbility onDestroy');
    this.scheduler.stop();
    this.locationService.stopTracking();
    this.dbHelper.close();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info(APP_TAG, 'EntryAbility onWindowStageCreate');

    // 运行时申请定位权限
    const atManager = abilityAccessCtrl.createAtManager();
    const locPermissions: Array<Permissions> = [
      'ohos.permission.LOCATION',
      'ohos.permission.APPROXIMATELY_LOCATION'
    ];
    atManager.requestPermissionsFromUser(this.context, locPermissions)
      .then((result) => {
        const granted = result.authResults.filter((r: number) => r === 0).length;
        Logger.info(APP_TAG,
          'Location permissions: %{public}d/%{public}d granted', granted, locPermissions.length);
      })
      .catch((err: Error) => {
        Logger.error(APP_TAG,
          'Failed to request location permissions: %{public}s', err.message);
      });

    // 等待数据库就绪后加载 MapPage
    Promise.resolve(this.dbInitPromise).then(() => {
      windowStage.loadContent('pages/MapPage', (err) => {
        if (err.code) {
          Logger.error(APP_TAG,
            'Failed to load MapPage. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        Logger.info(APP_TAG, 'MapPage loaded successfully');
      });
    }).catch((err: Error) => {
      Logger.warn(APP_TAG,
        'DB init failed (%{public}s), loading MapPage anyway', err.message);
      windowStage.loadContent('pages/MapPage', (err2) => {
        if (err2.code) {
          Logger.error(APP_TAG,
            'Failed to load MapPage (fallback). Cause: %{public}s', JSON.stringify(err2));
        }
      });
    });
  }

  onWindowStageDestroy(): void {
    Logger.info(APP_TAG, 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    Logger.info(APP_TAG, 'EntryAbility onForeground');
    if (!this.locationService.isTrackingActive()) {
      this.locationService.startTracking();
      Logger.info(APP_TAG, 'Location service resumed');
    }
  }

  onBackground(): void {
    Logger.info(APP_TAG, 'EntryAbility onBackground');
    if (this.locationService.isTrackingActive()) {
      Logger.info(APP_TAG, 'Location tracking continues in background');
    }
  }
}
