import AppKit
import AgentAimCore
import QuartzCore
import ServiceManagement

// AgentAim —— Agent 运行等待期间的轻量化瞄准训练。
//
// 实现路线：AppKit + Core Animation **图层**，没有渲染循环。
//
// 为什么不是 SpriteKit：实测（同一台机器，footprint = 活动监视器口径）
//   · SpriteKit                待机 133MB → 对局 207MB
//   · 视图反复重绘（drawRect）  待机  54MB → 满载 215MB   ← 比 SpriteKit 还差
//   · Core Animation 图层      待机  55MB → 满载  55MB   ← 本实现，几乎不随负载变化
//
// 关键差别不在「用哪个框架」，而在**更新方式**：
//   SpriteKit / drawRect 的每一帧都会重新光栅化全屏内容，产生新的后备存储；
//   本实现里全屏背景只光栅化一次，之后准星和靶子只是**改 position**——
//   渲染服务端负责合成，应用侧不再产生任何新的大块内存。
//
// 由于一切变化都是事件驱动的（鼠标移动 / 点击 / 倒计时），这里连渲染循环都不需要。

private let targetCount = 3

// 一局**没有时限**：什么时候结束完全由用户决定（Esc / Q / 右键），
// 或者由 Agent 状态变化、以及下面这条「久未操作」兜底替你决定。
//
// 去掉 30 秒一局不只是「更自由」：时限曾经是新手唯一的必然出口（不管会不会按 Esc，
// 30 秒后屏幕都会自己还给你）。删掉它，就等于删掉那条不需要任何知识的护栏，
// 所以这个兜底不是可选项，而是那次删除的配套。
//
// 判据取「既没开枪也没动鼠标」，而不是只看开枪：慢慢瞄准的人不该被误判成已经离开。
//
// 时长可以用 `--idle-seconds` 覆盖。理由和 --dwell-seconds 一样：这条兜底是删掉
// 30 秒时限之后唯一「不需要知道任何规则就会发生」的出口，它要能被验收，
// 而不是只能靠干等 90 秒来"相信它是好的"。
private let idleAbandonSeconds: TimeInterval = max(1, Double(numericArgument("--idle-seconds") ?? 90))

// 悬停确认圆环 —— 它是自动触发训练时的开始确认，也是「双击之后屏幕上到底发生了什么」的答案。
//
// 双击启动或 Agent 开始工作时，圆环出现在屏幕底部中央；鼠标移进去停满 2 秒才开始一局，
// 中途移出立即归零，10 秒没人理它自己消失。用户从菜单明确点「开始训练」则直接开局。
//
// 它取代了两样东西：
//   · 原来那个首启说明窗（内容太多，而且它是唯一会主动出现的界面）
//   · 原来那个「按空格或点击开始」的开始弹层
// 换成圆环之后：零文字、零按钮、不要求点击（确认之前点击会落到用户的工作窗口上），
// 而且它自己会走开。玩法写在 README / AGENTS.md 里，由帮忙安装的 agent 转述。
private let dwellRingDiameter: CGFloat = 56
private let dwellRingLineWidth: CGFloat = 4
/// 圆环不能和透明窗口一样大：描边抗锯齿与阴影都会越过几何边界，贴着窗口画会被方形边缘裁掉。
/// 80pt 画布让 56pt 圆环四周各留 12pt，也给后续轻微缩放动效留出空间。
private let dwellCanvasDiameter: CGFloat = 80
private let dwellRingPadding: CGFloat = (dwellCanvasDiameter - dwellRingDiameter) / 2
/// 两次读鼠标坐标之间的间隔。轮询只发生在圆环存活的那 ≤10 秒里。
private let dwellPollInterval: TimeInterval = 0.05
/// 圆环出现后多久没人理就自己消失。`--dwell-timeout` 可覆盖，理由同 `--dwell-seconds`：
/// 「人手伸进来就不再计时」这条要靠它才能快速验证 —— 否则得等满 10 秒才知道有没有被截断。
private let dwellTimeoutSeconds: TimeInterval = max(1, Double(numericArgument("--dwell-timeout") ?? 10))
/// 圆环离「可用区域」底边的距离 —— 用 `NSScreen.visibleFrame` 定位，
/// 它已经把 Dock 与菜单栏排除在外，所以不用自己算 Dock 在哪。
private let dwellBottomInset: CGFloat = 44

// 停留满多少秒算确认。调试时可用 `--dwell-seconds` 覆盖，
// 传 0 会退化成「不等悬停，直接开始」，等价于原来的 --autostart。
private let dwellConfirmSeconds: TimeInterval = max(0, Double(numericArgument("--dwell-seconds") ?? 2))

private func numericArgument(_ name: String) -> CGFloat? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    guard let value = Double(arguments[index + 1]) else { return nil }
    return CGFloat(value)
}

// 取一个字符串参数；后面跟着的是另一个开关时视为「没给」，回退到默认值。
private func stringArgument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    return value.hasPrefix("--") ? nil : value
}

// 可通过命令行覆盖：--target-scale 0.85 --sensitivity 1.0 --crosshair-scale 1.2。
// --sensitivity 保留为调试用的「屏幕点数倍率」；正常使用走 VALORANT / CS2 配置。
private let targetScale: CGFloat = max(0.2, numericArgument("--target-scale") ?? 1)
private let crosshairScale: CGFloat = max(0.4, numericArgument("--crosshair-scale") ?? 1)
private let sensitivityArgument = numericArgument("--sensitivity")

// 目标尺寸、出生范围、最小间距这些数字**不在这里** ——
// 它们全部住在 `AgentAimCore.TargetFieldParameters`（`Sources/AgentAimCore/TargetField.swift`）。
//
// 搬走不是因为这里放不下，而是因为 Windows 侧要用的必须是**同一组数字**：
// 留一份副本在这里，就等于允许两端各自漂移，而漂移只会以「手感不太一样」
// 这种无法定位的现象出现。尺寸倍率 `--target-scale` 仍在命令行，由
// `syncFieldGeometry()` 注入靶场。

// 固定本局的随机种子。默认每局从系统随机源取一个新种子；指定之后，
// **两端可以吃同一个种子跑出同一局** —— 跨端比对时这是唯一能逐帧对齐的办法，
// 也是 `fixtures/gameplay-v1.json` 那套向量成立的前提。
private let targetSeedArgument = stringArgument("--target-seed").flatMap { UInt64($0) }

// 命中光环的图层池。池子复用了就不再分配，同时支持极快连击时多个光环并存。
private let hitRingCount = 6
// 准星位图边长。现在只是一个点，尺寸跟着缩到最小可容纳范围（--crosshair-scale 调大时也不裁切）。
private let crosshairImageSize: CGFloat = 32

private enum GameState {
    case ready
    case playing
    case finished
}

private enum RoundEndReason {
    /// 90 秒里既没开枪也没动过鼠标 —— 人已经走了，把屏幕还回去。
    case idle
    /// Esc / Q / 右键。
    case escape
    /// 菜单栏「隐藏」。
    case hidden
    /// Agent 从工作中变成等待/已回复 —— 该去处理它了，必须立刻把点击还给用户。
    case agent(AgentAttention)
    case termination
}

private extension AgentAggregate {
    var hudText: String {
        switch phase {
        case .idle: return "Agent 空闲"
        case .working: return sessionCount > 1 ? "\(sessionCount) 个 Agent 工作中" : "Agent 工作中"
        case .waiting: return "Agent 等待确认"
        case .responded: return "Agent 已回复"
        case .failed: return "Agent 运行失败"
        }
    }

    var menuText: String {
        "当前状态：\(hudText)"
    }
}

// MARK: - 视觉常量

private let backgroundColorTop = NSColor(calibratedRed: 0.02, green: 0.027, blue: 0.048, alpha: 1)
private let backgroundColorBottom = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.12, alpha: 1)
private let baseColor = NSColor(calibratedRed: 0.025, green: 0.032, blue: 0.055, alpha: 1)
private let accentColor = NSColor(calibratedRed: 0.35, green: 1, blue: 0.83, alpha: 1)
private let pillColor = NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.72, alpha: 0.18)
private let pillBorderColor = NSColor(calibratedRed: 0.42, green: 1, blue: 0.88, alpha: 0.72)
private let workingColor = NSColor(calibratedRed: 0.43, green: 1, blue: 0.72, alpha: 0.7)

// v5「甲」形态：整屏透明覆盖层，工作窗口透过它可见。
//
// 关掉全屏背景位图不只是视觉取舍 —— 那张 1470×956pt @2x 的渐变位图是启动期最大的一笔
// 图层后备存储（约 22MB），透明形态下它既看不见又白占内存，所以是「不生成」而不是「设透明」。
// 加 --opaque 可以退回旧的深色背景，用来做 A/B 对照。
private let transparentOverlay = !CommandLine.arguments.contains("--opaque")

// 覆盖层层级：默认 `.screenSaver`，连菜单栏与通知一起盖住 —— 这是「上班时不被发现」的前提。
// 代价必须写在明处：玩的时候左上角应用菜单点不到，**唯一的出口是键盘**。
// 所以出口做了冗余（Esc / Q / 右键），并在 HUD 上常显。
// `--show-menu-bar` 把层级压到 mainMenu(24) 之下、普通窗口之上：菜单栏在游戏期间仍然
// 可见可点，等于天然多一个出口 —— 给不在乎隐身的用户。
private let overlayCoversMenuBar = !CommandLine.arguments.contains("--show-menu-bar")

private let overlayWindowLevel: NSWindow.Level = overlayCoversMenuBar
    ? .screenSaver
    : NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)

// UserDefaults 键名集中在这里，避免字符串散落各处。
//
// 不做任何需要用户先设置的事，是这个应用对陌生用户的默认承诺。
// 首启说明窗和「前几局引导」已经拆掉；这些键只保存统一设置窗口里的显式选择。
private enum DefaultsKey {
    static let autoStart = "autoStartOnAgentWork"
    static let sensitivityProfile = "sensitivityProfile"
    static let sensitivityValue = "sensitivityValue"
    static let mouseDPI = "mouseDPI"
    static let csDisplayMode = "csDisplayMode"

    /// `--probe-ui` 专用：调试观测写进这个独立 suite，
    /// 既不会污染真实偏好，又能被 `defaults read` 从任何环境读到。
    static let probeSuite = "com.agentaim.probe"
}

private nonisolated(unsafe) let backgroundGradient: CGGradient = {
    let colors = [backgroundColorTop.cgColor, backgroundColorBottom.cgColor] as CFArray
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
}()

