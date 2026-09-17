//! AgentAim 的可移植玩法核心。
//!
//! 这个 crate 里**没有一行**窗口、图层、渲染或输入代码，也**没有任何依赖**。
//! 它只回答四个问题：靶子多大、生在哪、这一枪打中没有、这一枪值多少分。
//!
//! 为什么要有它：macOS 外壳（AppKit + Core Animation）与将来的 Windows 外壳
//! （Win32 + 分层窗口）**必然**是两套实现 —— 窗口层级、透明合成、指针锁定、
//! 托盘/菜单栏这些东西没有可共享的实现。但如果计分公式和出生几何也各写一遍，
//! 两端就会以「手感不太一样」这种无法定位的方式漂移，而不是以编译错误暴露出来。
//!
//! 所以共享的东西被刻意收窄成两样：
//!
//! 1. **规则** —— 就是这个 crate，与 [`../Sources/AgentAimCore`](../../Sources/AgentAimCore) 一一对应；
//! 2. **协议** —— `fixtures/gameplay-v1.json` 那套语言中立的 golden vector，
//!    两端都必须逐字段复现它（见 `tests/golden_vectors.rs`）。
//!
//! 随机性由外部注入的 [`SplitMix64`] 提供，算法与 Swift 侧逐位一致。
//! **随机数的消耗顺序是契约的一部分**：每生成一个靶子先抽 1 次直径，
//! 再抽最多 `candidateAttempts` 组 (x, y)。少抽一个数，整局全错。

pub mod geometry;
pub mod rng;
pub mod score;
pub mod target_field;

pub use geometry::{AimPoint, AimTarget, TargetSnapshot};
pub use rng::SplitMix64;
pub use score::ScoreBoard;
pub use target_field::{TargetField, TargetFieldParameters};

/// `fixtures/gameplay-v1.json` 的版本号。
///
/// 只在**破坏兼容**时递增：递增就意味着 Windows 侧必须同步，
/// 也意味着这份 crate 与 Swift 侧必须同时改。
pub const VECTOR_VERSION: u32 = 1;
