/**
 * AI Agent — 自然语言活动修正
 * 两步确认：查找匹配段 → 用户确认 → 执行修改
 */
import { Dao } from '../database/Dao';
import { ActivitySegment } from '../model/ActivitySegment';
import { getDayKey } from '../common/LocationUtils';
import { ClaudeService, ClaudeReply } from './ClaudeService';
import { CalibrationService } from './CalibrationService';
import { CalibrationSource } from '../common/Constants';
import { PlatformBridge } from '../platform/PlatformBridge';
import { HttpResponse } from '../platform/network/INetworkProvider';
import { AmapSearchService } from './map/AmapSearchService';

const TAG = 'AiAgent';

interface ParsedIntent {
  target: string;
  action: string;
  value: string;
}

interface PendingEdit {
  segIndex: number;
  seg: ActivitySegment;
  dayKey: string;
  newType?: string;
  newPoiName?: string;
}
type PendingConfirmation = PendingEdit;

const TYPE_ALIAS: Record<string, string> = {
  '购物':'shopping','逛街':'shopping',
  '吃饭':'dining','餐饮':'dining','聚餐':'dining','用餐':'dining','午饭':'dining','晚饭':'dining','早餐':'dining',
  '运动':'sports','跑步':'sports','健身':'sports','锻炼':'sports','游泳':'sports','打球':'sports','骑行':'sports',
  '工作':'work','上班':'work','办公':'work',
  '回家':'home','居家':'home','在家':'home',
  '通勤':'commute','交通':'commute','坐车':'commute','地铁':'commute','走路':'commute','步行':'commute',
  '休闲':'leisure','钓鱼':'leisure','玩':'leisure','娱乐':'leisure',
  '旅游':'travel','出行':'travel',
};
const TYPE_LABEL_REV: Record<string, string> = {
  'shopping':'购物','dining':'餐饮','sports':'运动','work':'工作',
  'home':'居家','commute':'通勤','leisure':'休闲','travel':'旅游',
};

function mapType(word: string): string {
  if (TYPE_ALIAS[word]) return TYPE_ALIAS[word];
  for (const k of Object.keys(TYPE_ALIAS)) { if (word.includes(k)) return TYPE_ALIAS[k]; }
  return '';
}

export interface AgentContext {
  lastSegmentType: string; lastSegmentPoi: string;
  lastSegmentLat: number; lastSegmentLng: number;
  todayDistance: number; todaySegCount: number; footprintCount: number;
  /** 用户基础信息（软引导，不强制） */
  userName: string; userCity: string; userPreferences: string;
}

export interface AgentReply {
  text: string;
  action?: string; actionParam?: number;
}

export class AiAgent {
  private dao: Dao;
  private ctx: AgentContext;
  private pending: PendingConfirmation | null = null;
  private todaySegs: ActivitySegment[] = [];
  private allSegs: ActivitySegment[] = []; // 最近7天所有段
  private dayForAllSegs: string[] = [];   // allSegs 对应的 dayKey
  private lastAiText: string = '';
  private claude: ClaudeService = new ClaudeService();

  constructor(dao: Dao) {
    this.dao = dao;
    this.ctx = { lastSegmentType:'', lastSegmentPoi:'', lastSegmentLat:0, lastSegmentLng:0, todayDistance:0, todaySegCount:0, footprintCount:0, userName:'', userCity:'', userPreferences:'' };
    this.claude.loadApiKey();
  }

  updateContext(ctx: Partial<AgentContext>): void {
    if (ctx.lastSegmentType !== undefined) this.ctx.lastSegmentType = ctx.lastSegmentType;
    if (ctx.lastSegmentPoi !== undefined) this.ctx.lastSegmentPoi = ctx.lastSegmentPoi;
    if (ctx.lastSegmentLat !== undefined) this.ctx.lastSegmentLat = ctx.lastSegmentLat;
    if (ctx.lastSegmentLng !== undefined) this.ctx.lastSegmentLng = ctx.lastSegmentLng;
    if (ctx.todayDistance !== undefined) this.ctx.todayDistance = ctx.todayDistance;
    if (ctx.todaySegCount !== undefined) this.ctx.todaySegCount = ctx.todaySegCount;
    if (ctx.footprintCount !== undefined) this.ctx.footprintCount = ctx.footprintCount;
    if (ctx.userName !== undefined) this.ctx.userName = ctx.userName;
    if (ctx.userCity !== undefined) this.ctx.userCity = ctx.userCity;
    if (ctx.userPreferences !== undefined) this.ctx.userPreferences = ctx.userPreferences;
  }

