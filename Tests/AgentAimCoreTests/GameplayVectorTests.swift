import Foundation
import Testing
@testable import AgentAimCore

// MARK: - 已冻结的向量文件

/// 语言中立的玩法向量。
///
/// 这个文件是 macOS 与 Windows 两端唯一的「手感合同」：Swift 侧生成并回放它，
/// Rust 侧读同一份文件、跑同一段逻辑、逐字段对表。任何一端改了出生几何、
/// 计分公式或随机数消耗顺序，测试立刻变红 —— 而不是等玩家感觉到「Windows 上
/// 靶子好像更爱挤在一起」。
///
/// 版本号只在**破坏兼容**时递增。递增意味着 Windows 侧必须同步。
struct GameplayVectorFile: Codable {
    var version: Int
    var generator: String
    var rngDrawOrder: String
    var rngKnownAnswers: [RNGKnownAnswer]
    var cases: [GameplayVectorCase]
}

struct RNGKnownAnswer: Codable {
    var seed: UInt64
    var firstOutputs: [String]
}

struct GameplayVectorCase: Codable {
    var name: String
    var notes: String
    var screenWidth: Double
    var screenHeight: Double
    var capacity: Int
    var parameters: TargetFieldParameters
    var seed: UInt64
    var shots: [AimPoint]
    var expected: GameplayVectorExpectation
}

struct GameplayVectorExpectation: Codable {
    var initialTargets: [TargetSnapshot]
    var shotResults: [GameplayVectorShotResult]
    var finalTargets: [TargetSnapshot]
    var totals: ScoreBoard
}

struct GameplayVectorShotResult: Codable {
    var hit: Bool
    var hitIndex: Int?
    var score: Int
    var streak: Int
}

enum GameplayVectors {
    static let version = 1

