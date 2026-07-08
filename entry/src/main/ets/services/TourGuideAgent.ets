/**
 * 导游 AI Agent — 对话式旅游规划师
 * 每步工具执行后立即返回地图标记数据，实现渐进式可视化
 */
import { ClaudeService, ClaudeReply } from './ClaudeService';
import { AmapSearchService } from './map/AmapSearchService';
import { PoiResult, LatLng, NavRoute, DirectionMode } from './map/MapTypes';
import { TourPlan, TourDay, TourPoiItem, createEmptyPlan } from '../model/TourPlan';
import { Logger } from '../common/Logger';

const TAG = 'TourGuideAgent';

const SYSTEM_PROMPT: string = `你是小途，资深旅游规划师。

## 风格
- 口语化，像朋友聊天，主动推进对话
- 一次只问1个问题，不要啰嗦
- 给出具体建议，不要泛泛而谈

## 工作流程
1. 问目的地和天数
2. geocode_city 定位城市
3. search_hotels 搜酒店，推荐2-3个让用户选
4. 用户选好酒店后，用 make_plan 生成行程计划
5. 展示每天行程

## 工具（回复末尾添加 ---JSON---）
{
  "action":"geocode_city","city":"成都"
}
{
  "action":"search_hotels"
}
{
  "action":"search_poi","keywords":"景点"
}
{
  "action":"make_plan","hotel":"锦江宾馆","hotelLat":"30.6","hotelLng":"104.1"
}

## 重要
- geocode_city 只需执行一次
- search_hotels 和 search_poi 之前确保城市已定位
- 用户确认酒店后，立即调用 make_plan，把酒店名和坐标填进去
- 每次都要主动推进到下一步，不要等用户催
- 不需要搜索时不要加 ---JSON---`;

export interface ToolCall {
  action: string;
  keywords?: string;
  city?: string;
  hotel?: string;
  hotelLat?: string;
  hotelLng?: string;
}

/** 地图标记数据 */
export interface MapMarker {
  name: string;
  lat: number;
  lng: number;
  type: string;
}

export interface AgentResponse {
  text: string;
  toolCall?: ToolCall;
  plan?: TourPlan;
  mapCenter?: LatLng;
  markers?: MapMarker[];
  polyline?: LatLng[];
}

export class TourGuideAgent {
  private claude: ClaudeService;
  private plan: TourPlan;
  private toolCallCount: number;

  constructor() {
    this.claude = new ClaudeService();
    this.claude.loadApiKey();
    this.plan = createEmptyPlan();
    this.toolCallCount = 0;
  }

  reset(): void {
    this.plan = createEmptyPlan();
    this.claude.clearHistory();
    this.toolCallCount = 0;
  }

  getPlan(): TourPlan {
    return this.plan;
  }

  /** 处理用户输入 */
  async process(input: string): Promise<AgentResponse> {
    this.toolCallCount = 0;
    const userMsg: string = '用户: ' + input;
    const reply: ClaudeReply = await this.claude.chatConversation(userMsg, SYSTEM_PROMPT);
    const text: string = reply.text || '抱歉，我暂时无法回复。';
    const toolCall: ToolCall | undefined = this.parseToolCall(text);
    if (toolCall) {
      return { text: this.stripJson(text), toolCall: toolCall };
    }
    return { text: this.stripJson(text) };
  }