  // 确认词列表
  private static readonly YES: string[] = '是,对,好,行,可,嗯,确认,yes,y,ok,没错,对的,好的,行吧,可以,是的,对的对的,确认修改'.split(',');
  private static readonly NO: string[] = '否,不,别,错,取消,no,n,不对,不是,不要,算了,别改,不确认,错了,不对不对'.split(',');

  async process(msg: string): Promise<AgentReply> {
    const m: string = msg.trim();
    if (m.length === 0) return { text: '嗯？' };

    // ── 待确认状态 ──
    if (this.pending) {
      if (this.isYes(m)) return await this.applyPending();
      if (this.isNo(m)) { this.pending = null; return { text: '已取消。你想改哪一个？' }; }
      if (m.length <= 3) return { text: '你是说"是"还是"否"？' };
      // 用户说了别的内容 → 在待确认状态下重新分析（可能是换了一个目标）
      this.pending = null;
    }

    // ── 加载今日段 ──
    await this.loadRecentSegs();

    // ── 密钥设置 ──
    if (m.startsWith('密钥 ') || m.startsWith('key ') || m.startsWith('sk-')) {
      const key: string = m.replace(/^(密钥 |key )/, '').trim();
      const detected: string = ClaudeService.detectProvider(key);
      if (detected !== 'none') {
        await this.claude.setApiKey(key);
        const name: string = this.claude.providerName;
        return { text: `${name} API 密钥已保存！现在有网络时我会用 AI 来理解你的意图。` };
      }
      // 无法自动识别（如盘古 Bearer Token）
      if (m.includes('盘古') || m.includes('华为') || m.includes('pangu')) {
        await this.claude.setApiKey(key, 'pangu');
        return { text: '华为盘古密钥已保存！现在有网络时我会用 AI 来理解你的意图。' };
      }
      return {
        text: '密钥格式无法自动识别。请在"设置"页面手动选择服务商后保存。\n• Claude: sk-ant-xxx\n• DeepSeek: sk-xxx\n• 华为盘古: Bearer Token（去设置页保存）'
      };
    }

    // 每次对话前重新加载密钥（用户可能在设置页刚保存）
    await this.claude.loadApiKey(true);

    // ── 尝试 AI 在线模式（传全部天数据）──
    if (this.allSegs.length > 0) {
      let ctxInfo: string = `${this.ctx.footprintCount}足迹点 ${this.allSegs.length}个活动段（跨${new Set(this.dayForAllSegs).size}天）`;
      // 添加用户基础信息作为软引导
      if (this.ctx.userName) {
        ctxInfo += ` 用户:${this.ctx.userName}`;
      }
      if (this.ctx.userCity) {
        ctxInfo += ` 城市:${this.ctx.userCity}`;
      }
      if (this.ctx.userPreferences) {
        ctxInfo += ` 偏好:${this.ctx.userPreferences}(仅供参考,保持推荐多样性)`;
      }
      const cr: ClaudeReply = await this.claude.chat(m, this.allSegs, ctxInfo);
      if (cr.text.length > 0) {
        // 处理 AI 结构化响应
        if (cr.action === 'setKey' && cr.text.includes('密钥')) {
          // handled above
        }
        if (cr.action === 'confirm' && cr.segIndex && cr.segIndex > 0) {
          // 按 AI 返回的 dayKey 找段，找不到回退 allSegs
          const aiDayKey: string = cr.dayKey || getDayKey(Date.now());
          const daySegs: ActivitySegment[] = [];
          for (let i = 0; i < this.allSegs.length; i++) {
            if (this.dayForAllSegs[i] === aiDayKey) daySegs.push(this.allSegs[i]);
          }
          const localSegs: ActivitySegment[] = daySegs.length > 0 ? daySegs : this.allSegs;
          const idx: number = cr.segIndex - 1;
          if (idx >= localSegs.length) {
            this.lastAiText = cr.text;
            // fall through to local rules
          } else {
            const seg: ActivitySegment = localSegs[idx];
            this.pending = {
              segIndex: idx, seg,
              dayKey: aiDayKey,
              newType: cr.newType || undefined,
              newPoiName: cr.newPoiName || undefined
            };
            // 构建统一格式的确认消息
            const poi: string = seg.poiName || '未知地点';
            const oldLabel: string = TYPE_LABEL_REV[seg.activityType] || seg.activityType;
            const day: string = this.dayLabel(aiDayKey);
            let confirmText: string = `【确认修改】\n${day} 第${cr.segIndex}段：${oldLabel} @${poi}`;
            if (cr.newType) confirmText += `\n改为 → ${TYPE_LABEL_REV[cr.newType] || cr.newType}`;
            if (cr.newPoiName) confirmText += `\n改名为 → ${cr.newPoiName}`;
            confirmText += '\n\n回复"是"确认，"否"取消';
            return { text: confirmText };
          }
        }
        // 普通回复或包含 action
        if (cr.action === 'show_recs' || cr.action === 'refresh_timeline' || cr.action === 'switch_day') {
          return { text: cr.text, action: cr.action, actionParam: cr.actionParam };
        }

        // 工具调用：web_search, web_fetch, amap_search, get_weather
        const toolActions: string[] = ['web_search', 'web_fetch', 'amap_search', 'get_weather'];
        if (cr.action && toolActions.indexOf(cr.action) >= 0) {
          const toolResult: string = await this.executeTool(cr.action, cr.newPoiName || '', cr.newType || '',
            this.ctx.lastSegmentLat, this.ctx.lastSegmentLng);
          // 将结果反馈给 AI 再做一次推理
          const followUp: string = `工具执行结果：[${cr.action}]\n${toolResult}\n\n请基于以上结果回答用户。`;
          const cr2: ClaudeReply = await this.claude.chat(followUp, this.allSegs, ctxInfo);
          if (cr2.text.length > 0) {
            return { text: cr2.text, action: cr2.action, actionParam: cr2.actionParam };
          }
          return { text: toolResult };
        }

        // AI 返回了文字但没有结构化 action → 直接返回 AI 回复，不要再走本地规则
        return { text: cr.text };
      }
    }

    // ── AI 不可用 / 无结构化响应，走本地规则 ──
    if (this.todaySegs.length === 0) return { text: '今天还没有活动段。' };

    // ── 快速指令 ──
    if (m === '列表' || m === '活动' || m === '全部') return this.listSegs();
    if (this.includesAny(m, '帮助,怎么用,功能,?')) return this.helpText();
    if (this.includesAny(m, '你好,hi,嗨,嘿')) return { text: `你好！今天${this.ctx.todaySegCount}个活动段。说"列表"看看？` };
    if (this.includesAny(m, '推荐,附近,周边')) return { text: '已显示附近推荐。', action: 'show_recs' };
    if (this.includesAny(m, '刷新,更新,重新')) return { text: '已刷新。', action: 'refresh_timeline' };
    if (this.includesAny(m, '多少,多远,多久,统计,数据,汇总,今天走,今天跑,距离,总览')) {
      const km: string = (this.ctx.todayDistance / 1000).toFixed(1);
      return { text: `今日：${this.ctx.footprintCount}足迹点 | ${km}km | ${this.ctx.todaySegCount}个活动段` };
    }

    // ── 智能解析：找出目标段 + 操作 + 值 ──
    const intent: ParsedIntent = this.parseIntent(m);
    const match: PendingConfirmation | null = this.findSegmentAnyDay(intent.target);

    // 有明确操作但找不到匹配段 → 列出所有天可选段
    if (!match && (intent.action === 'retype' || intent.action === 'rename')) {
      let list: string = `找不到「${intent.target}」对应的活动段。最近有：\n`;
      let lastDay: string = '';
      for (let i = 0; i < this.allSegs.length; i++) {
        const dk: string = this.dayForAllSegs[i];
        if (dk !== lastDay) {
          list += `\n${this.dayLabel(dk)}：\n`;
          lastDay = dk;
        }
        const sameDay: ActivitySegment[] = [];
        for (let j = 0; j < this.allSegs.length; j++) {
          if (this.dayForAllSegs[j] === dk) sameDay.push(this.allSegs[j]);
        }
        const localIdx: number = sameDay.indexOf(this.allSegs[i]);
        list += `[${localIdx + 1}] ${this.describeSeg(this.allSegs[i], localIdx)}\n`;
      }
      list += '\n请用"昨天第1个改成Y"或"第X个改成Y"来指定。';
      return { text: list };
    }

    if (!match) {
      if (this.allSegs.length === 0) return { text: '还没有任何活动段。' };
      // 无目标 → 列出所有段
      let list: string = '请指定要修改的段。比如"昨天第1个改成购物"：\n';
      let lastDay: string = '';
      for (let i = 0; i < this.allSegs.length; i++) {
        const dk: string = this.dayForAllSegs[i];
        if (dk !== lastDay) { list += `\n${this.dayLabel(dk)}：\n`; lastDay = dk; }
        const sameDay: ActivitySegment[] = [];
        for (let j = 0; j < this.allSegs.length; j++) {
          if (this.dayForAllSegs[j] === dk) sameDay.push(this.allSegs[j]);
        }
        const localIdx: number = sameDay.indexOf(this.allSegs[i]);
        list += `[${localIdx + 1}] ${this.describeSeg(this.allSegs[i], localIdx)}\n`;
      }
      return { text: list };
    }

    const seg: ActivitySegment = match.seg;
    const dk: string = match.dayKey;
    const idx: number = match.segIndex;
    const day: string = this.dayLabel(dk);
    const desc: string = `${day} ${this.describeSeg(seg, idx)}`;
    // 临时诊断
    const diag: string = `[调试: target="${intent.target}" dayKey=${dk} allSegs=${this.allSegs.length}]`;

    // 查询模式
    if (intent.action === 'query') {
      return { text: `「${desc}」。你想改它的名字还是活动类型？` };
    }

    // 改名
    if (intent.action === 'rename' && intent.value.length > 0) {
      this.pending = { segIndex: idx, seg, dayKey: dk, newPoiName: intent.value };
      const poi: string = seg.poiName || '未知地点';
      return { text: `【确认修改】\n${day} 第${idx + 1}段：${poi}\n改名为 → ${intent.value}\n\n回复"是"确认，"否"取消\n${diag}` };
    }

    // 改类型
    if (intent.action === 'retype' && intent.value.length > 0) {
      const mapped: string = mapType(intent.value);
      if (!mapped) return { text: `"${intent.value}"我没理解。支持的：购物、吃饭、运动、工作、回家、通勤、休闲、旅游` };
      this.pending = { segIndex: idx, seg, dayKey: dk, newType: mapped };
      const poi: string = seg.poiName || '未知地点';
      const oldLabel: string = TYPE_LABEL_REV[seg.activityType] || seg.activityType;
      const newLabel: string = TYPE_LABEL_REV[mapped] || mapped;
      return { text: `【确认修改】\n${day} 第${idx + 1}段：${oldLabel} @${poi}\n改为 → ${newLabel}（${intent.value}）\n\n回复"是"确认，"否"取消\n${diag}` };
    }

    // 无明确操作 → 确认目标段
    return { text: `你是指「${desc}」吗？想改名还是改类型？比如"改成购物"或"叫万象城"。` };
  }

