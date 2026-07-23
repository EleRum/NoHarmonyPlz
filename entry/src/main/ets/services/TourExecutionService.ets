/**
 * Shared execution state for the guided tour flow.
 * It connects TourGuidePage planning with MapPage navigation/check-in.
 */
import { Dao } from '../database/Dao';
import { TourPlan, TourDay, isMarkerPoi } from '../model/TourPlan';

const TOUR_EXECUTION_KEY: string = 'tour_execution_session';

export interface TourExecutionPoi {
  name: string;
  lat: number;
  lng: number;
  type: string;
  timeSlot: string;
  note: string;
  checked: boolean;
}

export interface TourExecutionSession {
  active: boolean;
  planCity: string;
  dayIndex: number;
  dayLabel: string;
  currentPoiIndex: number;
  startedAt: number;
  updatedAt: number;
  pois: TourExecutionPoi[];
}

export class TourExecutionService {
  static async start(plan: TourPlan, dayIndex: number): Promise<TourExecutionSession | null> {
    if (!plan || dayIndex < 0 || dayIndex >= plan.dailyPlans.length) return null;
    const day: TourDay = plan.dailyPlans[dayIndex];
    if (!day.pois || day.pois.length === 0) return null;
    const pois: TourExecutionPoi[] = [];
    for (const poi of day.pois) {
      if (isMarkerPoi(poi)) continue;
      if (!poi.name || poi.name.length === 0) continue;
      if (!poi.lat || !poi.lng) continue;
      pois.push({
        name: poi.name,
        lat: poi.lat,
        lng: poi.lng,
        type: poi.type || '',
        timeSlot: poi.timeSlot || '',
        note: poi.note || '',
        checked: false,
      });
    }
    if (pois.length === 0) return null;

    const now: number = Date.now();
    const session: TourExecutionSession = {
      active: true,
      planCity: plan.city || '',
      dayIndex: dayIndex,
      dayLabel: day.label || `第${dayIndex + 1}天`,
      currentPoiIndex: 0,
      startedAt: now,
      updatedAt: now,
      pois: pois,
    };
    await TourExecutionService.save(session);
    return session;
  }

  static async getActive(): Promise<TourExecutionSession | null> {
    try {
      const raw = await Dao.getInstance().queryUserProfile(TOUR_EXECUTION_KEY);
      if (!raw || !raw.preferenceValue || raw.preferenceValue.length === 0) return null;
      const session = JSON.parse(raw.preferenceValue) as TourExecutionSession;
      if (!session || !session.active || !session.pois || session.pois.length === 0) return null;
      if (!(session.currentPoiIndex >= 0)) session.currentPoiIndex = 0;
      if (session.currentPoiIndex > session.pois.length) session.currentPoiIndex = session.pois.length;
      return session;
    } catch (_e) {
      return null;
    }
  }

  static async save(session: TourExecutionSession): Promise<void> {
    session.updatedAt = Date.now();
    await Dao.getInstance().upsertUserProfile(TOUR_EXECUTION_KEY, JSON.stringify(session), 1);
  }

  static async clear(): Promise<void> {
    await Dao.getInstance().upsertUserProfile(TOUR_EXECUTION_KEY, '', 0);
  }

  static getCurrentPoi(session: TourExecutionSession | null): TourExecutionPoi | null {
    if (!session || !session.pois || session.pois.length === 0) return null;
    let start: number = session.currentPoiIndex;
    if (!(start >= 0) || start >= session.pois.length) start = 0;
    for (let i = start; i < session.pois.length; i++) {
      if (!session.pois[i].checked) {
        session.currentPoiIndex = i;
        return session.pois[i];
      }
    }
    for (let i = 0; i < start; i++) {
      if (!session.pois[i].checked) {
        session.currentPoiIndex = i;
        return session.pois[i];
      }
    }
    return null;
  }

  static checkedCount(session: TourExecutionSession | null): number {
    if (!session || !session.pois) return 0;
    let count: number = 0;
    for (const poi of session.pois) {
      if (poi.checked) count++;
    }
    return count;
  }

  static markCurrentChecked(session: TourExecutionSession): TourExecutionSession {
    const poi: TourExecutionPoi | null = TourExecutionService.getCurrentPoi(session);
    if (!poi) return session;
    session.pois[session.currentPoiIndex].checked = true;
    session.currentPoiIndex = TourExecutionService.nextOpenIndex(session, session.currentPoiIndex + 1);
    session.updatedAt = Date.now();
    return session;
  }

  static nextOpenIndex(session: TourExecutionSession, startIndex: number): number {
    for (let i = Math.max(0, startIndex); i < session.pois.length; i++) {
      if (!session.pois[i].checked) return i;
    }
    return session.pois.length;
  }
}