  /** 执行工具并返回结果（含地图更新数据 + AI 继续对话） */
  async executeToolAndContinue(action: string, params: Record<string, string>): Promise<AgentResponse> {
    this.toolCallCount++;
    if (this.toolCallCount > 5) {
      return { text: '规划进行中，请告诉我接下来想做什么？' };
    }

    let resultText: string = '';
    let mapCenter: LatLng | undefined = undefined;
    let markers: MapMarker[] | undefined = undefined;

    switch (action) {
      case 'geocode_city': {
        const city: string = params['city'] ?? '';
        if (this.plan.city === city && this.plan.cityLat !== 0) {
          resultText = `城市${city}已定位。`;
        } else {
          const loc: LatLng | null = await AmapSearchService.getInstance().geocodeCity(city);
          if (loc) {
            this.plan.city = city;
            this.plan.cityLat = loc.latitude;
            this.plan.cityLng = loc.longitude;
            resultText = `城市${city}定位成功(${loc.latitude.toFixed(4)},${loc.longitude.toFixed(4)})。`;
            mapCenter = loc;
          } else {
            resultText = `城市"${city}"定位失败，请确认城市名。`;
          }
        }
        break;
      }
      case 'search_hotels': {
        if (this.plan.cityLat === 0) {
          const tc: ToolCall = { action: 'geocode_city', city: this.plan.city || '成都' };
          return { text: '需要先定位城市。', toolCall: tc };
        }
        const pois: PoiResult[] = await AmapSearchService.getInstance().searchHotels(this.plan.cityLat, this.plan.cityLng);
        const top5: PoiResult[] = pois.slice(0, 5);
        markers = top5.map((p: PoiResult): MapMarker => ({
          name: p.name, lat: p.latitude, lng: p.longitude, type: '酒店'
        }));
        resultText = pois.length > 0
          ? `${this.plan.city}酒店(top5)：\n` + top5.map((p, i) => `${i + 1}. ${p.name} | ${p.address || ''} | ${p.distance}m`).join('\n')
          : `未找到${this.plan.city}酒店。`;
        break;
      }
      case 'search_poi': {
        if (this.plan.cityLat === 0) {
          const tc: ToolCall = { action: 'geocode_city', city: params['city'] || '' };
          return { text: '需要先定位城市。', toolCall: tc };
        }
        const kw: string = params['keywords'] ?? '景点';
        const pois: PoiResult[] = await AmapSearchService.getInstance().searchPoiByCategory(kw, this.plan.cityLat, this.plan.cityLng, 20000);
        const top8: PoiResult[] = pois.slice(0, 8);
        markers = top8.map((p: PoiResult): MapMarker => ({
          name: p.name, lat: p.latitude, lng: p.longitude, type: kw
        }));
        resultText = pois.length > 0
          ? `"${kw}"搜索(top8)：\n` + top8.map((p, i) => `${i + 1}. ${p.name} | ${p.address || ''} | ${p.distance}m`).join('\n')
          : `未找到"${kw}"。`;
        break;
      }
      case 'make_plan': {
        const hotelName: string = params['hotel'] ?? '';
        const hotelLat: number = parseFloat(params['hotelLat'] ?? '0');
        const hotelLng: number = parseFloat(params['hotelLng'] ?? '0');
        if (!hotelName || hotelLat === 0) {
          resultText = '请提供酒店名称和坐标。';
          break;
        }
        this.plan.hotel = { name: hotelName, lat: hotelLat, lng: hotelLng, type: '酒店住宿', timeSlot: '入住', duration: '全程', note: '' };
        this.plan.days = this.plan.days || 3;

        const attr: PoiResult[] = await AmapSearchService.getInstance().searchPoiByCategory('景点|公园|博物馆', this.plan.cityLat, this.plan.cityLng, 15000);
        const foods: PoiResult[] = await AmapSearchService.getInstance().searchPoiByCategory('美食|餐厅|小吃', this.plan.cityLat, this.plan.cityLng, 10000);
        const timeSlots: string[] = ['上午9:00', '中午12:00', '下午14:00', '晚上18:00'];

        this.plan.dailyPlans = [];
        for (let d: number = 0; d < this.plan.days; d++) {
          const pois: TourPoiItem[] = [];
          pois.push({ name: hotelName, lat: hotelLat, lng: hotelLng, type: '酒店住宿', timeSlot: '出发', duration: '', note: '' });
          const a1: number = d * 2;
          const a2: number = d * 2 + 1;
          const f1: number = d * 2;
          if (a1 < attr.length) pois.push({ name: attr[a1].name, lat: attr[a1].latitude, lng: attr[a1].longitude, type: attr[a1].type || '景点', timeSlot: timeSlots[0], duration: '1-2h', note: attr[a1].address || '' });
          if (f1 < foods.length) pois.push({ name: foods[f1].name, lat: foods[f1].latitude, lng: foods[f1].longitude, type: foods[f1].type || '美食', timeSlot: timeSlots[1], duration: '1h', note: foods[f1].address || '' });
          if (a2 < attr.length) pois.push({ name: attr[a2].name, lat: attr[a2].latitude, lng: attr[a2].longitude, type: attr[a2].type || '景点', timeSlot: timeSlots[2], duration: '1-2h', note: attr[a2].address || '' });
          pois.push({ name: hotelName, lat: hotelLat, lng: hotelLng, type: '酒店住宿', timeSlot: '返回', duration: '', note: '' });
          this.plan.dailyPlans.push({ dayIndex: d, label: `第${d + 1}天`, pois: pois, route: null });
        }
        this.plan.status = 'complete';

        // 计算每条路线的路径
        for (let d: number = 0; d < this.plan.dailyPlans.length; d++) {
          const day: TourDay = this.plan.dailyPlans[d];
          const allPts: LatLng[] = [];
          for (let pi: number = 0; pi < day.pois.length - 1; pi++) {
            try {
              const route: NavRoute | null = await AmapSearchService.getInstance().directionRouteRest(
                day.pois[pi].lat, day.pois[pi].lng,
                day.pois[pi + 1].lat, day.pois[pi + 1].lng,
                DirectionMode.DRIVING
              );
              if (route && route.path.length > 0) {
                for (const pt of route.path) allPts.push(pt);
              }
            } catch (_e) { /* ignore */ }
          }
          if (allPts.length > 0) {
            day.route = { distance: 0, duration: 0, path: allPts, steps: [], origin: '', destination: '' };
          }
        }

        resultText = `已生成${this.plan.days}天${this.plan.city}行程！\n` +
          this.plan.dailyPlans.map((day) => `${day.label}：${day.pois.filter((p) => p.type !== '酒店住宿').map((p) => p.name).join(' → ')}`).join('\n');
        break;
      }
      case 'get_weather': {
        resultText = `${params['city'] || this.plan.city}近日天气：晴转多云 20-28°C（参考）。`;
        break;
      }
      default:
        resultText = `工具 ${action} 执行完毕。`;
    }

    // 反馈 AI 继续对话
    const ctx: string = `当前计划：城市=${this.plan.city}(${this.plan.cityLat.toFixed(2)},${this.plan.cityLng.toFixed(2)}) 酒店=${this.plan.hotel?.name || '未选'} 天数=${this.plan.days}`;
    const followMsg: string = `工具 ${action} 结果：\n${resultText}\n\n请基于此继续与用户对话。`;
    const reply: ClaudeReply = await this.claude.chatConversation(followMsg, SYSTEM_PROMPT);
    const text: string = reply.text || '收到，请继续。';
    const nextTool: ToolCall | undefined = this.parseToolCall(text);

    const resp: AgentResponse = {
      text: this.stripJson(text),
      toolCall: nextTool,
      mapCenter: mapCenter,
      markers: markers,
    };

    if (action === 'make_plan' && this.plan.dailyPlans.length > 0) {
      resp.plan = this.plan;
    }
    return resp;
  }

