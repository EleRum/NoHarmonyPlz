# 足迹地图 (Footprint Map)

> 🥾 **小足** — 一个有温度的 AI 旅行搭子。自动记录足迹、陪你聊天、帮你搜索、懂你的行程。

## 项目概述

足迹地图是一个 HarmonyOS 原生应用，GPS 自动追踪用户轨迹，AI 分析行为模式（餐饮/购物/运动/通勤等），支持**自然语言对话**、**网页搜索**、**周边推荐**和**天气查询**。

🏆 适配 **2026 鸿蒙高校创新赛**（C4-AI），可报 **Agent 创新** 或 **应用创新** 方向。

### 技术栈

| 层 | 技术 |
|---|---|
| **UI** | ArkTS + ArkUI |
| **平台** | HarmonyOS 5.0 (API 12) / OpenHarmony 6.1 (API 24) |
| **地图** | WebView + 高德 JSAPI v2.0 |
| **AI** | 华为盘古 / Claude / DeepSeek 三后端，自动切换 |
| **数据库** | SQLite（`@kit.ArkData/relationalStore`） |
| **构建** | Hvigor |

---

## 快速开始

### 环境

| 工具 | 版本 |
|---|---|
| DevEco Studio | 5.0+ (API 12) 或 6.1.1+ (API 24) |
| Hvigor | 对应 SDK 版本 |

### 运行

```bash
# 编译
hvigorw assembleApp

# 产物
entry/build/default/outputs/default/entry-default-signed.hap
```

或在 DevEco Studio 中直接 Run ▶。

### 设置 AI 密钥

打开应用 → 点 💬 AI 聊天 → 输入密钥：

```
sk-你的密钥
```

| 前缀 | 后端 | 获取方式 |
|---|---|---|
| `sk-hw-*` | 华为盘古 | 华为云 ModelArts Studio |
| `sk-*` | DeepSeek | platform.deepseek.com |
| `sk-ant-*` | Claude | console.anthropic.com |

> 无密钥时 AI 也能用本地规则做基本操作，但设置密钥后"小足"人格才会真正激活。

---

## 架构

```
┌─────────────────────────────────────────────────┐
│                   Pages (UI)                     │
│   MapPage / TimelinePage / RecommendPage         │
│   ReportPage / WaypointDetailPage / SettingsPage │
├─────────────────────────────────────────────────┤
│               Services (业务逻辑)                 │
│   LocationService / PhotoService                 │
│   ActivityClassifier / RecommendationEngine      │
│   AgentScheduler / AiAgent / ClaudeService       │
│   WebRecommendationService / WebSearchParser     │
├──────────────┬──────────────────────────────────┤
│  Map Bridge  │       Platform Bridge             │
│  (WebView +  │  Database / Network / Location    │
│   AMap JSAPI)│  Photo / File (接口抽象)           │
├──────────────┴──────────────────────────────────┤
│             HarmonyOS 系统能力                    │
│  @kit.ArkData / @kit.LocationKit                │
│  @kit.NetworkKit / @kit.MediaLibraryKit          │
└─────────────────────────────────────────────────┘
```

### 设计要点

**平台抽象** — 所有系统能力通过接口抽象（`IDatabase`、`INetworkProvider`、`ILocationProvider`），HarmonyOS 和 OpenHarmony 分别有独立实现，支持 API 12 和 API 24 双目标编译。

**地图方案** — WebView 内联高德 JSAPI v2.0 + 桥接脚本，通过 `runJavaScript()` / `javaScriptProxy` 双向通信。不依赖原生 Map Kit，跨版本兼容性好。

**AI 多后端** — `ClaudeService` 按 API Key 前缀自动识别华为盘古 / Claude / DeepSeek，统一 OpenAI 兼容接口。

**推荐引擎** — 四层递进搜索架构，确保推荐永不空返：

```
generateNow()
  ├─ ① 按时段 + 用户偏好 → 搜索词（早餐→面馆 / 午餐→偏好 / 下午茶→咖啡 / 周末→景点）
  ├─ ② 高德 REST API 并行双查询（精确 + 宽泛，1km 半径）+ 百度→大众点评
  ├─ ③ 历史活动降级（排除 work/commute/home，所有有效类型打分取 top 3）
  └─ ④ 终极兜底（空关键词搜附近任意 POI）
```

---

## 项目结构

