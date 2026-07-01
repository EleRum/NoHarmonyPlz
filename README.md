# 足迹地图 (Footprint Map)

> AI Agent 驱动的智慧出行助手 — 自动记录足迹、理解行为、主动推荐

## 项目概述

足迹地图是一个 HarmonyOS 原生应用，自动追踪用户 GPS 位置，通过 AI 分析行为模式（餐饮/购物/运动/通勤等），并主动推荐周边 POI。

### 技术栈

| 层 | 技术 |
|---|------|
| **UI 框架** | ArkTS + ArkUI 声明式组件 |
| **平台** | HarmonyOS NEXT (API 24) |
| **地图渲染** | WebView + 高德 JSAPI v2.0 |
| **AI 引擎** | Claude / DeepSeek API，自然语言交互 |
| **数据库** | SQLite（通过 `relationalStore`） |
| **构建工具** | Hvigor |

---

## 架构设计

```
┌─────────────────────────────────────────────┐
│                  Pages (UI)                  │
│  MapPage / TimelinePage / RecommendPage     │
│        ReportPage / WaypointDetailPage       │
├─────────────────────────────────────────────┤
│              Services (业务逻辑)             │
│  LocationService / PhotoService             │
│  RecommendationEngine / AgentScheduler      │
│  ActivityClassifier / AiAgent / ClaudeService│
├──────────────┬──────────────────────────────┤
│  Map Bridge  │     Platform Bridge           │
│  MapJsBridge │  ┌─────────┬─────────┐       │
│  + AMap JSAPI│  │Database │Network  │       │
│  (WebView)   │  ├─────────┼─────────┤       │
│              │  │Location │Photo    │       │
│              │  └─────────┴─────────┘       │
├──────────────┴──────────────────────────────┤
│            HarmonyOS 系统能力                │
│  @kit.ArkData / @kit.LocationKit            │
│  @kit.NetworkKit / @kit.MediaLibraryKit     │
└─────────────────────────────────────────────┘
```

### 核心设计原则

**1. 平台抽象层 (Platform Bridge)**

所有系统能力（数据库、网络、定位、相册）通过接口抽象，HarmonyOS 使用 `@kit.*` 原生 API 实现：

- `IDatabase` — SQLite CRUD，通过 `@kit.ArkData/relationalStore` 实现
- `INetworkProvider` — HTTP 请求，通过 `@kit.NetworkKit` 实现
- `ILocationProvider` — GPS 追踪 + 逆地理编码，通过 `@kit.LocationKit` 实现
- `IPhotoAccess` — 相册扫描，通过 `@kit.MediaLibraryKit` 实现

**2. 地图方案**

使用 WebView 加载高德 JSAPI v2.0，通过双向桥接实现地图交互：

- `rawfile/map/map.html` — 地图 HTML 入口
- `rawfile/map/jsapi-bridge.js` — JS 侧 FootMapBridge
- `MapJsBridge.ets` — ArkTS 侧桥接控制器

双向通信：`controller.runJavaScript()` → JS，`javaScriptProxy` ← JS。

---

## 项目结构

```
MyApplication2/
├── AppScope/                    # 应用级配置（bundleName、图标）
├── entry/                       # 主模块
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/    # 应用入口 (EntryAbility)
│       │   ├── pages/           # 5 个页面
│       │   ├── services/        # 业务服务层
│       │   │   └── map/         # 地图桥接 (MapJsBridge + 类型定义)
│       │   ├── platform/        # 平台抽象层
│       │   │   ├── database/    # IDatabase + HarmonyDatabase
│       │   │   ├── network/     # INetworkProvider + HarmonyNetworkProvider + FetchNetworkProvider
│       │   │   ├── location/    # ILocationProvider + HarmonyLocationProvider
│       │   │   ├── photo/       # IPhotoAccess + HarmonyPhotoAccess
│       │   │   └── file/        # IFileProvider (预留)
│       │   ├── database/        # DatabaseHelper + Dao (数据访问层)
│       │   ├── model/           # 数据模型 (Footprint/ActivitySegment/Recommendation/UserProfile)
│       │   └── common/          # Logger + Constants + LocationUtils
│       ├── resources/rawfile/map/  # 高德 JSAPI HTML + JS Bridge
│       └── module.json5         # 模块配置
├── build-profile.json5          # 构建配置
└── oh-package.json5             # 依赖管理
```

---

## 数据流

```
GPS 定位 ──→ LocationService ──→ Dao.insertFootprint()
                                       │
                                  Footprint.db
                                       │
                ┌──────────────────────┼──────────────────────┐
                ▼                      ▼                      ▼
       ActivityClassifier     RecommendationEngine      AiAgent
        (行为分类)             (偏好学习+POI评分)      (自然语言修正)
                │                      │                      │
                ▼                      ▼                      ▼
       ActivitySegment           Recommendation         ClaudeService
           (活动段)              (推荐结果)              (LLM API)
```

### 数据模型

| 表 | 用途 |
|----|------|
| `footprint` | GPS 轨迹点（经纬度、时间戳、速度、来源） |
| `activity_segment` | 聚合活动段（类型、时间段、POI、照片数） |
| `user_profile` | 用户偏好（API Key、饮食/购物权重等） |
| `recommendation` | AI 推荐缓存（地点名、类型、理由、接受状态） |

---

## 环境要求

| 工具 | 版本 |
|------|------|
| DevEco Studio | 6.1.1.280+ |
| HarmonyOS SDK | 6.1.1.125 (API 24) |
| Hvigor | 6.1.1 |

---

## 构建与运行

### 方式一：DevEco Studio

1. 用 DevEco Studio 打开项目根目录
2. 等待 Sync 完成
3. 点击 Run（▶）编译并部署到设备/模拟器

### 方式二：命令行

```bash
# 编译 debug HAP
hvigorw assembleHap -p product=default -p buildMode=debug

# 编译 release HAP
hvigorw assembleHap -p product=default -p buildMode=release
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

---

## 地图配置

API Key 在 `entry/src/main/ets/common/Constants.ets` 中配置：

```typescript
export const AMAP_API_KEY: string = 'your-api-key';
```

请到[高德开放平台](https://lbs.amap.com/)申请 JS API Key。

---

## AI Agent 集成

支持 Claude 和 DeepSeek 两个 LLM 后端，在 `ClaudeService.ets` 中自动检测 API Key 前缀：

- `sk-ant-*` → Anthropic Messages API
- `sk-*` → DeepSeek Chat Completions API

AI Agent (`AiAgent.ets`) 支持自然语言修改活动段，例如：
- "昨天第1个改成购物"
- "把今天下午的改成运动"
- "上周三的餐饮改成川菜"

---

## 权限说明

| 权限 | 用途 |
|------|------|
| `ohos.permission.INTERNET` | 地图加载、AI API 调用 |
| `ohos.permission.GET_NETWORK_INFO` | 网络状态检测 |
| `ohos.permission.LOCATION` | GPS 足迹追踪 |
| `ohos.permission.APPROXIMATELY_LOCATION` | 区域识别 |

---

## 已知问题

| 问题 | 说明 |
|------|------|
| 模拟器地图空白 | HarmonyOS 模拟器缺乏 GPU 加速，WebView 中高德 JSAPI 可能无法正常渲染，真机正常 |
| 相册扫描 | 部分模拟器上 `MediaLibraryKit` 可能无媒体数据 |
