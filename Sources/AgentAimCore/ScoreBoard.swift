import Foundation

/// 计分与连击。
///
/// 和 `TargetField` 一样，这里没有一行代码需要知道自己在哪个操作系统上跑 ——
/// 但一旦两端对不上，「同一枪在 Mac 上加 100、在 Windows 上加 105」这种事
/// 只会在有人截图对比时才发现。所以它同样属于必须共享的那一块。
public struct ScoreBoard: Equatable, Sendable, Codable {
    /// 每枪的基础分。
    public static let basePoints = 100
    /// 每 1 连击增加的分数。
    public static let streakStep = 5
    /// 连击加成的封顶值。
    ///
    /// 有上限是刻意的：无上限时分数会指数式膨胀，一局越久越只剩数字在动，
    /// 而「连击 20」正好是大多数人能感觉到的极限。
    public static let streakBonusCap = 20

    public private(set) var score = 0
    public private(set) var shots = 0
    public private(set) var hits = 0
    public private(set) var streak = 0
    public private(set) var bestStreak = 0

    public init() {}

    public mutating func reset() {
        score = 0
        shots = 0
        hits = 0
        streak = 0
        bestStreak = 0
    }

    /// 记一枪。返回本枪得分（未命中为 0）。
    ///
    /// 连击加成取**开火前**的连击数：第一枪是 0 连击，拿基础分 100；
    /// 第 21 枪起加成封顶在 20。
    @discardableResult
    public mutating func registerShot(hit: Bool) -> Int {
        shots += 1
        guard hit else {
            streak = 0
            return 0
        }
        let points = Self.basePoints + min(streak, Self.streakBonusCap) * Self.streakStep
        score += points
        hits += 1
        streak += 1
        bestStreak = max(bestStreak, streak)
        return points
    }

    public var accuracy: Double {
        shots == 0 ? 0 : Double(hits) / Double(shots)
    }
}
