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
  ├─ ① AI 生成 5 个搜索词（Claude/DeepSeek/盘古，无 AI 时兜底）
  ├─ ② 渐进半径多类别搜索：1km → 2km → 5km，每个查询独立执行
  ├─ ③ 提取照片：每个 POI 的 photos[0].url 直接从 place/around 响应获取
  ├─ ④ 交错混合：5 个查询轮流取，保证类别多样性，≥10 条
  ├─ ⑤ AI 批量生成推荐理由
  ├─ ⑥ 空关键词扩大搜索
  ├─ ⑦ 缓存复用 → 同城历史降级（< 30km，最多 3 条）
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
│   │   │   ├── RecommendPage.ets    # 今日推荐
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
│   │   │   ├── CalibrationService.ets # 校准服务（类型/名称/删除）
│   │   │   ├── CalibrationSignal.ets  # 跨页面校准信号（模块级变量）
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
│   │   ├── model/                   # Footprint / ActivitySegment / Recommendation / UserProfile / SegmentCalibration
│   │   └── common/                  # Logger / Constants / LocationUtils / CalibrationSignal
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
    │ + CalibrationService                            │
    │   (段校准/改名/删除)                             │
    ▼                                                 ▼
   segment_calibration                        (盘古/Claude/DeepSeek)
   (独立校准记录表)
         + Timeline + MapPage 实时刷新
```

### 数据库

| 表 | 字段 |
|---|---|
| `footprint` | 经纬度、时间戳、速度、精度、POI、活动标签、来源 |
| `activity_segment` | 类型、起止时间、POI、照片数、摘要 |
| `user_profile` | 键值偏好（API Key、权重） |
| `recommendation` | 地点、类型、理由、来源、富数据 JSON |
| `segment_calibration` | 日期、起止时间、校准类型、校准名称、来源、软删除标记 |

---

## AI 能力

### 小足 — 旅行搭子

一个口语化、有记忆、会聊天的 AI 伙伴：

- 🗺️ 聊路线、聊发现——"这家火锅好吃不？上次路过排好长队！"
- 🌧️ 关心天气——"明天好像要下雨，记得带伞哦"
- 📊 轻松回顾——"这周走了 43 公里，绕锦城湖 8 圈哈哈哈"
- 🧠 记住对话上下文，不会"失忆"

### 今日推荐

AI 生成搜索意图 + 高德 POI 搜索 + 渐进半径 + 真实店面照片：

- 🤖 **AI 搜索词生成** — Claude/DeepSeek/盘古分析时段/偏好/城市，生成 5 个搜索词涵盖多类别（无 AI 时兜底）
- 📍 **渐进半径** — 1km → 2km → 5km，不够自动扩大，确保 ≥10 条推荐
- 🖼️ **真实店面照片** — 高德 `place/around` 响应自带 `photos` 数组，直接提取第一张店面照；无照片时 emoji + 彩色卡片头
- 📝 **AI 推荐理由** — 批量生成口语化推荐语（"周末遛娃圣地草坪超大"），无 AI 时关键词匹配兜底
- ⭐ **Web 富数据** — 百度搜索大众点评/美团评分、评论数、推荐菜
- 🔄 **交错混合** — 5 个搜索词轮流取结果，保证类别多样性
- 🏙️ **同城过滤** — 历史降级仅限同城（距离 < 30km），最多 3 条
- 🔘 **手动刷新** — 🔄 按钮主动刷新；位置偏移 >500m 自动刷新；不再 30s 轮询

### 🚧 导游模式（开发中）

> 跑团 DM 式协作规划 + GPS 实地讲解

#### 核心流程
```
AI 聊天输入"导游"
  → 协作对话：城市/日期/天数/人数/预算/兴趣/体力
  → AI 生成多日行程（高德 POI 搜索 + AI 编排路线 + 讲解词）
  → 🗺️ 导游 Tab 查看行程（按天切换、POI 卡片）
  → GPS 接近 200m → 弹讲解卡片 → 自动导航下一个
```

#### 已实现
- 🤖 **AI 协作式规划** — 对话中逐步收集偏好，AI 提取画像 + 生成行程
- 📋 **导游 Tab** — 底部 🗺️ Tab，行程列表 + 天选择器 + 开始/停止
- 🎙️ **GPS 讲解** — 走近 POI 200m → 弹卡片（名称+讲解词+时长+必做）
- 📍 **城市坐标搜索** — 高德地理编码 → 用目标城市坐标搜索 POI

#### 待完成
- 🛣️ 真实路径（高德 `direction` API 获取 polyline，替代直线）
- 📅 按具体日期规划（目前只按天数）
- 🗣️ TTS 语音播报
- 🌧️ 天气感知调整
- ✏️ 手动拖动调整 POI 顺序

#### 新增文件
| 文件 | 作用 |
|------|------|
| `model/TourProfile.ets` | 用户画像 |
| `model/TourPoi.ets` | 行程 POI 模型 |
| `model/TourDay.ets` | `TourDay` + `TourPlan` |
| `services/TourPlannerService.ets` | AI 行程生成 + 地理编码 |
| `services/TourGuideService.ets` | GPS 驱动实地导游 |
| `pages/TourContent.ets` | 导游 Tab 页面 |
| `pages/TourPanel.ets` | 讲解卡片覆盖层 |

### 工具调用

| 工具 | 触发方式 | 实现 |
|---|---|---|
| 🔍 网页搜索 | "帮我搜XX" | 百度优先, DuckDuckGo 海外兜底 |
| 📄 网页抓取 | "读一下这个链接" | HTTP GET + 文本提取 |
| 📍 周边搜索 | "附近有什么好吃的" | 高德 REST API + JSAPI 双通道 |
| 🌤️ 天气查询 | "今天天气" | 高德天气 API |

### 活动段校准

AI 自动分类可能出错。应用支持**手动校准**和 **AI Agent 校准**两种方式修正活动段的类型、地点名称，或直接删除误判的活动。

#### 手动校准（WaypointDetailPage）

地图或时间线点击段 → 详情页右侧 **✏️ 编辑**按钮 → 校准面板：

| 操作 | 说明 | 实现 |
|------|------|------|
| 修改类型 | 8 种类型（餐饮/购物/运动/工作/居家/通勤/休闲/出行）点选即改 | `CalibrationService.calibrateType()` + 直接更新 `activity_segment` |
| 修改名称 | 弹窗输入新地点名 | `CalibrationService.calibratePoiName()` + `Dao.updateActivitySegment()` |
| 删除段 | 确认弹窗 → 段从 DB 移除 | `CalibrationService.deleteSegment()` 软删除 + 硬删除 |
| 恢复 AI | 清除手动校准，恢复 AI 原始分类 | `CalibrationService.removeCalibration()` |

#### AI Agent 校准

聊天中自然语言修改，两步确认（建议 → "是/否"）→ `CalibrationService` + 直接段更新。

#### 校准保护机制

当天活动段每 30 秒被 `ActivityClassifier` 重新分类（先删后插）。校准记录存储在**独立**的 `segment_calibration` 表中，每次分类后通过**时间范围重叠匹配**自动合并到新生成的段上，确保校准不被覆盖。

跨页面实时刷新通过 `CalibrationSignal` 模块级信号 + 2 秒轮询实现，不依赖生命周期回调。

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
