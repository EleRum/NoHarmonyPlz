/**
 * 主题系统 — 浅色/深色双模式 + 字体、间距、圆角常量
 * 通过 AppStorage + @StorageLink 实现响应式切换
 */

// ═══════════════════════════════════════════════════
//  颜色定义
// ═══════════════════════════════════════════════════

export class ThemeColors {
  pageBg: string = '#F2F3F5';
  surface: string = '#FFFFFF';
  surfaceSecondary: string = '#F5F6F8';
  primary: string = '#3366FF';
  primaryLight: string = '#EBF0FF';
  textPrimary: string = '#1A1A1C';
  textSecondary: string = '#8E8E93';
  textTertiary: string = '#B0B0B5';
  border: string = '#E5E5EA';
  divider: string = '#F0F0F3';
  success: string = '#34C759';
  danger: string = '#FF3B30';
  warning: string = '#FF9500';
  tabBarBg: string = '#FFFFFF';
  overlay: string = '#80000000';
  toast: string = '#333333CC';
  shadow: string = '#10000000';
}

function makeLightColors(): ThemeColors {
  const c: ThemeColors = new ThemeColors();
  c.pageBg = '#F2F3F5';
  c.surface = '#FFFFFF';
  c.surfaceSecondary = '#F5F6F8';
  c.primary = '#3366FF';
  c.primaryLight = '#EBF0FF';
  c.textPrimary = '#1A1A1C';
  c.textSecondary = '#8E8E93';
  c.textTertiary = '#B0B0B5';
  c.border = '#E5E5EA';
  c.divider = '#F0F0F3';
  c.success = '#34C759';
  c.danger = '#FF3B30';
  c.warning = '#FF9500';
  c.tabBarBg = '#FFFFFF';
  c.overlay = '#80000000';
  c.toast = '#333333CC';
  c.shadow = '#10000000';
  return c;
}

function makeDarkColors(): ThemeColors {
  const c: ThemeColors = new ThemeColors();
  c.pageBg = '#191919';
  c.surface = '#262626';
  c.surfaceSecondary = '#1E1E1F';
  c.primary = '#5B8DFF';
  c.primaryLight = '#1E2A45';
  c.textPrimary = '#E5E5E5';
  c.textSecondary = '#98989D';
  c.textTertiary = '#6E6E73';
  c.border = '#333333';
  c.divider = '#2C2C2C';
  c.success = '#30D158';
  c.danger = '#FF453A';
  c.warning = '#FF9F0A';
  c.tabBarBg = '#1F1F1F';
  c.overlay = '#B0000000';
  c.toast = '#444444DD';
  c.shadow = '#00000040';
  return c;
}

export const LightColors: ThemeColors = makeLightColors();
export const DarkColors: ThemeColors = makeDarkColors();

// ═══════════════════════════════════════════════════
//  主题获取（响应式 — 通过 AppStorage）
// ═══════════════════════════════════════════════════

const THEME_KEY: string = 'theme_is_dark';

/** 根据传入的 mode 返回主题色（配合 @StorageLink 实现响应式） */
export function getTheme(mode?: string): ThemeColors {
  if (mode) return mode === 'dark' ? DarkColors : LightColors;
  try {
    const m: string | undefined = AppStorage.get(THEME_KEY) as string | undefined;
    return m === 'dark' ? DarkColors : LightColors;
  } catch (e) {
    return LightColors;
  }
}

/** 切换深色模式，写入 AppStorage 触发所有 @StorageLink 组件重渲染 */
export function toggleTheme(): void {
  try {
    const current: string | undefined = AppStorage.get(THEME_KEY) as string | undefined;
    const next: string = current === 'dark' ? 'light' : 'dark';
    AppStorage.setOrCreate(THEME_KEY, next);
  } catch (e) {
    AppStorage.setOrCreate(THEME_KEY, 'dark');
  }
}

/** 设置深色模式 */
export function setDarkTheme(dark: boolean): void {
  try {
    AppStorage.setOrCreate(THEME_KEY, dark ? 'dark' : 'light');
  } catch (e) {
    // ignore
  }
}

/** 当前是否为深色 */
export function isDarkTheme(): boolean {
  try {
    return AppStorage.get(THEME_KEY) === 'dark';
  } catch (e) {
    return false;
  }
}

// ═══════════════════════════════════════════════════
//  字体大小常量
// ═══════════════════════════════════════════════════

export class FONT {
  static readonly hero: number = 28;
  static readonly title: number = 24;
  static readonly heading: number = 18;
  static readonly subheading: number = 15;
  static readonly body: number = 14;
  static readonly caption: number = 12;
  static readonly label: number = 10;
}

// ═══════════════════════════════════════════════════
//  圆角常量
// ═══════════════════════════════════════════════════

export class RADIUS {
  static readonly sm: number = 8;
  static readonly md: number = 12;
  static readonly lg: number = 16;
  static readonly xl: number = 20;
  static readonly pill: number = 24;
  static readonly full: number = 9999;
}

// ═══════════════════════════════════════════════════
//  间距常量
// ═══════════════════════════════════════════════════

export class SPACE {
  static readonly xs: number = 4;
  static readonly sm: number = 8;
  static readonly md: number = 12;
  static readonly lg: number = 16;
  static readonly xl: number = 20;
  static readonly xxl: number = 24;
  static readonly xxxl: number = 32;
}
