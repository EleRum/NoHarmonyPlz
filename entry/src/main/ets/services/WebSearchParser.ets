/**
 * Web 搜索结果解析工具
 * 纯函数集合：解析 DuckDuckGo HTML、提取评分/评论、名称相似度
 * 无外部依赖，所有解析基于正则
 */

export interface DdgResult {
  title: string;
  url: string;
  snippet: string;
}

export interface BaiduResult {
  title: string;
  url: string;
  snippet: string;
}

/**
 * 从 DuckDuckGo Lite HTML 提取搜索结果
 * DDG lite 页面结构：<a class="result__a" href="url">title</a> + <td class="result__snippet">snippet</td>
 */
export function parseDuckDuckGoResults(html: string, domainFilter?: string): DdgResult[] {
  const results: DdgResult[] = [];
  // DDG lite: 结果链接在 <a class="result__a" href="..."> 中
  const linkRegex: RegExp = /<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi;
  let match: RegExpExecArray | null = linkRegex.exec(html);
  while (match !== null) {
    const url: string = match[1];
    const title: string = stripHtmlTags(match[2]).trim();
    // 提取对应的 snippet（紧跟其后的 result__snippet）
    const snippetStart: number = match.index + match[0].length;
    const remaining: string = html.substring(snippetStart);
    const snippetMatch: RegExpExecArray | null = /<td[^>]*class="result__snippet"[^>]*>([\s\S]*?)<\/td>/i.exec(remaining);
    const snippet: string = snippetMatch ? stripHtmlTags(snippetMatch[1]).trim() : '';

    if (title.length > 0 && url.length > 0) {
      // 可选域名过滤
      if (domainFilter && domainFilter.length > 0) {
        if (!url.includes(domainFilter)) {
          linkRegex.exec(html);
          match = linkRegex.exec(html);
          continue;
        }
      }
      results.push({ title, url, snippet });
    }
    match = linkRegex.exec(html);
  }
  return results;
}

/**
 * 从百度搜索结果 HTML 提取搜索结果
 * 百度页面结构：<h3 class="t"><a href="url">title</a></h3> + <span class="content-right_...">snippet</span>
 */
