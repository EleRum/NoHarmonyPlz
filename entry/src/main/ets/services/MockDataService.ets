/**
 * Mock 数据注入服务
 * 模拟校园/公园连续行走/跑步轨迹 —— 人在路上走，不是几个孤立点
 */
import { Logger } from '../common/Logger';
import { Footprint } from '../model/Footprint';
import { ActivitySegment } from '../model/ActivitySegment';
import { Dao } from '../database/Dao';
import { getDayKey } from '../common/LocationUtils';

const TAG = 'MockDataService';

// 路线拐点
interface Waypoint {
  lng: number;
  lat: number;
  label: string;
  photos: string[];        // 模拟照片描述
  activityTag: string;     // 在此点做什么
  stayMin: number;         // 停留时长（分钟）
}

// 插值坐标点
interface Coord {
  lng: number;
  lat: number;
}

// 一天的路线计划
interface DayPlan {
  dayOffset: number;
  route: Waypoint[];
  activityType: string;
  activityPoiName: string;
  speedBase: number;
}

const ONE_MIN: number = 60000;
const ONE_HOUR: number = 60 * ONE_MIN;
const SAMPLE_INTERVAL_SEC: number = 5;
const GPS_NOISE: number = 0.000015;

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

// 两点间按步数线性插值（加弧线偏移模拟道路弯曲）
function interpolatePath(
  lng1: number, lat1: number,
  lng2: number, lat2: number,
  steps: number
): Coord[] {
  const pts: Coord[] = [];
  for (let s = 1; s <= steps; s++) {
    const t: number = s / (steps + 1);
    const arc: number = Math.sin(t * Math.PI) * 0.00008;
    const dx: number = lng2 - lng1;
    const dy: number = lat2 - lat1;
    const len: number = Math.sqrt(dx * dx + dy * dy);
    const nx: number = len > 0 ? -dy / len : 0;
    const ny: number = len > 0 ? dx / len : 0;
    pts.push({
      lng: lerp(lng1, lng2, t) + nx * arc,
      lat: lerp(lat1, lat2, t) + ny * arc
    });
  }
  return pts;
}