  // ─── 更灵活的意图解析 ───
  private static readonly ACTION_WORDS: string[] = '改成,改为,换成,修改为,修正为,应该是,应当是,其实是,我觉得是'.split(',');
  private static readonly RENAME_WORDS: string[] = '叫,是,名叫,应该叫,名字是,叫它,叫成,命名,称为'.split(',');

  private parseIntent(msg: string): ParsedIntent {
    let target: string = msg;
    let action: string = '';
    let value: string = '';

    // 找"把X改成Y" 模式
    if (msg.startsWith('把') || msg.startsWith('将')) {
      for (const aw of AiAgent.ACTION_WORDS) {
        const idx: number = msg.indexOf(aw);
        if (idx > 1) {
          target = msg.substring(1, idx).trim(); // 去掉"把"
          value = msg.substring(idx + aw.length).trim();
          action = 'retype';
          break;
        }
      }
    }

    // 找"X改成Y" 模式（无"把"）
    if (!action) {
      for (const aw of AiAgent.ACTION_WORDS) {
        const idx: number = msg.indexOf(aw);
        if (idx > 0) {
          target = msg.substring(0, idx).trim();
          value = msg.substring(idx + aw.length).trim();
          action = 'retype';
          break;
        }
      }
    }

    // 找"X叫Y" 模式（改名）
    if (!action) {
      for (const rw of AiAgent.RENAME_WORDS) {
        const idx: number = msg.indexOf(rw);
        if (idx > 0) {
          target = msg.substring(0, idx).trim();
          value = msg.substring(idx + rw.length).trim();
          // 排除 "X是什么" "X叫什么" 模式
          if (value.length === 0 || msg.includes('什么') || msg.includes('哪')) {
            action = 'query';
            value = '';
          } else {
            action = 'rename';
          }
          break;
        }
      }
    }

    // 纯查询
    if (!action && this.includesAny(msg, '是什么,叫什么,是哪个,哪一个,是什么活动')) {
      action = 'query';
    }

    return { target, action, value };
  }