    /// `#filePath` 上溯两级就是仓库根 —— 刻意不放进测试资源 bundle，
    /// 因为 Rust 侧也要直接读这个路径。
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/gameplay-v1.json")
    }

    static func load() throws -> GameplayVectorFile {
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(GameplayVectorFile.self, from: data)
    }

    static func encode(_ file: GameplayVectorFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// 用固定种子跑一段脚本，把「发生了什么」原样记下来。
    ///
    /// 开火点不是手写的常量：先取当前某只靶子的圆心（距离 0，必然命中），
    /// 再补一个屏幕角落（必然空枪）。这样生成出来的坐标是确定的，写进文件之后
    /// 就与靶位无关了 —— Rust 侧只当成一组字面量回放。
    static func makeCase(
        name: String,
        notes: String,
        screenWidth: Double,
        screenHeight: Double,
        capacity: Int,
        parameters: TargetFieldParameters = .standard,
        seed: UInt64
    ) -> GameplayVectorCase {
        var field = TargetField(
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            capacity: capacity,
            parameters: parameters
        )
        var rng = SplitMix64(seed: seed)
        for index in 0..<capacity {
            field.spawn(index: index, using: &rng)
        }
        let initialTargets = field.snapshot

        var board = ScoreBoard()
        var shots: [AimPoint] = []
        var results: [GameplayVectorShotResult] = []

        func fire(at point: AimPoint) {
            shots.append(point)
            let hitIndex = field.hitTest(at: point)
            board.registerShot(hit: hitIndex != nil)
            if let hitIndex {
                field.spawn(index: hitIndex, using: &rng)
            }
            results.append(
                GameplayVectorShotResult(
                    hit: hitIndex != nil,
                    hitIndex: hitIndex,
                    score: board.score,
                    streak: board.streak
                )
            )
        }

        func fireAtCenter(of index: Int) {
            guard let target = field.target(at: index) else { return }
            fire(at: target.center)
        }

        // 顺序是刻意的，依次覆盖：命中 → 断连击 → 换一只 → 连续命中把加成顶到上限。
        fireAtCenter(of: 0)
        fire(at: AimPoint(x: 4, y: 4))
        fireAtCenter(of: min(1, capacity - 1))
        fireAtCenter(of: min(2, capacity - 1))
        fire(at: AimPoint(x: screenWidth - 4, y: screenHeight - 4))
        for _ in 0..<22 {
            fireAtCenter(of: 0)
        }

        return GameplayVectorCase(
            name: name,
            notes: notes,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            capacity: capacity,
            parameters: parameters,
            seed: seed,
            shots: shots,
            expected: GameplayVectorExpectation(
                initialTargets: initialTargets,
                shotResults: results,
                finalTargets: field.snapshot,
                totals: board
            )
        )
    }

    /// 回放一个 case —— 这就是 Rust 侧要照着写的那段逻辑。
    static func replay(_ testCase: GameplayVectorCase) -> GameplayVectorExpectation {
        var field = TargetField(
            screenWidth: testCase.screenWidth,
            screenHeight: testCase.screenHeight,
            capacity: testCase.capacity,
            parameters: testCase.parameters
        )
        var rng = SplitMix64(seed: testCase.seed)
        for index in 0..<testCase.capacity {
            field.spawn(index: index, using: &rng)
        }
        let initialTargets = field.snapshot

        var board = ScoreBoard()
        var results: [GameplayVectorShotResult] = []
        for shot in testCase.shots {
            let hitIndex = field.hitTest(at: shot)
            board.registerShot(hit: hitIndex != nil)
            if let hitIndex {
                field.spawn(index: hitIndex, using: &rng)
            }
            results.append(
                GameplayVectorShotResult(
                    hit: hitIndex != nil,
                    hitIndex: hitIndex,
                    score: board.score,
                    streak: board.streak
                )
            )
        }

        return GameplayVectorExpectation(
            initialTargets: initialTargets,
            shotResults: results,
            finalTargets: field.snapshot,
            totals: board
        )
    }

    static func makeFile() -> GameplayVectorFile {
        GameplayVectorFile(
            version: version,
            generator: "swift AgentAimCore",
            rngDrawOrder: "每个靶子：先 1 次直径，再最多 candidateAttempts 组 (x, y)；"
                + "每组候选点先抽 x 再抽 y；未命中不消耗随机数",
            rngKnownAnswers: ([0, 1, 42, 20260916] as [UInt64]).map { seed in
                var rng = SplitMix64(seed: seed)
                return RNGKnownAnswer(
                    seed: seed,
                    firstOutputs: (0..<4).map { _ in String(format: "0x%016llX", rng.next()) }
                )
            },
            cases: [
                makeCase(
                    name: "screen-1470x956-standard",
                    notes: "基准机器尺寸，出厂参数",
                    screenWidth: 1470,
                    screenHeight: 956,
                    capacity: 3,
                    seed: 20260916
                ),
                makeCase(
                    name: "screen-2560x1440-standard",
                    notes: "大屏：间距与出生范围都由比例决定，不再走像素下限",
                    screenWidth: 2560,
                    screenHeight: 1440,
                    capacity: 3,
                    seed: 1
                ),
                makeCase(
                    name: "screen-1470x956-target-scale-0.85",
                    notes: "靶子整体缩到 85%，验证直径公式里的倍率项",
                    screenWidth: 1470,
                    screenHeight: 956,
                    capacity: 3,
                    parameters: TargetFieldParameters(targetScale: 0.85),
                    seed: 42
                ),
                makeCase(
                    name: "screen-1024x768-spacing-floor",
                    notes: "屏宽 1024：屏宽×0.10 = 102.4 低于 110 下限，间距应取 110",
                    screenWidth: 1024,
                    screenHeight: 768,
                    capacity: 3,
                    seed: 7
                ),
                makeCase(
                    name: "screen-500x400-crowded",
                    notes: "极端小屏：三个靶子放不下，24 次重试后接受最后一个候选点（不许卡死）",
                    screenWidth: 500,
                    screenHeight: 400,
                    capacity: 3,
                    seed: 3
                )
            ]
        )
    }
}

