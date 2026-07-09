# 足迹旅行地图 (Footprint Travel Map)

基于 HarmonyOS 的 AI 智能旅行规划与足迹记录应用。

## 功能

### 🗺️ 足迹地图 (MapPage)
- GPS 实时定位追踪，记录每日活动轨迹
- 自动识别活动类型：步行、骑行、驾车、停留等
- 按天分组显示历史足迹和路线
- POI 标记点击查看详情

### 🤖 AI 旅行规划师·小途 (TourGuidePage)
- 对话式旅行规划：自然语言描述需求即可
- 自动定位城市 → 推荐酒店 → 生成行程骨架
- 逐点添加景点和美食：`"第一天上午去宽窄巷子"`
- 智能交通方式：步行 (<1km) / 驾车 (>1km)，支持手动指定 `"坐地铁去XX"`
- 计划实时在地图上可视化：POI 标记 + 路线
- 快捷回复按钮：搜索结果一键选择，上下文感知
- 支持按名称删除/修改行程中的地点

### 🔍 搜索
- 全城文字搜索酒店、景点、美食（高德 API）
- 点击标记查看详情：评分、人均、电话

### 📊 数据
- 足迹数据本地 SQLite 存储
- AI 对话历史持久化
- 多 AI 后端：Claude / DeepSeek / 华为盘古

## 技术架构

```
HarmonyOS (ArkTS) + WebView 地图

entry/src/main/ets/
├── pages/
│   ├── MapPage.ets           # 足迹地图主页
│   ├── TourGuidePage.ets     # AI 旅行规划页
│   ├── TimelinePage.ets      # 时间线
│   ├── RecommendPage.ets     # 推荐
│   ├── SettingsPage.ets      # 设置
│   └── WaypointDetailPage.ets # 地点详情
├── services/
│   ├── TourGuideAgent.ets    # AI 规划 Agent
│   ├── ClaudeService.ets     # 多 AI 后端服务
│   ├── LocationService.ets   # GPS 定位
│   └── map/
│       ├── AmapSearchService.ets  # 高德 REST API
│       ├── MapJsBridge.ets        # ArkTS↔JS 桥接
│       └── MapWebView.ets         # WebView 地图组件
├── model/
│   └── TourPlan.ets          # 旅行计划数据模型
└── database/
    └── DatabaseHelper.ets     # SQLite 数据库
```

### 地图方案

WebView 加载高德 JSAPI 2.0，自建 ArkTS ↔ JavaScript 双向桥接：
- **ArkTS → JS**：`controller.runJavaScript()`
- **JS → ArkTS**：`javaScriptProxy` 回调

搜索 API：周边搜索 `/v3/place/around` + 文字搜索 `/v3/place/text`

### AI 多后端

| 后端 | Key 前缀 | 模型 |
|------|---------|------|
| Claude | `sk-ant-*` | `claude-sonnet-4-6` |
| DeepSeek | `sk-*` | `deepseek-chat` |
| 华为盘古 | 手动选择 | `openpangu-2.0-flash` |

## 快速开始

### 环境
- DevEco Studio 5.0+
- HarmonyOS SDK API 12+
- 高德地图 API Key

### 构建
```bash
hvigorw assembleHap -p product=default -p buildMode=debug
```

### 配置 AI
在设置页或聊天框输入密钥：
```
密钥 sk-your-api-key
```
- DeepSeek（便宜）：`sk-xxx`
- Claude（更强）：`sk-ant-xxx`

## 使用流程

```
用户："想去成都3天"
  → AI 定位城市 → 推荐5个酒店 → 点击选择
  → 生成行程骨架（仅酒店）
  → AI："想看什么景点？想吃点什么？"

用户："第一天上午去宽窄巷子"
  → 全城搜索 → 添加 POI → 驾车路线 → 地图更新 ✅

用户："中午走路去附近火锅"
  → 搜索 → 步行路线 → 地图更新 ✅

用户："下午坐地铁去春翠里"
  → 搜索 → 公交路线 → 地图更新 ✅

用户："第一天不要宽窄巷子了"
  → 按名称匹配 → 删除 → 路线重算 ✅
```

## 快捷回复

每步 AI 回复后自动显示上下文相关的快捷按钮：

| 场景 | 按钮 |
|------|------|
| 酒店搜索结果 | 前5个酒店名 + 🔄换一批 |
| 计划生成后 | 加景点、加美食、改酒店、删景点 |
| 添加 POI 后 | 再加一个、换交通方式、看看行程 |

## 确定性修改检测

不依赖 AI 工具调用，通过正则直接识别用户意图：

| 用户说 | 自动执行 |
|--------|---------|
| `第X天去/吃/看 XX` | search_and_add |
| `删除/去掉 第X天 XX` | remove_poi_from_day |
| `坐地铁/公交/走路/开车去 XX` | 指定交通方式 |
| `第X天 第N个` | 精确按索引删除 |

v2.0.1
