//! 靶场：何时、在哪、多大 —— 以及打中哪一只。
//!
//! 与 `Sources/AgentAimCore/TargetField.swift` 一一对应。运算顺序是**契约的一部分**：
//! 浮点乘法不满足结合律，把 `a*b*c` 写成 `a*(b*c)` 可能在末位产生差异，
//! 而末位差异在 24 次候选点重试里会被放大成完全不同的靶位。
//! 所以下面的算式与 Swift 侧保持相同的括号结构，不要"顺手化简"。
//!
//! 关于"两端算得一样"的准确含义（别把它想得比实际更严）：
//! 两端**重算**出来的值是逐位相同的，但契约文件 `fixtures/gameplay-v1.json`
//! 用十进制写浮点，读回来时会引入解析噪声 —— 实测 serde_json 在某个值上错 1 ULP。
//! 所以对表是"坐标/直径在 1e-9 内相同"，而**命中判定与计分逐字段精确相同**。
//! 后者才是真正把两端钉住的那一项。

use crate::geometry::{AimPoint, AimTarget, TargetSnapshot};
use crate::rng::SplitMix64;

/// 靶场的全部可调参数。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TargetFieldParameters {
    /// 基准直径 = 屏宽 × 这个区间内的一随机比例。
    pub base_diameter_lower: f64,
    pub base_diameter_upper: f64,
    /// 面积因子。「缩为 1/2」按**面积**算：直径乘 √0.5 才是面积减半，
    /// 直径直接砍半会让面积只剩 1/4，视觉上会突然小一大截。
    pub area_factor: f64,
    pub target_scale: f64,
    /// 靶子之间的最小间距：取下限与「屏宽 × 比例」的较大者。
    pub min_spacing_floor: f64,
    pub min_spacing_ratio: f64,
    /// 出生范围的一半（相对屏幕中心），同样有像素下限。
    pub spawn_extent_floor_x: f64,
    pub spawn_extent_floor_y: f64,
    pub spawn_extent_ratio_x: f64,
    pub spawn_extent_ratio_y: f64,
    /// 找一个不与现有靶子重叠的位置，最多重试几次。
    pub candidate_attempts: u32,
}

impl Default for TargetFieldParameters {
    fn default() -> Self {
        Self {
            base_diameter_lower: 0.030,
            base_diameter_upper: 0.040,
            area_factor: 0.5,
            target_scale: 1.0,
            min_spacing_floor: 110.0,
            min_spacing_ratio: 0.10,
            spawn_extent_floor_x: 180.0,
            spawn_extent_floor_y: 130.0,
            spawn_extent_ratio_x: 0.34,
            spawn_extent_ratio_y: 0.28,
            candidate_attempts: 24,
        }
    }
}

/// 靶场。
///
/// `targets` 里 `None` 表示这个槽位当前没有靶子 —— Swift 侧用的是
/// `[AimTarget?]`，两边语义一致：**未生成的槽位不参与间距判定**。
#[derive(Debug, Clone)]
pub struct TargetField {
    pub parameters: TargetFieldParameters,
    pub screen_width: f64,
    pub screen_height: f64,
    targets: Vec<Option<AimTarget>>,
}

impl TargetField {
    pub fn new(
        screen_width: f64,
        screen_height: f64,
        capacity: usize,
        parameters: TargetFieldParameters,
    ) -> Self {
        Self {
            parameters,
            screen_width,
            screen_height,
            targets: vec![None; capacity],
        }
    }

    pub fn capacity(&self) -> usize {
        self.targets.len()
    }

    pub fn center(&self) -> AimPoint {
        AimPoint::new(self.screen_width / 2.0, self.screen_height / 2.0)
    }

    /// 目标直径按屏幕宽度取比例：换显示器时视觉大小一致，不随分辨率漂移。
    ///
    /// 这是**唯一**的直径公式，`make_diameter` 只是给它喂一个随机比例。
    /// 独立出来是为了让「导出预览图」「打印尺寸区间」这些地方不用重抄一遍算式。
    pub fn diameter(&self, base_ratio: f64) -> f64 {
        self.screen_width * base_ratio * self.parameters.area_factor.sqrt() * self.parameters.target_scale
    }