export function parseBaiduResults(html: string, domainFilter?: string): BaiduResult[] {
  const results: BaiduResult[] = [];

  // 百度搜索结果通常包含在 <h3 class="t"> 标签中
  const resultRegex: RegExp = /<h3[^>]*class="[^"]*t[^"]*"[^>]*>[\s\S]*?<a[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?<\/h3>[\s\S]*?<span[^>]*class="[^"]*content-right_[^"]*"[^>]*>([\s\S]*?)<\/span>/gi;

  let match: RegExpExecArray | null = resultRegex.exec(html);
  while (match !== null) {
    const url: string = match[1];
    const title: string = stripHtmlTags(match[2]).trim();
    const snippet: string = stripHtmlTags(match[3] || '').trim();

    if (title.length > 0 && url.length > 0) {
      // 可选域名过滤
      if (domainFilter && domainFilter.length > 0) {
        if (!url.includes(domainFilter)) {
          match = resultRegex.exec(html);
          continue;
        }
      }
      results.push({ title, url, snippet });
    }
    match = resultRegex.exec(html);
  }

  // 备用解析：尝试更通用的百度结果模式
  if (results.length === 0) {
    const linkRegex: RegExp = /<h3[^>]*>[\s\S]*?<a[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?<\/h3>/gi;
    let linkMatch: RegExpExecArray | null = linkRegex.exec(html);
    while (linkMatch !== null) {
      const url: string = linkMatch[1];
      const title: string = stripHtmlTags(linkMatch[2]).trim();

      if (title.length > 0 && url.length > 0 && url.startsWith('http')) {
        // 查找可能的摘要（在链接后的 div 或 span 中）
        const afterLink: string = html.substring(linkMatch.index + linkMatch[0].length);
        const snippetMatch: RegExpExecArray | null = /<div[^>]*class="[^"]*c-abstract[^"]*"[^>]*>([\s\S]*?)<\/div>/i.exec(afterLink) ||
                                                   /<span[^>]*class="[^"]*content-right_[^"]*"[^>]*>([\s\S]*?)<\/span>/i.exec(afterLink);
        const snippet: string = snippetMatch ? stripHtmlTags(snippetMatch[1]).trim() : '';

        // 可选域名过滤
        if (domainFilter && domainFilter.length > 0) {
          if (!url.includes(domainFilter)) {
            linkMatch = linkRegex.exec(html);
            continue;
          }
        }
        results.push({ title, url, snippet });
      }
      linkMatch = linkRegex.exec(html);
    }
  }

  return results;
}

/**
 * 从文本片段中提取评分 (0-5)
 * 匹配模式: ★★★★☆, 评分：4.5, 4.5分, 4.5/5
 */
export function parseRatingFromSnippet(text: string): number {
  // 星号模式
  const starRegex: RegExp = new RegExp('([★⭐]{1,5})');
  const starMatch: RegExpExecArray | null = starRegex.exec(text);
  if (starMatch) {
    return Math.min(5, starMatch[1].length);
  }
  // 数字评分模式
  const scorePatterns: RegExp[] = [
    new RegExp('[评評][分分][:：]?\\s*(\\d+\\.?\\d*)'),
    new RegExp('(\\d+\\.?\\d*)[\\/／]5'),
    new RegExp('(\\d+\\.?\\d*)\\s*[分星星]'),
  ];
  for (const pat of scorePatterns) {
    const m: RegExpExecArray | null = pat.exec(text);
    if (m) {
      const score: number = parseFloat(m[1]);
      if (score > 0 && score <= 5) return score;
    }
  }
  return 0;
}

/**
 * 从文本片段中提取评论数
 * 匹配模式: 3280条评价, 3280条评论, 3280评论, (3280)
 */
export function parseReviewCount(text: string): number {
  const patterns: RegExp[] = [
    new RegExp('(\\d+)\\s*[条條]?\\s*[评評][价價論论]'),
    new RegExp('(\\d+)\\s*[条條]?\\s*评论'),
    new RegExp('\\((\\d+)\\)'),
  ];
  for (const pat of patterns) {
    const m: RegExpExecArray | null = pat.exec(text);
    if (m) return parseInt(m[1]);
  }
  return 0;
}

/**
 * 从大众点评详情页 HTML 提取推荐菜
 * 匹配 "推荐菜" 或 "必点" 后的菜名列表
 */
export function extractPopularItems(html: string): string {
  // 大众点评推荐菜区域
  const recRegex: RegExp = new RegExp('推荐菜[：:]*([\\s\\S]{0,200})');
  const recMatch: RegExpExecArray | null = recRegex.exec(html);
  if (recMatch) {
    const raw: string = recMatch[1];
    // 提取菜名（中文词组，逗号/顿号分隔）
    const items: string[] = [];
    const itemRegex: RegExp = new RegExp('[一-龥]{2,8}', 'g');
    let m: RegExpExecArray | null = itemRegex.exec(raw);
    while (m !== null && items.length < 5) {
      items.push(m[0]);
      m = itemRegex.exec(raw);
    }
    if (items.length > 0) {
      return items.join('、');
    }
  }
  return '';
}

/**
 * 清理 HTML 标签
 */
export function stripHtmlTags(html: string): string {
  return html.replace(/<[^>]*>/g, '').replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ');
}

/**
 * 规范化地点名称：去多余空格、常见后缀
 */
export function normalizePlaceName(name: string): string {
  return name.replace(/\s+/g, '')
    .replace(/[（(].*?[）)]/g, '')  // 去括号内容
    .trim();
}

/**
 * 两个名称的字符重叠相似度 (0-1)
 * 用于判断是否为同一家店
 */
export function nameSimilarity(a: string, b: string): number {
  const na: string = normalizePlaceName(a);
  const nb: string = normalizePlaceName(b);
  if (na.length === 0 || nb.length === 0) return 0;
  if (na === nb) return 1;
  // 计算字符交集
  const setA: string[] = na.split('');
  const setB: string[] = nb.split('');
  let intersection: number = 0;
  const used: boolean[] = new Array<boolean>(setB.length).fill(false);
  for (let i = 0; i < setA.length; i++) {
    for (let j = 0; j < setB.length; j++) {
      if (!used[j] && setA[i] === setB[j]) {
        intersection++;
        used[j] = true;
        break;
      }
    }
  }
  const maxLen: number = Math.max(setA.length, setB.length);
  return intersection / maxLen;
}
