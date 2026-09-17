import Foundation

/// 屏幕平面上的一个点。
///
/// 刻意用 `Double` 而不是 `CGPoint`：core 模块是要给 Windows 侧逐字段对齐的，
/// 不该把 CoreGraphics 的类型带进可移植层。`CGFloat` 在 64 位平台就是 `Double`，
/// 所以外壳侧转换是零成本的。
public struct AimPoint: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = AimPoint(x: 0, y: 0)

    /// 两点距离。
    ///
    /// 用 `sqrt(dx*dx + dy*dy)` 而不是 `hypot`：`sqrt` 由 IEEE-754 要求「正确舍入」，
    /// 任何语言、任何 CPU 上结果逐位相同；`hypot` 的实现允许有误差，跨语言对表时
    /// 会在边界靶子上产生真假难辨的 1e-16 级差异。
    public func distance(to other: AimPoint) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// 一个靶子。
public struct AimTarget: Equatable, Sendable, Codable {
    public var center: AimPoint
    public var diameter: Double

    public init(center: AimPoint, diameter: Double) {
        self.center = center
        self.diameter = diameter
    }

    public var radius: Double { diameter / 2 }

    public func contains(_ point: AimPoint) -> Bool {
        center.distance(to: point) <= radius
    }
}

/// 带序号的目标快照，只用于对表与验收。
public struct TargetSnapshot: Equatable, Sendable, Codable {
    public var index: Int
    public var center: AimPoint
    public var diameter: Double
}

/// 靶场的全部可调参数。
///
/// 这些数字原来是散在 `AimView` 里的私有常量，抽出来有两个理由：
/// 一是两端必须用同一组数字，二是它们能被写进 golden vector 一起对表 ——
/// 「手感一致」最终就落在这几个数上。
public struct TargetFieldParameters: Equatable, Sendable, Codable {
    /// 基准直径 = 屏宽 × 这个区间内的一随机比例。
    public var baseDiameterRange: ClosedRange<Double>
    /// 面积因子。注意「缩为 1/2」按**面积**算：直径乘 √0.5 才是面积减半，
    /// 直径直接砍半会让面积只剩 1/4，视觉上会突然小一大截。
    public var areaFactor: Double
    public var targetScale: Double
    /// 靶子之间的最小间距：取下限与「屏宽 × 比例」的较大者。
    public var minSpacingFloor: Double
    public var minSpacingRatio: Double
    /// 出生范围的一半（相对屏幕中心），同样有像素下限。
    public var spawnExtentFloorX: Double
    public var spawnExtentFloorY: Double
    public var spawnExtentRatioX: Double
    public var spawnExtentRatioY: Double
    /// 找一个不与现有靶子重叠的位置，最多重试几次。
    public var candidateAttempts: Int

    public init(
        baseDiameterRange: ClosedRange<Double> = 0.030...0.040,
        areaFactor: Double = 0.5,
        targetScale: Double = 1,
        minSpacingFloor: Double = 110,
        minSpacingRatio: Double = 0.10,
        spawnExtentFloorX: Double = 180,
        spawnExtentFloorY: Double = 130,
        spawnExtentRatioX: Double = 0.34,
        spawnExtentRatioY: Double = 0.28,
        candidateAttempts: Int = 24
    ) {
        self.baseDiameterRange = baseDiameterRange
        self.areaFactor = areaFactor
        self.targetScale = targetScale
        self.minSpacingFloor = minSpacingFloor
        self.minSpacingRatio = minSpacingRatio
        self.spawnExtentFloorX = spawnExtentFloorX
        self.spawnExtentFloorY = spawnExtentFloorY
        self.spawnExtentRatioX = spawnExtentRatioX
        self.spawnExtentRatioY = spawnExtentRatioY
        self.candidateAttempts = candidateAttempts
    }

    public static let standard = TargetFieldParameters()
}

/// 靶场：何时、在哪、多大 —— 以及打中哪一只。
///
/// 这是整个项目里**唯一一块真正可跨端共享**的东西。它不认识窗口、图层、像素格式，
/// 也不知道鼠标是怎么被锁住的；它只做一道确定的算术题。两端的窗口层必然各写一遍，
/// 但这一块必须只有一份语义，否则「macOS 上 3 个靶子、Windows 上 4 个」这种漂移
/// 会以玩家的体感差异出现，而不是以编译错误出现。
///
/// 随机性由外部注入的 `SplitMix64` 提供，调用顺序是契约的一部分：
/// 每生成一个靶子，先抽 1 次直径，再抽最多 `candidateAttempts` 组 (x, y)。
public struct TargetField: Sendable {
    public var parameters: TargetFieldParameters
    public var screenWidth: Double
    public var screenHeight: Double
    /// `nil` 表示这个槽位当前没有靶子。
    public private(set) var targets: [AimTarget?]