    pub fn make_diameter(&self, rng: &mut SplitMix64) -> f64 {
        let base = rng.next_double(
            self.parameters.base_diameter_lower,
            self.parameters.base_diameter_upper,
        );
        self.diameter(base)
    }

    pub fn min_spacing(&self) -> f64 {
        self.parameters
            .min_spacing_floor
            .max(self.screen_width * self.parameters.min_spacing_ratio)
    }

    /// 准星能到达整个屏幕，所以出生范围可以放大 —— 瞄准行程越大越接近真实甩枪。
    /// 仍需保证 出生半径 + 目标半径 ≤ 半个屏幕，否则目标会贴到边缘、甚至被裁掉。
    pub fn spawn_extent(&self) -> AimPoint {
        AimPoint::new(
            self.parameters
                .spawn_extent_floor_x
                .max(self.screen_width * self.parameters.spawn_extent_ratio_x),
            self.parameters
                .spawn_extent_floor_y
                .max(self.screen_height * self.parameters.spawn_extent_ratio_y),
        )
    }

    /// 随机取一个出生点，尽量避开已有靶子。
    ///
    /// 重试是**有上限**的：靶子少的时候几乎一次就中，而一旦屏幕小到放不下，
    /// 无限重试就会变成开局卡死。24 次之后接受最后一个候选点 ——
    /// 挤在一起也比转不动强。`fixtures/gameplay-v1.json` 里
    /// `screen-500x400-crowded` 这个 case 专门盯着这条路径。
    pub fn make_position(&self, rng: &mut SplitMix64) -> AimPoint {
        let extent = self.spawn_extent();
        let origin = self.center();
        let spacing = self.min_spacing();
        let mut candidate = origin;
        for _ in 0..self.parameters.candidate_attempts {
            candidate = AimPoint::new(
                origin.x + rng.next_double(-extent.x, extent.x),
                origin.y + rng.next_double(-extent.y, extent.y),
            );
            let occupied: Vec<AimTarget> = self.targets.iter().flatten().copied().collect();
            if occupied
                .iter()
                .all(|target| target.center.distance(candidate) > spacing)
            {
                break;
            }
        }
        candidate
    }

    /// 生成一个靶子放进指定槽位。
    ///
    /// **先抽直径、再抽位置** —— 这个顺序是契约：反过来的话随机数序列会错位，
    /// 两端从第一个靶子起就对不上。
    pub fn spawn(&mut self, index: usize, rng: &mut SplitMix64) -> AimTarget {
        let diameter = self.make_diameter(rng);
        let position = self.make_position(rng);
        let target = AimTarget::new(position, diameter);
        if index < self.targets.len() {
            self.targets[index] = Some(target);
        }
        target
    }

    pub fn target(&self, index: usize) -> Option<AimTarget> {
        self.targets.get(index).copied().flatten()
    }

    /// 直接把一只靶子放到指定槽位，绕过随机性。给回放与测试用。
    pub fn place(&mut self, index: usize, target: AimTarget) {
        if index < self.targets.len() {
            self.targets[index] = Some(target);
        }
    }

    pub fn reset(&mut self) {
        for slot in self.targets.iter_mut() {
            *slot = None;
        }
    }

    /// 一枪打在哪一只上。
    ///
    /// 取「圆心距 ≤ 半径」里最近的那一只；距离相同时取序号小的
    /// （严格小于比较决定了这一点，别改成 `<=`）。
    pub fn hit_test(&self, point: AimPoint) -> Option<usize> {
        let mut best: Option<usize> = None;
        let mut best_distance = f64::MAX;
        for (index, target) in self.targets.iter().enumerate() {
            let Some(target) = target else { continue };
            let distance = target.center.distance(point);
            if distance <= target.radius() && distance < best_distance {
                best_distance = distance;
                best = Some(index);
            }
        }
        best
    }

    /// 按序号排列的、当前存在的靶子。
    pub fn snapshot(&self) -> Vec<TargetSnapshot> {
        self.targets
            .iter()
            .enumerate()
            .filter_map(|(index, target)| {
                target.map(|target| TargetSnapshot {
                    index,
                    center: target.center,
                    diameter: target.diameter,
                })
            })
            .collect()
    }
}
