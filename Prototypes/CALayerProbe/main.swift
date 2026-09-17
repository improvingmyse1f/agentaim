import AppKit
import QuartzCore

// 分水岭实验：验证「把『移动准星』从『重绘屏幕』改成『移动图层』」能否避开
// 全屏重绘带来的约 90MB 常驻内存。
//
// 背景：AppKitMinimal 原型已经证明，只要视图在全屏尺寸上被连续重绘，
// 无论画什么内容，footprint 都会涨到 ~145MB 以上。推测原因是层背视图每次
// 局部失效都会导致整屏后备存储重新分配。
//
// 本实验架构上刻意不同：
//   · 背景 + 网格   → 预渲染成一张位图，作为 backgroundLayer.contents，之后永不改动
//   · 3 个靶子      → 各自一个小 CALayer，只改 position（不重绘）
//   · 准星          → 一个小 CALayer，只改 position
//   · HUD 文本      → 一个 CATextLayer，低频改 string
// 全屏尺寸的图层自始至终只被光栅化一次，其余变化都只是图层位移/小图层重绘。
//
//   swiftc -swift-version 6 -O -o /tmp/calayer-probe Prototypes/CALayerProbe/main.swift -framework AppKit

private let targetCount = 3
private let sensitivity: CGFloat = 1.16
private let aimInset: CGFloat = 18
private let gridSpacing: CGFloat = 56
private let stressMode = CommandLine.arguments.contains("--stress")
// 测量校准用：--ballast <MB> 分配并写满指定大小的内存并持有，用于验证
// 外部读到的 footprint 是否真的能反映内存增长。
private let ballastMB: Int = {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--ballast"), index + 1 < args.count else { return 0 }
    return Int(args[index + 1]) ?? 0
}()
private let crosshairSize: CGFloat = 48

// CGGradient 构造后不可变、可安全跨线程共享，这里显式声明为 nonisolated，
// 否则 main.swift 顶层的全局量会被推断成 MainActor 隔离，供非隔离的绘制辅助函数引用时报错。
private nonisolated(unsafe) let backgroundGradient: CGGradient = {
    let colors = [
        NSColor(calibratedRed: 0.025, green: 0.032, blue: 0.055, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.12, alpha: 1).cgColor
    ] as CFArray
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
}()

private nonisolated(unsafe) let targetGradient: CGGradient = {
    let colors = [
        NSColor(calibratedRed: 0.58, green: 1, blue: 0.98, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.82, alpha: 1).cgColor
    ] as CFArray
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
}()

/// 建一个离屏位图上下文。注意坐标系是 y 向上，与 AppKit 视图一致。
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

private func makeCrosshairImage(scale: CGFloat) -> CGImage? {
    makeImage(pixelSize: CGSize(width: crosshairSize, height: crosshairSize), scale: scale) { ctx in
        ctx.translateBy(x: crosshairSize / 2, y: crosshairSize / 2)
        let gap: CGFloat = 7
        let length: CGFloat = 12
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        let segments: [(CGPoint, CGPoint)] = [
            (CGPoint(x: -gap - length, y: 0), CGPoint(x: -gap, y: 0)),
            (CGPoint(x: gap, y: 0), CGPoint(x: gap + length, y: 0)),
            (CGPoint(x: 0, y: -gap - length), CGPoint(x: 0, y: -gap)),
            (CGPoint(x: 0, y: gap), CGPoint(x: 0, y: gap + length))
        ]
        for (from, to) in segments {
            ctx.move(to: from)
            ctx.addLine(to: to)
        }
        ctx.strokePath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: -1.7, y: -1.7, width: 3.4, height: 3.4))
    }
}

