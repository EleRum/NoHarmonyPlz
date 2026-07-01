/**
 * 用户画像模型
 * 对应 user_profile 表
 */
import { ValuesBucket } from '../platform/database/IDatabase';

export class UserProfile {
  id: number = 0;
  preferenceKey: string = '';
  preferenceValue: string = '';  // JSON string
  confidence: number = 0;
  updateTime: number = 0;

  static fromResultSet(row: ValuesBucket): UserProfile {
    const up = new UserProfile();
    up.id = row['id'] as number ?? 0;
    up.preferenceKey = row['preference_key'] as string ?? '';
    up.preferenceValue = row['preference_value'] as string ?? '';
    up.confidence = row['confidence'] as number ?? 0;
    up.updateTime = row['update_time'] as number ?? 0;
    return up;
  }

  toValuesBucket(): ValuesBucket {
    return {
      'preference_key': this.preferenceKey,
      'preference_value': this.preferenceValue,
      'confidence': this.confidence,
      'update_time': this.updateTime
    };
  }
}