  private parseToolCall(text: string): ToolCall | undefined {
    const idx: number = text.indexOf('---JSON---');
    let jsonStr: string = '';
    if (idx >= 0) {
      jsonStr = text.substring(idx + 10).trim();
    } else {
      const m = text.match(/\{[\s\S]*"action"[\s\S]*\}/);
      if (m) jsonStr = m[0];
    }
    if (!jsonStr) return undefined;
    try {
      const obj = JSON.parse(jsonStr) as Record<string, string>;
      if (obj['action']) {
        const tc: ToolCall = { action: obj['action'] ?? '' };
        if (obj['keywords']) tc.keywords = obj['keywords'];
        if (obj['city']) tc.city = obj['city'];
        if (obj['hotel']) tc.hotel = obj['hotel'];
        if (obj['hotelLat']) tc.hotelLat = obj['hotelLat'];
        if (obj['hotelLng']) tc.hotelLng = obj['hotelLng'];
        return tc;
      }
    } catch (_e) { /* ignore */ }
    return undefined;
  }

  private stripJson(text: string): string {
    const idx: number = text.indexOf('---JSON---');
    if (idx >= 0) return text.substring(0, idx).trim();
    return text.replace(/\n*\{[\s\S]*"action"[\s\S]*\}$/, '').trim();
  }
}
