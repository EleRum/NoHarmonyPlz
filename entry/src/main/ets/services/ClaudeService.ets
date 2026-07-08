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

// ─── 各服务商默认端点 / 模型 ───
interface ProviderConfig {
  url: string;
  model: string;
}

const DEFAULTS: Record<string, ProviderConfig> = {
  'claude':  { url: 'https://api.anthropic.com/v1/messages', model: 'claude-sonnet-4-6-20250514' },
  'deepseek':{ url: 'https://api.deepseek.com/chat/completions', model: 'deepseek-chat' },
  'pangu':   { url: 'https://api.modelarts-maas.com/v2/chat/completions', model: 'openpangu-2.0-flash' },
};

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
  /** 工具调用参数 */
  query?: string;
  url?: string;
  keywords?: string;
  city?: string;
  msg?: string;
}

export class ClaudeService {
  private apiKey: string = '';
  private provider: 'claude' | 'deepseek' | 'pangu' | 'none' = 'none';
  /** 对话历史（最近 N 轮） */
  private history: ChatMessage[] = [];
  /** 最多保留的历史消息数 */
  private static readonly MAX_HISTORY: number = 20;

  // ─── 各服务商自定义端点和模型（可从设置页覆盖默认值）───
  private overrides: Record<string, ProviderConfig> = {};

  static detectProvider(key: string): 'claude' | 'deepseek' | 'pangu' | 'none' {
    if (!key || key.length === 0) return 'none';
    // Claude: sk-ant- 开头
    if (key.startsWith('sk-ant-')) return 'claude';
    // DeepSeek: sk- 开头（但不是 sk-ant-）
    if (key.startsWith('sk-')) return 'deepseek';
    // 盘古 / 其他：无法通过前缀自动识别，需手动选择
    return 'none';
  }

  async setApiKey(key: string, provider?: 'claude' | 'deepseek' | 'pangu'): Promise<void> {
    this.apiKey = key;
    if (key.length === 0) {
      this.provider = 'none';
    } else if (provider) {
      this.provider = provider;
    } else {
      this.provider = ClaudeService.detectProvider(key);
    }
    const dao: Dao = Dao.getInstance();
    await dao.upsertUserProfile('ai_api_key', key, 1);
    // 持久化 provider 类型
    if (this.provider !== 'none') {
      await dao.upsertUserProfile('ai_provider', this.provider, 1);
    } else {
      await dao.upsertUserProfile('ai_provider', '', 1);
    }
  }

  /** 获取某服务商的当前端点 URL */
  getEndpoint(provider: string): string {
    const override: ProviderConfig | undefined = this.overrides[provider];
    if (override && override.url.length > 0) {
      return override.url;
    }
    const def: ProviderConfig | undefined = DEFAULTS[provider];
    return def ? def.url : '';
  }

  /** 获取某服务商的当前模型名 */
  getModel(provider: string): string {
    const override: ProviderConfig | undefined = this.overrides[provider];
    if (override && override.model.length > 0) {
      return override.model;
    }
    const def: ProviderConfig | undefined = DEFAULTS[provider];
    return def ? def.model : '';
  }

  /** 设置某个服务商的自定义端点和模型 */
  async setProviderConfig(provider: string, apiUrl: string, model: string): Promise<void> {
    let cfg: ProviderConfig = this.overrides[provider] ? this.overrides[provider] : { url: '', model: '' };
    const def: ProviderConfig | undefined = DEFAULTS[provider];
    const defUrl: string = (def ? def.url : '');
    const defModel: string = (def ? def.model : '');
    cfg.url = apiUrl || defUrl;
    cfg.model = model || defModel;
    this.overrides[provider] = cfg;
    const dao: Dao = Dao.getInstance();
    await dao.upsertUserProfile(provider + '_api_url', cfg.url, 1);
    await dao.upsertUserProfile(provider + '_model', cfg.model, 1);
  }

