import AppKit
import CoreGraphics
import SpriteKit

private let sessionDuration: TimeInterval = 30
private let targetCount = 3

private enum GameState {
    case ready
    case playing
    case finished
}

@MainActor
private final class AimScene: SKScene {
    private let worldNode = SKNode()
    private let targetLayer = SKNode()
    private let hudLayer = SKNode()
    private let modalLayer = SKNode()
    private let flashNode = SKSpriteNode(color: NSColor(calibratedRed: 0.18, green: 1, blue: 0.72, alpha: 1), size: .zero)

    private var state: GameState = .ready
    private var targetNodes: [SKSpriteNode] = []
    private var score = 0
    private var shots = 0
    private var hits = 0
    private var streak = 0
    private var bestStreak = 0
    private var startedAt: TimeInterval = 0
    private var cameraOffset = CGPoint.zero
    private let sensitivity: CGFloat = 1.16

    private var scoreLabel = SKLabelNode()
    private var timeLabel = SKLabelNode()
    private var streakLabel = SKLabelNode()

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = NSColor(calibratedRed: 0.025, green: 0.032, blue: 0.055, alpha: 1)

        addChild(worldNode)
        worldNode.addChild(targetLayer)
        addChild(hudLayer)
        addChild(modalLayer)
        addChild(flashNode)
        flashNode.zPosition = 90
        flashNode.alpha = 0
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        view.window?.acceptsMouseMovedEvents = true
        view.window?.makeFirstResponder(self)
        rebuildBackground()
        showReady()
        if CommandLine.arguments.contains("--autostart") {
            startSession()
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        rebuildBackground()
        flashNode.size = size
        flashNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        switch state {
        case .ready: showReady()
        case .playing: layoutHUD()
        case .finished: showFinished()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            quit()
            return
        }
        if event.keyCode == 49, state != .playing {
            startSession()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard state == .playing else { return }
        cameraOffset.x -= event.deltaX * sensitivity
        cameraOffset.y += event.deltaY * sensitivity
        clampCamera()
        targetLayer.position = cameraOffset
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        switch state {
        case .ready, .finished:
            startSession()
        case .playing:
            fire()
        }
    }

    override func update(_ currentTime: TimeInterval) {
        guard state == .playing else { return }
        if startedAt == 0 { startedAt = currentTime }

        let remaining = max(0, sessionDuration - (currentTime - startedAt))
        timeLabel.text = String(format: "%.1f", remaining)
        if remaining <= 0 {
            finishSession()
        }
    }

    private func startSession() {
        state = .playing
        score = 0
        shots = 0
        hits = 0
        streak = 0
        bestStreak = 0
        startedAt = 0
        cameraOffset = .zero
        targetLayer.position = .zero
        targetLayer.removeAllChildren()
        targetNodes.removeAll()
        modalLayer.removeAllChildren()
        configureHUD()
        for _ in 0..<targetCount { spawnTarget() }
        setPointerCaptured(true)
    }

    private func finishSession() {
        state = .finished
        setPointerCaptured(false)
        targetLayer.removeAllChildren()
        targetNodes.removeAll()
        hudLayer.removeAllChildren()
        showFinished()
    }

    private func fire() {
        shots += 1
        let aimPoint = CGPoint(x: size.width / 2, y: size.height / 2)
        let hitNode = targetNodes.first { node in
            let renderedPosition = CGPoint(
                x: node.position.x + targetLayer.position.x,
                y: node.position.y + targetLayer.position.y
            )
            return hypot(renderedPosition.x - aimPoint.x, renderedPosition.y - aimPoint.y) <= node.size.width / 2
        }

        guard let hitNode else {
            streak = 0
            updateHUD()
            return
        }

        hits += 1
        score += 100 + min(streak, 20) * 5
        streak += 1
        bestStreak = max(bestStreak, streak)
        targetNodes.removeAll { $0 === hitNode }
        hitNode.removeFromParent()
        spawnTarget()
        pulseHitFeedback()
        updateHUD()
    }

    private func spawnTarget() {
        let diameter = CGFloat.random(in: 70...94)
        let node = SKSpriteNode(texture: Self.targetTexture, size: CGSize(width: diameter, height: diameter))
        node.name = "target"
        node.zPosition = 20
        node.position = randomTargetPosition()
        node.setScale(1.18)
        node.run(.scale(to: 1, duration: 0.11))
        targetLayer.addChild(node)
        targetNodes.append(node)
    }

    private func randomTargetPosition() -> CGPoint {
        let horizontal = max(190, size.width * 0.34)
        let vertical = max(130, size.height * 0.27)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var candidate = center

        for _ in 0..<24 {
            candidate = CGPoint(
                x: center.x + CGFloat.random(in: -horizontal...horizontal),
                y: center.y + CGFloat.random(in: -vertical...vertical)
            )
            if targetNodes.allSatisfy({ hypot($0.position.x - candidate.x, $0.position.y - candidate.y) > 150 }) {
                break
            }
        }
        return candidate
    }

    private func clampCamera() {
        let horizontal = max(230, size.width * 0.40)
        let vertical = max(170, size.height * 0.32)
        cameraOffset.x = min(horizontal, max(-horizontal, cameraOffset.x))
        cameraOffset.y = min(vertical, max(-vertical, cameraOffset.y))
    }

    private func configureHUD() {
        hudLayer.removeAllChildren()

        scoreLabel = makeLabel(size: 18, weight: .semibold, color: .white)
        scoreLabel.horizontalAlignmentMode = .left
        hudLayer.addChild(scoreLabel)

        timeLabel = makeLabel(size: 24, weight: .bold, color: .white)
        hudLayer.addChild(timeLabel)

        streakLabel = makeLabel(size: 18, weight: .semibold, color: .white)
        streakLabel.horizontalAlignmentMode = .right
        hudLayer.addChild(streakLabel)

        let working = makeLabel(size: 13, weight: .medium, color: NSColor(calibratedRed: 0.43, green: 1, blue: 0.72, alpha: 0.7))
        working.text = "Agent 工作中"
        working.name = "working"
        hudLayer.addChild(working)

        let crosshair = makeCrosshair()
        crosshair.name = "crosshair"
        hudLayer.addChild(crosshair)

        updateHUD()
        layoutHUD()
    }

    private func layoutHUD() {
        scoreLabel.position = CGPoint(x: 36, y: size.height - 52)
        timeLabel.position = CGPoint(x: size.width / 2, y: size.height - 54)
        streakLabel.position = CGPoint(x: size.width - 36, y: size.height - 52)
        hudLayer.childNode(withName: "working")?.position = CGPoint(x: size.width / 2, y: 28)
        hudLayer.childNode(withName: "crosshair")?.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private func updateHUD() {
        scoreLabel.text = "得分  \(score)"
        streakLabel.text = "连击  \(streak)"
    }

    private func showReady() {
        guard state == .ready else { return }
        modalLayer.removeAllChildren()
        addCenteredLabel("AGENT AIM", y: size.height / 2 + 58, size: 34, weight: .bold, color: .white)
        addCenteredLabel("30 秒反应训练", y: size.height / 2 + 12, size: 18, weight: .medium, color: NSColor.white.withAlphaComponent(0.62))
        addPill("按空格或点击开始", y: size.height / 2 - 58)
        addCenteredLabel("Esc 退出", y: 32, size: 13, weight: .regular, color: NSColor.white.withAlphaComponent(0.36))
    }

    private func showFinished() {
        modalLayer.removeAllChildren()
        let accuracy = shots == 0 ? 0 : Int((Double(hits) / Double(shots)) * 100)
        addCenteredLabel("训练完成", y: size.height / 2 + 88, size: 30, weight: .bold, color: .white)
        addCenteredLabel("\(score)", y: size.height / 2 + 8, size: 64, weight: .bold, color: NSColor(calibratedRed: 0.35, green: 1, blue: 0.83, alpha: 1))
        addCenteredLabel("最高连击 \(bestStreak)   ·   命中率 \(accuracy)%", y: size.height / 2 - 42, size: 17, weight: .medium, color: NSColor.white.withAlphaComponent(0.64))
        addPill("空格或点击再来一局", y: size.height / 2 - 108)
        addCenteredLabel("Esc 退出", y: 32, size: 13, weight: .regular, color: NSColor.white.withAlphaComponent(0.36))
    }

    private func rebuildBackground() {
        worldNode.removeAllChildren()

        let background = SKSpriteNode(texture: Self.backgroundTexture, size: size)
        background.position = CGPoint(x: size.width / 2, y: size.height / 2)
        background.zPosition = -100
        worldNode.addChild(background)

        let grid = SKShapeNode()
        let path = CGMutablePath()
        let spacing: CGFloat = 64
        stride(from: CGFloat(0), through: size.width, by: spacing).forEach { x in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        stride(from: CGFloat(0), through: size.height, by: spacing).forEach { y in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        grid.path = path
        grid.strokeColor = NSColor.white.withAlphaComponent(0.035)
        grid.lineWidth = 1
        grid.zPosition = -90
        worldNode.addChild(grid)

        worldNode.addChild(targetLayer)
        flashNode.size = size
        flashNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private func pulseHitFeedback() {
        flashNode.removeAllActions()
        flashNode.alpha = 0.25
        flashNode.run(.fadeOut(withDuration: 0.11))
    }

    private func makeCrosshair() -> SKNode {
        let node = SKShapeNode()
        let path = CGMutablePath()
        let gap: CGFloat = 7
        let length: CGFloat = 12
        path.move(to: CGPoint(x: -gap - length, y: 0)); path.addLine(to: CGPoint(x: -gap, y: 0))
        path.move(to: CGPoint(x: gap, y: 0)); path.addLine(to: CGPoint(x: gap + length, y: 0))
        path.move(to: CGPoint(x: 0, y: -gap - length)); path.addLine(to: CGPoint(x: 0, y: -gap))
        path.move(to: CGPoint(x: 0, y: gap)); path.addLine(to: CGPoint(x: 0, y: gap + length))
        node.path = path
        node.strokeColor = .white
        node.lineWidth = 2
        node.lineCap = .round

        let dot = SKShapeNode(circleOfRadius: 1.7)
        dot.fillColor = .white
        dot.strokeColor = .clear
        node.addChild(dot)
        return node
    }

    private func addCenteredLabel(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let label = makeLabel(size: size, weight: weight, color: color)
        label.text = text
        label.position = CGPoint(x: self.size.width / 2, y: y)
        modalLayer.addChild(label)
    }

    private func addPill(_ text: String, y: CGFloat) {
        let shape = SKShapeNode(rectOf: CGSize(width: 190, height: 44), cornerRadius: 22)
        shape.position = CGPoint(x: size.width / 2, y: y)
        shape.fillColor = NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.72, alpha: 0.18)
        shape.strokeColor = NSColor(calibratedRed: 0.42, green: 1, blue: 0.88, alpha: 0.72)
        shape.lineWidth = 1
        modalLayer.addChild(shape)

        let label = makeLabel(size: 15, weight: .semibold, color: .white)
        label.text = text
        shape.addChild(label)
    }

    private func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> SKLabelNode {
        let label = SKLabelNode()
        label.fontName = NSFont.systemFont(ofSize: size, weight: weight).fontName
        label.fontSize = size
        label.fontColor = color
        label.verticalAlignmentMode = .center
        return label
    }

    private func setPointerCaptured(_ captured: Bool) {
        if captured {
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        } else {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            NSCursor.unhide()
            if let screen = view?.window?.screen {
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            }
        }
    }

    private func quit() {
        setPointerCaptured(false)
        NSApplication.shared.terminate(nil)
    }

    private static let backgroundTexture: SKTexture = {
        let imageSize = CGSize(width: 512, height: 512)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return SKTexture(image: image)
        }
        let colors = [
            NSColor(calibratedRed: 0.02, green: 0.027, blue: 0.048, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.12, alpha: 1).cgColor
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 512, y: 512), options: [])
        image.unlockFocus()
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }()

    private static let targetTexture: SKTexture = {
        let imageSize = CGSize(width: 128, height: 128)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return SKTexture(image: image)
        }
        let colors = [
            NSColor(calibratedRed: 0.58, green: 1, blue: 0.98, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.82, alpha: 1).cgColor
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        let rect = CGRect(origin: .zero, size: imageSize).insetBy(dx: 3, dy: 3)
        context.addEllipse(in: rect)
        context.clip()
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: 48, y: 84),
            startRadius: 2,
            endCenter: CGPoint(x: 64, y: 64),
            endRadius: 61,
            options: []
        )
        context.resetClip()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.82).cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: rect)
        image.unlockFocus()
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }()
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

        let window = AimWindow(
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

        let gameView = SKView(frame: screen.frame)
        gameView.preferredFramesPerSecond = 60
        gameView.ignoresSiblingOrder = true
        gameView.shouldCullNonVisibleNodes = true
        window.contentView = gameView
        window.acceptsMouseMovedEvents = true
        let scene = AimScene(size: screen.frame.size)
        gameView.presentScene(scene)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(scene)
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
