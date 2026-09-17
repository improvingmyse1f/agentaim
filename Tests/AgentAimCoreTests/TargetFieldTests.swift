import Foundation
import Testing
@testable import AgentAimCore

@Suite("确定性随机数")
struct DeterministicRandomTests {
    /// 外部参照值：由一份独立的 Python 实现算出（与 Swift 无关），先验地钉住了算法。
    /// Windows 侧移植完之后，第一件该跑的就是这条。
    @Test func matchesExternallyVerifiedKnownAnswers() {
        var rng = SplitMix64(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
        #expect(rng.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(rng.next() == 0x06C4_5D18_8009_454F)
        #expect(rng.next() == 0xF88B_B8A8_724C_81EC)
    }

    @Test func sameSeedProducesSameSequence() {
        var a = SplitMix64(seed: 20260916)
        var b = SplitMix64(seed: 20260916)
        var c = SplitMix64(seed: 20260917)
        let left = (0..<64).map { _ in a.next() }
        let right = (0..<64).map { _ in b.next() }
        let other = (0..<64).map { _ in c.next() }
        #expect(left == right)
        #expect(left != other)
    }

    @Test func unitDrawsStayInRangeAndAreNotConstant() {
        var rng = SplitMix64(seed: 7)
        var values: [Double] = []
        for _ in 0..<4096 {
            values.append(rng.nextUnit())
        }
        #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })
        #expect(Set(values).count > 4000)
        let mean = values.reduce(0, +) / Double(values.count)
        #expect(abs(mean - 0.5) < 0.02)
    }

    @Test func intervalDrawsRespectBounds() {
        var rng = SplitMix64(seed: 11)
        for _ in 0..<1024 {
            let value = rng.nextDouble(in: -3.5...7.25)
            #expect(value >= -3.5 && value <= 7.25)
        }
    }
}

@Suite("靶场几何")
struct TargetFieldGeometryTests {
    private func field(
        width: Double,
        height: Double,
        capacity: Int = 3,
        parameters: TargetFieldParameters = .standard
    ) -> TargetField {
        TargetField(
            screenWidth: width,
            screenHeight: height,
            capacity: capacity,
            parameters: parameters
        )
    }

    /// 记忆里那份「1470×956 屏上是 31–42pt」的结论，现在由测试盯着。
    @Test func diameterStaysInsideDocumentedBand() {
        var rng = SplitMix64(seed: 5)
        let subject = field(width: 1470, height: 956)
        for _ in 0..<2048 {
            let diameter = subject.makeDiameter(using: &rng)
            #expect(diameter >= 31.1 && diameter <= 41.7, "直径跑出 31–42pt：\(diameter)")
        }
    }

    @Test func diameterScalesWithScreenWidthButNotHeight() {
        var rngA = SplitMix64(seed: 9)
        var rngB = SplitMix64(seed: 9)
        var rngC = SplitMix64(seed: 9)
        let wide = field(width: 2940, height: 956).makeDiameter(using: &rngA)
        let base = field(width: 1470, height: 956).makeDiameter(using: &rngB)
        let tall = field(width: 1470, height: 1912).makeDiameter(using: &rngC)
        #expect(abs(wide - base * 2) < 1e-9)
        #expect(abs(tall - base) < 1e-9)
    }

    @Test func minSpacingTakesLargerOfFloorAndRatio() {
        #expect(field(width: 1024, height: 768).minSpacing == 110)
        #expect(field(width: 1470, height: 956).minSpacing == 147)
        #expect(field(width: 2560, height: 1440).minSpacing == 256)
    }

    @Test func spawnExtentTakesLargerOfFloorAndRatio() {
        let tiny = field(width: 500, height: 400).spawnExtent
        #expect(tiny == AimPoint(x: 180, y: 130))

        let base = field(width: 1470, height: 956).spawnExtent
        #expect(abs(base.x - 499.8) < 1e-9)
        #expect(abs(base.y - 267.68) < 1e-9)

        let large = field(width: 2560, height: 1440).spawnExtent
        #expect(abs(large.x - 870.4) < 1e-9)
        #expect(abs(large.y - 403.2) < 1e-9)
    }

    /// 出生范围必须真的装得下：出生半径 + 靶子半径 ≤ 半个屏幕，否则靶子会被裁掉。
    @Test func spawnExtentFitsInsideScreen() {
        for (width, height) in [(1024.0, 768.0), (1470.0, 956.0), (2560.0, 1440.0)] {
            let subject = field(width: width, height: height)
            let extent = subject.spawnExtent
            #expect(extent.x + 21 <= width / 2)
            #expect(extent.y + 21 <= height / 2)
        }
    }

    @Test func spawnsAvoidEachOtherWhenThereIsRoom() {
        var subject = field(width: 1470, height: 956)
        var rng = SplitMix64(seed: 20260916)
        for index in 0..<subject.capacity {
            subject.spawn(index: index, using: &rng)
        }
        let centers = subject.snapshot.map(\.center)
        #expect(centers.count == 3)
        for i in centers.indices {
            for j in centers.indices where j > i {
                #expect(
                    centers[i].distance(to: centers[j]) > subject.minSpacing,
                    "第 \(i) 与第 \(j) 只靶子挨得比最小间距还近"
                )
            }
        }
    }

