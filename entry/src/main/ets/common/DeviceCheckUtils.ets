/**
 * 设备服务检测工具
 * 用于检测 GPS 定位服务和网络连接状态
 */
import { geoLocationManager } from '@kit.LocationKit';
import { connection } from '@kit.NetworkKit';
import { Logger } from './Logger';

const TAG = 'DeviceCheck';

/** 服务状态检测结果 */
export interface ServiceStatus {
  /** GPS 定位是否开启 */
  locationEnabled: boolean;
  /** 网络是否已连接 */
  networkConnected: boolean;
}

/**
 * 检测 GPS 定位服务是否开启
 * 使用同步 API，兼容 API 10+
 */
export function checkLocationEnabled(): boolean {
  try {
    const enabled: boolean = geoLocationManager.isLocationEnabled();
    Logger.info(TAG, 'Location enabled: %{public}s', enabled ? 'true' : 'false');
    return enabled;
  } catch (e) {
    Logger.error(TAG, 'Failed to check location status: %{public}s', JSON.stringify(e));
    return false;
  }
}

/**
 * 检测网络是否已连接
 * 通过检查默认网络是否存在来判断
 */
export async function checkNetworkConnected(): Promise<boolean> {
  try {
    const hasNet: boolean = await connection.hasDefaultNet();
    Logger.info(TAG, 'Network connected: %{public}s', hasNet ? 'true' : 'false');
    return hasNet;
  } catch (e) {
    Logger.error(TAG, 'Failed to check network status: %{public}s', JSON.stringify(e));
    return false;
  }
}

/**
 * 综合检测 GPS 和网络状态
 * @returns 包含 locationEnabled 和 networkConnected 的状态对象
 */
export async function checkServicesStatus(): Promise<ServiceStatus> {
  const locationEnabled: boolean = checkLocationEnabled();
  const networkConnected: boolean = await checkNetworkConnected();

  Logger.info(TAG, 'Service status — GPS: %{public}s, Network: %{public}s',
    locationEnabled ? 'ON' : 'OFF',
    networkConnected ? 'ON' : 'OFF');

  return {
    locationEnabled: locationEnabled,
    networkConnected: networkConnected
  };
}

/**
 * 判断是否所有必要服务都已就绪
 */
export function isAllServicesReady(status: ServiceStatus): boolean {
  return status.locationEnabled && status.networkConnected;
}
