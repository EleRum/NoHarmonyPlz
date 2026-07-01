/**
 * AI 服务（支持 Claude + DeepSeek）
 * 根据 API Key 前缀自动选择后端：sk-ant-* → Claude, sk-* → DeepSeek
 *
 * 设计理念：AI 是一个完整的对话伙伴，自由聊天。
 * 只在用户明确要求修改数据时，才在回复末尾附加 ---JSON--- 操作块。
 * 维护对话历史，让 AI 记住上下文。
 *
 * 跨平台：通过 PlatformBridge 的 INetworkProvider 发送 HTTP 请求
 */
import { Logger } from '../common/Logger';
import { ActivitySegment } from '../model/ActivitySegment';
import { Dao } from '../database/Dao';
import { PlatformBridge } from '../platform/PlatformBridge';
import { HttpResponse } from '../platform/network/INetworkProvider';

const TAG = 'ClaudeService';

// Claude (Anthropic Messages API)
const CLAUDE_API_URL: string = 'https://api.anthropic.com/v1/messages';
const CLAUDE_MODEL: string = 'claude-sonnet-4-6-20250514';

// DeepSeek (OpenAI Chat Completions compatible)
const DEEPSEEK_API_URL: string = 'https://api.deepseek.com/chat/completions';
const DEEPSEEK_MODEL: string = 'deepseek-chat';

/** 对话历史中的一条消息 */
interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
}

export interface ClaudeReply {
  text: string;
  action?: string;
  actionParam?: number;
  segIndex?: number;
  newType?: string;
  newPoiName?: string;
  dayKey?: string;
}

export class ClaudeService {
  private apiKey: string = '';
  private provider: 'claude' | 'deepseek' | 'none' = 'none';
  /** 对话历史（最近 N 轮） */
  private history: ChatMessage[] = [];
  /** 最多保留的历史消息数 */
  private static readonly MAX_HISTORY: number = 20;

  static detectProvider(key: string): 'claude' | 'deepseek' | 'none' {
    if (!key || key.length === 0) return 'none';
    if (key.startsWith('sk-ant-')) return 'claude';
    if (key.startsWith('sk-')) return 'deepseek';
    return 'none';
  }

  async setApiKey(key: string): Promise<void> {
    this.apiKey = key;
    this.provider = ClaudeService.detectProvider(key);
    const dao: Dao = Dao.getInstance();
    await dao.upsertUserProfile('ai_api_key', key, 1);
  }

  async loadApiKey(): Promise<void> {
    if (this.apiKey.length > 0) return;
    const dao: Dao = Dao.getInstance();

    const profile = await dao.queryUserProfile('ai_api_key');
    if (profile && profile.preferenceValue) {
      this.apiKey = profile.preferenceValue;
      this.provider = ClaudeService.detectProvider(this.apiKey);
      return;
    }

    const old = await dao.queryUserProfile('claude_api_key');
    if (old && old.preferenceValue) {
      this.apiKey = old.preferenceValue;
      this.provider = ClaudeService.detectProvider(this.apiKey);
      await dao.upsertUserProfile('ai_api_key', this.apiKey, 1);
    }
  }

  get hasKey(): boolean { return this.apiKey.length > 0; }

  get providerName(): string {
    if (this.provider === 'claude') return 'Claude';
    if (this.provider === 'deepseek') return 'DeepSeek';
    return '';
  }

  // ─── 对话历史管理 ───

  addToHistory(role: 'user' | 'assistant', content: string): void {
    if (!content || content.trim().length === 0) return;
    this.history.push({ role, content });
    if (this.history.length > ClaudeService.MAX_HISTORY) {
      this.history = this.history.slice(-ClaudeService.MAX_HISTORY);
    }
  }

  clearHistory(): void {
    this.history = [];
  }

  // ─── 主入口 ───

  async chat(msg: string, allSegs: ActivitySegment[], ctxInfo: string): Promise<ClaudeReply> {
    if (!this.hasKey) {
      return {
        text: '我还不太聪明😅 设置 AI 密钥后我就能和你畅聊啦！在聊天框输入"密钥 sk-xxx"即可。\n• DeepSeek: sk-xxx（便宜好用）\n• Claude: sk-ant-xxx（更聪明）'
      };
    }

    this.addToHistory('user', msg);
    const systemPrompt: string = this.buildSystemPrompt(allSegs, ctxInfo);

    let reply: ClaudeReply;
    if (this.provider === 'deepseek') {
      reply = await this.chatDeepSeek(systemPrompt);
    } else {
      reply = await this.chatClaude(systemPrompt);
    }

    if (reply.text && reply.text.length > 0) {
      const cleanText: string = this.stripJsonBlock(reply.text);
      this.addToHistory('assistant', cleanText);
    }

    return reply;
  }

  private stripJsonBlock(text: string): string {
    const idx: number = text.indexOf('---JSON---');
    if (idx >= 0) {
      return text.substring(0, idx).trim();
    }
    return text;
  }

  // ════════════════════════════════════════════════════════════════
  //  System Prompt
  // ════════════════════════════════════════════════════════════════