private nonisolated(unsafe) let targetGradient: CGGradient = {
    let colors = [
        NSColor(calibratedRed: 0.58, green: 1, blue: 0.98, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.82, alpha: 1).cgColor
    ] as CFArray
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
}()

// MARK: - 图像工厂
//
// 这三张位图各只生成一次，之后反复复用。靶子位图固定 128×128，
// 实际尺寸由图层 bounds 缩放得到，所以不同大小的靶子不需要重新光栅化。

private func makeImage(pixelSize: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
    let width = Int(pixelSize.width * scale)
    let height = Int(pixelSize.height * scale)
    guard width > 0, height > 0 else { return nil }
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx)
    return ctx.makeImage()
}

private func makeBackgroundImage(size: CGSize, scale: CGFloat) -> CGImage? {
    makeImage(pixelSize: size, scale: scale) { ctx in
        ctx.drawLinearGradient(
            backgroundGradient,
            start: .zero,
            end: CGPoint(x: size.width, y: size.height),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.05).cgColor)
        ctx.setLineWidth(1)
        let spacing: CGFloat = 56
        var x: CGFloat = 0
        while x <= size.width {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: size.height))
            x += spacing
        }
        var y: CGFloat = 0
        while y <= size.height {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: size.width, y: y))
            y += spacing
        }
        ctx.strokePath()
    }
}

private func makeTargetImage(scale: CGFloat) -> CGImage? {
    let side: CGFloat = 128
    return makeImage(pixelSize: CGSize(width: side, height: side), scale: scale) { ctx in
        // 描边线宽 3pt，把圆心线放在距边缘 1.5pt 处，圆的外沿正好贴合位图边界。
        // 这样图层 bounds 就等于靶子的实际直径 —— 之前内缩 3pt 会让可见圆
        // 比设定值小约 5%，尺寸怎么调都对不上手感。
        let rect = CGRect(x: 1.5, y: 1.5, width: side - 3, height: side - 3)
        ctx.addEllipse(in: rect)
        ctx.clip()
        // drawsBeforeStartLocation 不能省：起始半径 2pt 以内若不被填充，
        // 高光中心会透出底层颜色，显示成一个黑洞。
        ctx.drawRadialGradient(
            targetGradient,
            startCenter: CGPoint(x: rect.minX + rect.width * 0.369, y: rect.minY + rect.height * 0.664),
            startRadius: 2,
            endCenter: CGPoint(x: rect.midX, y: rect.midY),
            endRadius: rect.width * 0.5,
            options: [.drawsBeforeStartLocation]
        )
        ctx.resetClip()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.82).cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: rect)
    }
}

// 命中光环：与靶子同尺寸的圆环，命中时在原地扩散淡出。
// 相比整屏闪一下，局部反馈不会打断视野，也不会让屏幕整体一亮。
private func makeRingImage(scale: CGFloat) -> CGImage? {
    let side: CGFloat = 128
    return makeImage(pixelSize: CGSize(width: side, height: side), scale: scale) { ctx in
        let rect = CGRect(x: 3, y: 3, width: side - 6, height: side - 6)
        ctx.setStrokeColor(accentColor.cgColor)
        ctx.setLineWidth(6)
        ctx.strokeEllipse(in: rect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: rect)
    }
}

// 准星：一个实心点。
//
// 去掉四段臂的原因：臂会压在靶子上干扰判读，而点小、位置唯一，
// 「打没打中」只由点是否落在圆内决定，命中判定和视觉所见完全一致。
// 深色衬底不是装饰 —— 靶子是亮青色渐变，纯白点在亮背景上会糊掉，
// 一圈稍大的半透明黑正好把白点从亮底里拉出来。
private func makeCrosshairImage(scale: CGFloat) -> CGImage? {
    let size = crosshairImageSize
    return makeImage(pixelSize: CGSize(width: size, height: size), scale: scale) { ctx in
        ctx.translateBy(x: size / 2, y: size / 2)
        let dotRadius: CGFloat = 3 * crosshairScale
        let backing = dotRadius + 1.3
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.fillEllipse(in: CGRect(x: -backing, y: -backing, width: backing * 2, height: backing * 2))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: -dotRadius, y: -dotRadius, width: dotRadius * 2, height: dotRadius * 2))
    }
}

// MARK: - 主视图

@MainActor
private final class AimView: NSView {
    private let root = CALayer()
    private let backgroundLayer = CALayer()
    private let crosshairLayer = CALayer()
    private var targetLayers: [CALayer] = []
    /// 靶场：出生几何、命中判定、靶位状态全在 `AgentAimCore.TargetField` 里。
    ///
    /// 视图这边只剩「把结果画出来」和「把鼠标交给谁」—— 前者可共享、后者不可共享，
    /// 这一条边界就是将来 Windows 外壳要替换的那一半。尺寸在每次取用前由 `syncFieldGeometry()`
    /// 从 `bounds` 同步（窗口尺寸只在分辨率变化时变）。
    private var field = TargetField(
        screenWidth: 1470,
        screenHeight: 956,
        capacity: targetCount
    )
    /// 一局的随机源。开一局抽一个新种子，之后整局的随机性都由它决定 ——
    /// 同一个种子在两端能复现同一局，golden vector 才有意义。
    private var targetRNG = SplitMix64(seed: 0)
    private var hitRingLayers: [CALayer] = []
    private var hitRingCursor = 0
    private var hitRingImage: CGImage?

    private let scoreLayer = CATextLayer()
    /// 时长**正计时**，而且很淡。
    ///
    /// 一局没有时限，它只是「已经过了多久」的背景信息，不该像原来那样抢注意力 ——
    /// 旧版是 24pt 粗体白字居中，因为那时它是个约束（倒计时）。
    private let elapsedLayer = CATextLayer()
    private let streakLayer = CATextLayer()
    private let workingLayer = CATextLayer()
    /// 玩的时候**始终**显示出口提示。
    ///
    /// 覆盖层盖住了菜单栏，所以玩的时候唯一出口就是键盘 —— 不写出来，陌生用户
    /// 不知道自己被困住了、也不知道按什么。
    /// 三个等效出口都写上去不是啰嗦：这是唯一的逃生通道，冗余在这里是功能。
    private let exitHintLayer = CATextLayer()

    private static let hudExitText = "Esc / Q / 右键 退出"

    private var state: GameState = .ready
    fileprivate var isPlaying: Bool { state == .playing }
    fileprivate var onEndRequested: ((RoundEndReason) -> Void)?
    /// 计分与连击。公式在核心里，理由同靶场：数字对不上只会被玩家感觉到，
    /// 不会被编译器发现。
    private var scoreboard = ScoreBoard()
    private var startedAt: CFTimeInterval = 0
    /// 最后一次「有动作」的时刻（开枪，或者移动鼠标）。久未操作兜底靠它判断。
    private var lastActivityAt: CFTimeInterval = 0
    /// 1Hz 心跳。同一条心跳既推进时长、又检查人是不是走了 —— 一局里只有它一个定时器。
    private var heartbeatTimer: Timer?

    /// 本局使用的游戏原生灵敏度快照。鼠标计数先变成角度，再由虚拟相机投影到屏幕。
    private var roundSensitivity = FPSSensitivity.defaultTactical
    private var roundDisplayMode = FPSDisplayMode.widescreen16x9
    private var aimAngles = FPSAimAngles()
    private var lastMouseCounts = FPSMouseCounts(x: 0, y: 0)
    private var lastMouseInputSource = "none"
    private var crosshair = CGPoint.zero
    private var crosshairNode: CALayer?
    private var cursorHidden = false
    private var restoringInputOwnership = false
    private var focusRepairPending = false
    private var inputGeneration: UInt64 = 0
    private var isTerminating = false
    private var agentAggregate = AgentAggregate(phase: .idle, sessionCount: 0)
    private let aimInset: CGFloat = 18
    private var targetImage: CGImage?
    private var crosshairImage: CGImage?

    // 覆盖层浮在最前，但应用不一定是 key 窗口（刚从工作应用切过来时就不是）。
    // 非 key 窗口的第一下点击默认只用于「激活窗口」，事件本身会被丢掉 ——
    // 表现就是第一枪不响，而用户会以为是判定出了问题。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    // MARK: 生命周期

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        wantsLayer = true
        guard let host = layer else { return }
        let scale = window.backingScaleFactor

        host.addSublayer(root)
        root.frame = bounds
        root.masksToBounds = true
        root.backgroundColor = transparentOverlay ? nil : baseColor.cgColor

        backgroundLayer.contentsGravity = .resize
        backgroundLayer.zPosition = 0
        root.addSublayer(backgroundLayer)

        let targets = CALayer()
        targets.zPosition = 10
        root.addSublayer(targets)
        targetImage = makeTargetImage(scale: scale)
        for _ in 0..<targetCount {
            let layer = CALayer()
            layer.contents = targetImage
            layer.contentsGravity = .resize
            layer.contentsScale = scale
            layer.isHidden = true
            targets.addSublayer(layer)
            targetLayers.append(layer)
        }
        targetHost = targets

        crosshairImage = makeCrosshairImage(scale: scale)
        crosshairLayer.contents = crosshairImage
        crosshairLayer.contentsGravity = .resize
        crosshairLayer.contentsScale = scale
        crosshairLayer.bounds = CGRect(x: 0, y: 0, width: crosshairImageSize, height: crosshairImageSize)
        crosshairLayer.zPosition = 20
        crosshairLayer.isHidden = true
        root.addSublayer(crosshairLayer)

        // 命中反馈：不做全屏闪光，那会让整块屏幕一亮、打断视野；
        // 改为在被击中的位置扩散一圈光环，动画由渲染服务端执行。
        hitRingImage = makeRingImage(scale: scale)
        for _ in 0..<hitRingCount {
            let ring = CALayer()
            ring.contents = hitRingImage
            ring.contentsGravity = .resize
            ring.contentsScale = scale
            ring.opacity = 0
            ring.zPosition = 22
            root.addSublayer(ring)
            hitRingLayers.append(ring)
        }

        configureTextLayers(scale: scale)

        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(self)