  // ─── 辅助：字符串包含判断 ───
  private includesAny(text: string, csv: string): boolean {
    const items: string[] = csv.split(',');
    for (const item of items) { if (text.includes(item)) return true; }
    return false;
  }

  private isYes(m: string): boolean {
    const s: string = m.toLowerCase();
    for (const y of AiAgent.YES) { if (s === y) return true; }
    // 以这些词开头的短句
    if (s.length <= 4) {
      for (const y of ['是','对','好','行','嗯','ok','yes','y']) { if (s.startsWith(y)) return true; }
    }
    return false;
  }

  private isNo(m: string): boolean {
    const s: string = m.toLowerCase();
    for (const n of AiAgent.NO) { if (s === n) return true; }
    if (s.length <= 4) {
      for (const n of ['不','否','别','错','no','n']) { if (s.startsWith(n)) return true; }
    }
    return false;
  }

  private helpText(): AgentReply {
    let txt: string = '✅ v3 跨天模式\n\n用法：\n';
    txt += '• "列表" — 看所有天的段\n';
    txt += '• "昨天第1个改成购物"\n';
    txt += '• "前天第2个叫万象城"\n';
    txt += '• "今天第1个改成运动"\n';
    txt += `\n当前已加载 ${this.allSegs.length} 个段`;
    return { text: txt };
  }

