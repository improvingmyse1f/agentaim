import AppKit
import CoreGraphics

// 最小 AppKit 原型 —— 唯一目的：回答「换掉 SpriteKit 到底能省多少内存」。
//
// 只保留核心交互，用来测出一个可信的内存下限：
//   · 准星（指针锁定 + 位移累加，与主版本同一套模型）
//   · 3 个靶子（点中即重生成）
//   · 背景渐变 + 网格（视觉与主版本一致，否则内存不可比）
//   · 一行计分文本（CoreText 有字体缓存开销，必须计入，否则数字虚低）
//
// 关键设计：**没有渲染循环**。所有重绘都是事件驱动的，而且只失效发生变化的
// 矩形区域（准星走过的两小块 + 被打中的靶子），因此静止时 CPU 恒为 0。
//
//   swiftc -O -o /tmp/agentaim-minimal Prototypes/AppKitMinimal.swift -framework AppKit
//
// 参数：
//   --stress   用 60Hz 定时器驱动准星画圈 + 靶子重生成，强制满负载重绘，
//              用于测「最坏情况」的内存与 CPU。

private let targetCount = 3
private let sensitivity: CGFloat = 1.16
private let aimInset: CGFloat = 18
private let gridSpacing: CGFloat = 56
private let stressMode = CommandLine.arguments.contains("--stress")
// 内存归因开关：--no-bg 完全不画背景；--bg-image 把静态背景预渲染成一张位图后只做拷贝。
private let skipBackground = CommandLine.arguments.contains("--no-bg")
private let useBackgroundImage = CommandLine.arguments.contains("--bg-image")

private let screenBackground = NSColor(calibratedRed: 0.025, green: 0.032, blue: 0.055, alpha: 1)
private let gridColor = NSColor.white.withAlphaComponent(0.05)

// 渐变对象缓存一次复用：每帧新建 CGGradient 会产生无谓的分配。
private let backgroundGradient: CGGradient = {
    let colors = [
        NSColor(calibratedRed: 0.025, green: 0.032, blue: 0.055, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.12, alpha: 1).cgColor
    ] as CFArray
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
}()

private let targetGradient: CGGradient = {
    let colors = [
        NSColor(calibratedRed: 0.58, green: 1, blue: 0.98, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.82, alpha: 1).cgColor
    ] as CFArray
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
}()

private let hudAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .bold),
    .foregroundColor: NSColor.white
]

