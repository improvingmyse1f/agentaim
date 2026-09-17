# AgentAim

Agent 运行等待期间使用的轻量化 macOS 瞄准小游戏原型。

## 当前原型

- Gridshot 式训练，**一局没有时限** —— 什么时候结束由你决定（`Esc`），或者交给 Agent 状态
- 从菜单点「开始训练」会直接开局；双击启动或 Agent 自动触发时，屏幕底部中央会出现确认圆环，
  鼠标停进去 2 秒才开始，中途移出立即归零
- 锁定鼠标，**点状准星**在屏幕空间内移动（世界静止）
- 灵敏度使用 **VALORANT / Counter-Strike 2** 游戏配置：只需填写游戏内灵敏度；
  DPI 可选，仅用于显示对应的 `cm/360`
- 三目标即时刷新，时长以很淡的正计时显示在左下角
- 命中反馈是**命中点局部的光环扩散**，不做全屏闪光
- 得分、连击
- 常驻运行并显示在 Dock 和 `⌘ Command + Tab`；从桌面左上角 `AgentAim` 菜单控制，感知 Codex / Claude Code / WorkBuddy 的工作、等待、回复与失败状态
- `Esc`（或 `Q`、右键）随时结束本局、释放鼠标并回到开局前的应用
- **90 秒里既没开枪也没动鼠标 → 自动收局**：不需要知道任何规则就会发生的出口

**自动开局与登录启动默认都是关的。** 在 `AgentAim` →「设置…」打开「Agent 工作时自动开始」之后，
Agent 新一轮工作持续 2 秒时会亮起确认圆环；**人真的把鼠标停进去 2 秒，覆盖层才会出现**。
Agent 变成等待确认、已回复或失败时，自动安全收局并返回之前的应用。

## 安装

```bash
./scripts/package.sh
open dist/AgentAim.app
```

产物是 **ad-hoc 签名**（`codesign --force --sign -`），不是开发者签名，所以从网络下载得到的
副本会被 Gatekeeper 拦下。放行方式：右键 → 打开，或者

```bash
xattr -dr com.apple.quarantine /Applications/AgentAim.app
```

让 agent 帮忙安装的话，把 [`AGENTS.md`](AGENTS.md) 交给它即可 —— 里面有安装步骤和
一份可以直接念给用户听的用法说明。

### 启动之后会发生什么

本应用会显示在 Dock 和 `⌘ Command + Tab`。激活应用后，入口在桌面左上角的 `AgentAim`
菜单。双击之后，屏幕底部中央还会出现一个 56pt 的圆环，10 秒后它自己消失；Dock 会继续
表明应用正在运行。

圆环是自动触发时的确认，也是「我启动了」的答案 —— 一句话都不用写：

| 你想做的事 | 怎么做 |
|---|---|
| 主动开始一局 | 桌面左上角 `AgentAim` →「开始训练」，直接开局 |
| 接受自动触发 | 鼠标移进圆环，**停满 2 秒**（圈会被填满） |
| 算了不玩了 | 移开就行，进度立即归零；10 秒不理它，它自己走开 |
| 以后不自动出现 | 别开「登录时启动」即可；它默认就是关的 |

圆环**不吃任何点击**（`ignoresMouseEvents = true`），所以它挡在底部的时候 Dock 照样能点。
这是刻意的：确认之前你还在工作，那时候被吃掉的每一次点击都是故障。

两个开关都在 `AgentAim` →「设置…」里，**默认都是关的**：

| 开关 | 默认 | 作用 |
|---|---|---|
| Agent 工作时自动开始 | 关 | Codex / Claude Code 开始干活时亮起确认圆环 |
| 登录时启动 | 关 | 开机后常驻运行 |

### 灵敏度

打开 `AgentAim` →「设置…」即可设置：

- 游戏配置：`VALORANT` 或 `Counter-Strike 2`
- 游戏画面：CS2 可选 `16:9` 或 `4:3 拉伸`；VALORANT 使用固定视野
- 游戏内灵敏度：直接填写对应游戏设置中的原始数值
- 鼠标 DPI（可选）：如需查看 `cm/360`，填写鼠标软件中的真实 DPI/CPI
- `cm/360`：填写 DPI 后自动显示；切换游戏配置时会自动换算数值并保持同一鼠标下的手感