  /** 解析日期偏移：昨天→1, 前天→2, 今天→0, 否则→-1 */
  private parseDayOffset(hint: string): number {
    if (hint.includes('前天') || hint.includes('大前天')) return hint.includes('大前天') ? 3 : 2;
    if (hint.includes('昨天')) return 1;
    if (hint.includes('今天')) return 0;
    return -1; // 未指定
  }

  /** 返回 { seg, dayKey, localIndex } | null */
  private findSegmentAnyDay(hint: string): PendingConfirmation | null {
    const dayOffset: number = this.parseDayOffset(hint);
    let candidates: ActivitySegment[] = [];
    let candidateDays: string[] = [];

    if (dayOffset >= 0) {
      // 限定某一天
      const targetDay: string = getDayKey(Date.now() - dayOffset * 86400000);
      for (let i = 0; i < this.allSegs.length; i++) {
        if (this.dayForAllSegs[i] === targetDay) {
          candidates.push(this.allSegs[i]);
          candidateDays.push(this.dayForAllSegs[i]);
        }
      }
    } else {
      // 全量搜索（优先今天）
      candidates = this.allSegs;
      candidateDays = this.dayForAllSegs;
    }

    if (candidates.length === 0) return null;

    // 去掉日期词后的纯 hint
    const cleanHint: string = hint.replace(/[昨今前大]天/g, '').trim();

    // 显式编号匹配
    const numMatch: RegExpMatchArray | null = cleanHint.match(/第?\s*(\d+)\s*个?/);
    if (numMatch) {
      const idx: number = parseInt(numMatch[1]) - 1;
      if (idx >= 0 && idx < candidates.length) {
        const dk: string = candidateDays[idx];
        // 找该段在其 day 内的序号
        const daySegs: ActivitySegment[] = [];
        for (let i = 0; i < this.allSegs.length; i++) {
          if (this.dayForAllSegs[i] === dk) daySegs.push(this.allSegs[i]);
        }
        const localIdx: number = daySegs.indexOf(candidates[idx]);
        return { segIndex: localIdx >= 0 ? localIdx : idx, seg: candidates[idx], dayKey: dk };
      }
    }

    // 内容匹配打分
    let bestIdx: number = -1;
    let bestScore: number = -1;
    for (let i = 0; i < candidates.length; i++) {
      const seg: ActivitySegment = candidates[i];
      let score: number = 0;

      const h: number = new Date(seg.startTime).getHours();
      if (cleanHint.includes('早上') && h >= 6 && h < 9) score += 3;
      if (cleanHint.includes('上午') && h >= 9 && h < 12) score += 3;
      if (cleanHint.includes('中午') && h >= 11 && h < 14) score += 3;
      if (cleanHint.includes('下午') && h >= 13 && h < 18) score += 3;
      if (cleanHint.includes('晚上') && h >= 19 && h < 23) score += 3;

      const hourMatch: RegExpMatchArray | null = cleanHint.match(/(\d{1,2})\s*[点:：]/);
      if (hourMatch) {
        const targetH: number = parseInt(hourMatch[1]);
        const diff: number = Math.abs(h - targetH);
        if (diff === 0) score += 5;
        else if (diff <= 1) score += 3;
        else if (diff <= 2) score += 1;
      }

      const poi: string = seg.poiName || '';
      if (poi.length > 0) {
        if (cleanHint.includes(poi)) score += 10;
        else {
          let charMatch: number = 0;
          for (let c = 0; c < poi.length; c++) { if (cleanHint.includes(poi[c])) charMatch++; }
          if (charMatch >= Math.max(2, poi.length * 0.5)) score += 6;
          else if (charMatch >= 1 && poi.length >= 3) score += 2;
        }
        const words: string[] = cleanHint.split(/[\s，。！？、的在了是]/);
        for (const w of words) { if (w.length >= 2 && poi.includes(w)) score += 4; }
      }

      const typeLabel: string = TYPE_LABEL_REV[seg.activityType] || seg.activityType;
      if (cleanHint.includes(seg.activityType) || cleanHint.includes(typeLabel)) score += 4;

      if (cleanHint.includes('最后') || cleanHint.includes('最新')) score += (i + 1);

      // 今天优先加权
      const today: string = getDayKey(Date.now());
      if (candidateDays[i] === today) score += 2;

      if (score > bestScore) { bestScore = score; bestIdx = i; }
    }

    if (bestScore <= 0 && candidates.length > 0 && cleanHint.length === 0) {
      bestIdx = candidates.length - 1; // 无目标词 → 默认最后
    }
    if (bestIdx < 0) return null;

    const dk: string = candidateDays[bestIdx];
    const daySegs: ActivitySegment[] = [];
    for (let i = 0; i < this.allSegs.length; i++) {
      if (this.dayForAllSegs[i] === dk) daySegs.push(this.allSegs[i]);
    }
    const localIdx: number = daySegs.indexOf(candidates[bestIdx]);
    return { segIndex: localIdx >= 0 ? localIdx : bestIdx, seg: candidates[bestIdx], dayKey: dk };
  }