export class MockDataService {
  static async injectIfEmpty(dao: Dao): Promise<void> {
    const count: number = await dao.getFootprintCount();
    if (count > 0) {
      Logger.info(TAG, 'Already has %{public}d footprints, skip mock', count);
      return;
    }

    Logger.info(TAG, 'Empty DB — injecting continuous walking/running tracks');
    const now: number = Date.now();

    // ============== 多日路线定义 ==============
    // 坐标范围：成都高新区锦城湖公园周边（近似）
    // 道路名用真实附近地标
    const days: DayPlan[] = [
      // ── 今天：环锦城湖跑步 5km ──
      {
        dayOffset: 0,
        activityType: 'sports',
        activityPoiName: '锦城湖夜跑',
        speedBase: 3.2,
        route: [
          { lng: 104.0690, lat: 30.5780, label: '起点·湖西入口', photos: ['锦城湖夕阳倒影', '热身拉伸区'], activityTag: 'sports', stayMin: 3 },
          { lng: 104.0715, lat: 30.5785, label: '湖北岸观景台', photos: ['湖面夜景灯光'], activityTag: 'sports', stayMin: 1 },
          { lng: 104.0740, lat: 30.5790, label: '湖东桥', photos: [], activityTag: 'sports', stayMin: 0 },
          { lng: 104.0745, lat: 30.5765, label: '湖南岸绿道', photos: ['绿道夜跑自拍'], activityTag: 'sports', stayMin: 2 },
          { lng: 104.0720, lat: 30.5755, label: '湖西栈道', photos: ['栈道灯光水面'], activityTag: 'sports', stayMin: 1 },
          { lng: 104.0695, lat: 30.5760, label: '终点·湖西入口', photos: [], activityTag: 'sports', stayMin: 5 },
        ]
      },
      // ── 昨天：沿天府大道散步 — 慢走约 3km ──
      {
        dayOffset: 1,
        activityType: 'commute',
        activityPoiName: '天府大道散步',
        speedBase: 1.4,
        route: [
          { lng: 104.0665, lat: 30.5723, label: '天府软件园A区', photos: ['工位窗外夜景'], activityTag: 'work', stayMin: 60 },
          { lng: 104.0680, lat: 30.5740, label: '星巴克·天府店', photos: ['拿铁+街景'], activityTag: 'dining', stayMin: 25 },
          { lng: 104.0710, lat: 30.5780, label: '银泰城', photos: ['商场圣诞装饰', '买的新鞋'], activityTag: 'shopping', stayMin: 45 },
          { lng: 104.0735, lat: 30.5820, label: '交子公园北口', photos: ['公园落日'], activityTag: 'leisure', stayMin: 15 },
          { lng: 104.0755, lat: 30.5865, label: '金融城地铁站', photos: [], activityTag: 'commute', stayMin: 5 },
        ]
      },
      // ── 前天：从家到公司的通勤骑行 ──
      {
        dayOffset: 2,
        activityType: 'commute',
        activityPoiName: '通勤骑行',
        speedBase: 5.5,
        route: [
          { lng: 104.0600, lat: 30.5680, label: '家·南城都汇', photos: ['早餐咖啡'], activityTag: 'home', stayMin: 30 },
          { lng: 104.0630, lat: 30.5685, label: '益州大道·早餐摊', photos: ['煎饼果子'], activityTag: 'dining', stayMin: 8 },
          { lng: 104.0650, lat: 30.5700, label: '天府一街路口', photos: [], activityTag: 'commute', stayMin: 0 },
          { lng: 104.0665, lat: 30.5723, label: '天府软件园', photos: ['车棚停车照'], activityTag: 'work', stayMin: 0 },
        ]
      },
      // ── 大前天：逛街购物路线 — 慢走 ──
      {
        dayOffset: 3,
        activityType: 'shopping',
        activityPoiName: '银泰城购物',
        speedBase: 1.2,
        route: [
          { lng: 104.0710, lat: 30.5780, label: '银泰城西门', photos: [], activityTag: 'shopping', stayMin: 5 },
          { lng: 104.0725, lat: 30.5785, label: 'ZARA 服饰', photos: ['试穿新外套'], activityTag: 'shopping', stayMin: 30 },
          { lng: 104.0735, lat: 30.5775, label: '海底捞·午餐', photos: ['火锅沸腾照', '番茄锅底'], activityTag: 'dining', stayMin: 75 },
          { lng: 104.0720, lat: 30.5765, label: '盒马鲜生', photos: ['购物车满当当', '买了车厘子'], activityTag: 'shopping', stayMin: 20 },
          { lng: 104.0710, lat: 30.5780, label: '银泰城西门', photos: [], activityTag: 'shopping', stayMin: 0 },
        ]
      },
      // ── 四天前：晨跑 3km — 快跑 ──
      {
        dayOffset: 4,
        activityType: 'sports',
        activityPoiName: '交子公园晨跑',
        speedBase: 4.5,
        route: [
          { lng: 104.0735, lat: 30.5820, label: '公园北门', photos: ['晨光中的公园入口'], activityTag: 'sports', stayMin: 2 },
          { lng: 104.0750, lat: 30.5830, label: '环湖东路·观鸟台', photos: ['白鹭起飞抓拍'], activityTag: 'sports', stayMin: 3 },
          { lng: 104.0760, lat: 30.5815, label: '南草坪', photos: ['草坪晨露'], activityTag: 'sports', stayMin: 1 },
          { lng: 104.0745, lat: 30.5805, label: '西步道·樱花林', photos: ['樱花特写', '跑步路线截图'], activityTag: 'sports', stayMin: 4 },
          { lng: 104.0735, lat: 30.5820, label: '公园北门', photos: [], activityTag: 'sports', stayMin: 0 },
        ]
      },
    ];

    // ============== 写入足迹和活动片段 ==============
    for (let di = 0; di < days.length; di++) {
      const plan: DayPlan = days[di];
      const dayStart: number = now - plan.dayOffset * 24 * ONE_HOUR - 8 * ONE_HOUR;
      let ts: number = dayStart + 5 * ONE_MIN; // 当天早上 5 点开始
      const dayKey: string = getDayKey(ts);
      const footprints: Footprint[] = [];

      // ── 沿路线的每一个拐点对之间，按时间间隔插值生成连续 GPS 点 ──
      for (let i = 1; i < plan.route.length; i++) {
        const from: Waypoint = plan.route[i - 1];
        const to: Waypoint = plan.route[i];

        // 计算两点间的距离（近似）
        const dx: number = (to.lng - from.lng) * 111000 * Math.cos((from.lat + to.lat) / 2 * Math.PI / 180);
        const dy: number = (to.lat - from.lat) * 111000;
        const distM: number = Math.sqrt(dx * dx + dy * dy);

        // 按速度算出耗时
        const speedMs: number = plan.speedBase * (0.85 + Math.random() * 0.3); // ±15% 波动
        const durationSec: number = distM / speedMs;
        const steps: number = Math.max(3, Math.round(durationSec / SAMPLE_INTERVAL_SEC));

        // 插值生成连续点
        const inter: Coord[] = interpolatePath(
          from.lng, from.lat, to.lng, to.lat, steps
        );

        for (let s = 0; s < inter.length; s++) {
          ts += SAMPLE_INTERVAL_SEC * 1000;
          const fp: Footprint = new Footprint();
          // GPS 加噪
          fp.latitude = inter[s].lat + (Math.random() - 0.5) * GPS_NOISE;
          fp.longitude = inter[s].lng + (Math.random() - 0.5) * GPS_NOISE;
          fp.accuracy = 5 + Math.random() * 15;
          fp.timestamp = ts;
          fp.poiName = '';
          fp.poiType = plan.activityType;
          fp.activityTag = plan.activityType;
          fp.source = 'gps';
          fp.speed = speedMs + (Math.random() - 0.5) * 1.5;
          fp.dayKey = dayKey;
          fp.stayDuration = 0;
          footprints.push(fp);
        }
      }

      // 拐点处打标签：写入 poiName、活动类型、停留时长、照片引用
      const fpLen: number = footprints.length;
      for (let i = 0; i < plan.route.length; i++) {
        const wp: Waypoint = plan.route[i];
        const idx: number = fpLen > 0
          ? Math.min(fpLen - 1, Math.floor(i * fpLen / plan.route.length))
          : 0;
        footprints[idx].poiName = wp.label;
        footprints[idx].activityTag = wp.activityTag;
        footprints[idx].stayDuration = wp.stayMin * 60 * 1000;
        footprints[idx].photoId = wp.photos.length > 0 ? wp.photos.join('|') : '';
      }

      // 批量写入
      for (const fp of footprints) {
        await dao.insertFootprint(fp);
      }

      Logger.info(TAG,
        'Day %{public}s: %{public}d track points, speed ~%{public}.1f m/s',
        dayKey, footprints.length, plan.speedBase);

      // ── 写入活动片段 ──
      const seg: ActivitySegment = new ActivitySegment();
      seg.dayKey = dayKey;
      seg.startTime = footprints[0].timestamp;
      seg.endTime = footprints[footprints.length - 1].timestamp;
      seg.activityType = plan.activityType;
      seg.poiName = plan.activityPoiName;
      seg.latitude = plan.route[0].lat;
      seg.longitude = plan.route[0].lng;
      seg.photoCount = 0;
      seg.summary = '';
      await dao.insertActivitySegment(seg);
    }

    Logger.info(TAG, 'Mock data: %{public}d days of continuous tracks injected', days.length);
  }
}