        rebuildBackground()
        crosshair = CGPoint(x: bounds.midX, y: bounds.midY)
        hideHUD()
    }

    private var targetHost = CALayer()

    private func configureTextLayers(scale: CGFloat) {
        let specs: [(CATextLayer, CGFloat, NSFont.Weight, NSColor, CATextLayerAlignmentMode, CGFloat)] = [
            (scoreLayer, 18, .semibold, .white, .left, 320),
            // 时长：12pt、三成白。它的职责是「看得见但不打扰」，所以既不加粗也不居中。
            (elapsedLayer, 12, .medium, NSColor.white.withAlphaComponent(0.3), .left, 200),
            (streakLayer, 18, .semibold, .white, .right, 320),
            (workingLayer, 13, .medium, workingColor, .center, 240),
            (exitHintLayer, 13, .medium, NSColor.white.withAlphaComponent(0.62), .right, 240)
        ]
        for (textLayer, size, weight, color, alignment, width) in specs {
            // font 传字体名（而不是 NSFont 对象）时 CATextLayer 才会采用 fontSize。
            textLayer.font = NSFont.systemFont(ofSize: size, weight: weight).fontName as CFTypeRef
            textLayer.fontSize = size
            textLayer.foregroundColor = color.cgColor
            textLayer.alignmentMode = alignment
            textLayer.isWrapped = false
            textLayer.truncationMode = .none
            textLayer.contentsScale = scale
            applyReadableBackdrop(to: textLayer)
            textLayer.bounds = CGRect(x: 0, y: 0, width: width, height: size * 1.5)
            textLayer.zPosition = 40
            root.addSublayer(textLayer)
        }
        workingLayer.string = agentAggregate.hudText
        exitHintLayer.string = Self.hudExitText
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        root.frame = bounds
        rebuildBackground()
        layoutLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        targetImage = makeTargetImage(scale: scale)
        crosshairImage = makeCrosshairImage(scale: scale)
        hitRingImage = makeRingImage(scale: scale)
        for layer in targetLayers {
            layer.contents = targetImage
            layer.contentsScale = scale
        }
        for ring in hitRingLayers {
            ring.contents = hitRingImage
            ring.contentsScale = scale
        }
        crosshairLayer.contents = crosshairImage
        crosshairLayer.contentsScale = scale
        rebuildBackground()
    }

    private func rebuildBackground() {
        // 透明形态下不生成背景位图。这一句就是「省下 22MB」的地方：
        // 位图只在启动和窗口尺寸变化时生成，省掉之后整局都不会再有全屏后备存储。
        guard !transparentOverlay else { return }
        let scale = window?.backingScaleFactor ?? 2
        withoutImplicitAnimations {
            backgroundLayer.frame = bounds
            backgroundLayer.contents = makeBackgroundImage(size: bounds.size, scale: scale)
        }
    }

    private func layoutLayers() {
        let width = bounds.width
        let height = bounds.height
        syncFieldGeometry()
        if state == .playing, sensitivityArgument == nil {
            updateCrosshairFromAimAngles()
        }
        withoutImplicitAnimations {
            scoreLayer.position = CGPoint(x: 36 + scoreLayer.bounds.width / 2, y: height - 52)
            streakLayer.position = CGPoint(x: width - 36 - streakLayer.bounds.width / 2, y: height - 52)
            // 底部一行三格：[时长 · 淡] [Agent 状态] [出口提示 · 常显]。
            // HUD 只占四个角，屏幕中央除了准星和靶子什么都没有。
            elapsedLayer.position = CGPoint(x: 36 + elapsedLayer.bounds.width / 2, y: 28)
            workingLayer.position = CGPoint(x: width / 2, y: 28)
            exitHintLayer.position = CGPoint(x: width - 36 - exitHintLayer.bounds.width / 2, y: 28)
            clampCrosshair()
            crosshairLayer.position = crosshair
        }
    }

    // MARK: 输入

    /// 出口不止 Esc 一个键。
    ///
    /// 覆盖层盖住菜单栏 ⇒ 玩的时候点不到菜单栏 ⇒ 出口只剩键盘。对一个刚下载下来、
    /// 什么都没读过的人来说，「唯一出口是一个他没被告知的键」和「没有出口」是同一件事。
    /// 所以：Esc（写在 HUD 上）+ Q（退出的通用直觉）+ 右键（慌张时最本能的动作）。
    /// 三者零成本，纯粹买容错。
    private static let exitKeyCodes: Set<UInt16> = [53, 12]

    override func keyDown(with event: NSEvent) {
        if Self.exitKeyCodes.contains(event.keyCode) {
            onEndRequested?(.escape)
        }
    }

    /// 右键 = 紧急退出。不做「右键开火」之类的映射，避免和这条逃生通道抢语义。
    override func rightMouseDown(with event: NSEvent) {
        onEndRequested?(.escape)
    }

    override func mouseMoved(with event: NSEvent) {
        guard state == .playing else { return }
        // 世界静止，只有准星在屏幕空间上移动。输入链与 FPS 一致：未加速鼠标计数先变成
        // 游戏原生转角，再通过该游戏的 FOV 投影到透明二维靶场。
        // 指针被锁住（永不撞到屏幕边缘、位移不会断流），准星位置由位移累加得出，
        // 因此撞到边界后反向移动会立刻脱离，不存在死区。
        lastActivityAt = CACurrentMediaTime()
        let delta = mouseDelta(from: event)
        if let sensitivityArgument {
            // 调试后门保留旧语义：直接指定「屏幕点 / 鼠标计数」。正常使用不走这里。
            crosshair.x += delta.x * sensitivityArgument
            crosshair.y -= delta.y * sensitivityArgument
            clampCrosshair()
        } else {
            let angleDelta = roundSensitivity.angleDelta(
                horizontalCounts: Double(delta.x),
                verticalCounts: -Double(delta.y)
            )
            aimAngles.yawDegrees += angleDelta.yawDegrees
            aimAngles.pitchDegrees += angleDelta.pitchDegrees
            updateCrosshairFromAimAngles()
        }
        withoutImplicitAnimations {
            crosshairLayer.position = crosshair
        }
    }

    private func mouseDelta(from event: NSEvent) -> CGPoint {
        guard let cgEvent = event.cgEvent else {
            lastMouseInputSource = "appKitFallback"
            lastMouseCounts = FPSMouseCounts(x: Double(event.deltaX), y: Double(event.deltaY))
            return CGPoint(x: event.deltaX, y: event.deltaY)
        }

        let unacceleratedX = cgEvent.getIntegerValueField(.eventUnacceleratedPointerMovementX)
        let unacceleratedY = cgEvent.getIntegerValueField(.eventUnacceleratedPointerMovementY)
        lastMouseInputSource = (unacceleratedX != 0 || unacceleratedY != 0)
            ? "unaccelerated"
            : "legacyFallback"
        let counts = FPSMouseCounts.preferred(
            unacceleratedX: unacceleratedX,
            unacceleratedY: unacceleratedY,
            fallbackX: cgEvent.getIntegerValueField(.mouseEventDeltaX),
            fallbackY: cgEvent.getIntegerValueField(.mouseEventDeltaY)
        )
        lastMouseCounts = counts
        return CGPoint(x: counts.x, y: counts.y)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // 覆盖层只在玩的时候可见，所以这里不再有「点一下开始」的分支 ——
        // 开局的确认交给底部那个圆环，而它刻意不吃任何点击。
        guard state == .playing else { return }
        // 透明窗口收到 inactive-first-mouse 时也要在同一次点击里重新拿回输入权，
        // 不能让用户再点第二下才能命中。
        restoreInputOwnershipIfPlaying()
        fire()
    }

    private func clampCrosshair() {
        crosshair.x = min(bounds.width - aimInset, max(aimInset, crosshair.x))
        crosshair.y = min(bounds.height - aimInset, max(aimInset, crosshair.y))
    }

    private func updateCrosshairFromAimAngles() {
        guard let projection = FPSPerspectiveProjection(
            horizontalFieldOfView: roundSensitivity.profile.horizontalFieldOfView(displayMode: roundDisplayMode),
            viewportWidth: Double(bounds.width),
            viewportHeight: Double(bounds.height),
            inset: Double(aimInset)
        ) else {
            crosshair = CGPoint(x: bounds.midX, y: bounds.midY)
            aimAngles = FPSAimAngles()
            return
        }

        aimAngles = projection.clamped(aimAngles)
        let point = projection.point(for: aimAngles)
        crosshair = CGPoint(x: point.x, y: point.y)
    }

    // MARK: 对局流程

    fileprivate func beginRoundContent(sensitivity: FPSSensitivity, displayMode: FPSDisplayMode) {
        inputGeneration &+= 1
        isTerminating = false
        focusRepairPending = false
        restoringInputOwnership = false
        state = .playing
        scoreboard.reset()
        startedAt = CACurrentMediaTime()
        lastActivityAt = startedAt
        crosshair = CGPoint(x: bounds.midX, y: bounds.midY)
        roundSensitivity = sensitivity
        roundDisplayMode = sensitivity.profile == .valorant ? .widescreen16x9 : displayMode
        aimAngles = FPSAimAngles()
        lastMouseCounts = FPSMouseCounts(x: 0, y: 0)
        lastMouseInputSource = "none"

        syncFieldGeometry()
        field.reset()
        targetRNG = SplitMix64(seed: targetSeedArgument ?? UInt64.random(in: .min ... .max))
        for index in 0..<targetCount {
            spawnTarget(at: index)
            targetLayers[index].isHidden = false
        }
        crosshairLayer.isHidden = false
        crosshairNode = crosshairLayer
        showHUD()
        layoutLayers()

        heartbeatTimer?.invalidate()
        let heartbeat = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        heartbeatTimer = heartbeat
        RunLoop.main.add(heartbeat, forMode: .common)
        tick()
    }

    fileprivate func endRoundContent() {
        guard state == .playing else { return }
        // 先失效异步焦点修复，再释放全局鼠标状态。
        state = .finished
        inputGeneration &+= 1
        focusRepairPending = false
        restoringInputOwnership = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        setPointerCaptured(false, warpCursor: false)
        field.reset()
        for layer in targetLayers { layer.isHidden = true }
        crosshairLayer.isHidden = true
        crosshairNode = nil
        hideHUD()
    }

    /// 1Hz 心跳：推进时长，并检查「人是不是已经走了」。
    ///
    /// 这一局没有时限，所以心跳不再负责任何**结束条件**；它只是把兜底判据从
    /// 「时间到了」换成「90 秒里既没开枪也没动鼠标」。两条都不需要任何知识就会发生。
    @objc private func tick() {
        guard state == .playing else { return }
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - startedAt)
        withoutImplicitAnimations {
            elapsedLayer.string = String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
        }
        if now - lastActivityAt >= idleAbandonSeconds {
            onEndRequested?(.idle)
        }
    }

    private func fire() {
        lastActivityAt = CACurrentMediaTime()
        syncFieldGeometry()
        let hitIndex = field.hitTest(at: AimPoint(x: Double(crosshair.x), y: Double(crosshair.y)))
        scoreboard.registerShot(hit: hitIndex != nil)

        guard let hitIndex, let hitTarget = field.target(at: hitIndex) else {
            updateHUD()
            return
        }

        // 命中点与直径必须在重新生成**之前**取走：紧接着的 spawn 会覆盖这个槽位。
        spawnTarget(at: hitIndex)
        pulseHitFeedback(
            at: CGPoint(x: hitTarget.center.x, y: hitTarget.center.y),
            diameter: CGFloat(hitTarget.diameter)
        )
        updateHUD()
    }

    /// 把窗口尺寸与倍率交给靶场。
    ///
    /// 目标直径按屏宽取比例、出生范围按屏幕取比例，所以窗口尺寸一变就必须重新同步；
    /// 分辨率变化不是每帧事件，这个赋值本身可以忽略不计。
    private func syncFieldGeometry() {
        field.screenWidth = Double(bounds.width)
        field.screenHeight = Double(bounds.height)
        field.parameters.targetScale = Double(targetScale)
    }

    // MARK: 目标

    private func spawnTarget(at index: Int) {
        let target = field.spawn(index: index, using: &targetRNG)
        let diameter = CGFloat(target.diameter)
        let position = CGPoint(x: target.center.x, y: target.center.y)
        let layer = targetLayers[index]
        withoutImplicitAnimations {
            layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            layer.position = position
            layer.isHidden = false
        }
        // 出生时的轻微缩放，由渲染服务端执行，应用侧无逐帧开销。
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.18
        animation.toValue = 1.0
        animation.duration = 0.11
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "spawn")
    }

    /// 命中反馈：在命中位置扩散一圈光环。
    /// 只改图层的位置、尺寸和 opacity，逐帧插值由 Core Animation 在渲染服务端完成，
    /// 应用侧不产生任何绘制工作，也没有整屏重绘。
    private func pulseHitFeedback(at point: CGPoint, diameter: CGFloat) {
        let ring = hitRingLayers[hitRingCursor % hitRingLayers.count]
        hitRingCursor += 1
        ring.removeAllAnimations()
        withoutImplicitAnimations {
            ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ring.position = point
            ring.opacity = 0
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.9
        scale.toValue = 1.95
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.26
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "hit")
    }

    // MARK: HUD / 弹层

    private func updateHUD() {
        withoutImplicitAnimations {
            scoreLayer.string = "得分  \(scoreboard.score)"
            streakLayer.string = "连击  \(scoreboard.streak)"
            workingLayer.string = agentAggregate.hudText
            exitHintLayer.string = Self.hudExitText
        }
    }

    fileprivate func updateAgentAggregate(_ aggregate: AgentAggregate) {
        agentAggregate = aggregate
        withoutImplicitAnimations {
            workingLayer.string = aggregate.hudText
        }
    }

    /// 距离上一次「有动作」过去了多久；以及已经开了几枪。
    ///
    /// 只为调试观测而存在：久未操作兜底是一条**静默**路径（它只在没人看的时候发生），
    /// 没有这两个数字就只能靠"等 90 秒看看它会不会自己停"来猜。
    fileprivate var idleAge: CFTimeInterval { CACurrentMediaTime() - lastActivityAt }
    fileprivate var shotCount: Int { scoreboard.shots }

    /// 靶场与计分的可读快照。
    ///
    /// 靶位、直径、分数这些数字以前只存在于图层里 —— 而图层是**拍不到屏**的
    /// （本机没有屏幕录制权限）。现在它们能被打印出来，于是「换了核心之后手感没变」
    /// 这件事才第一次可以被验证，而不是被相信。
    fileprivate var gameplayProbeLines: [String] {
        func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
        var lines = [
            "score=\(scoreboard.score)",
            "streak=\(scoreboard.streak)",
            "bestStreak=\(scoreboard.bestStreak)",
            "hits=\(scoreboard.hits)",
            "accuracy=\(String(format: "%.3f", scoreboard.accuracy))",
            "targetCount=\(field.snapshot.count)",
            "minSpacing=\(String(format: "%.2f", field.minSpacing))",
            "spawnExtent=\(fmt(field.spawnExtent.x)),\(fmt(field.spawnExtent.y))"
        ]
        for target in field.snapshot {
            lines.append("target\(target.index)=\(fmt(target.center.x)),\(fmt(target.center.y)),\(fmt(target.diameter))")
        }
        return lines
    }

    fileprivate var sensitivityProbeLines: [String] {
        let yaw = String(format: "%.6f", aimAngles.yawDegrees)
        let pitch = String(format: "%.6f", aimAngles.pitchDegrees)
        let crosshairX = String(format: "%.2f", crosshair.x)
        let crosshairY = String(format: "%.2f", crosshair.y)
        return [
            "inputSource=\(lastMouseInputSource)",
            "mouseCounts=\(lastMouseCounts.x),\(lastMouseCounts.y)",
            "aimAngles=\(yaw),\(pitch)",
            "crosshair=\(crosshairX),\(crosshairY)"
        ]
    }

    /// 一局的 HUD 只在玩的时候存在。覆盖层在其余时间是被 `orderOut` 掉的，
    /// 所以「隐藏 HUD」不是视觉取舍，而是跟窗口状态保持一致。
    private func showHUD() {
        updateHUD()
        withoutImplicitAnimations {
            scoreLayer.isHidden = false
            elapsedLayer.isHidden = false
            streakLayer.isHidden = false
            workingLayer.isHidden = false
            exitHintLayer.isHidden = false
        }
    }

    private func hideHUD() {
        withoutImplicitAnimations {
            scoreLayer.isHidden = true
            elapsedLayer.isHidden = true
            streakLayer.isHidden = true
            workingLayer.isHidden = true
            exitHintLayer.isHidden = true
        }
    }


    // 指针仍然锁定：这样鼠标永远不会撞到屏幕边缘（位移不会断流），
    // 准星也不用依赖系统光标的绝对位置，省掉跨屏漂移和归位补偿。
    private func setPointerCaptured(_ captured: Bool, warpCursor: Bool = true) {
        guard captured != cursorHidden else { return }
        cursorHidden = captured
        if captured {
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        } else {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            NSCursor.unhide()
            if warpCursor, let screen = window?.screen {
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            }
        }
    }

    /// 透明覆盖层在非激活状态收到第一下点击时，AppKit 不保证它同步成为 key window。
    /// 每次开局和每次点击都显式恢复这组状态，确保第一枪不会落到下层应用。
    fileprivate func restoreInputOwnershipIfPlaying() {
        guard state == .playing, !isTerminating, !restoringInputOwnership, let window else { return }
        let generation = inputGeneration
        restoringInputOwnership = true

        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
        setPointerCaptured(true)

        // activate / makeKey 会同步触发一组窗口通知；到下一轮事件循环再解除防重入。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.inputGeneration == generation else { return }
            self.restoringInputOwnership = false
        }
    }

    /// AppKit 在应用失活时可能自行恢复系统箭头，但不会同步我们的 cursorHidden 状态。
    /// 先成对释放，再在下一轮事件循环重新捕获，避免状态看似已锁定、实际箭头已出现。
    fileprivate func repairInputOwnershipAfterFocusLoss() {
        guard state == .playing, !isTerminating, !focusRepairPending else { return }
        let generation = inputGeneration
        focusRepairPending = true
        setPointerCaptured(false, warpCursor: false)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.inputGeneration == generation,
                  self.state == .playing,
                  !self.isTerminating
            else { return }
            self.focusRepairPending = false
            self.restoreInputOwnershipIfPlaying()
        }
    }

    fileprivate func prepareForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        state = .finished
        inputGeneration &+= 1
        focusRepairPending = false
        restoringInputOwnership = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        setPointerCaptured(false, warpCursor: false)
    }
}