    @Test func emptySlotsAreReportedAsNoTarget() {
        let subject = field(width: 1470, height: 956)
        #expect(subject.capacity == 3)
        #expect(subject.snapshot.isEmpty)
        #expect(subject.target(at: 0) == nil)
        #expect(subject.target(at: 99) == nil)
    }

    @Test func resetClearsEverySlot() {
        var subject = field(width: 1470, height: 956)
        var rng = SplitMix64(seed: 2)
        for index in 0..<subject.capacity {
            subject.spawn(index: index, using: &rng)
        }
        subject.reset()
        #expect(subject.snapshot.isEmpty)
    }
}

@Suite("命中判定")
struct HitTestTests {
    private func fieldWith(_ targets: [AimTarget]) -> TargetField {
        var subject = TargetField(screenWidth: 1470, screenHeight: 956, capacity: targets.count)
        for (index, target) in targets.enumerated() {
            subject.place(target, at: index)
        }
        return subject
    }

    @Test func returnsNilOnEmptyField() {
        let subject = fieldWith([AimTarget(center: AimPoint(x: 100, y: 100), diameter: 40)])
        #expect(subject.hitTest(at: AimPoint(x: 100, y: 100)) == 0)
        #expect(subject.target(at: 0) != nil)
        #expect(TargetField(screenWidth: 100, screenHeight: 100, capacity: 0).hitTest(at: .zero) == nil)
    }

    @Test func radiusBoundaryIsInclusive() {
        let subject = fieldWith([AimTarget(center: AimPoint(x: 100, y: 100), diameter: 40)])
        #expect(subject.hitTest(at: AimPoint(x: 120, y: 100)) == 0)
        #expect(subject.hitTest(at: AimPoint(x: 120.000001, y: 100)) == nil)
        #expect(subject.hitTest(at: AimPoint(x: 80, y: 100)) == 0)
        #expect(subject.hitTest(at: AimPoint(x: 79.999999, y: 100)) == nil)
    }

    @Test func concentricOverlapPicksTheNearerTarget() {
        let subject = fieldWith([
            AimTarget(center: AimPoint(x: 300, y: 300), diameter: 200),
            AimTarget(center: AimPoint(x: 320, y: 300), diameter: 200)
        ])
        #expect(subject.hitTest(at: AimPoint(x: 319, y: 300)) == 1)
        #expect(subject.hitTest(at: AimPoint(x: 280, y: 300)) == 0)
    }

    @Test func exactTiePicksLowerIndex() {
        let subject = fieldWith([
            AimTarget(center: AimPoint(x: 200, y: 300), diameter: 200),
            AimTarget(center: AimPoint(x: 400, y: 300), diameter: 200)
        ])
        #expect(subject.hitTest(at: AimPoint(x: 300, y: 300)) == 0)
    }
}

@Suite("计分与连击")
struct ScoreBoardTests {
    @Test func freshBoardIsAllZero() {
        let board = ScoreBoard()
        #expect(board.score == 0)
        #expect(board.shots == 0)
        #expect(board.hits == 0)
        #expect(board.streak == 0)
        #expect(board.bestStreak == 0)
        #expect(board.accuracy == 0)
    }

    @Test func firstHitIsWorthBasePoints() {
        var board = ScoreBoard()
        #expect(board.registerShot(hit: true) == 100)
        #expect(board.score == 100)
        #expect(board.streak == 1)
        #expect(board.bestStreak == 1)
    }

    @Test func streakBonusGrowsByFivePerHitAndCapsAtTwenty() {
        var board = ScoreBoard()
        var awarded: [Int] = []
        for _ in 0..<25 {
            awarded.append(board.registerShot(hit: true))
        }
        #expect(awarded[0] == 100)
        #expect(awarded[1] == 105)
        #expect(awarded[19] == 195)
        #expect(awarded[20] == 200)
        #expect(awarded[24] == 200)
        // 100+105+...+195 = 20×100 + 5×(0+…+19)，再加 5 枪封顶的 200。
        #expect(board.score == 20 * 100 + 5 * 190 + 5 * 200)
        #expect(board.streak == 25)
        #expect(board.bestStreak == 25)
        #expect(board.hits == 25)
        #expect(board.shots == 25)
        #expect(board.accuracy == 1)
    }

    @Test func missResetsStreakButKeepsBest() {
        var board = ScoreBoard()
        for _ in 0..<4 {
            board.registerShot(hit: true)
        }
        #expect(board.streak == 4)
        #expect(board.registerShot(hit: false) == 0)
        #expect(board.streak == 0)
        #expect(board.bestStreak == 4)
        #expect(board.shots == 5)
        #expect(board.hits == 4)
        // 断连击之后回到基础分，而不是接着 4 连击的加成。
        #expect(board.registerShot(hit: true) == 100)
        #expect(board.bestStreak == 4)
    }

    @Test func resetClearsEverything() {
        var board = ScoreBoard()
        board.registerShot(hit: true)
        board.registerShot(hit: false)
        board.reset()
        #expect(board == ScoreBoard())
    }
}
