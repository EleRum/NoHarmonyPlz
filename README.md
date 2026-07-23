# 足迹旅行地图 (Footprint Travel Map)

基于 HarmonyOS 的 AI 智能旅行规划与足迹记录应用。

## 开发前须知

- 看[备忘.md](备忘.md)！！

## 功能

### 🗺️ 地图 & 足迹
- GPS 实时定位追踪，自动记录每日活动轨迹
- 按天分组显示历史足迹和路线（不同颜色标记）
- 地图推荐标记自动展示附近热门地点
- 深色地图模式（CSS 滤镜回退方案）
- GPS / 网络状态检测，HOA 环境下自动乐观放行

### 💡 智能推荐
- AI 引擎根据时间、位置、用户偏好生成附近推荐
- 定时后台刷新（可关闭），右下角浮动刷新按钮
- 推荐全页显示照片、评分、推荐理由
- 设置中可开关：后台自动刷新 / 地图显示标记

### 👤 用户画像
- 用户名、年龄、城市、性别、旅行偏好标签
- 偏好仅作软引导，保留推荐多样性
- 首次启动 → 欢迎页 → 填写昵称即可开始

### 🧭 AI 导游（小途）
- 对话式旅行规划，全屏地图 + 底部聊天面板
- **跨城交通**：高铁(G)/动车(D)/火车(K/T/Z) 车次查询，AI 生成结构化方案卡片
- **预算管理**：总预算设定、POI 花费自动估算（优先用高德人均消费）、进度条
- **主动推进**：定位→搜酒店→建计划→估预算 自动串联
- 三餐时间感知，导航时长推算时间槽
- 多天行程切换，路线计算与绘制

### 🤖 AI 助手（小足）
- 自然语言活动修正（地图 AI 浮钮）
- 支持 Claude / DeepSeek / 华为盘古，密钥在设置页管理

### 🎨 主题
- 浅色 / 深色双模式，设置持久化（退出不丢失）
- 统一设计系统：配色、字体、圆角、间距常量

## 导航

| Tab | 内容 |
|-----|------|
| 🗺️ 地图 | 地图 + 浮动按钮（推荐/AI/导航/刷新） |
| 📋 行程 | 时间线 + 行程报告 |
| 🧭 导游 | AI 旅游规划（全屏地图+聊天） |
| 👤 我的 | 个人资料 + 深色开关 + 设置 |

## 技术架构

```
entry/src/main/ets/
├── pages/
│   ├── MapPage.ets              # 地图主页
│   ├── WelcomePage.ets          # 首次启动欢迎页
│   ├── UserProfilePage.ets      # 个人资料编辑
│   ├── RecommendPage.ets        # 推荐全页
│   ├── TourGuidePage.ets        # AI 导游（交通卡片+行程+预算三合一）
│   ├── ProfilePage.ets          # 资料+设置
│   ├── SettingsPage.ets         # 设置入口
│   ├── SettingsDetailPage.ets   # AI/推荐/隐私/关于子页
│   ├── TravelJournalPage.ets    # 行程+报告
│   └── WaypointDetailPage.ets   # 地点详情
├── common/
│   ├── Theme.ets                # 深浅主题系统
│   ├── TravelPreferenceTags.ets # 偏好标签+跨页信号
│   ├── DeviceCheckUtils.ets     # GPS/网络检测（HOA兼容）
│   ├── GpsNetworkDialog.ets     # 服务提醒弹窗
│   └── Logger.ets / Constants.ets / LocationUtils.ets
├── services/
│   ├── TourGuideAgent.ets       # 小途 (交通+预算+自动串联)
│   ├── AiAgent.ets              # 小足 (活动修正)
│   ├── ClaudeService.ets        # 多AI后端
│   ├── RecommendationEngine.ets # 推荐引擎
│   ├── AgentScheduler.ets       # 推荐调度器
│   └── map/
│       ├── AmapSearchService.ets      # 高德搜索+跨城 transit
│       ├── TransportSearchService.ets # 聚合数据/WebXml票务
│       ├── MapJsBridge.ets            # JS桥接
│       ├── MapWebView.ets             # WebView地图组件
│       ├── MapTypes.ets               # 类型定义
│       └── IMapService.ets            # 地图接口
├── model/
│   ├── TourPlan.ets             # 旅行计划模型(含预算+交通)
│   ├── UserProfile.ets          # 用户画像
│   ├── Footprint.ets            # 足迹
│   └── ...
└── database/                    # SQLite + DAO
```

## 路线规划示例

```
"去成都"              → 自动定位 → 搜酒店
"预算5000"            → 设定预算 → 自动估算
"武汉到成都高铁"       → AI生成G/D车次卡片 → 点击选择
"第一天去宽窄巷子"     → 搜索+添加 → 自动标人均¥60 → 预算更新
"中午去附近火锅"       → 自动标人均¥80
```

## Agent 可信与隐私安全

- 工具失败、空返回、超时和未找到会直接显示给用户，不再包装成成功结果
- 小途的系统提示要求城市、POI、天气、车次、价格只能来自工具结果或当前行程备忘录
- 工具调用前做参数校验，缺少城市、日期、预算、坐标等关键信息时会提示补充
- 工具全部失败时跳过后续模型续写，直接返回失败说明和下一步，降低 token 花费并减少失败后幻觉
- AI Key 保存在本地数据库；调用所选模型服务时仅作为认证信息发送给该模型服务商
- 设置页提供“隐私与数据”入口，可查看本地保存、必要联网、权限使用说明，并二次确认清除本地数据

## 数据持久化

| 操作 | 数据保留？ |
|------|-----------|
| 切 tab | ✅ 内存 |
| 退后台 | ✅ 内存 |
| 杀进程 | ✅ SQLite（足迹、活动段、用户画像、AI 密钥、聊天记录、主题、旅游计划） |
| 隐私与数据 → 清除本地数据 | ❌ 删除足迹、活动段、推荐、校准、个人资料、AI Key、聊天和行程缓存 |

v2.1.0