```
MyApplication2/
├── AppScope/                        # 应用配置
├── entry/src/main/
│   ├── ets/
│   │   ├── entryability/            # EntryAbility 入口
│   │   ├── pages/                   # 6 个页面
│   │   │   ├── MapPage.ets          # 主地图页（WebView + GPS + 足迹渲染）
│   │   │   ├── TimelinePage.ets     # 时间线
│   │   │   ├── RecommendPage.ets    # AI 推荐（30s 自动轮询）
│   │   │   ├── ReportPage.ets       # 行程报告
│   │   │   ├── WaypointDetailPage.ets # 足迹详情
│   │   │   └── SettingsPage.ets     # 设置页
│   │   ├── services/
│   │   │   ├── AiAgent.ets          # AI 对话 + 工具调用
│   │   │   ├── ClaudeService.ets    # LLM 服务（盘古/Claude/DeepSeek）
│   │   │   ├── LocationService.ets  # 后台 GPS 追踪
│   │   │   ├── ActivityClassifier.ets # 行为分类器（8 种活动类型）
│   │   │   ├── RecommendationEngine.ets # 推荐引擎（四层递进）
│   │   │   ├── AgentScheduler.ets   # 定时推荐调度（GPS+地图就绪后触发）
│   │   │   ├── WebRecommendationService.ets # Web 搜索（百度+大众点评）
│   │   │   ├── WebSearchParser.ets  # 搜索结果解析（百度/DDG）
│   │   │   ├── MockDataService.ets  # 模拟轨迹数据注入
│   │   │   ├── PhotoService.ets     # 照片扫描
│   │   │   └── map/                 # 地图桥接层
│   │   │       ├── MapJsBridge.ets   # ArkTS 侧桥接控制器
│   │   │       ├── MapWebView.ets    # WebView 组件
│   │   │       ├── MapTypes.ets      # 类型定义
│   │   │       └── AmapSearchService.ets # POI 搜索（JS 桥）
│   │   ├── platform/                # 平台抽象层
│   │   │   ├── database/            # IDatabase + HarmonyDatabase
│   │   │   ├── network/             # INetworkProvider + 实现
│   │   │   ├── location/            # ILocationProvider + 实现
│   │   │   └── photo/               # IPhotoAccess + 实现
│   │   ├── database/                # DatabaseHelper + Dao
│   │   ├── model/                   # Footprint / ActivitySegment / Recommendation / UserProfile
│   │   └── common/                  # Logger / Constants / LocationUtils
│   └── resources/rawfile/map/       # map.html（内联 JS 桥接 + FootMapBridge）
└── build-profile.json5              # 双目标构建配置
```

---

## 数据流

```
GPS ──→ LocationService ──→ Footprint.db
                                  │
           ┌──────────────────────┼──────────────────────┐
           ▼                      ▼                      ▼
   ActivityClassifier    RecommendationEngine        AiAgent
    (行为分类 → 8 种)     (偏好学习 → POI 推荐)     (自然语言 + 工具调用)
           │                      │                      │
           ▼                      ▼                      ▼
   ActivitySegment          Recommendation          ClaudeService
         + Timeline         (地图+Web+降级)     (盘古/Claude/DeepSeek)
```

### 数据库

| 表 | 字段 |
|---|---|
| `footprint` | 经纬度、时间戳、速度、精度、POI、活动标签、来源 |
| `activity_segment` | 类型、起止时间、POI、照片数、摘要 |
| `user_profile` | 键值偏好（API Key、权重） |
| `recommendation` | 地点、类型、理由、来源、富数据 JSON |

---

## AI 能力

### 小足 — 旅行搭子

一个口语化、有记忆、会聊天的 AI 伙伴：

- 🗺️ 聊路线、聊发现——"这家火锅好吃不？上次路过排好长队！"
- 🌧️ 关心天气——"明天好像要下雨，记得带伞哦"
- 📊 轻松回顾——"这周走了 43 公里，绕锦城湖 8 圈哈哈哈"
- 🧠 记住对话上下文，不会"失忆"

### 今日推荐

主动推荐引擎，G​​PS + 地图 + 大众点评 + 用户习惯四维融合：

- 🕐 **时段感知** — 早餐推面馆咖啡，午餐推偏好美食，下午推甜品，周末推景点
- 📍 **周边优先** — 高德 REST API 直调，1km 半径，不依赖 WebView 状态
- ⭐ **大众点评** — 百度搜索抓取评分/评论/推荐菜，Web 富数据合并展示
- 🧠 **偏好学习** — 从历史 ActivitySegment 学习口味偏好，个性化打分排序
- 🔄 **自动轮询** — 推荐页 30s 刷新，GPS 移动后自动更新

### 工具调用

| 工具 | 触发方式 | 实现 |
|---|---|---|
| 🔍 网页搜索 | "帮我搜XX" | 百度优先, DuckDuckGo 海外兜底 |
| 📄 网页抓取 | "读一下这个链接" | HTTP GET + 文本提取 |
| 📍 周边搜索 | "附近有什么好吃的" | 高德 REST API + JSAPI 双通道 |
| 🌤️ 天气查询 | "今天天气" | 高德天气 API |

### 活动段编辑

自然语言修改活动类型和地名：

```
"昨天第1个改成购物"
"今天下午的叫万象城"
```

→ 两步确认（AI 建议 → 用户"是/否"）→ 数据库更新

---

## 权限

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` | 地图加载、AI API、搜索 |
| `ohos.permission.GET_NETWORK_INFO` | 网络状态 |
| `ohos.permission.LOCATION` | GPS 追踪 |
| `ohos.permission.APPROXIMATELY_LOCATION` | 区域识别 |

---

## 已知问题

| 问题 | 说明 |
|---|---|
| 模拟器地图 | 部分模拟器 WebView 不支持 GPU 加速，高德 JSAPI 可能渲染异常，真机正常 |
| 模拟器 GPS | 模拟器 GPS 默认坐标可能与实际位置不符，需在模拟器设置中手动调整 |
| 相册扫描 | 模拟器上 MediaLibraryKit 可能无媒体数据 |
| 地图偏移 | 坐标需为 GCJ-02（火星坐标），WGS-84 会有约 500m 偏移 |