// MARK: - 对表测试

@Suite("玩法向量")
struct GameplayVectorTests {
    @Test func fixtureIsVersionedAndNonEmpty() throws {
        let file = try GameplayVectors.load()
        #expect(file.version == GameplayVectors.version)
        #expect(file.cases.count >= 5)
        #expect(file.cases.allSatisfy { !$0.shots.isEmpty })
    }

    /// 端到端对表：Swift 实现必须逐字段复现已冻结的向量。
    ///
    /// 这条测试红了只有两种可能：要么改坏了逻辑，要么**有意**改了玩法却忘了
    /// 重新生成向量 —— 后者必须同步告诉 Windows 侧。
    @Test func swiftImplementationMatchesFrozenVectors() throws {
        let file = try GameplayVectors.load()
        for testCase in file.cases {
            let actual = GameplayVectors.replay(testCase)
            let expected = testCase.expected

            #expect(
                actual.initialTargets.count == expected.initialTargets.count,
                "\(testCase.name): 开局靶子数量不一致"
            )
            for (lhs, rhs) in zip(actual.initialTargets, expected.initialTargets) {
                #expect(lhs.index == rhs.index, "\(testCase.name): 靶子序号不一致")
                expectClose(lhs.center, rhs.center, "\(testCase.name): 开局靶位")
                expectClose(lhs.diameter, rhs.diameter, "\(testCase.name): 开局直径")
            }

            #expect(actual.shotResults.count == expected.shotResults.count)
            for index in actual.shotResults.indices {
                let lhs = actual.shotResults[index]
                let rhs = expected.shotResults[index]
                #expect(lhs.hit == rhs.hit, "\(testCase.name): 第 \(index) 枪命中与否不一致")
                #expect(lhs.hitIndex == rhs.hitIndex, "\(testCase.name): 第 \(index) 枪命中序号不一致")
                #expect(lhs.score == rhs.score, "\(testCase.name): 第 \(index) 枪得分不一致")
                #expect(lhs.streak == rhs.streak, "\(testCase.name): 第 \(index) 枪连击不一致")
            }

            for (lhs, rhs) in zip(actual.finalTargets, expected.finalTargets) {
                #expect(lhs.index == rhs.index, "\(testCase.name): 收局靶子序号不一致")
                expectClose(lhs.center, rhs.center, "\(testCase.name): 收局靶位")
                expectClose(lhs.diameter, rhs.diameter, "\(testCase.name): 收局直径")
            }

            #expect(actual.totals == expected.totals, "\(testCase.name): 总分板不一致")
        }
    }

    /// 向量文件是生成出来的，不是手抄的。
    /// 需要有意改玩法时：`AGENTAIM_WRITE_FIXTURES=1 swift test --filter writesFrozenVectors`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTAIM_WRITE_FIXTURES"] == "1"))
    func writesFrozenVectors() throws {
        let file = GameplayVectors.makeFile()
        let directory = GameplayVectors.fixtureURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try GameplayVectors.encode(file).write(to: GameplayVectors.fixtureURL)
        print("已写出 \(GameplayVectors.fixtureURL.path)")
    }

    private func expectClose(_ lhs: AimPoint, _ rhs: AimPoint, _ label: String) {
        #expect(abs(lhs.x - rhs.x) < 1e-9, "\(label): x \(lhs.x) vs \(rhs.x)")
        #expect(abs(lhs.y - rhs.y) < 1e-9, "\(label): y \(lhs.y) vs \(rhs.y)")
    }

    private func expectClose(_ lhs: Double, _ rhs: Double, _ label: String) {
        #expect(abs(lhs - rhs) < 1e-9, "\(label): \(lhs) vs \(rhs)")
    }
}