// MARK: - 资源导出（仅调试）

@MainActor
private func dumpAssets(to directory: String) {
    let scale: CGFloat = 2
    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    func write(_ image: CGImage?, as name: String) {
        guard let image else {
            print("  导出失败：\(name)（生成器返回 nil）")
            return
        }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        guard let data else {
            print("  导出失败：\(name)（PNG 编码失败）")
            return
        }
        do {
            try data.write(to: directoryURL.appendingPathComponent(name))
            print("  \(name)  \(image.width)×\(image.height)px")
        } catch {
            print("  写入失败 \(name)：\(error)")
        }
    }

    let screenWidth = NSScreen.main?.frame.width ?? 1470
    // 尺寸区间从靶场参数推出来，而不是在这里重抄一遍算式 —— 数字只有一份来源。
    var previewField = TargetField(screenWidth: Double(screenWidth), screenHeight: 0, capacity: 0)
    previewField.parameters.targetScale = Double(targetScale)
    let small = CGFloat(previewField.diameter(forBaseRatio: previewField.parameters.baseDiameterRange.lowerBound))
    let large = CGFloat(previewField.diameter(forBaseRatio: previewField.parameters.baseDiameterRange.upperBound))

    write(makeCrosshairImage(scale: scale), as: "crosshair.png")
    write(makeTargetImage(scale: scale), as: "target.png")
    write(makeRingImage(scale: scale), as: "ring.png")

    // 按真实比例合成的场景：两个极端尺寸的靶子并排，准星按真实大小压在大靶子上。
    // 这张图用来判断「点相对靶子有多大」，以及视觉边界和命中判定是否一致。
    let canvas = CGSize(width: 340, height: 200)
    write(
        makeImage(pixelSize: canvas, scale: scale) { ctx in
            let midY = canvas.height / 2
            if let target = makeTargetImage(scale: scale) {
                ctx.draw(target, in: CGRect(x: 26, y: midY - small / 2, width: small, height: small))
                ctx.draw(target, in: CGRect(x: 150, y: midY - large / 2, width: large, height: large))
            }
            if let crosshair = makeCrosshairImage(scale: scale) {
                let side = crosshairImageSize
                ctx.draw(
                    crosshair,
                    in: CGRect(x: 150 + large / 2 - side / 2, y: midY - side / 2, width: side, height: side)
                )
            }
        },
        as: "composite.png"
    )

    let fmt = { (value: CGFloat) in String(format: "%.1f", value) }
    print("  屏幕宽 \(Int(screenWidth))pt")
    print("  靶子直径 \(fmt(small))–\(fmt(large))pt（面积系数 \(previewField.parameters.areaFactor)，目标尺寸倍率 \(targetScale)）")
    print("  准星点直径 \(fmt(6 * crosshairScale))pt")
}