  // ─── 确认执行 ───
  private async applyPending(): Promise<AgentReply> {
    if (!this.pending) return { text: '没有待确认的修改。' };
    const p: PendingConfirmation = this.pending;
    this.pending = null;

    try {
      const dayKey: string = p.dayKey || getDayKey(Date.now());
      const segs: ActivitySegment[] = await this.dao.queryActivitySegmentsByDay(dayKey);
      if (p.segIndex >= segs.length) return { text: '段已被删除，无法修改。' };

      const target: ActivitySegment = segs[p.segIndex];
      const calService: CalibrationService = CalibrationService.getInstance();

      // 1. 通过校准服务持久化修正（独立于 activity_segment 表，不惧覆盖）
      if (p.newType && p.newPoiName) {
        await calService.calibrateBoth(dayKey, target.startTime, p.newType, p.newPoiName,
          CalibrationSource.AI_AGENT, target.endTime);
      } else if (p.newType) {
        await calService.calibrateType(dayKey, target.startTime, p.newType,
          CalibrationSource.AI_AGENT, target.endTime);
      } else if (p.newPoiName) {
        await calService.calibratePoiName(dayKey, target.startTime, p.newPoiName,
          CalibrationSource.AI_AGENT, target.endTime);
      }

      // 2. 立即应用修改到 activity_segment（立即生效，不等下次分类周期）
      if (p.newType) {
        target.activityType = p.newType;
        target.summary = `${p.newType} · ${Math.round((target.endTime - target.startTime) / 60000)}分钟`;
      }
      if (p.newPoiName) {
        target.poiName = p.newPoiName;
      }
      await this.dao.updateActivitySegment(target);

      // 3. 刷新内存中的段数据
      await this.loadRecentSegs();

      const desc: string = this.describeSeg(target, p.segIndex);
      const day: string = this.dayLabel(dayKey);
      return { text: `已修改：${day} ${desc}`, action: 'segments_changed' };
    } catch (e) {
      return { text: '修改失败，请稍后再试。' };
    }
  }

