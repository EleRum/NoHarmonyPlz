/**
 * 推荐记录模型
 * 对应 recommendation 表
 */
import { ValuesBucket } from '../platform/database/IDatabase';

export class Recommendation {
  id: number = 0;
  placeName: string = '';
  placeType: string = '';
  latitude: number = 0;
  longitude: number = 0;
  reason: string = '';
  triggerContext: string = '';
  isAccepted: number = 0;
  timestamp: number = 0;
  /** JSON: {rating, reviewCount, popularItems, sourceUrl, source, tags} */
  enrichmentJson: string = '';

  static fromResultSet(row: ValuesBucket): Recommendation {
    const rec = new Recommendation();
    rec.id = row['id'] as number ?? 0;
    rec.placeName = row['place_name'] as string ?? '';
    rec.placeType = row['place_type'] as string ?? '';
    rec.latitude = row['latitude'] as number ?? 0;
    rec.longitude = row['longitude'] as number ?? 0;
    rec.reason = row['reason'] as string ?? '';
    rec.triggerContext = row['trigger_context'] as string ?? '';
    rec.isAccepted = row['is_accepted'] as number ?? 0;
    rec.timestamp = row['timestamp'] as number ?? 0;
    rec.enrichmentJson = row['enrichment_json'] as string ?? '';
    return rec;
  }

  toValuesBucket(): ValuesBucket {
    return {
      'place_name': this.placeName,
      'place_type': this.placeType,
      'latitude': this.latitude,
      'longitude': this.longitude,
      'reason': this.reason,
      'trigger_context': this.triggerContext,
      'is_accepted': this.isAccepted,
      'timestamp': this.timestamp,
      'enrichment_json': this.enrichmentJson
    };
  }
}
