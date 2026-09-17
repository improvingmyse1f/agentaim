//! 计分与连击，与 `Sources/AgentAimCore/ScoreBoard.swift` 一一对应。
//!
//! 一旦两端对不上，「同一枪在 Mac 上加 100、在 Windows 上加 105」这种事
//! 只会在有人截图对比时才发现 —— 所以它属于必须共享的那一块。

/// 每枪的基础分。
pub const BASE_POINTS: i32 = 100;
/// 每 1 连击增加的分数。
pub const STREAK_STEP: i32 = 5;
/// 连击加成的封顶值。
///
/// 有上限是刻意的：无上限时分数会指数式膨胀，一局越久越只剩数字在动，
/// 而「连击 20」正好是大多数人能感觉到的极限。
pub const STREAK_BONUS_CAP: i32 = 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ScoreBoard {
    score: i32,
    shots: u32,
    hits: u32,
    streak: i32,
    best_streak: i32,
}

impl ScoreBoard {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn score(&self) -> i32 {
        self.score
    }

    pub fn shots(&self) -> u32 {
        self.shots
    }

    pub fn hits(&self) -> u32 {
        self.hits
    }

    pub fn streak(&self) -> i32 {
        self.streak
    }

    pub fn best_streak(&self) -> i32 {
        self.best_streak
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// 记一枪，返回本枪得分（未命中为 0）。
    ///
    /// 连击加成取**开火前**的连击数：第一枪是 0 连击，拿基础分 100；
    /// 第 21 枪起加成封顶在 20。
    pub fn register_shot(&mut self, hit: bool) -> i32 {
        self.shots += 1;
        if !hit {
            self.streak = 0;
            return 0;
        }
        let points = BASE_POINTS + self.streak.min(STREAK_BONUS_CAP) * STREAK_STEP;
        self.score += points;
        self.hits += 1;
        self.streak += 1;
        self.best_streak = self.best_streak.max(self.streak);
        points
    }

    pub fn accuracy(&self) -> f64 {
        if self.shots == 0 {
            0.0
        } else {
            self.hits as f64 / self.shots as f64
        }
    }
}
