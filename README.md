# 足迹旅行地图 (Footprint Travel Map)

基于 HarmonyOS 的 AI 智能旅行规划与足迹记录应用。

## 功能

### 🗺️ 足迹地图
- GPS 实时定位追踪，记录每日活动轨迹
- 自动识别活动类型：步行、骑行、驾车、停留等
- 按天分组显示历史足迹和路线
- GPS 和网络状态检测，未开启时弹窗提醒用户前往系统设置

### 👤 用户画像
- 用户基础信息：昵称、年龄、居住城市、性别
- 旅行偏好标签：美食探索、自然风光、历史文化等 10 类可选
- 偏好仅作软引导，不影响推荐多样性
- 首次启动自动进入欢迎引导流程，只需填写昵称即可开始

### 🤖 AI 助手·小途 & 小足
- **小途**：对话式旅行规划，自然语言描述需求
- **小足**：自然语言活动修正，说"昨天第1个改成购物"即可
- 酒店**可选**：本地人不需要酒店，游客可以中途换酒店
- 用户画像融入对话上下文，但保持推荐多样性
- 智能交通：步行 (<1km) / 驾车 (>1km) / 公交地铁 (用户指定)
- 计划实时地图可视化：POI 标记 + 路线
- 点击标记查看详情：名称、地址、评分、人均、电话
- 快捷回复按钮：根据上下文自动切换
- **三层持久化**：翻页、退后台、杀进程都不丢计划

### 🔔 智能提醒
- GPS 未开启 → 弹窗引导前往位置设置
- 网络未连接 → 弹窗引导前往无线网络设置
- 服务恢复后自动关闭弹窗

### 📊 持久化
- 内存 → 翻页保留
- SQLite → 杀进程保留（足迹、活动段、用户画像、AI 密钥）
- 清空按钮 → 手动清除

## 技术架构

```
HarmonyOS (ArkTS) + WebView 地图

entry/src/main/ets/
├── pages/
│   ├── MapPage.ets              # 足迹地图主页
│   ├── WelcomePage.ets          # 首次启动欢迎页
│   ├── UserProfilePage.ets      # 个人资料编辑页
│   ├── TourGuidePage.ets        # AI 旅行规划页
│   ├── TimelinePage.ets         # 时间线
│   ├── RecommendPage.ets        # 推荐
│   ├── ReportPage.ets           # 行程报告
│   ├── SettingsPage.ets         # 设置
│   └── WaypointDetailPage.ets   # 地点详情
├── common/
│   ├── Logger.ets               # 日志工具
│   ├── Constants.ets            # 常量/枚举
│   ├── LocationUtils.ets        # 位置计算工具
│   ├── CalibrationSignal.ets    # 跨页面信号
│   ├── DeviceCheckUtils.ets     # GPS/网络检测工具
│   ├── GpsNetworkDialog.ets     # 服务提醒弹窗
│   └── TravelPreferenceTags.ets # 旅行偏好常量与信号
├── services/
│   ├── TourGuideAgent.ets       # AI 规划 Agent（小途）
│   ├── AiAgent.ets              # AI 活动修正 Agent（小足）
│   ├── ClaudeService.ets        # 多 AI 后端
│   ├── RecommendationEngine.ets # 推荐引擎
│   ├── AgentScheduler.ets       # 推荐调度器
│   ├── LocationService.ets      # GPS 定位
│   └── map/
│       ├── AmapSearchService.ets # 高德 REST API
│       ├── MapJsBridge.ets       # ArkTS↔JS 桥接
│       └── MapWebView.ets        # WebView 地图组件
├── model/
│   ├── Footprint.ets            # 足迹点
│   ├── ActivitySegment.ets      # 活动段
│   ├── UserProfile.ets          # 偏好键值存储
│   ├── UserBasicInfo.ets        # 用户基础信息
│   ├── TourPlan.ets             # 旅行计划
│   └── Recommendation.ets       # 推荐
└── database/
    ├── DatabaseHelper.ets        # SQLite 建表
    └── Dao.ets                   # 数据访问层
```

### 地图方案

WebView 加载高德 JSAPI 2.0，自建双向桥接：
- ArkTS → JS：`controller.runJavaScript()`
- JS → ArkTS：`javaScriptProxy` 回调

搜索：周边搜索 `/v3/place/around` + 文字搜索 `/v3/place/text`

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
在设置页面输入 API 密钥：
- DeepSeek（便宜）：`sk-xxx`
- Claude（更强）：`sk-ant-xxx`
- 华为盘古：Bearer Token（去设置页手动选择）

## 路线规划

```
"想去成都3天"
  → AI 定位城市（酒店可选，本地人跳过）
  → 生成行程骨架（城市中心起点）
  → AI："想看什么景点？吃什么？"

"第一天上午去宽窄巷子"
  → 全城搜索 → 添加 POI → 驾车路线 ✅

"中午走路去附近火锅"
  → 步行路线 ✅

"下午坐地铁去春熙路"
  → 公交路线 ✅

"第二天换希尔顿"
  → 替换起点和终点（到酒店就住下，不回家）✅

"第一天不要宽窄巷子了"
  → 按名称匹配 → 删除 → 路线重算 ✅
```

## 快捷回复

| 场景 | 按钮 |
|------|------|
| 搜索结果 | 前5个 + 🔄换一批 |
| 计划生成后 | 加景点、加美食、改酒店、删景点 |
| 添加 POI 后 | 再加一个、换交通方式、看看行程 |

## 确定性修改检测

不依赖 AI 工具调用，正则直接识别：

| 用户说 | 自动执行 |
|--------|---------|
| `第X天去/吃/看 XX` | search_and_add |
| `删除/去掉 第X天 XX` | remove_poi_from_day |
| `坐地铁/公交/走路/开车去 XX` | 指定交通方式 |

## 数据持久化

| 操作 | 计划保留？ |
|------|-----------|
| 切 tab | ✅ 内存 |
| 退后台 | ✅ 内存 |
| 杀进程 | ✅ SQLite |
| 清空按钮 | ❌ |

v2.0.2
