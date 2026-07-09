---
name: plan-route-not-updating-bug
description: ArkUI @State 对象引用不变导致 UI 不刷新 + hasDrawn 守卫阻止地图重绘
metadata:
  type: gotcha
---

## 问题
计划路线/地图不更新，永远显示第一次的第一天。在两个页面中存在不同原因：

### TourGuidePage（AI 旅游规划）
**根因**: `TourGuideAgent.executeToolAndContinue()` 返回 `this.plan`（同一对象引用），而 `TourGuidePage` 用 `this.plan = resp.plan` 赋值。ArkUI 的 `@State` 使用 `===` 引用比较，相同引用 = 无变化 = UI 不刷新。

**修复**:
1. `executeToolAndContinue()` 返回 `JSON.parse(JSON.stringify(this.plan))` 深拷贝（TourGuideAgent.ets:262）
2. `process()` 检测新规划请求时重置计划为 createEmptyPlan()
3. `make_plan` 工具添加 `days` 参数支持
4. `ForEach` 添加 key 生成器确保列表正确渲染

### MapPage（足迹路线）
**根因**: `drawOnMap()` 方法有 `if (this.hasDrawn) return; this.hasDrawn = true;` 守卫，首次绘制后永久阻止重绘。

**修复**:
1. 移除 `hasDrawn` 字段和守卫
2. 添加 `clearDayOverlays()` 方法，在每次 `drawOnMap()` 前清除旧覆盖层

**Why:** ArkUI @State 仅比较顶层引用；对象内属性变更不触发 UI 更新。深拷贝确保每次都是新引用。
**How to apply:** 任何返回给 @State 变量的对象都需要是新引用（深拷贝或新构造）。地图重绘方法不应使用一次性守卫，应支持清除 + 重绘。
