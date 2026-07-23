/**
 * 跨页面共享状态 — 用于 WaypointDetailPage 通知 MapPage 校准已变更
 * 使用模块级静态变量，不依赖 AppStorage / 生命周期 / @Watch
 */

interface SignalResult {
  hasNew: boolean;
  newTs: number;
}

export class CalibrationSignal {
  static changeTs: number = 0;

  /** 发出校准变更信号 */
  static fire(): void {
    CalibrationSignal.changeTs = Date.now();
  }

  /** 检查并消费信号 */
  static consume(lastTs: number): SignalResult {
    const s: SignalResult = { hasNew: false, newTs: lastTs };
    if (CalibrationSignal.changeTs > 0 && CalibrationSignal.changeTs !== lastTs) {
      s.hasNew = true;
      s.newTs = CalibrationSignal.changeTs;
    }
    return s;
  }
}