默认是 `VALORANT 0.327`，不会猜测鼠标 DPI。设置从下一局开始生效，
不会在正在进行的训练中突然改变手感。当前匹配标准腰射；CS2 的 16:9 与 4:3 拉伸分别使用
对应的水平视野。AgentAim 不渲染三维场景，但会用同一套鼠标计数、转角和透视投影还原
从屏幕中心甩到目标所需的距离。

### 为什么必须读原始鼠标计数

准星移动链是 `游戏配置 + 游戏内灵敏度 → 每计数角度 → 虚拟相机透视投影`；DPI 不参与移动倍率，
只在用户填写后用于显示 `cm/360`：

```
degreesPerCount   = 该游戏的 yawDegreesPerCount × 游戏内灵敏度      // VALORANT 0.07、CS2 0.022
centimetersPer360 = 360 × 2.54 / (DPI × degreesPerCount)
yaw                = 累计水平鼠标计数 × degreesPerCount
focalLength        = 视口宽度 / (2 × tan(水平 FOV / 2))
screenX            = 屏幕中心 X + focalLength × tan(yaw)
```

其中有一点很容易做错：**位移优先取 Core Graphics 明确标记为未加速的
`eventUnacceleratedPointerMovementX/Y`**，不能把 AppKit 的 `event.deltaX/Y` 当作鼠标计数。
只有合成事件没有未加速字段时，才回退到普通整数 delta。这样系统指针速度不会被再次混入
游戏灵敏度。另一个易错点是 FOV：角度到屏幕位置必须用透视投影，不能用
`角度 × 屏幕宽度 ÷ FOV` 的线性近似。

`--sensitivity` 保留为绕过这套换算的调试后门，正常使用不该碰它。
模型本身在 `Sources/AgentAimCore/FPSSensitivity.swift`，测试覆盖默认不猜 DPI、
cm/360 基准、跨游戏换算、DPI 不改变角增益、双向切换无漂移、透视投影和边缘无死区。

自动开局虽然要手动打开，打开后也只是「亮一个圆环」而**不会直接接管屏幕** ——
覆盖层会在你没预料的时候吃掉所有点击（视觉透明 ≠ 事件穿透），所以确认这一步不能省。

### 怎么退出去

覆盖层在 `.screenSaver` 层级，**它会连菜单栏一起盖住** —— 玩的时候左上角应用菜单点不到，
出口只有键盘。所以出口做了三份冗余，外加一条不需要任何知识的兜底：

| 方式 | 说明 |
|---|---|
| `Esc` | 主要出口，玩的时候 HUD 上常显 |
| `Q` | 同上，多一个键纯为买容错 |
| 右键 | 慌张时最本能的动作 |
| 90 秒无操作 | 既没开枪也没动鼠标，屏幕自己还回来 |

**万一鼠标被卡住了**（进程被强杀、指针锁定没还原）：在终端执行

```bash
killall AgentAim
```

进程收到 `SIGTERM` 会先还原全局指针状态再退出；正常情况下按 `Esc` 走的就是这条路径。

不想让覆盖层盖住菜单栏（等于天然多一个出口，代价是游戏期间菜单栏变化会被看见）
就用 `--show-menu-bar` 启动。

## 隐私与权限

- **零网络**。除本地 Unix Datagram socket（私有运行目录 0700 + socket 0600）外不建立任何连接，
  没有遥测、没有更新检查。
- **零额外权限**。指针锁定（`CGAssociateMouseAndMouseCursorPosition`）、窗口层级、
  以及确认圆环的悬停检测（轮询 `NSEvent.mouseLocation`）全都不需要「辅助功能」或
  「输入监控」—— 这是刻意的：能用系统调用或公共读接口办到的，就不去申请权限。
  当前版本**还没有**读任何其他应用的窗口信息（「靶子避开最前窗口」是计划中的功能）；
  真要做时也只会读 `CGWindowListCopyWindowInfo` 的 bounds / ownerPID / layer，
  **绝不读 `kCGWindowName`** —— 只有那一条才需要「屏幕录制」权限。
- hook 转发器只发送 provider、session/turn ID、事件名、通知子类型、布尔中断标记与时间戳，
  绝不发送 cwd、错误文本、prompt、工具输入输出、assistant message 或 transcript。

## 接入 Codex / Claude Code Hooks