    public init(
        screenWidth: Double,
        screenHeight: Double,
        capacity: Int,
        parameters: TargetFieldParameters = .standard
    ) {
        self.parameters = parameters
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.targets = Array(repeating: nil, count: max(0, capacity))
    }

    public var capacity: Int { targets.count }

    public var center: AimPoint {
        AimPoint(x: screenWidth / 2, y: screenHeight / 2)
    }

    /// 目标直径按屏幕宽度取比例：换显示器时视觉大小一致，不随分辨率漂移。
    ///
    /// 这是一个**单一公式**，`makeDiameter` 只是给它喂一个随机比例。
    /// 独立出来是为了让「导出预览图」「打印尺寸区间」这些地方不用重抄一遍算式 ——
    /// 抄第二遍就意味着两边迟早会不一致。
    public func diameter(forBaseRatio base: Double) -> Double {
        screenWidth * base * parameters.areaFactor.squareRoot() * parameters.targetScale
    }

    public func makeDiameter(using rng: inout SplitMix64) -> Double {
        diameter(forBaseRatio: rng.nextDouble(in: parameters.baseDiameterRange))
    }

    public var minSpacing: Double {
        max(parameters.minSpacingFloor, screenWidth * parameters.minSpacingRatio)
    }

    /// 准星能到达整个屏幕，所以出生范围可以放大 —— 瞄准行程越大越接近真实甩枪。
    /// 仍需保证 出生半径 + 目标半径 ≤ 半个屏幕，否则目标会贴到边缘、甚至被裁掉。
    public var spawnExtent: AimPoint {
        AimPoint(
            x: max(parameters.spawnExtentFloorX, screenWidth * parameters.spawnExtentRatioX),
            y: max(parameters.spawnExtentFloorY, screenHeight * parameters.spawnExtentRatioY)
        )
    }

    /// 随机取一个出生点，尽量避开已有靶子。
    ///
    /// 重试是**有上限**的：靶子少的时候几乎一次就中，而一旦屏幕小到放不下，
    /// 无限重试就会变成开局卡死。24 次之后接受最后一个候选点 —— 挤在一起也比转不动强。
    public func makePosition(using rng: inout SplitMix64) -> AimPoint {
        let extent = spawnExtent
        let origin = center
        let spacing = minSpacing
        var candidate = origin
        for _ in 0..<parameters.candidateAttempts {
            candidate = AimPoint(
                x: origin.x + rng.nextDouble(in: -extent.x...extent.x),
                y: origin.y + rng.nextDouble(in: -extent.y...extent.y)
            )
            let occupied = targets.compactMap { $0 }
            if occupied.allSatisfy({ $0.center.distance(to: candidate) > spacing }) {
                break
            }
        }
        return candidate
    }

    @discardableResult
    public mutating func spawn(index: Int, using rng: inout SplitMix64) -> AimTarget {
        let diameter = makeDiameter(using: &rng)
        let position = makePosition(using: &rng)
        let target = AimTarget(center: position, diameter: diameter)
        if targets.indices.contains(index) {
            targets[index] = target
        }
        return target
    }

    public func target(at index: Int) -> AimTarget? {
        guard targets.indices.contains(index) else { return nil }
        return targets[index]
    }

    /// 直接把一只靶子放到指定槽位，绕过随机性。
    /// 给「回放一段已有的靶位」「测试里搭一个确定的场面」用。
    public mutating func place(_ target: AimTarget, at index: Int) {
        guard targets.indices.contains(index) else { return }
        targets[index] = target
    }

    public mutating func reset() {
        targets = Array(repeating: nil, count: targets.count)
    }

    /// 一枪打在哪一只上。
    ///
    /// 命中判定取「圆心距 ≤ 半径」里最近的那一只；距离相同时取序号小的
    /// （严格小于比较决定了这一点，别改成 `<=`）。
    public func hitTest(at point: AimPoint) -> Int? {
        var best: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, target) in targets.enumerated() {
            guard let target else { continue }
            let distance = target.center.distance(to: point)
            if distance <= target.radius, distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// 按序号排列的、当前存在的靶子。用于对表与验收。
    public var snapshot: [TargetSnapshot] {
        targets.enumerated().compactMap { index, target in
            target.map { TargetSnapshot(index: index, center: $0.center, diameter: $0.diameter) }
        }
    }
}