  // ─── 辅助 ───
  private async loadRecentSegs(): Promise<void> {
    const todayKey: string = getDayKey(Date.now());
    this.todaySegs = await this.dao.queryActivitySegmentsByDay(todayKey);
    this.todaySegs.sort((a, b) => a.startTime - b.startTime);

    // 加载最近 14 天所有段
    this.allSegs = [];
    this.dayForAllSegs = [];
    for (let offset = 0; offset < 14; offset++) {
      const dk: string = getDayKey(Date.now() - offset * 24 * 60 * 60 * 1000);
      const segs: ActivitySegment[] = await this.dao.queryActivitySegmentsByDay(dk);
      for (const s of segs) {
        this.allSegs.push(s);
        this.dayForAllSegs.push(dk);
      }
    }
  }

  /** dayKey → 中文标签 */
  private dayLabel(dk: string): string {
    const today: string = getDayKey(Date.now());
    if (dk === today) return '今天';
    const yesterday: string = getDayKey(Date.now() - 86400000);
    if (dk === yesterday) return '昨天';
    const dby: string = getDayKey(Date.now() - 2 * 86400000);
    if (dk === dby) return '前天';
    // fallback: YYYYMMDD → M/D
    if (dk.length >= 8) {
      const m: string = parseInt(dk.substring(4, 6)).toString();
      const d: string = parseInt(dk.substring(6, 8)).toString();
      return `${m}/${d}`;
    }
    return dk;
  }

  private describeSeg(seg: ActivitySegment, idx: number): string {
    const typeLabel: string = TYPE_LABEL_REV[seg.activityType] || seg.activityType;
    const start: Date = new Date(seg.startTime);
    const end: Date = new Date(seg.endTime);
    const timeStr: string = `${start.getHours()}:${String(start.getMinutes()).padStart(2,'0')}-${end.getHours()}:${String(end.getMinutes()).padStart(2,'0')}`;
    const poi: string = seg.poiName ? ` @${seg.poiName}` : '';
    return `第${idx+1}段 ${typeLabel} ${timeStr}${poi}`;
  }

  private listSegs(): AgentReply {
    if (this.allSegs.length === 0) return { text: '还没有任何活动段。' };
    let txt: string = '✅ v3 最近活动段：\n';
    let lastDay: string = '';
    for (let i = 0; i < this.allSegs.length; i++) {
      const dk: string = this.dayForAllSegs[i];
      if (dk !== lastDay) { txt += `\n${this.dayLabel(dk)}：\n`; lastDay = dk; }
      const sameDay: ActivitySegment[] = [];
      for (let j = 0; j < this.allSegs.length; j++) {
        if (this.dayForAllSegs[j] === dk) sameDay.push(this.allSegs[j]);
      }
      const localIdx: number = sameDay.indexOf(this.allSegs[i]);
      txt += `[${localIdx + 1}] ${this.describeSeg(this.allSegs[i], localIdx)}\n`;
    }
    txt += '\n说"昨天第1个改成购物"来修改。';
    return { text: txt };
  }

  /** 执行工具调用并返回结果文本 */
  private async executeTool(action: string, query: string, keywords: string,
                            lat: number, lng: number): Promise<string> {
    const q: string = query || keywords || '';
    try {
      if (action === 'web_search') {
        return await this.webSearch(q);
      } else if (action === 'web_fetch') {
        return await this.webFetch(q);
      } else if (action === 'amap_search') {
        return await this.amapSearch(keywords || q, lat, lng);
      } else if (action === 'get_weather') {
        return await this.getWeather(q);
      }
    } catch (e) {
      return `工具执行失败，请稍后重试。`;
    }
    return `未知工具: ${action}`;
  }