打包后，状态转发器位于 `AgentAim.app/Contents/MacOS/AgentAimHook`。仓库提供三份模板，
并一并复制到应用内的 `Contents/Resources/hooks/`：

- `hooks/codex-hooks.example.json`
- `hooks/claude-settings.example.json`
- `hooks/workbuddy-settings.example.json`（WorkBuddy，见下节；用脚本安装更稳）

将模板里的 `/ABSOLUTE/PATH/TO/AgentAim.app` 替换为实际绝对路径，再把 `hooks` 内容**合并**进
自己的配置；不要整份覆盖已有配置。所有命令均同步、`timeout: 1`，转发失败时静默退出 0。
Codex 配置后需在 `/hooks` 中确认信任；模板变化后会重新要求信任。
AgentAim 主程序需要保持运行；状态转发器不会自行启动主程序。

转发器只发送 provider、session/turn ID、事件名、通知子类型、布尔中断标记和时间戳，绝不发送
cwd、错误文本、prompt、工具输入输出、assistant message 或 transcript。通信使用用户私有 Unix
Datagram：运行目录权限 0700、socket 权限 0600、单包上限 8KB。

当前限制：Codex 0.147 不支持异步 hooks、Interrupt 或 StopFailure；Claude Code 2.1.221 也没有
模型思考阶段的 Interrupt。两端在“模型思考时被用户中断”这一场景都可能无法立即通知 AgentAim；
Claude 的工具执行中断可通过 `PostToolUseFailure.is_interrupt` 识别。若 Codex 的受限执行环境禁止
Unix Socket，转发器会按设计静默失败，需要在真实 `/hooks` 环境中做一次状态变化验收。

### 接入 WorkBuddy（CodeBuddy Code）

WorkBuddy 的 hook 机制与 Claude Code 同源，但事件集**少 5 个**：
`PermissionRequest` / `Elicitation` / `ElicitationResult` / `PostToolUseFailure` / `StopFailure`
在它那里都不存在（写进配置只会被当未知事件跳过）。后果最重的一条是：
**「agent 在等我确认」只剩 `Notification` + matcher `permission_prompt` 这一条路**，
漏掉它就等于丢掉 waiting 自动收局 —— 而这正是甲形态下唯一能救用户出来的信号。

配置写进 WorkBuddy 自己的 `~/.workbuddy/settings.json`：

```bash
./scripts/install-workbuddy-hooks.py --dry-run   # 先看会改什么
./scripts/install-workbuddy-hooks.py             # 安装（自动备份、幂等、可重复跑）
./scripts/install-workbuddy-hooks.py --remove    # 卸载：只摘自己的条目
```

**各应用互不影响**，这是硬要求：

- 脚本**只写 WorkBuddy 那一个文件**。Claude Code 的 `~/.claude/settings.json`、
  Codex 的 `~/.codex/{config.toml,hooks.json}`、插件自带的 `hooks/hooks.json`
  一个字节都不碰 —— 可用 `shasum -a 256` 在安装前后比对验证。
- 写入方式是**只追加**：既有的顶层键（`sandbox` / `claw` / `enabledPlugins` …）与既有的
  hook 条目原样保留；已有同一条命令时直接跳过（幂等）；`--remove` 也要求 command 里
  同时含 `AgentAimHook` 与 `--provider workbuddy` 两个标记才摘，不会误伤别人的 hook。
- 转发器本身也把副作用压到零：**不打印任何内容**。所以 `UserPromptSubmit` /
  `SessionStart` 这类「stdout 会进上下文」的事件不会被污染对话；`timeout: 1` 秒 +
  任何失败都 `exit 0`，WorkBuddy 没开时绝不拖慢 agent。
- WorkBuddy 走独立 provider（`--provider workbuddy`），与 Claude Code 的会话分属两个
  命名空间，一个应用的事件改不到另一个应用的状态。

> Provider 是线上协议的一部分：`--provider workbuddy` 需要**新版主程序**在跑，
> 旧版收到会解码失败并静默忽略。装完 hook 记得重启一次 AgentAim。

### 怎么验证 hook 真的通了

**不要看退出码。** 转发器的设计目标就是「失败静默、exit 0」，所以
「投递成功」和「根本没投递」在退出码上完全一样。唯一可靠的判据是：**在 socket 上真收到数据报**。