/// 靶子位图固定 128×128，实际直径由图层 bounds 缩放得到，因此只需生成一次。
private func makeTargetImage(scale: CGFloat) -> CGImage? {
    makeImage(pixelSize: CGSize(width: 128, height: 128), scale: scale) { ctx in
        let rect = CGRect(x: 3, y: 3, width: 122, height: 122)
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.drawRadialGradient(
            targetGradient,
            startCenter: CGPoint(x: 48, y: 84),
            startRadius: 2,
            endCenter: CGPoint(x: 64, y: 64),
            endRadius: 61,
            options: []
        )
        ctx.resetClip()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.82).cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: rect)
    }
}

@MainActor
private final class ProbeView: NSView {
    private let backgroundLayer = CALayer()
    private let crosshairLayer = CALayer()
    private let textLayer = CATextLayer()
    private var targetLayers: [CALayer] = []
    private var crosshair = CGPoint.zero
    private var score = 0
    private var cursorHidden = false
    private var stressTimer: Timer?
    private var stressAngle: CGFloat = 0
    private var ballast: UnsafeMutableRawPointer?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        wantsLayer = true
        guard let root = layer else {
            log("setup failed: no backing layer")
            return
        }
        let scale = window.backingScaleFactor

        root.backgroundColor = NSColor(calibratedRed: 0.025, green: 0.032, blue: 0.055, alpha: 1).cgColor

        // 全屏背景：只光栅化一次，之后再不触碰，因此不参与逐帧重绘。
        backgroundLayer.frame = bounds
        backgroundLayer.contents = makeBackgroundImage(scale: scale)
        backgroundLayer.contentsGravity = .resize
        backgroundLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(backgroundLayer)

        let targetImage = makeTargetImage(scale: scale)
        for _ in 0..<targetCount {
            let layer = CALayer()
            layer.contents = targetImage
            layer.contentsGravity = .resize
            // 关闭隐式动画：游戏里需要的是立即到位，不是 0.25s 缓动。
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
            root.addSublayer(layer)
            targetLayers.append(layer)
        }

        crosshairLayer.contents = makeCrosshairImage(scale: scale)
        crosshairLayer.contentsGravity = .resize
        crosshairLayer.bounds = CGRect(x: 0, y: 0, width: crosshairSize, height: crosshairSize)
        crosshairLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        root.addSublayer(crosshairLayer)

        textLayer.string = "0"
        textLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        textLayer.fontSize = 24
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.contentsScale = scale
        textLayer.actions = ["contents": NSNull(), "string": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(textLayer)

        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(self)

        crosshair = CGPoint(x: bounds.midX, y: bounds.midY)
        spawnAllTargets()
        layoutHUD()
        crosshairLayer.position = crosshair
        setPointerCaptured(true)
        if stressMode { startStress() }

        if ballastMB > 0 {
            let bytes = ballastMB * 1024 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 4096)
            buffer.initializeMemory(as: UInt8.self, repeating: 0xA5, count: bytes)
            ballast = buffer
            log("ballast allocated: \(ballastMB)MB")
        }