  /** 网页搜索 — 使用 DuckDuckGo HTML 搜索（免费，无需 API Key） */
  private async webSearch(queryStr: string): Promise<string> {
    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(
        `https://lite.duckduckgo.com/lite/?q=${encodeURI(queryStr)}`,
        { method: 'GET', connectTimeout: 5000, readTimeout: 8000 }
      );
      if (resp.responseCode === 200) {
        // 简单提取标题和链接
        const html: string = resp.result;
        const results: string[] = [];
        const linkRegex = /<a[^>]*href="([^"]*)"[^>]*>([^<]*)<\/a>/gi;
        let count: number = 0;
        let matchArr: string[] | null = linkRegex.exec(html) as string[] | null;
        while (matchArr !== null && count < 5) {
          const url: string = matchArr[1] || '';
          const title: string = matchArr[2] || '';
          if (!url.startsWith('//') && title.trim().length > 3) {
            results.push(`${title.trim()}`);
            count++;
          }
          matchArr = linkRegex.exec(html) as string[] | null;
        }
        if (results.length > 0) {
          return `搜索"${queryStr}"结果:\n${results.map((r, i) => `${i + 1}. ${r}`).join('\n')}`;
        }
        return `未找到"${queryStr}"的相关结果。`;
      }
      return `搜索请求失败(${resp.responseCode})`;
    } catch (e) {
      return `网页搜索暂时不可用。`;
    }
  }

  /** 网页抓取 */
  private async webFetch(url: string): Promise<string> {
    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(url,
        { method: 'GET', connectTimeout: 5000, readTimeout: 10000 }
      );
      if (resp.responseCode === 200) {
        // 简单提取文本（去掉 HTML 标签）
        const text: string = resp.result.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
        return text.substring(0, 1500) + (text.length > 1500 ? '...[已截断]' : '');
      }
      return `网页获取失败(${resp.responseCode})`;
    } catch (e) {
      return `网页获取失败。`;
    }
  }

  /** 高德周边搜索 */
  private async amapSearch(keywordsStr: string, lat: number, lng: number): Promise<string> {
    try {
      const searchService: AmapSearchService = AmapSearchService.getInstance();
      const pois = await searchService.nearbySearch(keywordsStr, lat, lng, 3000);
      if (pois.length > 0) {
        return `📍 在你常活动区域搜"${keywordsStr}"：\n${pois.slice(0, 5).map((p, i) =>
          `${i + 1}. ${p.name} (${p.type || ''}) — ${p.address || ''}`
        ).join('\n')}`;
      }
      return `📍 在你常活动区域未找到"${keywordsStr}"。`;
    } catch (e) {
      return `周边搜索暂时不可用。`;
    }
  }

  /** 天气查询 */
  private async getWeather(cityName: string): Promise<string> {
    try {
      const bridge: PlatformBridge = PlatformBridge.getInstance();
      // 使用高德天气 API（免费）
      const weatherKey: string = 'fc2c6f05fd1c51af417ddb1aa4f0aec3';
      // 先获取城市 adcode
      const geoUrl: string = `https://restapi.amap.com/v3/config/district?key=${weatherKey}&keywords=${encodeURI(cityName)}&subdistrict=0`;
      const geoResp: HttpResponse = await bridge.network.request(geoUrl,
        { method: 'GET', connectTimeout: 5000, readTimeout: 8000 }
      );
      let adcode: string = '';
      if (geoResp.responseCode === 200) {
        const geoData: Record<string, Object> = JSON.parse(geoResp.result) as Record<string, Object>;
        const districts: Object[] = (geoData['districts'] as Object[]) || [];
        if (districts.length > 0) {
          const d: Record<string, Object> = districts[0] as Record<string, Object>;
          adcode = (d['adcode'] as string) || '';
        }
      }
      if (!adcode) {
        return `未找到城市"${cityName}"。`;
      }
      const weatherUrl: string = `https://restapi.amap.com/v3/weather/weatherInfo?key=${weatherKey}&city=${adcode}&extensions=base`;
      const wResp: HttpResponse = await bridge.network.request(weatherUrl,
        { method: 'GET', connectTimeout: 5000, readTimeout: 8000 }
      );
      if (wResp.responseCode === 200) {
        const wData: Record<string, Object> = JSON.parse(wResp.result) as Record<string, Object>;
        const lives: Object[] = (wData['lives'] as Object[]) || [];
        if (lives.length > 0) {
          const live: Record<string, Object> = lives[0] as Record<string, Object>;
          return `${live['province'] || ''}${live['city'] || ''}: ${live['weather'] || ''}, ${live['temperature'] || ''}°C, ${live['winddirection'] || ''}风${live['windpower'] || ''}级, 湿度${live['humidity'] || ''}%`;
        }
      }
      return `天气查询失败。`;
    } catch (e) {
      return `天气查询暂时不可用。`;
    }
  }
}