```bash
./scripts/verify-hook-delivery.py                  # 一次校验 workbuddy / claude / codex
./scripts/verify-hook-delivery.py --provider claude # 只校验一条
```

它给每个 provider 起一个临时 socket、灌一条真实形状的 payload，然后断言：
数据报到了、`provider` 与 `hook_event_name` 对得上、且 `cwd` / `transcript_path` / `prompt` /
`tool_input` 这些私密字段**没有**出现在线上协议里。

#### 这条链路曾经整条是断的（2026-09-14）

`AgentAimHook` 从落地起**一次都没把事件送出去过**。原因在 stdin：
`FileHandle.read(upToCount:)` 在 **EOF 时返回 `nil`**，而旧实现写成
`guard let chunk = try? input.read(...) else { return nil }` ——
于是「JSON 已经完整读进来、接着遇到 EOF」和「读取真的出错」被压成同一条路径，
整个读取函数返回 nil，转发器静默 `exit 0`。

诊断过程值得记下来：`debug` / `release` / `dist` 三个二进制全部复现（排除「包是旧的」），
沙箱外复跑仍然失败（排除「沙箱拦截」），最后用一个只复现读取循环的小程序打印出
「**第 48 字节处 read 返回 nil**」—— 而 payload 正好 48 字节，说明数据读全了、是被 EOF 判死的。
修法是把 nil 与空块都当「读完了」（`AgentAimCore.HookStandardInputReader`），并补了回归测试。

**教训**：`try?` + `guard let` 会把「正常 EOF」和「真错误」压成同一条静默路径。
凡是「失败要静默」的组件，都必须配一个可观测的验收手段 ——
否则「静默 exit 0」会被当成「转发成功」，而它能骗过所有人。

## 自动触发确认：为什么是底部一个圆环

最早的做法是一个首启说明窗，后来是一个「按空格或点击开始」的弹层。两者都被一个
56pt 的圆环取代了，理由是这四件事只能同时满足于「一个不说话的小圆环」：

1. **不能要求点击。** 确认发生之前玩家还在工作，那时候任何被吃掉的点击都是故障；
   而弹层上的「点击开始」按钮本身就在吃点击。
2. **必须能撤回。** 按钮要么点要么不点，圆环可以「移出即归零」。
3. **不需要读文字。** 玩法写在 README / `AGENTS.md` 里，由帮忙安装的 agent 转述 ——
   这也是「极致优雅」的判据：屏幕上不该出现说明书。
4. **必须自己走开。** 10 秒没人理它，就当没发生过。

### 检测悬停为什么不用 `NSTrackingArea`

因为圆环**必须不吃点击**。这两条是互斥的：`ignoresMouseEvents = true` 的窗口收不到
`mouseEntered`，而能收到事件的窗口就一定会在那一块吃掉点击（底部中央正好是 Dock）。
绕开的办法只剩两条：

| 方案 | 权限 | 结论 |
|---|---|---|
| `NSEvent.addGlobalMonitorForEvents` / `CGEventTap` | 辅助功能 / 输入监控 | **否掉**。零权限是这个项目对外的承诺，不能为了一小块悬停检测破功 |
| 轮询 `NSEvent.mouseLocation` 每 50ms | **不需要任何权限** | 采用 |

代价被严格圈住了：轮询只存在于圆环出现的那 ≤10 秒里，**不玩的时候仍然是 0 开销**。
0.05s 的采样间隔带来的最大延迟是 50ms，人眼分辨不出「移出归零」晚了 50ms。

### 什么时候圆环不会出现加载动画

圆环出现时，鼠标可能**已经**在圈里（比如光标就停在屏幕底部中间）。这时如果直接开始计时，
就变成「鼠标放着没动，游戏却自己开了」。所以有一个 `requiresExitFirst` 门：
呈现时先看光标在不在圈里，在的话**必须先移出去一次**，再进来才算「进入」。

因此以下情况不会出现加载动画：

- 圆环出现时鼠标已经在圈内；先移出、再移入后才会开始填充
- 10 秒内从未有效进入，圆环已经超时消失
- 使用菜单「开始训练」时直接开局，根本不显示圆环
- 调试参数 `--dwell-seconds 0` 会跳过动画并立即确认

