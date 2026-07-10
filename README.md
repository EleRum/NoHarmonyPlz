# 足迹旅行地图 (Footprint Travel Map)

基于 HarmonyOS 的 AI 智能旅行规划与足迹记录应用。

## 开发前须知

- 看[备忘.md](%E5%A4%87%E5%BF%98.md)！！

## 功能

### 🗺️ 地图 & 足迹
- GPS 实时定位追踪，自动记录每日活动轨迹
- 按天分组显示历史足迹和路线（不同颜色标记）
- 地图推荐标记自动展示附近热门地点
- 右下角刷新按钮一键更新推荐
- GPS / 网络状态检测，未开启时弹窗引导

### 💡 智能推荐
- AI 引擎根据时间、位置、用户偏好生成附近推荐
- 推荐展示照片、评分、推荐理由
- 推荐全页可查看详情，点击进入地点详情页
- 设置中可开关：后台自动刷新 / 地图显示标记
- 地图右下角 🔄 按钮手动刷新

### 👤 用户画像
- 用户名、年龄、城市、性别、旅行偏好标签
- 偏好仅作软引导，保留推荐多样性
- 首次启动 → 欢迎页 → 填写昵称即可开始

### 🤖 AI 助手
- **小途**：对话式旅行规划（导游 tab）
- **小足**：自然语言活动修正（地图 AI 浮钮）
- 支持 Claude / DeepSeek / 华为盘古
- 网页搜索、高德搜索、天气查询工具链

### 🎨 主题
- 浅色 / 深色双模式，我的页一键切换
- 统一设计系统：配色、字体、圆角、间距常量

## 导航

| Tab | 内容 |
|-----|------|
| 🗺️ 地图 | 地图 + 浮动按钮（推荐/AI/导航/刷新） |
| 📋 行程 | 时间线 + 行程报告 |
| 🧭 导游 | AI 旅游规划 |
| 👤 我的 | 个人资料 + 深色开关 + 设置 |

## 技术架构

```
entry/src/main/ets/
├── pages/
│   ├── MapPage.ets              # 地图主页
│   ├── WelcomePage.ets          # 首次启动欢迎页
│   ├── UserProfilePage.ets      # 个人资料编辑
│   ├── RecommendPage.ets        # 推荐全页
│   ├── TourGuidePage.ets        # AI 导游
│   ├── TravelJournalPage.ets    # 时间线+报告
│   ├── ProfilePage.ets          # 资料+设置
│   ├── SettingsPage.ets         # AI密钥/推荐开关
│   ├── TimelinePage.ets         # 时间线
│   ├── ReportPage.ets           # 行程报告
│   └── WaypointDetailPage.ets   # 地点详情
├── common/
│   ├── Theme.ets                # 深浅主题系统
│   ├── TravelPreferenceTags.ets # 偏好标签+跨页信号
│   ├── DeviceCheckUtils.ets     # GPS/网络检测
│   ├── GpsNetworkDialog.ets     # 服务提醒弹窗
│   ├── Logger.ets / Constants.ets / LocationUtils.ets
│   └── CalibrationSignal.ets    # 校准信号
├── services/
│   ├── TourGuideAgent.ets       # 小途 (旅行规划)
│   ├── AiAgent.ets              # 小足 (活动修正)
│   ├── ClaudeService.ets        # 多AI后端
│   ├── RecommendationEngine.ets # 推荐引擎
│   ├── AgentScheduler.ets       # 推荐调度器
│   └── map/                     # 高德地图服务
├── model/                       # 数据模型
└── database/                    # SQLite + DAO
```

## 快速开始

### 环境
- DevEco Studio 5.0+
- HarmonyOS SDK API 12+

### 构建
```bash
hvigorw assembleHap -p product=default -p buildMode=debug
```

### 配置 AI
设置页输入密钥：DeepSeek `sk-xxx` / Claude `sk-ant-xxx` / 华为盘古

## 路线规划示例

```
"想去成都3天"        → 定位城市 → 生成行程骨架
"第一天上午去宽窄巷子" → 搜索POI → 添加路线
"中午走路去附近火锅"   → 步行路线
"下午坐地铁去春熙路"   → 公交路线
"第一天不要宽窄巷子了" → 删除 → 路线重算
```

v2.0.3
