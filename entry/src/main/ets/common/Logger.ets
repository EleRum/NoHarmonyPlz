/**
 * 跨平台日志工具类
 * 替换 @kit.PerformanceAnalysisKit (hilog)，使用 console API
 * 保持与 hilog 兼容的调用签名以最小化迁移成本
 *
 * 迁移规则:
 *   hilog.info(domain, tag, format, ...args) → Logger.info(tag, format, ...args)
 *   hilog.warn(domain, tag, format, ...args) → Logger.warn(tag, format, ...args)
 *   hilog.error(domain, tag, format, ...args) → Logger.error(tag, format, ...args)
 */
export class Logger {
  /**
   * 信息级别日志
   * @param tag 日志标签（原 hilog 的第三个参数）
   * @param message 格式化消息，支持 %{public}s, %{public}d 占位符
   * @param args 替换占位符的可变参数
   */
  static info(tag: string, message: string, ...args: Object[]): void {
    const formatted: string = Logger.formatMessage(message, args);
    console.info(`[${tag}] ${formatted}`);
  }

  /**
   * 警告级别日志
   */
  static warn(tag: string, message: string, ...args: Object[]): void {
    const formatted: string = Logger.formatMessage(message, args);
    console.warn(`[${tag}] ${formatted}`);
  }

  /**
   * 错误级别日志
   */
  static error(tag: string, message: string, ...args: Object[]): void {
    const formatted: string = Logger.formatMessage(message, args);
    console.error(`[${tag}] ${formatted}`);
  }

  /**
   * 调试级别日志（仅开发环境）
   */
  static debug(tag: string, message: string, ...args: Object[]): void {
    const formatted: string = Logger.formatMessage(message, args);
    console.debug(`[${tag}] ${formatted}`);
  }

  /**
   * 将 hilog 格式字符串转换为实际值
   * 支持: %{public}s (字符串), %{public}d (数字), %{public}f (浮点)
   */
  private static formatMessage(message: string, args: Object[]): string {
    if (!args || args.length === 0) {
      return message;
    }
    let result: string = message;
    let argIndex: number = 0;
    // 按顺序替换 hilog 格式占位符
    result = result.replace(/%\{public\}[sdf]|%\{private\}[sdf]/g, (): string => {
      if (argIndex < args.length) {
        const val: Object = args[argIndex];
        argIndex++;
        return String(val);
      }
      return 'undefined';
    });
    return result;
  }
}