// MARK: - 窗口与入口

private final class AimWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 共用工具

/// 关闭隐式动画。Core Animation 默认会给属性变化补上 0.25s 缓动，
/// 对逐帧精确的准星/靶子来说必须精确到位；需要动画的地方一律改用显式 CABasicAnimation。
@MainActor
private func withoutImplicitAnimations(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

/// 透明形态下任何小图层都会落在任意桌面内容上，白压白就等于消失。
/// 加一层不带偏移的暗色贴边（阴影半径 3pt），什么背景下都读得出来。
/// 只用在文字、小药丸、圆环这类小图层上，不会引入全屏后备存储。
@MainActor
private func applyReadableBackdrop(to layer: CALayer) {
    guard transparentOverlay else { return }
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = 0.8
    layer.shadowRadius = 3
    layer.shadowOffset = .zero
}

// MARK: - 悬停确认圆环

/// 自动触发训练前的确认圆环。
///
/// 它是「要开始了」这件事唯一的可见载体：出现在屏幕底部中央，鼠标停进去 2 秒才开始一局，
/// 中途移出立即归零，10 秒没人理就自己消失。没有文字、没有按钮、也不要求点击。
///
/// 那 10 秒只是「没人理它」的宽限：手一旦伸进圈里就不再多算 ——
/// 否则 9.5 秒才移进去的人会看着圈快填满、然后被到点收走，什么都没发生。
///
/// 为什么是一个独立小窗，而不是覆盖层上的一块区域：
/// 覆盖层的存在意义就是吃掉整屏点击（玩的时候才不会点到工作窗口），但**开始之前**
/// 用户还在工作，那时候任何被吃掉的点击都是故障。所以确认界面必须比覆盖层更克制：
/// 可见圆环只有 56×56；承载它的透明画布是 80×80，给描边和阴影留出不被裁切的空间。
/// 窗口仍然 `ignoresMouseEvents = true` —— 它从不吃点击，连底部的 Dock 都不挡。
///
/// 代价是窗口不吃事件，`NSTrackingArea` 就不会触发。剩下两条路：
///   · `NSEvent.addGlobalMonitorForEvents` / `CGEventTap`：要辅助功能或输入监控权限。
///     「零权限」是这个项目对外的承诺之一，不能为了一小块悬停检测破功 —— 直接否掉。
///   · 轮询 `NSEvent.mouseLocation`：不需要任何权限，代价是存活期间每 50ms 读一次坐标。
/// 取后者，并且把轮询严格限制在圆环存在的 ≤10 秒里：不玩的时候仍然是 0 开销。
///
/// 屏幕上那圈进度由 `CABasicAnimation(strokeEnd)` 在渲染服务端插值，
/// 应用侧只在「进入 / 移出 / 确认」三个时刻各写一次图层，全程没有逐帧绘制。
@MainActor
private final class DwellConfirm: NSObject {
    /// 确认之后开始一局。由 AppDelegate 注入。
    var onConfirm: (() -> Void)?
    /// 圆环收起后的收尾（超时、被取消、或已确认）。用来让 AppDelegate 释放自己。
    var onDismiss: (() -> Void)?

    private let window: NSWindow
    private let hostLayer: CALayer
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var pollTimer: Timer?
    /// 「没人理它」的截止时刻。不用独立的超时定时器，就放在心跳里判：
    /// 这样可以做到「人手一伸进来就停止计时」—— 否则 9.5 秒才移进去的人会看着圈快填满、
    /// 然后被 10 秒到点收走，什么都没发生。圆环是现在**唯一**的开局方式，不能这样截断。
    private var idleDeadline: CFTimeInterval = 0
    /// 本次「进入」圆环的时刻。nil 表示此刻不在圈里。
    private var enteredAt: CFTimeInterval?
    /// 呈现时鼠标**已经**在圈里（比如光标就停在屏幕底部中间）。
    ///
    /// 这种情况下必须先移出再移入才算「进入」—— 否则一出现就被判成「用户已经停留满了」，
    /// 于是「鼠标放着没动，游戏却自己开了」。这是悬停确认唯一会误触的地方。
    private var requiresExitFirst = false
    /// 每次呈现递增。用来让上一次还没执行的淡出收尾作废，
    /// 否则它会把新呈现的那个圆环一起藏掉。
    private var presentation: UInt64 = 0

    private let fadeInSeconds: TimeInterval = 0.18
    private let fadeOutSeconds: TimeInterval = 0.22

    init(screen: NSScreen?) {
        let canvasSize = dwellCanvasDiameter
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 这三行是它存在的理由：纯指示器 —— 不吃点击、不抢焦点、不参与窗口循环。
        window.ignoresMouseEvents = true
        window.level = overlayWindowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
        view.wantsLayer = true
        hostLayer = view.layer ?? CALayer()

        let lineWidth = dwellRingLineWidth
        let layerFrame = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        let path = CGPath(
            ellipseIn: CGRect(
                x: dwellRingPadding + lineWidth / 2,
                y: dwellRingPadding + lineWidth / 2,
                width: dwellRingDiameter - lineWidth,
                height: dwellRingDiameter - lineWidth
            ),
            transform: nil
        )
        let specs: [(CAShapeLayer, NSColor)] = [
            (trackLayer, NSColor.white.withAlphaComponent(0.30)),
            (progressLayer, accentColor.withAlphaComponent(0.92))
        ]
        for (shape, color) in specs {
            // 明确图层尺寸，让旋转围绕画布中心发生；不能依赖零尺寸图层的隐式行为。
            shape.frame = layerFrame
            shape.path = path
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            applyReadableBackdrop(to: shape)
            hostLayer.addSublayer(shape)
        }
        trackLayer.strokeEnd = 1
        // strokeEnd 要从 12 点开始顺时针填 —— CALayer 的 0 度在 3 点方向，所以转 -90°。
        progressLayer.strokeEnd = 0
        progressLayer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)

        window.contentView = view
        super.init()
    }

    // MARK: 呈现与消失

    /// 呈现圆环，返回它在屏幕坐标里的矩形（供调试观测核对）。
    @discardableResult
    fileprivate func present(on screen: NSScreen?) -> CGRect {
        let target = screen ?? NSScreen.main
        // 用 visibleFrame 定位：它已经把 Dock 与菜单栏排除在外，不用自己算 Dock 在哪。
        // 以可见圆环而非透明画布定位，扩画布后视觉位置保持不变。
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(NSPoint(
            x: visible.midX - dwellCanvasDiameter / 2,
            y: visible.minY + dwellBottomInset - dwellRingPadding
        ))

        presentation &+= 1
        stopTimers()
        enteredAt = nil
        progressLayer.removeAllAnimations()
        let scale = target?.backingScaleFactor ?? 2
        trackLayer.contentsScale = scale
        progressLayer.contentsScale = scale
        withoutImplicitAnimations {
            progressLayer.strokeEnd = 0
            hostLayer.opacity = 1
        }
        hostLayer.removeAllAnimations()
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = fadeInSeconds
        hostLayer.add(fadeIn, forKey: "fade")
        window.orderFrontRegardless()

        // 出现时鼠标若已经在圈里，必须先移出去一次。
        requiresExitFirst = containsCursor(NSEvent.mouseLocation)

        // 退化用法：`--dwell-seconds 0` ⇒ 不要求悬停，直接确认。
        guard dwellConfirmSeconds > 0 else {
            confirm()
            return window.frame
        }

        let poll = Timer(
            timeInterval: dwellPollInterval,
            target: self,
            selector: #selector(sample),
            userInfo: nil,
            repeats: true
        )
        pollTimer = poll
        RunLoop.main.add(poll, forMode: .common)
        idleDeadline = CACurrentMediaTime() + dwellTimeoutSeconds
        return window.frame
    }

    /// 淡出收起。超时或者被外部取消时走这条。
    fileprivate func dismiss() {
        guard pollTimer != nil else { return }
        stopTimers()
        enteredAt = nil
        progressLayer.removeAllAnimations()
        withoutImplicitAnimations { progressLayer.strokeEnd = 0 }

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = hostLayer.opacity
        fadeOut.toValue = 0
        fadeOut.duration = fadeOutSeconds
        hostLayer.removeAllAnimations()
        hostLayer.add(fadeOut, forKey: "fade")
        hostLayer.opacity = 0

        presentation &+= 1
        let token = presentation
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutSeconds) { [weak self] in
            guard let self, self.presentation == token else { return }
            self.window.orderOut(nil)
            self.onDismiss?()
        }
    }

    // MARK: 调试观测
    //
    // 截图拿不到窗口内容（缺「屏幕录制」权限），所以「圆环到底出现没有」这种失败
    // 只能靠可读的数字来验收 —— 和项目里其它静默组件一个规矩。

    fileprivate var windowFrame: CGRect { window.frame }
    fileprivate var ringFrame: CGRect {
        CGRect(
            x: window.frame.minX + dwellRingPadding,
            y: window.frame.minY + dwellRingPadding,
            width: dwellRingDiameter,
            height: dwellRingDiameter
        )
    }
    fileprivate var isVisible: Bool { window.isVisible }
    fileprivate var ignoresMouseEvents: Bool { window.ignoresMouseEvents }
    fileprivate var cursorInsideRing: Bool { containsCursor(NSEvent.mouseLocation) }
    fileprivate var progressState: String {
        if requiresExitFirst { return "waitingForExit" }
        if enteredAt != nil { return "filling" }
        return "waitingForEntry"
    }
    fileprivate var isProgressAnimationActive: Bool {
        progressLayer.animation(forKey: "fill") != nil
    }

    // MARK: 悬停判定

    /// 视觉是圆形，命中也必须是圆形。透明画布只负责容纳阴影，不能扩大成方形触发区。
    private func containsCursor(_ location: NSPoint) -> Bool {
        let frame = ringFrame
        let dx = location.x - frame.midX
        let dy = location.y - frame.midY
        let radius = dwellRingDiameter / 2
        return dx * dx + dy * dy <= radius * radius
    }

    /// 一次读数。整段悬停逻辑只有「进没进去」一个事实，其余都是它的状态机。
    @objc private func sample() {
        let now = CACurrentMediaTime()
        let inside = containsCursor(NSEvent.mouseLocation)

        if requiresExitFirst {
            // 呈现时鼠标已经在圈里：先等它离开一次，才开始认「进入」。
            // 这是悬停确认唯一会误触的地方 —— 少了它，「鼠标停着没动」会被读成
            // 「用户已经停留满了」，游戏自己就开了。
            // 但 deadline 在这里照样要算：停在圈里的鼠标不该让圆环永远不走。
            guard !inside else {
                if now >= idleDeadline { dismiss() }
                return
            }
            requiresExitFirst = false
        }

        if enteredAt == nil, now >= idleDeadline {
            dismiss()
            return
        }

        guard inside else {
            // 移出即归零 —— 不是暂停，不保留进度。
            guard enteredAt != nil else { return }
            enteredAt = nil
            // 顺手把「没人理」的计时重新给满：手还在附近，别在回来的那一瞬间把圆环收走。
            idleDeadline = now + dwellTimeoutSeconds
            progressLayer.removeAllAnimations()
            withoutImplicitAnimations { progressLayer.strokeEnd = 0 }
            return
        }

        if enteredAt == nil {
            enteredAt = now
            let fill = CABasicAnimation(keyPath: "strokeEnd")
            fill.fromValue = 0
            fill.toValue = 1
            fill.duration = dwellConfirmSeconds
            fill.timingFunction = CAMediaTimingFunction(name: .linear)
            withoutImplicitAnimations { progressLayer.strokeEnd = 1 }
            progressLayer.add(fill, forKey: "fill")
        }

        // 用挂钟时间判定，不依赖动画进度：动画被丢帧也不会让确认时机漂掉。
        if let enteredAt, now - enteredAt >= dwellConfirmSeconds {
            confirm()
        }
    }

    private func confirm() {
        // 确认后立刻硬切，不做淡出：覆盖层马上要接管整屏，这里再留 0.2 秒残影只会脏。
        let callback = onConfirm
        stopTimers()
        enteredAt = nil
        progressLayer.removeAllAnimations()
        presentation &+= 1
        withoutImplicitAnimations {
            progressLayer.strokeEnd = 0
            hostLayer.opacity = 0
        }
        hostLayer.removeAllAnimations()
        window.orderOut(nil)
        callback?()
    }

    private func stopTimers() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

