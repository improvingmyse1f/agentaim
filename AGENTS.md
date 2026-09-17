# AGENTS.md — 如果你正在帮用户安装 AgentAim

这个文件是给**帮忙安装的 agent** 看的：装完之后，请把下面「念给用户听」那一节
用自己的话转述给用户。应用本身不会解释自己，这是刻意的设计。

---

## 1. 它是什么

一个 macOS 瞄准小游戏，用来填掉 AI coding agent（Codex / Claude Code / WorkBuddy）
干活时那几十秒的等待。它会显示在 Dock 和 `⌘ Command + Tab`；激活应用后，从桌面左上角
`AgentAim` 菜单进入。**默认什么都不做** —— 不自动开局、不开机自启，
需要用户显式打开。

只有一个例外：**双击启动后，屏幕底部中央会出现一个 56pt 的圆环**，10 秒后自己消失。
那是唯一会主动出现的东西，用来证明"它真的启动了"。

## 2. 安装

```bash
cd <repo>
./scripts/package.sh
cp -R dist/AgentAim.app /Applications/     # 或用户指定的位置
```

产物是 ad-hoc 签名（不是开发者签名），所以如果是从网络下载的副本，Gatekeeper 会拦下它。
要么让用户右键 →「打开」，要么直接：

```bash
xattr -dr com.apple.quarantine /Applications/AgentAim.app
```

然后 `open /Applications/AgentAim.app`。**不需要授予任何权限** —— 不用辅助功能，
不用输入监控，不用屏幕录制。如果系统弹权限窗口，说明装错了东西。

## 3. 念给用户听（这一节是重点）

> 装好了。它会出现在 Dock 和 `⌘ Command + Tab`；点击应用后，设置与训练入口在桌面左上角
> 的 `AgentAim` 菜单里。训练不会自己开始。
>
> - **想玩**：桌面左上角 `AgentAim` →「开始训练」，会直接开始，不需要再经过圆环。
> - **不想玩了**：按 `Esc`。`Q` 和右键也一样。
>   玩的时候屏幕上只有一个很淡的计时，没有 30 秒限制，玩多久都行。
> - **走开了忘了关**：90 秒没开枪也没动鼠标，它会自己把屏幕还给你。
> - **注意**：开始之后鼠标点击会被游戏接管（所以 Shift+点击、切窗口都不行），
>   这是设计如此，不是卡住。按 `Esc` 立刻恢复。
> - **万一鼠标真的不动了**：在终端执行 `killall AgentAim`，它会先把鼠标状态还原再退出。
> - **想让它在 Agent 干活时自动开始**：`AgentAim` →「设置…」，打开「Agent 工作时自动开始」。
>   打开后也只是自动亮起那个圆环，仍然需要你把鼠标停进去两秒才会接管屏幕。
> - **想让手感和你平时玩的游戏一致**：`AgentAim` →「设置…」，选游戏（VALORANT / CS2），
>   填游戏内的原始灵敏度即可。鼠标 DPI 不用重复设置；只有想查看准确的 `cm/360` 时，
>   才在可选项里填写鼠标软件中的真实 DPI。默认是 VALORANT `0.327`；切换游戏配置时会
>   自动换算并保持同一鼠标下的手感。改完从下一局开始生效。

**请务必把「按 Esc 退出」和「killall AgentAim」这两条说清楚。**
这个应用在玩的时候会吃掉整屏点击，用户如果不知道出口，只会在原地乱点。

## 4. 可选：接入 hooks 做状态感知

装完之后可以让它知道 agent 的工作 / 等待 / 回复状态，从而在 agent 需要人时自动收局：

```bash
./scripts/install-workbuddy-hooks.py --dry-run   # 先看会改什么
./scripts/install-workbuddy-hooks.py             # 安装
```

- Claude Code / Codex 用 `hooks/` 下的模板手动合并进各自的配置，
  **不要整份覆盖用户已有的配置**。
- 硬约束：**不得影响其它应用的 hook**。脚本只写目标应用自己的配置文件、
  只追加不替换、幂等、`--remove` 只摘带自己标记的条目。