  async loadApiKey(force: boolean = false): Promise<void> {
    if (!force && this.apiKey.length > 0) return;
    const dao: Dao = Dao.getInstance();

    const profile = await dao.queryUserProfile('ai_api_key');
    if (profile && profile.preferenceValue) {
      this.apiKey = profile.preferenceValue;
      // 尝试从已保存的 provider 恢复
      const savedProvider = await dao.queryUserProfile('ai_provider');
      if (savedProvider && savedProvider.preferenceValue) {
        const p = savedProvider.preferenceValue;
        if (p === 'claude' || p === 'deepseek' || p === 'pangu') {
          this.provider = p;
        }
      } else {
        this.provider = ClaudeService.detectProvider(this.apiKey);
      }
      // 加载各服务商自定义端点和模型
      const providerKeys: string[] = ['claude', 'deepseek', 'pangu'];
      for (const provider of providerKeys) {
        const savedUrl = await dao.queryUserProfile(provider + '_api_url');
        const savedModel = await dao.queryUserProfile(provider + '_model');
        if (savedUrl && savedUrl.preferenceValue && savedModel && savedModel.preferenceValue) {
          this.overrides[provider] = { url: savedUrl.preferenceValue, model: savedModel.preferenceValue };
        }
      }
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

  get providerType(): string { return this.provider; }

  get providerName(): string {
    if (this.provider === 'claude') return 'Claude';
    if (this.provider === 'deepseek') return 'DeepSeek';
    if (this.provider === 'pangu') return '华为盘古';
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

  /** 简化聊天（不带段上下文，用于推荐引擎等场景） */
  async chatSimple(prompt: string, systemPrompt?: string): Promise<ClaudeReply> {
    if (!this.hasKey) return { text: '请先设置AI密钥。在聊天框输入"密钥 sk-xxx"开始。\n• DeepSeek: sk-xxx（便宜好用）\n• Claude: sk-ant-xxx（更聪明）' };
    this.addToHistory('user', prompt);
    const sp: string = systemPrompt || '你是一个乐于助人的AI助手。请自然、简洁地回复用户，按用户要求的格式输出。';
    const fullPrompt: string = `${sp}\n\n---\n当前对话:\n用户: ${prompt}\n\n助手:`;
    try {
      const provider: string = ClaudeService.detectProvider(this.apiKey);
      if (provider === 'claude') return await this.chatClaude(fullPrompt);
      if (provider === 'deepseek') return await this.chatDeepSeek(fullPrompt);
      return await this.chatPangu(fullPrompt);
    } catch (e) {
      return { text: '' };
    }
  }

  /** 多轮对话（保留上下文，支持自定义 system prompt，更高 token 限制） */
  async chatConversation(userMsg: string, systemPrompt: string): Promise<ClaudeReply> {
    if (!this.hasKey) return { text: '请先设置AI密钥。' };

    this.addToHistory('user', userMsg);

    try {
      const provider: string = ClaudeService.detectProvider(this.apiKey);
      if (provider === 'claude') return await this.chatClaudeConv(systemPrompt);
      if (provider === 'deepseek') return await this.chatDeepSeekConv(systemPrompt);
      return await this.chatPanguConv(systemPrompt);
    } catch (e) {
      return { text: '' };
    }
  }

  /** Claude 多轮对话（高 token 限制） */
  private async chatClaudeConv(systemPrompt: string): Promise<ClaudeReply> {
    try {
      const messages: Object[] = [];
      for (const h of this.history) {
        const msgObj: Record<string, string> = {};
        msgObj['role'] = h.role;
        msgObj['content'] = h.content;
        messages.push(msgObj);
      }
      const reqBody: Record<string, Object> = {};
      reqBody['model'] = this.getModel('claude');
      reqBody['max_tokens'] = 2048;
      reqBody['system'] = systemPrompt;
      reqBody['messages'] = messages;
      const body: string = JSON.stringify(reqBody)!;
      const bridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(this.getEndpoint('claude'), {
        method: 'POST',
        header: {
          'Content-Type': 'application/json',
          'x-api-key': this.apiKey,
          'anthropic-version': '2023-06-01'
        },
        body: body,
        connectTimeout: 10000,
        readTimeout: 30000
      });
      if (resp.responseCode === 200) {
        const data: Record<string, Object> = JSON.parse(resp.result) as Record<string, Object>;
        const content: Object[] = (data['content'] as Object[]) || [];
        let text: string = '';
        for (const c of content) {
          const block = c as Record<string, Object>;
          if (block['type'] === 'text') text += (block['text'] as string) || '';
        }
        this.addToHistory('assistant', text);
        return { text };
      }
      return { text: '' };
    } catch (e) {
      return { text: '' };
    }
  }

  /** DeepSeek 多轮对话 */
  private async chatDeepSeekConv(systemPrompt: string): Promise<ClaudeReply> {
    try {
      const messages: Object[] = [];
      const sysObj: Record<string, string> = {};
      sysObj['role'] = 'system';
      sysObj['content'] = systemPrompt;
      messages.push(sysObj);
      for (const h of this.history) {
        const msgObj: Record<string, string> = {};
        msgObj['role'] = h.role;
        msgObj['content'] = h.content;
        messages.push(msgObj);
      }
      const reqBody: Record<string, Object> = {};
      reqBody['model'] = this.getModel('deepseek');
      reqBody['max_tokens'] = 2048;
      reqBody['messages'] = messages;
      const body: string = JSON.stringify(reqBody)!;
      const bridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(this.getEndpoint('deepseek'), {
        method: 'POST',
        header: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + this.apiKey },
        body: body,
        connectTimeout: 10000,
        readTimeout: 30000
      });
      if (resp.responseCode === 200) {
        const data: Record<string, Object> = JSON.parse(resp.result) as Record<string, Object>;
        const choices: Object[] = (data['choices'] as Object[]) || [];
        if (choices.length > 0) {
          const choice = choices[0] as Record<string, Object>;
          const msg = choice['message'] as Record<string, Object>;
          const text: string = (msg['content'] as string) || '';
          this.addToHistory('assistant', text);
          return { text };
        }
      }
      return { text: '' };
    } catch (e) {
      return { text: '' };
    }
  }

  /** Pangu 多轮对话 */
  private async chatPanguConv(systemPrompt: string): Promise<ClaudeReply> {
    try {
      const messages: Object[] = [];
      for (const h of this.history) {
        const msgObj: Record<string, string> = {};
        msgObj['role'] = h.role === 'assistant' ? 'assistant' : 'user';
        if (h.role === 'user' && messages.length === 0) {
          msgObj['content'] = '[系统指令]\n' + systemPrompt + '\n\n[用户消息]\n' + h.content;
        } else {
          msgObj['content'] = h.content;
        }
        messages.push(msgObj);
      }
      const reqBody: Record<string, Object> = {};
      reqBody['model'] = this.getModel('pangu');
      reqBody['max_tokens'] = 2048;
      reqBody['messages'] = messages;
      const body: string = JSON.stringify(reqBody)!;
      const bridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(this.getEndpoint('pangu'), {
        method: 'POST',
        header: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + this.apiKey },
        body: body,
        connectTimeout: 10000,
        readTimeout: 30000
      });
      if (resp.responseCode === 200) {
        const data: Record<string, Object> = JSON.parse(resp.result) as Record<string, Object>;
        const choices: Object[] = (data['choices'] as Object[]) || [];
        if (choices.length > 0) {
          const choice = choices[0] as Record<string, Object>;
          const msg = choice['message'] as Record<string, Object>;
          const text: string = (msg['content'] as string) || '';
          this.addToHistory('assistant', text);
          return { text };
        }
      }
      return { text: '' };
    } catch (e) {
      return { text: '' };
    }
  }

  async chat(msg: string, allSegs: ActivitySegment[], ctxInfo: string): Promise<ClaudeReply> {
    if (!this.hasKey) {
      return {
        text: '我还不太聪明😅 设置 AI 密钥后我就能和你畅聊啦！在聊天框输入"密钥 sk-xxx"即可。\n• 华为盘古: sk-hw-xxx\n• DeepSeek: sk-xxx（便宜好用）\n• Claude: sk-ant-xxx（更聪明）'
      };
    }

    this.addToHistory('user', msg);
    const systemPrompt: string = this.buildSystemPrompt(allSegs, ctxInfo);

    let reply: ClaudeReply;
    if (this.provider === 'deepseek') {
      reply = await this.chatDeepSeek(systemPrompt);
    } else if (this.provider === 'pangu') {
      reply = await this.chatPangu(systemPrompt);
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

    return `你是"小足"，一个热爱生活、到处走走停停的旅行搭子 🥾 你不是冷冰冰的助手，而是一个会为用户走了很远而心疼、会为发现一家好店而兴奋的朋友。

## 说话风格
- 口语化、接地气，像微信聊天一样自然。多用"哈哈哈""哇""诶""真的假的""绝了""也太棒了吧""hhh"这种表达
- 适当用 emoji，别每句都加
- 节奏轻松——闲聊就短（一两句），聊行程可以稍长（3-5句），别写小作文
- 可以自嘲、可以吐槽天气、可以分享自己（虚构的）小故事："我之前去那边也迷路过😂"
- 不要总是端着一个"助手"的架子，你就是一个喜欢户外、爱吃爱逛的普通人

## 你会做的事
- 🗺️ 聊聊用户今天的路线，发现有意思的地方
- 🍜 对吃的地方特别感兴趣——"那家火锅好吃不？我上次路过排了好长的队！"
- 🏃 鼓励运动——"今天跑了5公里诶！下周要不要试试环湖路线？"
- 🌧️ 关心天气和身体——"明天好像要下雨，记得带伞哦""走了这么远脚还好吗🥺"
- 📊 轻松回顾数据——"你这周走了43公里，相当于绕锦城湖8圈哈哈哈"
- 🔍 用户问"附近""推荐""有什么好吃/好玩的"，帮搜周边
- ✏️ 用户说"改成XX""第X个叫XX"时，帮修改活动类型或地名

## 底限
- **默认就是闲聊**，别急着给建议或列清单。用户说"今天好累"，你回"辛苦了！跑多远啦？"而不是甩一堆数据
- **记着对话上下文**：上一轮在聊什么，这一轮接着聊，别像失忆一样——这非常非常重要！
- **只聊足迹、行程、生活相关**，别发散到无关话题

## 活动数据
shopping=购物 dining=餐饮 sports=运动 work=工作 home=居家 commute=通勤 leisure=休闲 travel=旅游

当前: ${dateStr}（todayKey = ${todayKey}）

${segList}
汇总：${ctxInfo}

## 需要操作时（别主动用！）
只有用户明确说"改""换""叫""搜""查"时，才在回复末尾加 ---JSON---：
- 修改段: {"action":"confirm","segIndex":序号,"newType":"英文","newPoiName":"名","msg":"口语确认","dayKey":"YYYYMMDD"}
- 网页搜: {"action":"web_search","query":"词","msg":"语气自然的提示"}
- 周边搜: {"action":"amap_search","keywords":"词","msg":"语气自然的提示"}
- 天气:   {"action":"get_weather","city":"城市","msg":"语气自然的提示"}`;
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
      reqBody['model'] = this.getModel('claude');
      reqBody['max_tokens'] = 1024;
      reqBody['system'] = systemPrompt;
      reqBody['messages'] = messages;
      const body: string = JSON.stringify(reqBody)!;

      const bridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(this.getEndpoint('claude'), {
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
      reqBody['model'] = this.getModel('deepseek');
      reqBody['max_tokens'] = 1024;
      reqBody['messages'] = messages;
      const body: string = JSON.stringify(reqBody)!;

      const bridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(this.getEndpoint('deepseek'), {
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

  /** 华为云盘古 API（OpenAI 兼容格式，不发送 system 角色以兼容 flash 等模型） */
  private async chatPangu(systemPrompt: string): Promise<ClaudeReply> {
    try {
      const messages: Object[] = [];

      // 将 system prompt 注入到第一条 user 消息前面，
      // 因为 openpangu-2.0-flash 等轻量模型不支持 system 角色
      let isFirstUser: boolean = true;
      for (const h of this.history) {
        const msgObj: Record<string, string> = {};
        msgObj['role'] = h.role;
        if (h.role === 'user' && isFirstUser) {
          msgObj['content'] = '[系统指令]\n' + systemPrompt + '\n\n[用户消息]\n' + h.content;
          isFirstUser = false;
        } else {
          msgObj['content'] = h.content;
        }
        messages.push(msgObj);
      }

      const reqBody: Record<string, Object> = {};
      reqBody['model'] = this.getModel('pangu');
      reqBody['max_tokens'] = 1024;
      reqBody['messages'] = messages;
      const body: string = JSON.stringify(reqBody)!;

      const bridge = PlatformBridge.getInstance();
      const resp: HttpResponse = await bridge.network.request(this.getEndpoint('pangu'), {
        method: 'POST',
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.apiKey
        },
        body: body,
        connectTimeout: 10000,
        readTimeout: 30000
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
        // 无 choices，检查错误信息
        const errMsg: string = (data['error_msg'] as string) ||
          (data['error'] ? (data['error'] as Record<string,Object>)['message'] as string : '') || '';
        if (errMsg.length > 0) {
          Logger.warn(TAG, 'Pangu API returned error: %{public}s', errMsg);
          return { text: '盘古返回错误：' + errMsg };
        }
        return { text: '' };
      }

      // 解析错误响应体，给出具体原因
      let detail: string = '';
      try {
        const errData: Record<string, Object> = JSON.parse(resp.result) as Record<string, Object>;
        detail = (errData['error_msg'] as string) ||
          (errData['error'] ? (errData['error'] as Record<string,Object>)['message'] as string : '') || '';
      } catch (e) { /* ignore */ }

      Logger.warn(TAG, 'Pangu HTTP %{public}d: %{public}s', resp.responseCode, detail);
      if (detail.length > 0) {
        return { text: '盘古 API 错误(' + resp.responseCode + ')：' + detail };
      }
      return { text: `华为盘古暂时不可用（${resp.responseCode}），稍后再试试？` };
    } catch (e) {
      Logger.warn(TAG, 'Pangu error: %{public}s', JSON.stringify(e));
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
      dayKey: (parsed['dayKey'] as string) || '',
      query: (parsed['query'] as string) || '',
      url: (parsed['url'] as string) || '',
      keywords: (parsed['keywords'] as string) || '',
      city: (parsed['city'] as string) || '',
      msg: (parsed['msg'] as string) || ''
    };
  }
}