进度用 `CABasicAnimation(strokeEnd)` 在渲染服务端插值，应用侧只在「进入 / 移出 / 确认」
三个时刻各写一次图层；确认用挂钟时间判定，不依赖动画进度，动画被丢帧也不会让时机漂掉。

## 瞄准模型

**准星在屏幕空间上移动，世界完全静止**。这保留了透明桌面靶场的交互，但灵敏度不再是
屏幕像素倍率：内部先累计与目标游戏相同的虚拟转角，再把转角投影为准星位置。

Aimlabs 等三维训练器是固定准星、旋转相机；AgentAim 没有三维世界，所以不能照搬画面结构。
两者可以共享同一个可验收口径：相同鼠标计数产生相同转角，FOV 只负责把该转角投影成视觉距离，
不参与或篡改 `cm/360`。因此切换 VALORANT / CS2 后，显示的游戏数字会改变，物理角增益保持不变；
选择不同游戏时，屏幕距离只会因为该游戏真实 FOV 不同而变化。

指针仍然锁定（`CGAssociateMouseAndMouseCursorPosition(0)`），所以鼠标永远不会撞到屏幕
边缘、位移不会断流。准星位置由位移累加得出并夹在屏幕内，反向移动会立刻脱出，没有死区。

世界静止后准星可达整个屏幕，目标出生范围因此可以放大到 ±34% 屏宽 / ±28% 屏高，
只需满足 `出生半径 + 目标半径 ≤ 半个屏幕`。

## 调参

```bash
swift run --target-scale 0.85      # 目标尺寸倍率，默认 1.0
swift run --crosshair-scale 1.25   # 准星点尺寸倍率，默认 1.0
swift run --sensitivity 1.0        # 调试用：绕过 cm/360 换算，直接指定「一个鼠标计数走几个屏幕点」
                                   # 正常使用不要碰它 —— 走菜单栏「灵敏度」填游戏内的真实数值
swift run --opaque                 # 退回旧的深色全屏背景，做 A/B 对照
swift run --dump-assets /tmp/aim   # 导出真实位图后退出（调试，见「怎么验证画面」）
```

覆盖层、确认圆环与兜底的调试开关：

```bash
swift run --show-menu-bar          # 层级降到菜单栏之下（23），菜单栏在游戏期间可见可点
swift run --autostart              # 跳过悬停确认直接开局（调试用，不写偏好设置）
swift run --dwell-seconds 0        # 不要求悬停，圆环一出现就开始（等价于上面的直接开局）
swift run --dwell-timeout 3        # 圆环「没人理」的宽限从 10 秒改短，便于验收
swift run --idle-seconds 5         # 把「无操作多久自动收局」从 90 秒改短，便于验收
swift run --show-settings              # 启动后直接打开统一设置面板（调试用）
swift run --probe-ui <path>        # 把启动后 1s / 8s / 12s 的窗口状态写出来（调试）
```

默认层级是 `.screenSaver`（1000），连菜单栏与通知一起盖住 —— 这是「上班时不被发现」的前提，
代价是玩的时候菜单栏点不到、出口只剩键盘；`--show-menu-bar` 把它降到 `mainMenu - 1`（23）。

`--probe-ui` 是为一个具体坑配的：**「窗口没出现」是静默失败** —— 退出码 0、日志空、进程还活着。
它把观测同时写进文件和一个独立 UserDefaults suite（`com.agentaim.probe`），因为用 `open`
启动时应用落在真实路径上、而校验用的 shell 可能被沙箱套了一层路径视图，只看文件会误判。
读法：`defaults read com.agentaim.probe`。

它同时是「圆环到底出现没有、10 秒后有没有消失、有没有在吃点击」的**验收手段**：

```bash
swift run --probe-ui /tmp/probe.txt &
sleep 13 && kill %1
defaults read com.agentaim.probe
#   at1s / at8s : dwellRing=present, isVisible=true, ignoresMouseEvents=true,
#                 canvasFrame=80x80, ringFrame=56x56, ringPadding=12
#   at12s       : dwellRing=nil ← 10 秒超时确实把它收走了
```

`--idle-seconds` 存在的理由和它一样：这条兜底是删掉 30 秒时限之后唯一「不需要知道任何规则
就会发生」的出口，如果只能靠干等 90 秒来验证，就等于没有验收手段。