        // 诊断输出：没有它就无法区分「真的很省」和「压根没画出来」。
        log(
            "setup ok: bounds=\(Int(bounds.width))x\(Int(bounds.height)) scale=\(scale) "
                + "sublayers=\(root.sublayers?.count ?? 0) "
                + "bgContents=\(backgroundLayer.contents == nil ? "nil" : "set") "
                + "targetContents=\(targetLayers.first?.contents == nil ? "nil" : "set") "
                + "crosshairContents=\(crosshairLayer.contents == nil ? "nil" : "set")"
        )
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds
        layoutHUD()
        crosshairLayer.position = crosshair
    }

    private func makeBackgroundImage(scale: CGFloat) -> CGImage? {
        // 先把几何量取出来：绘制闭包是非隔离的，不应在里面引用 self。
        let pixelSize = bounds.size
        let maxX = bounds.maxX
        let maxY = bounds.maxY
        let image = makeImage(pixelSize: pixelSize, scale: scale) { ctx in
            ctx.drawLinearGradient(
                backgroundGradient,
                start: .zero,
                end: CGPoint(x: maxX, y: maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.05).cgColor)
            ctx.setLineWidth(1)
            var x: CGFloat = 0
            while x <= maxX {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: maxY))
                x += gridSpacing
            }
            var y: CGFloat = 0
            while y <= maxY {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: maxX, y: y))
                y += gridSpacing
            }
            ctx.strokePath()
        }
        log("background image: \(image.map { "\($0.width)x\($0.height)" } ?? "nil")")
        return image
    }

    private func layoutHUD() {
        textLayer.bounds = CGRect(x: 0, y: 0, width: 200, height: 34)
        textLayer.position = CGPoint(x: bounds.midX, y: bounds.maxY - 70)
    }

    // MARK: - 靶子

    private var spawnExtent: CGPoint {
        CGPoint(x: max(180, bounds.width * 0.34), y: max(130, bounds.height * 0.28))
    }

    private var minSpacing: CGFloat {
        max(110, bounds.width * 0.10)
    }

    private func targetDiameter() -> CGFloat {
        bounds.width * CGFloat.random(in: 0.030...0.040)
    }

    private func randomTargetCenter() -> CGPoint {
        let extent = spawnExtent
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let centers = targetLayers.compactMap { $0.position == .zero ? nil : $0.position }
        var candidate = center
        for _ in 0..<24 {
            candidate = CGPoint(
                x: center.x + CGFloat.random(in: -extent.x...extent.x),
                y: center.y + CGFloat.random(in: -extent.y...extent.y)
            )
            if centers.allSatisfy({ hypot($0.x - candidate.x, $0.y - candidate.y) > minSpacing }) {
                break
            }
        }
        return candidate
    }

    private func place(_ layer: CALayer) {
        let diameter = targetDiameter()
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.position = randomTargetCenter()
    }

    private func spawnAllTargets() {
        for layer in targetLayers { place(layer) }
    }

    // MARK: - 输入

    override func mouseMoved(with event: NSEvent) {
        moveCrosshair(by: CGPoint(x: event.deltaX * sensitivity, y: -event.deltaY * sensitivity))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        fire()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            stressTimer?.invalidate()
            setPointerCaptured(false)
            NSApplication.shared.terminate(nil)
        }
    }

    private func moveCrosshair(by delta: CGPoint) {
        crosshair.x = min(bounds.maxX - aimInset, max(aimInset, crosshair.x + delta.x))
        crosshair.y = min(bounds.maxY - aimInset, max(aimInset, crosshair.y + delta.y))
        crosshairLayer.position = crosshair
    }

    private func fire() {
        for layer in targetLayers {
            let radius = layer.bounds.width / 2
            if hypot(layer.position.x - crosshair.x, layer.position.y - crosshair.y) <= radius {
                score += 100
                textLayer.string = "\(score)"
                place(layer)
                return
            }
        }
    }

    // MARK: - 满负载压测

    private func startStress() {
        let timer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(stressTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        stressTimer = timer
    }

    @objc private func stressTick() {
        stressAngle += 0.06
        let radius = min(bounds.width, bounds.height) * 0.30
        crosshair = CGPoint(
            x: bounds.midX + cos(stressAngle) * radius,
            y: bounds.midY + sin(stressAngle) * radius * 0.72
        )
        crosshairLayer.position = crosshair
        if Int(stressAngle * 10) % 12 == 0 {
            score += 100
            textLayer.string = "\(score)"
            place(targetLayers[Int.random(in: 0..<targetCount)])
        }
    }

    // MARK: - 指针锁定

    private func setPointerCaptured(_ captured: Bool) {
        guard captured != cursorHidden else { return }
        cursorHidden = captured
        if captured {
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        } else {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            NSCursor.unhide()
            if let screen = window?.screen {
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            }
        }
    }
}

private final class ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else {
            NSApplication.shared.terminate(nil)
            return
        }
        let window = ProbeWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = ProbeView(frame: screen.frame)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
private func runApplication() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}

runApplication()
