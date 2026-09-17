//! 确定性伪随机数发生器，与 `Sources/AgentAimCore/DeterministicRandom.swift` 逐位一致。

/// SplitMix64（Steele 等，2014）。
///
/// 选它是因为它**能被逐位复刻**：状态只有 64 位，每步三次回绕乘法，
/// 不依赖平台整型宽度、不依赖浮点行为。Swift / Rust / C++ / Python 都能写出
/// 结果完全相同的实现 —— 这是「两端手感一致」可以**被测试**而不是被相信的前提。
///
/// 算法一旦发布就不能再改：改一个常量，`fixtures/gameplay-v1.json` 里
/// 已冻结的向量全部作废。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// [0, 1) 上的均匀分布：取高 53 位，那是 double 尾数的精度上限。
    ///
    /// 除以 2^53 是**精确**的（2 的幂），所以与 Swift 侧 `* 0x1.0p-53` 结果逐位相同。
    pub fn next_unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / 9_007_199_254_740_992.0
    }

    /// 闭区间上的均匀分布。
    ///
    /// 刻意不用标准库的区间随机：它的实现细节（以及内部消耗几个随机数）
    /// 不受我们控制，跨语言对表时会对不上。
    /// `lower + u * (upper - lower)` 是两端都能写出逐位相同结果的写法。
    pub fn next_double(&mut self, lower: f64, upper: f64) -> f64 {
        lower + self.next_unit() * (upper - lower)
    }
}