`--dwell-timeout` 也是同一类：圆环「人手一伸进来就不再倒计时」这条规则，用
`--dwell-timeout 3 --dwell-seconds 2` 在 5 秒内就能验完 —— 在 t=2s 才开始悬停，
如果规则失效，圆环会在 t=3s 把填到一半的圈收走，那一局永远不会开始。

三个开关都会原样写进探针输出，所以数字对不上时一眼能看出「是不是启动参数没生效」。

`DwellConfirm.windowFrame` 用的是屏幕坐标（Cocoa，左下角原点），和 `NSWindow.frame` /
`NSEvent.mouseLocation` 同一套 —— **不要**和 `CGWarpMouseCursorPosition` 混用，它用的是
主屏左上角原点。`.workbuddy/probe/hover-probe.swift` 是一个把光标挪进圆环的小工具，
用来验收自动触发后的「悬停 2 秒 → 开局」路径。

目标直径 = `屏宽 × 0.030...0.040 × √targetAreaFactor`，`targetAreaFactor` 默认 0.5。

> **「缩为一半」按面积算，不按直径算。** 面积减半对应直径 ×√0.5（≈0.707）；
> 直径直接砍半会让面积只剩 1/4，视觉上会突然小一大截。改 `targetAreaFactor` 即可。

在 1470pt 宽的屏上当前是 **31–42pt**（占屏宽 2.1%–2.8%），换显示器时视觉大小一致。

### 目标尺寸的演变

| 版本 | 直径（1470pt 屏） | 相对最早直径 | 相对最早面积 |
|---|---|---|---|
| 最早（固定点数） | 70–94pt | 基准 | 基准 |
| 改为按屏宽取比例 | 44–59pt | 0.63x | 1/2.5 |
| 现在（面积再减半） | 31–42pt | 0.44x | ≈1/5 |

目标变小后，几何约束 `出生半径 + 目标半径 ≤ 半个屏幕` 反而更宽松（余量从 214pt 增到 220pt），
所以**尺寸和出生范围可以独立调**，不必联动。

### 准星为什么是一个点

四段臂版本的臂长 19pt、线宽 3pt，会压在靶子上干扰判读；而且臂的视觉长度和命中判定
（点是否落在圆内）没有对应关系。改成单点后，**所见即判定**：点中心就是判定中心，
点的大小只影响可辨识度。

点必须带深色衬底（半径 +1.3pt、60% 黑）——靶子是亮青色渐变，纯白点在亮底上会糊掉。
这条不是美观问题，是功能问题。

> 视觉常量还有一处容易被忽略的耦合：靶子位图的圆心线距边缘 1.5pt、描边线宽 3pt，
> **圆的外沿正好贴合位图边界**，所以图层 `bounds` 就等于靶子实际直径。
> 早先内缩 3pt 时可见圆比设定值小约 5%，尺寸怎么调都对不上手感。

## 怎么验证画面

本机没有「屏幕录制」权限，`screencapture` 只会拍到壁纸（详见文末），所以**不要用截图**
核对绘制结果。用程序自己把位图写出来：

```bash
swift run --dump-assets /tmp/aim
#   crosshair.png  64×64px     准星位图
#   target.png     256×256px   靶子位图
#   ring.png       256×256px   命中光环位图
#   composite.png  680×400px   按真实直径并排的两个靶子 + 真实大小的准星
```

`composite.png` 是最有用的一张：靶子按当前屏幕宽度换算成实际直径绘制，准星按实际点数
压在大靶子上，一眼能看出「点相对靶子有多大」。这个开关走的是**生产代码路径**，
不会出现「验证用的副本和实际实现悄悄不一致」。

## 运行

```bash
swift run
```

启动后从桌面左上角 `AgentAim` 菜单选择「开始训练」会直接开局；鼠标移动瞄准，
左键射击，`Esc`（或 `Q`、右键）
安全收局并回到开局前的应用。

也可以生成可直接双击运行的 macOS 应用（见「安装」）：

```bash
./scripts/package.sh
open dist/AgentAim.app
```

## 实现路线：AppKit + Core Animation 图层

**没有渲染循环，也没有 SpriteKit。** 一切变化都是事件驱动的：鼠标移动改准星图层的
`position`，点击改靶子图层，时长以 1Hz 刷新一个文本图层。一局只有一个定时器，
而且它同时干两件事：推进时长、检查人是不是已经走了。