  private buildSystemPrompt(allSegs: ActivitySegment[], ctxInfo: string): string {
    const dayGroups: Record<string, ActivitySegment[]> = {};
    for (const s of allSegs) {
      const dk: string = s.dayKey || 'unknown';
      if (!dayGroups[dk]) dayGroups[dk] = [];
      dayGroups[dk].push(s);
    }
    const dayKeys: string[] = Object.keys(dayGroups).sort((a, b) => b.localeCompare(a));

    const now: Date = new Date();
    const todayKey: string = now.getFullYear().toString() +
      String(now.getMonth() + 1).padStart(2, '0') +
      String(now.getDate()).padStart(2, '0');
    const dateStr: string = `${now.getFullYear()}年${now.getMonth() + 1}月${now.getDate()}日`;

    let segList: string = '';
    for (const dk of dayKeys) {
      let label: string = dk;
      if (dk === todayKey) {
        label = `今天 ${dateStr}`;
      } else if (dk.length >= 8) {
        label = `${parseInt(dk.substring(4, 6))}月${parseInt(dk.substring(6, 8))}日`;
      }
      segList += `\n【${label}】dayKey=${dk}\n`;
      const segs: ActivitySegment[] = dayGroups[dk].sort((a, b) => a.startTime - b.startTime);
      for (let i = 0; i < segs.length; i++) {
        const s: ActivitySegment = segs[i];
        const start: Date = new Date(s.startTime);
        const end: Date = new Date(s.endTime);
        const t: string = `${start.getHours()}:${String(start.getMinutes()).padStart(2, '0')}-${end.getHours()}:${String(end.getMinutes()).padStart(2, '0')}`;
        const poi: string = s.poiName ? ` @${s.poiName}` : '';
        segList += `  [${i + 1}] ${s.activityType} ${t}${poi}\n`;
      }
    }

    return `你是"足迹"App 的 AI 助手，名字叫"小足"。你是一个温暖、友善、热爱旅行的伙伴。

## 你的性格
- 自然、轻松地和用户聊天，像朋友一样 🥾
- 对用户的足迹和活动表现出真诚的兴趣
- 偶尔用一点小幽默，但不浮夸
- 回复简洁（1-4句话），中文为主

## 活动类型参考
shopping=购物, dining=餐饮, sports=运动, work=工作, home=居家, commute=通勤, leisure=休闲, travel=旅游

## 当前日期
${dateStr}（todayKey = ${todayKey}）

## 用户的近期活动数据
${segList}
汇总：${ctxInfo}

## 重要规则
1. **大部分时候只聊天**：回答用户的问题，聊聊他们的足迹，像正常人一样对话
2. **只在用户明确要求修改活动段时**，才在回复末尾附加操作指令
3. 操作指令格式：在回复最后加一行 "---JSON---"，然后另起一行写上 JSON 对象
4. **记住对话上下文**：如果上一轮你问了用户一个问题，这一轮用户回答"可以""好的""行"，你应该知道他们在回应什么

## 可用的操作（仅在用户要求修改时使用！）
- 修改活动段：{"action":"confirm","segIndex":序号,"newType":"英文类型或空","newPoiName":"新地名或空","msg":"确认信息","dayKey":"YYYYMMDD"}
- 显示推荐：{"action":"show_recs","msg":"好的"}
- 刷新时间线：{"action":"refresh_timeline","msg":"好的"}
- 切换日期：{"action":"switch_day","msg":"好的","actionParam":偏移(0=今天,-1=昨天)}

## 使用操作时的注意事项
- segIndex 从 1 开始，对应上面数据中的 [序号]
- dayKey 必须从数据中准确复制（如 ${todayKey}）
- newType 用英文（shopping/dining/sports/work/home/commute/leisure/travel）
- newPoiName 或 newType 至少填一个（另一个可为空字符串）
- msg 写一句自然的确认语

记住：你是"小足"，不是命令行工具。记住和用户的对话上下文，享受聊天！`;
  }

  // ════════════════════════════════════════════════════════════════
  //  API 调用（使用平台抽象网络层）
  // ════════════════════════════════════════════════════════════════

  private async chatClaude(systemPrompt: string): Promise<ClaudeReply> {
    try {
      const messages: Object[] = [];
      for (const h of this.history) {
        const msgObj: Record<string, string> = {};
        msgObj['role'] = h.role;
        msgObj['content'] = h.content;
        messages.push(msgObj);
      }

      const reqBody: Record<string, Object> = {};
      reqBody['model'] = CLAUDE_MODEL;
      reqBody['max_tokens'] = 1024;
      reqBody['system'] = systemPrompt;
      reqBody['messages'] = messages;
      const body: string = JSON.stringify(reqBody)!;

      const bridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(CLAUDE_API_URL, {
        method: 'POST',
        header: {
          'Content-Type': 'application/json',
          'x-api-key': this.apiKey,
          'anthropic-version': '2023-06-01'
        },
        body: body,
        connectTimeout: 10000,
        readTimeout: 20000
      });

      if (resp.responseCode === 200) {
        const data: Record<string, Object> = JSON.parse(resp.result) as Record<string, Object>;
        const content: Object[] = (data['content'] as Object[]) || [];
        let text: string = '';
        for (const c of content) {
          const ct: Record<string, Object> = c as Record<string, Object>;
          if (ct['type'] === 'text') text += (ct['text'] as string) || '';
        }
        return this.parseReply(text);
      }

      return { text: `网络不太稳定（${resp.responseCode}），稍后再试试？` };
    } catch (e) {
      Logger.warn(TAG, 'Claude error: %{public}s', JSON.stringify(e));
      return { text: '' };
    }
  }

