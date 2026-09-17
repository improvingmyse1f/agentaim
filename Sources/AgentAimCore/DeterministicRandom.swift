import Foundation

/// 确定性伪随机数发生器（SplitMix64）。
///
/// 为什么不用 `Double.random(in:)`：它走系统随机源，同一段逻辑在两台机器上跑出来的
/// 序列都不一样，于是「macOS 和 Windows 手感一致」这件事只能靠人肉感受。
/// 换成带种子的固定算法之后，两端可以吃同一个种子、吐出同一串数，再拿同一份
/// golden vector 互相对表 —— 一致性从「希望如此」变成「测试会红」。
///
/// 选 SplitMix64（Steele 等，2014）的理由：状态只有 64 位，每步三次乘法，
/// 全部用回绕算术（`&+` / `&*` / 逻辑移位），不依赖任何平台整型宽度或浮点行为，
/// 所以 Rust、C++、Swift 都能逐位复刻。
///
/// **注意**：这里的算法一旦发布就不能再改。改一个常量，已发布的 golden vector 全部作废。
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1) 上的均匀分布。取高 53 位 —— 那是 double 尾数的精度上限，
    /// 再多取几位会引入低位截断的偏置。
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// 闭区间上的均匀分布。
    ///
    /// 刻意不用标准库的 `Double.random(in:)`：那条路径的实现细节（以及它内部
    /// 消耗几个随机数）不受我们控制，跨语言对表时会对不上。`a + u*(b-a)`
    /// 是两端都能写出逐位相同结果的写法。
    public mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }
}