关键点不在「用哪个框架」，而在**更新方式**：

- **重绘像素**（SpriteKit 每帧光栅化，或 `drawRect` + `setNeedsDisplay`）——
  每帧都会产生新的全屏后备存储，内存随负载上涨。
- **移动图层**（本实现）——全屏背景只光栅化一次，之后准星和靶子只是改 `position`，
  渲染服务端负责合成，应用侧不再产生任何新的大块内存。

这条路线是实测选出来的，不是推演的。四种架构在同一台机器上的稳态 footprint：

| 架构 | 待机 | 满载 |
|---|---|---|
| 纯 AppKit 静态绘制（从不重绘） | 13.8 MB | — |
| 视图反复重绘（`drawRect` 脏矩形） | 54.3 MB | **215.1 MB** |
| **Core Animation 图层（本实现）** | **58.8 MB** | ≈ 58.8 MB |
| SpriteKit（旧实现） | 133.3 MB | **206.8 MB** |

两条结论：

1. **「换更底层的框架」不等于更省。** 视图重绘那条路满载时比 SpriteKit 还差，
   已被否掉。真正省的是把「重绘像素」换成「移动图层」。
2. **「待机停掉渲染循环」这类优化对内存几乎没影响**，它省的是 CPU。
   内存由框架固定开销 + 全屏表面的数量与生命周期决定，两件事不能混为一谈。

### 选型探针

`Prototypes/` 下保留了两个最小可运行探针，用来复现上面的数字：

```bash
swiftc -swift-version 6 -O -o /tmp/agentaim-minimal Prototypes/AppKitMinimal/main.swift -framework AppKit
swiftc -swift-version 6 -O -o /tmp/calayer-probe  Prototypes/CALayerProbe/main.swift  -framework AppKit
```

- `AppKitMinimal` —— 视图重绘方案。带 `--stress`（60Hz 强制满载）、`--no-bg`、
  `--bg-image` 等归因开关，用于证明「视图重绘并不省内存」。
- `CALayerProbe` —— 图层方案。带 `--stress`，以及 `--ballast <MB>`
  （分配并写满指定内存，用来校准测量链路本身是否灵敏）。

注意：探针需要 `-swift-version 6`，否则 `main.swift` 顶层代码的 MainActor 推断不生效。

### 与旧实现（SpriteKit）的对比

| | SpriteKit | 本实现 | |
|---|---|---|---|
| 待机 | 133.3 MB | **12.3 MB** | ↓ 10.8x |
| 对局中 | 206.8 MB | **12.6–13.8 MB** | ↓ 15x 以上 |
| 对局 vs 待机 | +73 MB | **±0.0–1.2 MB** | 不再随负载增长 |

旧实现的同日测量里，「待机 57.1 → 对局 57.3」已经证明这条路线与负载无关；
之后加入命中光环图层池（6 × 256×256px）使基线升到 58.8 MB 并保持稳定。

### 从那 58.8 MB 再砍到 12.3 MB：全屏背景位图

上面那张「四种架构」的对比表是在**旧的不透明形态**下测的（全屏深色渐变 + 网格）。
改用「甲形态」（整屏透明覆盖层）时，最大的一笔开销自己消失了：

一张 1470×956pt @2x 的渐变位图 ≈ 22 MB 数据，实测吃掉约 **40 MB footprint**
（同一台机器：54.6 MB → 12.3 MB）。所以在透明形态下它不是「设成透明」，
而是**根本不生成** —— `rebuildBackground()` 直接 return，`--opaque` 可以退回旧形态做对照。

**这条结论对任何全屏 AppKit 应用都成立：不要给全屏窗口铺背景图。**

当前实测（2026-09-14，debug 构建，每次测 7–14 秒）：

| 形态 | footprint |
|---|---|
| 待机（启动圆环亮着的那 10 秒，之后只剩 Dock 常驻） | 12.0 → 12.4 MB |
| 待机稳态 | **12.3 MB** |
| 对局中 | 12.6 / 13.5 / 13.8 MB（三次） |

确认圆环使用 80×80 的透明独立小窗承载 56×56 的可见圆环，四周 12pt 留给描边与阴影，
避免被方形窗口裁切。它的轮询只存在于那 ≤10 秒里，**没有带来可测的开销**。

