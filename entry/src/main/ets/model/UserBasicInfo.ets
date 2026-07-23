/**
 * 用户基础信息模型
 * 对应 user_basic_info 表，长期存储用户身份和偏好
 */
import { ValuesBucket } from '../platform/database/IDatabase';

export class UserBasicInfo {
  id: number = 0;
  username: string = '';
  age: number = 0;
  city: string = '';
  gender: string = '';
  travelPreferences: string = '[]';  // JSON array of preference tags
  createdAt: number = 0;
  updatedAt: number = 0;

  static fromResultSet(row: ValuesBucket): UserBasicInfo {
    const info = new UserBasicInfo();
    info.id = row['id'] as number ?? 0;
    info.username = row['username'] as string ?? '';
    info.age = row['age'] as number ?? 0;
    info.city = row['city'] as string ?? '';
    info.gender = row['gender'] as string ?? '';
    info.travelPreferences = row['travel_preferences'] as string ?? '[]';
    info.createdAt = row['created_at'] as number ?? 0;
    info.updatedAt = row['updated_at'] as number ?? 0;
    return info;
  }

  toValuesBucket(): ValuesBucket {
    return {
      'username': this.username,
      'age': this.age,
      'city': this.city,
      'gender': this.gender,
      'travel_preferences': this.travelPreferences,
      'created_at': this.createdAt,
      'updated_at': this.updatedAt
    };
  }

  /** 获取解析后的偏好标签数组 */
  getPreferenceTags(): string[] {
    try {
      const arr: string[] = JSON.parse(this.travelPreferences) as string[];
      return arr;
    } catch (e) {
      // ignore parse errors
    }
    return [];
  }

  /** 设置偏好标签（从字符串数组） */
  setPreferenceTags(tags: string[]): void {
    this.travelPreferences = JSON.stringify(tags);
  }

  /** 获取偏好标签的逗号分隔中文展示 */
  getPreferenceDisplay(): string {
    const tags: string[] = this.getPreferenceTags();
    return tags.length > 0 ? tags.join('、') : '';
  }

  /** 是否有完善的基础信息 */
  hasBasicInfo(): boolean {
    return this.username.length > 0 || this.city.length > 0;
  }
}
