# AgentAim

Agent 运行等待期间使用的轻量化 macOS 瞄准小游戏原型。

## 当前原型

- 30 秒 Gridshot 式训练
- 锁定鼠标并使用中心准星
- 三目标即时刷新
- 得分、连击、命中率
- `Esc` 随时释放鼠标并退出

当前版本只验证手感，尚未接入 Codex 或 Claude Code 状态。

## 运行

```bash
swift run
```

按空格开始，鼠标移动瞄准，左键射击，`Esc` 退出。

也可以生成可直接双击运行的 macOS 应用：

```bash
./scripts/package.sh
open dist/AgentAim.app
```

## 性能原则

- 原生 Swift/AppKit
- 无 Electron、Unity 或 WebView
- 待机不运行游戏循环
- 所有视觉均由代码绘制，无外部素材