@MainActor
private final class AimView: NSView {
    private var crosshair = CGPoint.zero
    private var targets: [CGPoint] = []
    private var diameters: [CGFloat] = []
    private var score = 0
    private var cursorHidden = false
    private var stressTimer: Timer?
    private var stressAngle: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    // MARK: - 生命周期

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(self)
        crosshair = CGPoint(x: bounds.midX, y: bounds.midY)
        spawnAllTargets()
        setPointerCaptured(true)
        if stressMode { startStress() }
    }

    // 这里不写 deinit：Timer 会强引用 target，视图与它同生命周期（进程级），
    // 退出路径统一在 keyDown 里 invalidate。

    // MARK: - 坐标工具

    private func discRect(_ center: CGPoint, diameter: CGFloat, pad: CGFloat = 3) -> CGRect {
        let r = diameter / 2 + pad
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    private func crosshairRect(_ center: CGPoint) -> CGRect {
        let r: CGFloat = 24
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    private func invalidate(_ rects: [CGRect]) {
        for rect in rects {
            setNeedsDisplay(rect.intersection(bounds).integral)
        }
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
        let old = crosshairRect(crosshair)
        crosshair.x = min(bounds.maxX - aimInset, max(aimInset, crosshair.x + delta.x))
        crosshair.y = min(bounds.maxY - aimInset, max(aimInset, crosshair.y + delta.y))
        // 只失效「旧位置 ∪ 新位置」这一小块，而不是整个视图。
        invalidate([old, crosshairRect(crosshair)])
    }

    // MARK: - 命中

    private func fire() {
        var hitIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, center) in targets.enumerated() {
            let distance = hypot(center.x - crosshair.x, center.y - crosshair.y)
            if distance <= diameters[index] / 2, distance < bestDistance {
                bestDistance = distance
                hitIndex = index
            }
        }
        guard let hitIndex else { return }

        score += 100
        let oldRect = discRect(targets[hitIndex], diameter: diameters[hitIndex])
        respawnTarget(at: hitIndex)
        invalidate([oldRect, discRect(targets[hitIndex], diameter: diameters[hitIndex])])
    }

    // MARK: - 靶子生成（与主版本同一套几何约束）

    private var spawnExtent: CGPoint {
        CGPoint(x: max(180, bounds.width * 0.34), y: max(130, bounds.height * 0.28))
    }

    private var minSpacing: CGFloat {
        max(110, bounds.width * 0.10)
    }

    private func randomTargetPosition() -> CGPoint {
        let extent = spawnExtent
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var candidate = center
        for _ in 0..<24 {
            candidate = CGPoint(
                x: center.x + CGFloat.random(in: -extent.x...extent.x),
                y: center.y + CGFloat.random(in: -extent.y...extent.y)
            )
            if targets.allSatisfy({ hypot($0.x - candidate.x, $0.y - candidate.y) > minSpacing }) {
                break
            }
        }
        return candidate
    }

    private func makeTarget() {
        targets.append(randomTargetPosition())
        diameters.append(bounds.width * CGFloat.random(in: 0.030...0.040))
    }

    private func spawnAllTargets() {
        targets.removeAll(keepingCapacity: true)
        diameters.removeAll(keepingCapacity: true)
        for _ in 0..<targetCount { makeTarget() }
    }

    private func respawnTarget(at index: Int) {
        let oldCenter = targets[index]
        let oldDiameter = diameters[index]
        targets[index] = randomTargetPosition()
        diameters[index] = bounds.width * CGFloat.random(in: 0.030...0.040)
        // 避免新靶子直接压在由它替换的旧位置上，否则看不太出来
        if hypot(targets[index].x - oldCenter.x, targets[index].y - oldCenter.y) < oldDiameter {
            targets[index] = randomTargetPosition()
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
        let old = crosshairRect(crosshair)
        crosshair = CGPoint(
            x: bounds.midX + cos(stressAngle) * radius,
            y: bounds.midY + sin(stressAngle) * radius * 0.72
        )
        if Int(stressAngle * 10) % 12 == 0 {
            score += 100
            let index = Int.random(in: 0..<targetCount)
            let oldTarget = discRect(targets[index], diameter: diameters[index])
            respawnTarget(at: index)
            invalidate([oldTarget, discRect(targets[index], diameter: diameters[index])])
        }
        invalidate([old, crosshairRect(crosshair)])
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.clip(to: dirtyRect)

        drawBackground(ctx, dirtyRect: dirtyRect)
        for (index, center) in targets.enumerated() where discRect(center, diameter: diameters[index]).intersects(dirtyRect) {
            drawTarget(ctx, center: center, diameter: diameters[index])
        }
        if crosshairRect(crosshair).intersects(dirtyRect) {
            drawCrosshair(ctx)
        }
        let hudRect = hudFrame
        if hudRect.intersects(dirtyRect) {
            drawHUD()
        }

        ctx.restoreGState()
    }

    private var hudFrame: CGRect {
        CGRect(x: bounds.midX - 120, y: bounds.maxY - 78, width: 240, height: 44)
    }

    // 静态背景预渲染成一张位图。直接每帧画渐变会让 CoreGraphics 针对每个不同的
    // 脏矩形缓存一份光栅化结果，内存随重绘次数堆积；预渲染一次后只做位图拷贝就没有这个问题。
    private lazy var backgroundImage: CGImage? = makeBackgroundImage()

    private func makeBackgroundImage() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let pixelWidth = Int(bounds.width * scale)
        let pixelHeight = Int(bounds.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        ctx.drawLinearGradient(
            backgroundGradient,
            start: .zero,
            end: CGPoint(x: bounds.maxX, y: bounds.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.setStrokeColor(gridColor.cgColor)
        ctx.setLineWidth(1)
        var x: CGFloat = 0
        while x <= bounds.maxX {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
            x += gridSpacing
        }
        var y: CGFloat = 0
        while y <= bounds.maxY {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
            y += gridSpacing
        }
        ctx.strokePath()
        return ctx.makeImage()
    }

    private func drawBackground(_ ctx: CGContext, dirtyRect: NSRect) {
        if skipBackground { return }

        if useBackgroundImage, let image = backgroundImage {
            ctx.saveGState()
            ctx.clip(to: dirtyRect)
            ctx.draw(image, in: bounds)
            ctx.restoreGState()
            return
        }

        ctx.saveGState()
        ctx.addRect(dirtyRect)
        ctx.clip()
        ctx.drawLinearGradient(
            backgroundGradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: bounds.maxX, y: bounds.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.setStrokeColor(gridColor.cgColor)
        ctx.setLineWidth(1)

        // 只画与脏矩形相交的网格线。
        var x = (dirtyRect.minX / gridSpacing).rounded(.down) * gridSpacing
        while x <= dirtyRect.maxX {
            ctx.move(to: CGPoint(x: x, y: dirtyRect.minY))
            ctx.addLine(to: CGPoint(x: x, y: dirtyRect.maxY))
            x += gridSpacing
        }
        var y = (dirtyRect.minY / gridSpacing).rounded(.down) * gridSpacing
        while y <= dirtyRect.maxY {
            ctx.move(to: CGPoint(x: dirtyRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: dirtyRect.maxX, y: y))
            y += gridSpacing
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawTarget(_ ctx: CGContext, center: CGPoint, diameter: CGFloat) {
        let r = diameter / 2
        let rect = CGRect(x: center.x - r, y: center.y - r, width: diameter, height: diameter)
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.drawRadialGradient(
            targetGradient,
            startCenter: CGPoint(x: center.x - r * 0.25, y: center.y + r * 0.32),
            startRadius: 1,
            endCenter: center,
            endRadius: r,
            options: []
        )
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.82).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
    }

    private func drawCrosshair(_ ctx: CGContext) {
        let gap: CGFloat = 7
        let length: CGFloat = 12
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        let x = crosshair.x
        let y = crosshair.y
        let segments: [(CGPoint, CGPoint)] = [
            (CGPoint(x: x - gap - length, y: y), CGPoint(x: x - gap, y: y)),
            (CGPoint(x: x + gap, y: y), CGPoint(x: x + gap + length, y: y)),
            (CGPoint(x: x, y: y - gap - length), CGPoint(x: x, y: y - gap)),
            (CGPoint(x: x, y: y + gap), CGPoint(x: x, y: y + gap + length))
        ]
        for (from, to) in segments {
            ctx.move(to: from)
            ctx.addLine(to: to)
        }
        ctx.strokePath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: x - 1.7, y: y - 1.7, width: 3.4, height: 3.4))
    }

    private func drawHUD() {
        let text = "\(score)" as NSString
        let size = text.size(withAttributes: hudAttributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 60),
            withAttributes: hudAttributes
        )
    }

    // MARK: - 指针锁定（与主版本一致）

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

private final class AimWindow: NSWindow {
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
        // 窗口配置必须与主版本逐项一致，否则内存数字不可比。
        let window = AimWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = screenBackground
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = AimView(frame: screen.frame)
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