@MainActor
private final class SensitivityPanelController: NSWindowController, NSTextFieldDelegate {
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sensitivityField = NSTextField()
    private let dpiField = NSTextField()
    private let distanceLabel = NSTextField(labelWithString: "")
    private let autoStartCheckbox = NSButton(checkboxWithTitle: "Agent 工作时自动开始", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let validationLabel = NSTextField(labelWithString: "")
    private var displayedConfiguration = FPSSensitivity.defaultTactical
    private var csDisplayMode = FPSDisplayMode.widescreen16x9
    var onApply: ((FPSSensitivity, FPSDisplayMode, Bool, Bool) -> Bool)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 372),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "设置"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildContent(in: panel)
    }

    required init?(coder: NSCoder) { nil }

    func present(
        configuration: FPSSensitivity,
        displayMode: FPSDisplayMode,
        autoStart: Bool,
        launchAtLogin: Bool
    ) {
        displayedConfiguration = configuration
        csDisplayMode = displayMode
        profilePopup.selectItem(at: FPSGameProfile.allCases.firstIndex(of: configuration.profile) ?? 0)
        sensitivityField.stringValue = Self.format(configuration.value, maximumFractionDigits: 9)
        dpiField.stringValue = configuration.dpi.map {
            Self.format($0, maximumFractionDigits: 0)
        } ?? ""
        autoStartCheckbox.state = autoStart ? .on : .off
        launchAtLoginCheckbox.state = launchAtLogin ? .on : .off
        validationLabel.stringValue = "设置将在下一局生效"
        validationLabel.textColor = .secondaryLabelColor
        refreshDisplayModeControl(for: configuration.profile)
        refreshDistance()

        guard let window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        sensitivityField.selectText(nil)
    }

    fileprivate var probeLines: [String] {
        [
            "settingsPanelVisible=\(window?.isVisible ?? false)",
            "settingsPanelTitle=\(window?.title ?? "nil")",
            "settingsPanelProfile=\(profilePopup.titleOfSelectedItem ?? "nil")",
            "settingsPanelDisplayMode=\(displayModePopup.titleOfSelectedItem ?? "nil")",
            "settingsPanelDisplayModeEnabled=\(displayModePopup.isEnabled)",
            "settingsPanelValue=\(sensitivityField.stringValue)",
            "settingsPanelDPI=\(dpiField.stringValue)",
            "settingsPanelDistance=\(distanceLabel.stringValue)",
            "settingsPanelAutoStart=\(autoStartCheckbox.state == .on)",
            "settingsPanelLaunchAtLogin=\(launchAtLoginCheckbox.state == .on)"
        ]
    }

    fileprivate func selectProfileForProbe(_ profile: FPSGameProfile) {
        guard let index = FPSGameProfile.allCases.firstIndex(of: profile) else { return }
        profilePopup.selectItem(at: index)
        profileChanged()
    }

    private func buildContent(in panel: NSPanel) {
        profilePopup.addItems(withTitles: FPSGameProfile.allCases.map(\.displayName))
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)

        displayModePopup.addItems(withTitles: FPSDisplayMode.allCases.map(\.displayName))
        displayModePopup.target = self
        displayModePopup.action = #selector(displayModeChanged)

        for field in [sensitivityField, dpiField] {
            field.alignment = .right
            field.delegate = self
            field.target = self
            field.action = #selector(valueChanged)
        }
        dpiField.placeholderString = "可选，仅用于 cm/360"

        distanceLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        validationLabel.font = .systemFont(ofSize: 12)

        let applyButton = NSButton(title: "应用", target: self, action: #selector(applySettings))
        applyButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"

        let rows = NSStackView(views: [
            makeRow(label: "自动行为", control: autoStartCheckbox),
            makeRow(label: "系统", control: launchAtLoginCheckbox),
            makeRow(label: "游戏配置", control: profilePopup),
            makeRow(label: "游戏画面", control: displayModePopup),
            makeRow(label: "游戏内灵敏度", control: sensitivityField),
            makeRow(label: "鼠标 DPI（可选）", control: dpiField),
            makeRow(label: "物理距离", control: distanceLabel)
        ])
        rows.orientation = .vertical
        rows.spacing = 12
        rows.alignment = .leading

        let buttons = NSStackView(views: [cancelButton, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let root = NSStackView(views: [rows, validationLabel, buttons])
        root.orientation = .vertical
        root.spacing = 14
        root.alignment = .trailing
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        panel.contentView = content
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            rows.widthAnchor.constraint(equalTo: root.widthAnchor),
            validationLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        ])
    }

    private func makeRow(label: String, control: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 104).isActive = true
        control.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    @objc private func profileChanged() {
        guard profilePopup.indexOfSelectedItem >= 0 else { return }
        let newProfile = FPSGameProfile.allCases[profilePopup.indexOfSelectedItem]

        if displayedConfiguration.profile == .counterStrike2,
           displayModePopup.indexOfSelectedItem >= 0 {
            csDisplayMode = FPSDisplayMode.allCases[displayModePopup.indexOfSelectedItem]
        }

        // action 触发时下拉框已经切到新 profile，但输入框里的数字仍属于旧 profile。
        // 必须用上一次已知 profile 解释这个数字，再换算；否则 VALORANT 0.327 会被当成
        // CS2 0.327，表面切换了游戏，实际 cm/360 会偏 3.18 倍。
        let source = currentFields(profile: displayedConfiguration.profile) ?? displayedConfiguration
        let converted = source.converted(to: newProfile)
        displayedConfiguration = converted
        sensitivityField.stringValue = Self.format(converted.value, maximumFractionDigits: 9)
        dpiField.stringValue = converted.dpi.map {
            Self.format($0, maximumFractionDigits: 0)
        } ?? ""
        refreshDisplayModeControl(for: newProfile)
        refreshDistance()
    }

    @objc private func displayModeChanged() {
        guard displayedConfiguration.profile == .counterStrike2,
              displayModePopup.indexOfSelectedItem >= 0
        else { return }
        csDisplayMode = FPSDisplayMode.allCases[displayModePopup.indexOfSelectedItem]
    }

    private func refreshDisplayModeControl(for profile: FPSGameProfile) {
        let mode = profile == .valorant ? FPSDisplayMode.widescreen16x9 : csDisplayMode
        displayModePopup.selectItem(at: FPSDisplayMode.allCases.firstIndex(of: mode) ?? 0)
        displayModePopup.isEnabled = profile == .counterStrike2
    }

    @objc private func valueChanged() {
        if let configuration = currentFields() {
            displayedConfiguration = configuration
        }
        refreshDistance()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let configuration = currentFields() {
            displayedConfiguration = configuration
        }
        refreshDistance()
    }

    private func refreshDistance() {
        guard let configuration = currentFields() else {
            distanceLabel.stringValue = "—"
            return
        }
        guard let distance = configuration.centimetersPer360 else {
            distanceLabel.stringValue = "填写 DPI 后显示"
            return
        }
        distanceLabel.stringValue = String(format: "%.1f cm/360", distance)
    }

    private func currentFields(profile explicitProfile: FPSGameProfile? = nil) -> FPSSensitivity? {
        let profile: FPSGameProfile
        if let explicitProfile {
            profile = explicitProfile
        } else {
            guard profilePopup.indexOfSelectedItem >= 0 else { return nil }
            profile = FPSGameProfile.allCases[profilePopup.indexOfSelectedItem]
        }
        let valueText = sensitivityField.stringValue.replacingOccurrences(of: ",", with: ".")
        let dpiText = dpiField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(valueText) else { return nil }
        let dpi: Double?
        if dpiText.isEmpty {
            dpi = nil
        } else if let parsedDPI = Double(dpiText) {
            dpi = parsedDPI
        } else {
            return nil
        }
        return FPSSensitivity(profile: profile, value: value, dpi: dpi)
    }

    @objc private func applySettings() {
        guard let configuration = currentFields() else {
            validationLabel.stringValue = "灵敏度须大于 0；DPI 可留空，填写时也须大于 0"
            validationLabel.textColor = .systemRed
            NSSound.beep()
            return
        }
        displayedConfiguration = configuration
        guard onApply?(
            configuration,
            csDisplayMode,
            autoStartCheckbox.state == .on,
            launchAtLoginCheckbox.state == .on
        ) ?? true else {
            validationLabel.stringValue = "“登录时启动”设置失败，请稍后重试"
            validationLabel.textColor = .systemRed
            NSSound.beep()
            return
        }
        window?.close()
    }

    @objc private func cancel() {
        window?.close()
    }

    private static func format(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct PendingAutoStart {
        let provider: AgentProvider
        let sessionID: String
        let turnID: String?
    }

    private static let autoStartDelay: TimeInterval = 2

    private var window: NSWindow?
    /// 覆盖层所在的屏幕。窗口被 `orderOut` 之后 `window.screen` 会变成 nil，
    /// 而确认圆环必须落在同一块屏幕上 —— 不然确认完之后画面会跳到另一块屏。
    private var overlayScreen: NSScreen?
    private weak var gameView: AimView?
    private var signalSources: [DispatchSourceSignal] = []
    private var statusMenuItem: NSMenuItem?
    private var startMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
    private var sensitivityPanelController: SensitivityPanelController?
    private var ipcServer: UnixDatagramServer?
    private var ipcListenerAvailable = false
    private var agentState = AgentStateStore()
    private var lastExternalApplicationPID: pid_t?
    private var returnApplicationPID: pid_t?
    private var returnCursorLocation: CGPoint?
    private var roundGeneration: UInt64 = 0
    private var pendingAutoStartTimer: Timer?
    private var pendingAutoStart: PendingAutoStart?
    private var isTerminating = false

    /// 正在等待确认的圆环。非 nil 表示「已经亮起来问你要不要开始了」。
    private var dwell: DwellConfirm?

    /// 自动开局：**默认关闭**。
    ///
    /// 这里过去在 UserDefaults 无值时返回 true —— 在「只有我自己用」的前提下成立，
    /// 对开源版是错的。陌生用户装好 hooks 后第一次让 agent 干活，就会有整整一层
    /// 全屏透明覆盖层接管屏幕，而他没见过这个 app，也不知道 Esc 能出去。
    ///
    /// 注意：现在即使打开它，也不再是「直接接管屏幕」—— 自动开局只会点亮底部那个
    /// 确认圆环，只有人真的把鼠标停进去 2 秒，覆盖层才出现。默认关 + 显式确认，两道都留着。
    private var autoStartOnAgentWork: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.autoStart) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.autoStart) }
    }

    private var sensitivityConfiguration: FPSSensitivity {
        get {
            let defaults = UserDefaults.standard
            let profile = defaults.string(forKey: DefaultsKey.sensitivityProfile)
                .flatMap(FPSGameProfile.init(rawValue:))
                ?? FPSSensitivity.defaultTactical.profile
            let value = defaults.object(forKey: DefaultsKey.sensitivityValue) == nil
                ? FPSSensitivity.defaultTactical.value
                : defaults.double(forKey: DefaultsKey.sensitivityValue)
            let dpi = defaults.object(forKey: DefaultsKey.mouseDPI).map { _ in
                defaults.double(forKey: DefaultsKey.mouseDPI)
            }
            return FPSSensitivity(profile: profile, value: value, dpi: dpi) ?? .defaultTactical
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.profile.rawValue, forKey: DefaultsKey.sensitivityProfile)
            defaults.set(newValue.value, forKey: DefaultsKey.sensitivityValue)
            if let dpi = newValue.dpi {
                defaults.set(dpi, forKey: DefaultsKey.mouseDPI)
            } else {
                defaults.removeObject(forKey: DefaultsKey.mouseDPI)
            }
        }
    }

    private var csDisplayModeConfiguration: FPSDisplayMode {
        get {
            UserDefaults.standard.string(forKey: DefaultsKey.csDisplayMode)
                .flatMap(FPSDisplayMode.init(rawValue:))
                ?? .widescreen16x9
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKey.csDisplayMode)
        }
    }

    /// 兜底：被 kill 或 Ctrl-C 时先把指针状态还原再退出。
    ///
    /// 指针锁定（`CGAssociateMouseAndMouseCursorPosition(0)`）是**全局状态**，
    /// 进程带着「已断开关联」的状态消失，用户的鼠标会留在原地不动 ——
    /// 这种失败模式没法靠按 Esc 补救，所以必须在进程被外部终止前处理。
    /// 用 DispatchSourceSignal 而不是裸 C handler：信号处理器里不能调 AppKit。
    private func installPointerRestoreOnSignal() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.terminateApplication()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installPointerRestoreOnSignal()
        configureMainMenu()
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        guard let screen = NSScreen.main else {
            NSApplication.shared.terminate(nil)
            return
        }
        overlayScreen = screen

        let window = AimWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = overlayWindowLevel
        // 甲形态的关键两行：窗口本身完全透明，桌面与工作窗口直接透过它显示。
        // 注意「视觉透明」不等于「事件穿透」—— 覆盖层照样吃掉整屏的点击，
        // 所以玩的时候工作应用既点不动也打不了字，这正是不做成穿透的代价。
        window.backgroundColor = transparentOverlay ? .clear : baseColor
        window.isOpaque = !transparentOverlay
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        let view = AimView(frame: screen.frame)
        view.wantsLayer = true
        view.onEndRequested = { [weak self] reason in self?.endRound(reason: reason) }
        window.contentView = view
        self.window = window
        self.gameView = view
        window.orderOut(nil)

        startIPCListener()
        updateAgentUI(agentState.aggregate)

        // 启动之后屏幕上必须**有东西**。主窗口 `orderOut(nil)` 后，Dock 和菜单栏能表明
        // 应用正在运行；底部圆环同时承担「我启动了」和「怎么开始」两件事，
        // 不用点、不用读，10 秒后自己走开。
        if CommandLine.arguments.contains("--autostart") {
            // 调试用途：跳过悬停确认直接开局。
            beginRound()
        } else {
            armRound()
        }

        // 调试用途：直接展示设置面板，供无菜单栏 AX 能力的验收环境读取。
        if CommandLine.arguments.contains("--show-settings")
            || CommandLine.arguments.contains("--show-sensitivity-settings") {
            openSettings()
        }

        // 调试验收：走真实设置面板的 profileChanged 路径，验证下拉框切换后显示值确实换算。
        if let rawProfile = stringArgument("--probe-sensitivity-switch"),
           let profile = FPSGameProfile(rawValue: rawProfile) {
            openSettings()
            sensitivityPanelController?.selectProfileForProbe(profile)
        }

        if let probePath = stringArgument("--probe-ui") {
            scheduleUIProbe(to: probePath)
        }
    }

    /// 调试开关：把圆环、统一设置窗口和主菜单是否出现写成可读结果。
    ///
    /// 截图拿不到窗口内容（缺「屏幕录制」权限），而「窗口没出现」这种失败是**静默**的 ——
    /// 退出码 0、日志空、进程还活着。所以按项目既有规矩给静默组件配一个可观测的验收手段。
    ///
    /// 结论同时写两个地方：文件 + 一个独立 UserDefaults suite。
    /// 只写文件是不够的：用 `open` 启动应用时，应用由 launchd 拉起、落在真实路径上，
    /// 而校验用的 shell 可能被沙箱套了一层路径视图，于是读不到那个文件 ——
    /// 这个坑会让人误判成「功能没生效」。`defaults read` 在任何环境下都读得到。
    private func scheduleUIProbe(to path: String) {
        let suite = UserDefaults(suiteName: DefaultsKey.probeSuite)
        suite?.removePersistentDomain(forName: DefaultsKey.probeSuite)

        for (label, delay) in [("at1s", 1.0), ("at8s", 8.0), ("at12s", 12.0)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let snapshot = self.uiProbeSnapshot(label: label)
                UserDefaults(suiteName: DefaultsKey.probeSuite)?.set(snapshot, forKey: label)
                let previous = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                try? (previous + snapshot + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private func uiProbeSnapshot(label: String) -> String {
        let moment: String
        switch label {
        case "at1s": moment = "1 秒"
        case "at8s": moment = "8 秒"
        default: moment = "12 秒"
        }
        var lines: [String] = ["[\(label)] 观测时刻 = 启动后 \(moment)"]
        lines.append("mainMenu=\(NSApplication.shared.mainMenu?.items.compactMap(\.submenu?.title).joined(separator: ",") ?? "nil")")
        lines.append("statusItem=absent")
        lines.append("autoStartOnAgentWork=\(autoStartOnAgentWork)")
        lines.append("isPlaying=\(gameView?.isPlaying ?? false)")
        lines.append("overlayWindowVisible=\(window?.isVisible ?? false)")
        lines.append("idleAbandonSeconds=\(idleAbandonSeconds)")
        lines.append("idleAge=\(String(format: "%.2f", gameView?.idleAge ?? 0))")
        lines.append("shots=\(gameView?.shotCount ?? 0)")
        if let gameView, gameView.isPlaying {
            lines.append(contentsOf: gameView.gameplayProbeLines)
        }
        if let gameView {
            lines.append(contentsOf: gameView.sensitivityProbeLines)
        }
        let sensitivity = sensitivityConfiguration
        lines.append("sensitivityProfile=\(sensitivity.profile.rawValue)")
        lines.append("sensitivityValue=\(sensitivity.value)")
        lines.append("csDisplayMode=\(csDisplayModeConfiguration.rawValue)")
        lines.append("mouseDPI=\(sensitivity.dpi.map { String($0) } ?? "unset")")
        lines.append("cmPer360=\(sensitivity.centimetersPer360.map { String(format: "%.2f", $0) } ?? "unavailable")")
        if let sensitivityPanelController {
            lines.append(contentsOf: sensitivityPanelController.probeLines)
        }
        lines.append("dwellConfirmSeconds=\(dwellConfirmSeconds)")
        lines.append("dwellTimeoutSeconds=\(dwellTimeoutSeconds)")
        if let dwell {
            let frame = dwell.windowFrame
            let ringFrame = dwell.ringFrame
            lines.append("dwellRing=present")
            lines.append("  isVisible=\(dwell.isVisible)")
            lines.append("  ignoresMouseEvents=\(dwell.ignoresMouseEvents)")
            lines.append("  canvasFrame=\(Int(frame.width))x\(Int(frame.height))")
            lines.append("  canvasOrigin=\(Int(frame.minX)),\(Int(frame.minY))")
            lines.append("  ringFrame=\(Int(ringFrame.width))x\(Int(ringFrame.height))")
            lines.append("  ringOrigin=\(Int(ringFrame.minX)),\(Int(ringFrame.minY))")
            lines.append("  ringPadding=\(Int(dwellRingPadding))")
            lines.append("  cursorInsideRing=\(dwell.cursorInsideRing)")
            lines.append("  progressState=\(dwell.progressState)")
            lines.append("  progressAnimationActive=\(dwell.isProgressAnimationActive)")
        } else {
            lines.append("dwellRing=nil")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 亮起自动触发时的确认圆环。
    ///
    /// 双击启动与 Agent 自动触发都可能发生在用户没有准备好交出鼠标的时候，所以仍需悬停确认；
    /// 菜单里的「开始训练」是用户已经明确表达的意图，直接走 `beginRound()`。
    @objc private func armRound() {
        guard !isTerminating, gameView?.isPlaying != true else { return }
        cancelPendingAutoStart()

        let ring = dwell ?? DwellConfirm(screen: overlayScreen)
        dwell = ring
        ring.onConfirm = { [weak self] in
            guard let self else { return }
            self.dwell = nil
            self.beginRound()
        }
        ring.onDismiss = { [weak self] in
            guard let self else { return }
            self.dwell = nil
        }
        // 圆环出现在哪块屏幕，决定了游戏会出现在哪块屏幕 ——
        // 覆盖层固定在 NSScreen.main，两者必须一致，否则确认完画面会跳一下。
        ring.present(on: overlayScreen ?? window?.screen ?? NSScreen.main)
    }

    /// 把正在等确认的圆环收掉。Agent 需要人、用户要退出、或者自动开局被关掉时调用。
    private func dismissDwell() {
        guard let dwell else { return }
        self.dwell = nil
        dwell.onConfirm = nil
        dwell.dismiss()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem(title: "AgentAim", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "AgentAim")
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let about = NSMenuItem(
            title: "关于 AgentAim",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApplication.shared
        applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())

        let status = NSMenuItem(title: AgentAggregate(phase: .idle, sessionCount: 0).menuText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        applicationMenu.addItem(status)
        applicationMenu.addItem(.separator())

        let start = NSMenuItem(title: "开始训练", action: #selector(beginRound), keyEquivalent: "")
        start.target = self
        applicationMenu.addItem(start)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())

        let hide = NSMenuItem(
            title: "隐藏 AgentAim",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApplication.shared
        applicationMenu.addItem(hide)
        applicationMenu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 AgentAim", action: #selector(terminateApplication), keyEquivalent: "q")
        quit.target = self
        applicationMenu.addItem(quit)

        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApplication.shared.mainMenu = mainMenu
        statusMenuItem = status
        startMenuItem = start
        settingsMenuItem = settings
    }

    @objc private func openSettings() {
        let controller = sensitivityPanelController ?? SensitivityPanelController()
        sensitivityPanelController = controller
        controller.onApply = { [weak self] configuration, displayMode, autoStart, launchAtLogin in
            guard let self else { return false }
            guard self.setLaunchAtLogin(enabled: launchAtLogin) else { return false }
            self.sensitivityConfiguration = configuration
            self.csDisplayModeConfiguration = displayMode
            self.setAutoStart(enabled: autoStart)
            return true
        }
        controller.present(
            configuration: sensitivityConfiguration,
            displayMode: csDisplayModeConfiguration,
            autoStart: autoStartOnAgentWork,
            launchAtLogin: SMAppService.mainApp.status == .enabled
        )
    }

    private func startIPCListener() {
        let server = UnixDatagramServer { data in
            guard let event = try? AgentIPCCodec.decode(data) else { return }
            Task { @MainActor in
                (NSApplication.shared.delegate as? AppDelegate)?.receiveAgentEvent(event)
            }
        }
        do {
            try server.start()
            ipcServer = server
            ipcListenerAvailable = true
        } catch {
            ipcListenerAvailable = false
        }
    }

    private func receiveAgentEvent(_ event: AgentHookEvent) {
        guard !isTerminating else { return }
        let transition = agentState.apply(event)
        guard transition.accepted else { return }
        updateAgentUI(transition.aggregate)
        if let attention = transition.attention {
            // Agent 从工作中变成等待/已回复 = 它在等人。这时必须做两件事：
            // 把正在进行的这一局收掉（覆盖层吃点击，不收掉就没法回它消息），
            // 以及把「来玩一局」的圆环也收掉 —— 别在人家该干活的时候把人往游戏里带。
            cancelPendingAutoStart()
            dismissDwell()
            if gameView?.isPlaying == true {
                endRound(reason: .agent(attention))
            }
        } else if transition.startedNewTurn {
            scheduleAutoStart(for: event)
        }
    }

    private func scheduleAutoStart(for event: AgentHookEvent) {
        guard autoStartOnAgentWork,
              gameView?.isPlaying != true,
              dwell == nil
        else { return }
        cancelPendingAutoStart()

        let provider = event.provider
        let sessionID = event.sessionID
        let turnID = event.turnID
        pendingAutoStart = PendingAutoStart(provider: provider, sessionID: sessionID, turnID: turnID)
        let timer = Timer(
            timeInterval: Self.autoStartDelay,
            target: self,
            selector: #selector(performPendingAutoStart),
            userInfo: nil,
            repeats: false
        )
        pendingAutoStartTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func performPendingAutoStart() {
        pendingAutoStartTimer = nil
        guard let pendingAutoStart else { return }
        self.pendingAutoStart = nil
        guard autoStartOnAgentWork,
              gameView?.isPlaying != true,
              agentState.isWorking(
                  provider: pendingAutoStart.provider,
                  sessionID: pendingAutoStart.sessionID,
                  turnID: pendingAutoStart.turnID
              )
        else { return }
        armRound()
    }

    private func cancelPendingAutoStart() {
        pendingAutoStartTimer?.invalidate()
        pendingAutoStartTimer = nil
        pendingAutoStart = nil
    }

    private func setAutoStart(enabled: Bool) {
        autoStartOnAgentWork = enabled
        if !enabled {
            cancelPendingAutoStart()
            // 关掉自动开局时，顺手把已经在等确认的圆环也收掉：那个圆环现在只是空等。
            dismissDwell()
        }
    }

    private func setLaunchAtLogin(enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if !enabled, service.status == .enabled {
                try service.unregister()
            } else if enabled, service.status != .enabled {
                try service.register()
            }
        } catch {
            // 注册失败（比如被系统策略拦下）就什么都不做 —— 不猜、也不做乐观更新：
            // 菜单上的勾必须等于真实状态，否则用户会以为自己已经设置好了。
            NSSound.beep()
            return false
        }
        return (SMAppService.mainApp.status == .enabled) == enabled
    }

    private func updateAgentUI(_ aggregate: AgentAggregate) {
        let statusText = ipcListenerAvailable ? aggregate.menuText : "当前状态：监听不可用"
        statusMenuItem?.title = statusText
        gameView?.updateAgentAggregate(aggregate)
        startMenuItem?.isEnabled = gameView?.isPlaying != true && !isTerminating
        settingsMenuItem?.isEnabled = gameView?.isPlaying != true && !isTerminating
    }

    @objc private func beginRound() {
        guard !isTerminating,
              let window,
              let gameView,
              !gameView.isPlaying
        else { return }

        cancelPendingAutoStart()
        // 兜底：任何路径进到开局，等待确认的圆环都不该再留着。
        dismissDwell()

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.processIdentifier != ownPID {
            lastExternalApplicationPID = frontmost.processIdentifier
        }
        returnApplicationPID = lastExternalApplicationPID
        returnCursorLocation = CGEvent(source: nil)?.location
        roundGeneration &+= 1

        gameView.beginRoundContent(
            sensitivity: sensitivityConfiguration,
            displayMode: csDisplayModeConfiguration
        )
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(gameView)
        gameView.restoreInputOwnershipIfPlaying()
        updateAgentUI(agentState.aggregate)
    }

    private func endRound(reason: RoundEndReason) {
        guard let window, let gameView, gameView.isPlaying || window.isVisible else { return }
        roundGeneration &+= 1
        let endingGeneration = roundGeneration

        gameView.endRoundContent()
        window.ignoresMouseEvents = true
        window.orderOut(nil)
        restoreCursorLocation()

        let applicationPID = returnApplicationPID
        returnApplicationPID = nil
        updateAgentUI(agentState.aggregate)

        guard case .termination = reason else {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !self.isTerminating,
                      self.roundGeneration == endingGeneration,
                      self.gameView?.isPlaying != true
                else { return }
                self.activateApplication(processIdentifier: applicationPID)
            }
            return
        }
    }

    private func restoreCursorLocation() {
        guard let location = returnCursorLocation else { return }
        returnCursorLocation = nil
        CGWarpMouseCursorPosition(location)
    }

    private func activateApplication(processIdentifier: pid_t?) {
        guard let processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated
        else { return }
        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @objc private func hideOverlay() {
        cancelPendingAutoStart()
        dismissDwell()
        if gameView?.isPlaying == true {
            endRound(reason: .hidden)
        } else {
            window?.ignoresMouseEvents = true
            window?.orderOut(nil)
        }
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        rememberExternalApplication(application)
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        lastExternalApplicationPID = application.processIdentifier
    }

    @objc private func terminateApplication() {
        prepareForTermination()
        NSApplication.shared.terminate(nil)
    }

    private func prepareForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        cancelPendingAutoStart()
        roundGeneration &+= 1

        let applicationPID = returnApplicationPID
        returnApplicationPID = nil
        // 退出时 AppKit 会关掉所有窗口。先让圆环停掉它的轮询和超时，
        // 否则进程退出前还会去读鼠标坐标。
        dismissDwell()
        gameView?.prepareForTermination()
        window?.ignoresMouseEvents = true
        window?.orderOut(nil)
        restoreCursorLocation()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        NSCursor.unhide()

        ipcServer?.stop()
        ipcServer = nil
        ipcListenerAvailable = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        activateApplication(processIdentifier: applicationPID)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isTerminating else { return }
        gameView?.repairInputOwnershipAfterFocusLoss()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !isTerminating else { return }
        gameView?.repairInputOwnershipAfterFocusLoss()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTerminating else { return }
        gameView?.restoreInputOwnershipIfPlaying()
    }

    func applicationWillTerminate(_ notification: Notification) {
        prepareForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
private func runApplication() {
    // 调试开关：把真实生成器产出的位图落盘后退出。
    // 本机截图拿不到窗口内容（缺「屏幕录制」权限），这是唯一能核对绘制结果的手段，
    // 而且走的是生产代码路径，不会出现「验证用的副本和实际实现不一致」。
    if CommandLine.arguments.contains("--dump-assets") {
        dumpAssets(to: stringArgument("--dump-assets") ?? NSTemporaryDirectory())
        return
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    // 保持启动状态可见：同时显示在 Dock 和 Command-Tab 应用切换器中。
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}

runApplication()