- 验完用 `./scripts/verify-hook-delivery.py` —— **不要看退出码**。
  转发器的设计目标就是「失败静默、exit 0」，所以退出码区分不出成功和"根本没投递"。
  唯一可靠的判据是 socket 上真收到了数据报。
- 装完 hook 记得重启一次 AgentAim。

## 5. 交付前自检

```bash
swift build -c release && swift test        # 65 个测试
./scripts/package.sh
```

玩法向量（`fixtures/gameplay-v1.json`）是 macOS 与 Windows 两端唯一的「手感合同」：
靶子出生几何、命中判定、计分公式与随机数消耗顺序全在里面。Swift 侧由
`Tests/AgentAimCoreTests/GameplayVectorTests.swift` 回放它，Rust 侧由
`port/agentaim-core/tests/golden_vectors.rs` 回放**同一份文件**。
**改了玩法就必须重新生成**：`AGENTAIM_WRITE_FIXTURES=1 swift test --filter writesFrozenVectors`
（生成完记得连同改动一起提交，并在 PR 里说清「Windows 侧要同步」）。

想肉眼核对两端是不是同一局：`--target-seed <数字>` 固定本局随机种子，
两端吃同一个种子应当画出**完全相同**的靶位。

**Rust 侧（可移植核心 + 将来的 Windows 外壳）**在 `port/`，是个独立 workspace：

```bash
cd port && cargo test        # 8 个测试，全部是跨端对表
```

它**零依赖**（serde/serde_json 只在 dev-dependencies），不碰窗口、不碰渲染。
本机 cargo 需要 `~/.cargo/bin/cargo`（没有的话 `rustup-init -y --profile minimal`）。
对表容许浮点在 1e-9 内，但命中判定与计分必须逐字段精确相同 —— 原因见
`port/agentaim-core/tests/golden_vectors.rs` 里 `FLOAT_TOLERANCE` 的注释。

界面相关的改动（尤其是窗口、圆环、层级）**不能靠截图验收** —— 本机没有屏幕录制权限时
`screencapture` 只会拍到壁纸。用可读的数字：

```bash
swift run --probe-ui /tmp/probe.txt &
sleep 13 && kill %1
defaults read com.agentaim.probe
```

期望看到：`at1s` / `at8s` 时 `dwellRing=present, isVisible=true, ignoresMouseEvents=true,
canvasFrame=80x80, ringFrame=56x56, ringPadding=12`，`at12s` 时 `dwellRing=nil`
（80pt 透明画布为描边与阴影留白，可见圆环仍为 56pt；10 秒超时确实收走了）。
`isPlaying` 全程应为 `false`（没有人去悬停）。

要验收自动触发后的「悬停 2 秒 → 开局」路径，用
`.workbuddy/probe/hover-probe.swift`（把光标挪进圆环）：

```bash
swiftc -O .workbuddy/probe/hover-probe.swift -o /tmp/hover-probe
swift run --probe-ui /tmp/p.txt --idle-seconds 20 &
sleep 1 && /tmp/hover-probe 735 <圆环中心 y> 3
# 8s / 12s 的快照应显示 isPlaying=true
```

## 6. 不要做的事

- **不要给全屏窗口铺背景图。** 一张 1470×956pt @2x 的渐变位图会吃掉约 40MB footprint
  （实测 54.6 MB → 12.3 MB）。透明形态下必须"不生成"，不是"设透明"。
- **不要为了悬停检测去申请权限**（`CGEventTap` / `addGlobalMonitorForEvents`）。
  轮询 `NSEvent.mouseLocation` 不需要任何权限，代价可控。
- **不要让任何行为"默认开启"。** 首个陌生用户不该被任何自动行为惊到 ——
  自动开局默认关，登录自启默认关。
- **不要给玩的时候加时限。** 30 秒一局已经删掉；那条时限曾经是新手唯一的必然出口，
  所以它必须由「90 秒无操作自动收局」来顶替，不能只删不加。
- **不要用 `ps` / `top` 测内存**，也不要用 RSS 下结论。用
  `~/.workbuddy/skills/macos-app-resource-footprint/scripts/footprint.py` 读
  `phys_footprint`（活动监视器口径），关键结论重复 2–3 次。