旧的 SpriteKit 实现保留在 `.workbuddy/backup/main-spritekit-2026-09-13.swift`。

## 性能原则

- 原生 Swift/AppKit + QuartzCore，无 Electron、Unity、WebView、SpriteKit
- 无渲染循环：静止时 CPU 为 0，不重绘、不空转
- 所有视觉均由代码绘制，无外部素材
- 全屏位图只在启动、窗口尺寸变化、屏幕缩放变化时生成（透明形态下**根本不生成**）
- 命中光环用固定大小的图层池（6 个）复用，连击再快也不分配新图层
- 一局只有一个 1Hz 定时器；确认圆环的 50ms 轮询只存在于它出现的那 ≤10 秒

### 命中反馈为什么要局部化

最初的做法是一块覆盖全屏的纯色图层，命中时 25% 不透明度闪 0.11s。
问题是它**让整块屏幕一亮**：视野被打断，亮度突兀，而且和准星位置无关，
给不出「我打中了那个靶子」的空间信息。改成命中点的光环扩散后，
反馈落在正确的位置上，屏幕整体亮度不变，而且依然是纯图层动画
（只改 `position` / `transform.scale` / `opacity`），渲染服务端插值，应用侧零绘制。

### 测量口径

用 `proc_pid_rusage` 读 `ri_phys_footprint`，重复 3 次取稳态值。测量脚本见
`~/.workbuddy/skills/macos-app-resource-footprint/`。

**footprint 与 RSS 会给出相反的排序，必须认清口径：**

| | 本实现（透明形态，2026-09-14） | SpriteKit 旧版 |
|---|---|---|
| footprint（活动监视器「内存」） | **12.3–13.8 MB** | 133–207 MB |
| RSS | 30–35 MB | 118 MB |

- `phys_footprint` = internal + compressed + iokit_mapped − purgeable_nonvolatile。
  它包含**压缩内存**和 **Metal / IOSurface 的 GPU 映射内存**（这部分不在 RSS 里），
  与活动监视器显示、以及系统内存压力判定一致。
- `RSS` 会把**共享的框架只读页**算进每个进程，重复计数，作为「这个应用吃多少内存」
  的指标偏虚高。

SpriteKit 的 footprint 远大于 RSS，正是因为它的 Metal 缓冲走 iokit 映射。
**本项目以 footprint 为主口径。**

#### 两个把人骗过的坑

1. **不要用 `proc_pidinfo` 加手算结构体偏移。** 按 `ri_uuid(16B)` + 8 字节字段
   手算下标读出来的 footprint 是 **1100 万 MB** 这种量级，而它看起来"像个数字"，
   很容易被当成结果。正确做法是用 `proc_pid_rusage` 配一个字段布局完整的
   `ctypes.Structure`。**判据：故意传一个不存在的 PID，必须返回错误；
   如果它照样给出数字，说明这个读法本身就是坏的。**
2. **读数为 0 或极小值时视为无效。** 进程启动完成前的窗口期会读到 0.1 MB ——
   曾经因此得出"8.1 MB"的结论，复测三次后稳定在 55–56 MB。
   关键结论一律重复 2–3 次，且要能解释数字的大小（持有 22.5 MB 位图的进程
   不可能只占 8 MB）。

#### 截图为什么拍不到窗口

`screencapture` 拍出的整屏图里只有桌面壁纸、没有应用窗口，**不等于窗口没画出来**。
这一条曾经导致一个错误结论（把 `isPaused` 的待机暂停改回低帧率）。

在没有「屏幕录制」权限时，`screencapture` 只会返回壁纸，但窗口其实是正常的。
要证明窗口存在，不要靠截图，用 `CGWindowListCopyWindowInfo` 读它的尺寸和层级：

```bash
# AgentAim 窗口: id=177693 layer=1000 1470x956pt
```

`layer=1000` 即 `.screenSaver` 层级，`1470x956pt` 是整屏尺寸 —— 这才是"窗口确实
盖满全屏"的证据（用 `--show-menu-bar` 启动时是 `layer=23`，刻意压在菜单栏之下）。
要检查窗口内部的绘制结果，用 `--dump-assets` 把真实位图写出来看
（见「怎么验证画面」），比截图可靠得多，也快得多。