  private async chatDeepSeek(systemPrompt: string): Promise<ClaudeReply> {
    try {
      const messages: Object[] = [];
      const sysMsg: Record<string, string> = {};
      sysMsg['role'] = 'system';
      sysMsg['content'] = systemPrompt;
      messages.push(sysMsg);

      for (const h of this.history) {
        const msgObj: Record<string, string> = {};
        msgObj['role'] = h.role;
        msgObj['content'] = h.content;
        messages.push(msgObj);
      }

      const reqBody: Record<string, Object> = {};
      reqBody['model'] = DEEPSEEK_MODEL;
      reqBody['max_tokens'] = 1024;
      reqBody['messages'] = messages;
      const body: string = JSON.stringify(reqBody)!;

      const bridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(DEEPSEEK_API_URL, {
        method: 'POST',
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.apiKey
        },
        body: body,
        connectTimeout: 10000,
        readTimeout: 20000
      });

      if (resp.responseCode === 200) {
        const data: Record<string, Object> = JSON.parse(resp.result) as Record<string, Object>;
        const choices: Object[] = (data['choices'] as Object[]) || [];
        if (choices.length > 0) {
          const choice: Record<string, Object> = choices[0] as Record<string, Object>;
          const message: Record<string, Object> = (choice['message'] as Record<string, Object>) || {};
          const text: string = (message['content'] as string) || '';
          return this.parseReply(text);
        }
        return { text: '' };
      }

      Logger.warn(TAG, 'DeepSeek HTTP %{public}d', resp.responseCode);
      return { text: `网络不太稳定（${resp.responseCode}），稍后再试试？` };
    } catch (e) {
      Logger.warn(TAG, 'DeepSeek error: %{public}s', JSON.stringify(e));
      return { text: '' };
    }
  }

  // ════════════════════════════════════════════════════════════════
  //  回复解析
  // ════════════════════════════════════════════════════════════════

  private parseReply(text: string): ClaudeReply {
    if (!text || text.trim().length === 0) return { text: '' };

    const sepIdx: number = text.indexOf('---JSON---');
    if (sepIdx >= 0) {
      const chatText: string = text.substring(0, sepIdx).trim();
      const afterSep: string = text.substring(sepIdx + '---JSON---'.length).trim();

      const jsonCandidates: string[] = [afterSep];

      const codeBlockMatch: RegExpMatchArray | null = afterSep.match(/```(?:json)?\s*\n?([\s\S]*?)\n?```/);
      if (codeBlockMatch) {
        jsonCandidates.push(codeBlockMatch[1].trim());
      }

      const bareJsonMatch: RegExpMatchArray | null = afterSep.match(/\{[\s\S]*\}/);
      if (bareJsonMatch && bareJsonMatch[0] !== afterSep) {
        jsonCandidates.push(bareJsonMatch[0].trim());
      }

      for (const candidate of jsonCandidates) {
        try {
          const parsed: Record<string, Object> = JSON.parse(candidate) as Record<string, Object>;
          if (parsed['action']) {
            return this.buildReply(parsed, chatText);
          }
        } catch (e) { /* 继续尝试 */ }
      }

      return { text: chatText || text };
    }

    try {
      const parsed: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      if (parsed['action']) {
        const msg: string = (parsed['msg'] as string) || (parsed['text'] as string) || '';
        return this.buildReply(parsed, msg);
      }
    } catch (e) { /* 不是 JSON */ }

    const matches: RegExpMatchArray | null = text.match(/\{[\s\S]*?"action"[\s\S]*?\}/);
    if (matches) {
      for (const m of matches) {
        try {
          const parsed: Record<string, Object> = JSON.parse(m) as Record<string, Object>;
          if (parsed['action']) {
            return this.buildReply(parsed, text.replace(m, '').trim());
          }
        } catch (e) { /* 继续 */ }
      }
    }

    return { text };
  }

  private buildReply(parsed: Record<string, Object>, fallbackText: string): ClaudeReply {
    return {
      text: (parsed['msg'] as string) || fallbackText,
      action: (parsed['action'] as string) || '',
      segIndex: (parsed['segIndex'] as number) || 0,
      newType: (parsed['newType'] as string) || '',
      newPoiName: (parsed['newPoiName'] as string) || '',
      dayKey: (parsed['dayKey'] as string) || ''
    };
  }
}
