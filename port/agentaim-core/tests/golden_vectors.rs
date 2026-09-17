//! 跨端对表：Rust 实现必须逐字段复现 `fixtures/gameplay-v1.json`。
//!
//! 这个文件存在的意义只有一个：**让两端不一致这件事变成红色，而不是变成玩家的体感**。
//! 同一份向量文件也被 Swift 侧（`Tests/AgentAimCoreTests/GameplayVectorTests.swift`）
//! 回放 —— 两边都过，才叫手感一致。
//!
//! 红了怎么办：
//! - 如果你刚改了玩法，那是**有意**的变更 ⇒ 先改 Swift、再
//!   `AGENTAIM_WRITE_FIXTURES=1 swift test --filter writesFrozenVectors` 重新生成向量，
//!   然后回来跑这个测试；
//! - 如果没人改玩法 ⇒ 说明这次移植**没抄对**，看下面打出来的字段名和差值。

use agentaim_core::{
    AimPoint, AimTarget, ScoreBoard, SplitMix64, TargetField, TargetFieldParameters, VECTOR_VERSION,
};
use serde::Deserialize;
use std::path::PathBuf;

const FIXTURE_RELATIVE_PATH: &str = "../../fixtures/gameplay-v1.json";

/// 浮点比较容差。
///
/// **它不是为了让测试好过，而是因为契约文件的浮点是用十进制写的。**
/// 实测已知的唯一偏差来源就一个 —— serde_json 的十进制解析：
///
/// ```text
/// "39.737625314654636"   Rust std（正确舍入）= 4043DE6A819D925A
///                        Python   （正确舍入）= 4043DE6A819D925A
///                        serde_json             = 4043DE6A819D925B   ← 1 ULP
/// ```
///
/// 也就是说：**Rust 重算出来的值（`…5A`）与 Python、与 Swift 的重算值一致，
/// 只有「从文件里读回来的那个期望值」被解析歪了 1 ULP。**
/// 差距量级 2.3e-13，对玩法没有任何意义，所以契约按容差成立；
/// 真正把两端钉在一起的是后面的**命中判定与计分逐字段精确比较** ——
/// 那几项没有容差，两端只要分歧就必须红。
///
/// 已知偏差被 `known_float_parsing_artifact_is_pinned` 这条测试钉住了：
/// serde_json 哪天修好，它会红，提醒我们把这里的容差收紧到 0。
const FLOAT_TOLERANCE: f64 = 1e-9;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VectorFile {
    version: u32,
    generator: String,
    rng_draw_order: String,
    rng_known_answers: Vec<RngKnownAnswer>,
    cases: Vec<VectorCase>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RngKnownAnswer {
    seed: u64,
    first_outputs: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VectorCase {
    name: String,
    notes: String,
    screen_width: f64,
    screen_height: f64,
    capacity: usize,
    parameters: VectorParameters,
    seed: u64,
    shots: Vec<VectorPoint>,
    expected: VectorExpectation,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VectorParameters {
    base_diameter_range: [f64; 2],
    area_factor: f64,
    target_scale: f64,
    min_spacing_floor: f64,
    min_spacing_ratio: f64,
    spawn_extent_floor_x: f64,
    spawn_extent_floor_y: f64,
    spawn_extent_ratio_x: f64,
    spawn_extent_ratio_y: f64,
    candidate_attempts: u32,
}

impl VectorParameters {
    fn to_core(&self) -> TargetFieldParameters {
        TargetFieldParameters {
            base_diameter_lower: self.base_diameter_range[0],
            base_diameter_upper: self.base_diameter_range[1],
            area_factor: self.area_factor,
            target_scale: self.target_scale,
            min_spacing_floor: self.min_spacing_floor,
            min_spacing_ratio: self.min_spacing_ratio,
            spawn_extent_floor_x: self.spawn_extent_floor_x,
            spawn_extent_floor_y: self.spawn_extent_floor_y,
            spawn_extent_ratio_x: self.spawn_extent_ratio_x,
            spawn_extent_ratio_y: self.spawn_extent_ratio_y,
            candidate_attempts: self.candidate_attempts,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
struct VectorPoint {
    x: f64,
    y: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VectorExpectation {
    initial_targets: Vec<VectorTarget>,
    shot_results: Vec<VectorShotResult>,
    final_targets: Vec<VectorTarget>,
    totals: VectorTotals,
}

#[derive(Debug, Deserialize)]
struct VectorTarget {
    index: usize,
    center: VectorPoint,
    diameter: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VectorShotResult {
    hit: bool,
    hit_index: Option<usize>,
    score: i32,
    streak: i32,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VectorTotals {
    score: i32,
    shots: u32,
    hits: u32,
    streak: i32,
    best_streak: i32,
}

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(FIXTURE_RELATIVE_PATH)
}

fn load_fixture() -> VectorFile {
    let path = fixture_path();
    let text = std::fs::read_to_string(&path).unwrap_or_else(|error| {
        panic!(
            "读不到向量文件 {}：{error}\n\
             它由 Swift 侧生成：AGENTAIM_WRITE_FIXTURES=1 swift test --filter writesFrozenVectors",
            path.display()
        )
    });
    serde_json::from_str(&text).expect("向量文件解析失败")
}

/// 回放一个 case —— 与 `GameplayVectors.replay` 逻辑一一对应。
fn replay(case: &VectorCase) -> VectorExpectation {
    let mut field = TargetField::new(
        case.screen_width,
        case.screen_height,
        case.capacity,
        case.parameters.to_core(),
    );
    let mut rng = SplitMix64::new(case.seed);
    for index in 0..case.capacity {
        field.spawn(index, &mut rng);
    }
    let initial_targets = field
        .snapshot()
        .into_iter()
        .map(|target| VectorTarget {
            index: target.index,
            center: VectorPoint {
                x: target.center.x,
                y: target.center.y,
            },
            diameter: target.diameter,
        })
        .collect();

    let mut board = ScoreBoard::new();
    let mut shot_results = Vec::with_capacity(case.shots.len());
    for shot in &case.shots {
        let hit_index = field.hit_test(AimPoint::new(shot.x, shot.y));
        board.register_shot(hit_index.is_some());
        if let Some(index) = hit_index {
            field.spawn(index, &mut rng);
        }
        shot_results.push(VectorShotResult {
            hit: hit_index.is_some(),
            hit_index,
            score: board.score(),
            streak: board.streak(),
        });
    }

    let final_targets = field
        .snapshot()
        .into_iter()
        .map(|target| VectorTarget {
            index: target.index,
            center: VectorPoint {
                x: target.center.x,
                y: target.center.y,
            },
            diameter: target.diameter,
        })
        .collect();

    VectorExpectation {
        initial_targets,
        shot_results,
        final_targets,
        totals: VectorTotals {
            score: board.score(),
            shots: board.shots(),
            hits: board.hits(),
            streak: board.streak(),
            best_streak: board.best_streak(),
        },
    }
}

fn close(lhs: f64, rhs: f64) -> bool {
    (lhs - rhs).abs() < FLOAT_TOLERANCE
}

#[test]
fn fixture_version_matches_this_crate() {
    let file = load_fixture();
    println!("generator = {}", file.generator);
    println!("rngDrawOrder = {}", file.rng_draw_order);
    assert_eq!(
        file.version, VECTOR_VERSION,
        "向量文件版本 {} 与 crate 期望的 {} 不一致 —— 玩法契约变了，双方必须同步",
        file.version, VECTOR_VERSION
    );
    assert!(file.cases.len() >= 5, "向量 case 太少");
    for case in &file.cases {
        assert!(!case.shots.is_empty(), "case {} 没有开火序列", case.name);
        assert!(
            !case.notes.is_empty(),
            "case {} 缺少说明，将来没人知道它在盯什么",
            case.name
        );
    }
}

/// PRNG 单独先验一次：如果这步就红了，后面整局的差异都只是它的下游症状。
#[test]
fn splitmix_matches_frozen_known_answers() {
    let file = load_fixture();
    assert!(!file.rng_known_answers.is_empty());
    for answer in &file.rng_known_answers {
        let mut rng = SplitMix64::new(answer.seed);
        for (position, expected) in answer.first_outputs.iter().enumerate() {
            let actual = format!("0x{:016X}", rng.next_u64());
            assert_eq!(
                &actual, expected,
                "seed {} 的第 {} 个输出不一致：Rust {actual} vs Swift {expected}",
                answer.seed, position
            );
        }
    }
}

/// 端到端对表。一次把**所有**不一致都打出来，而不是遇到第一个就停 ——
/// 定位移植错误时，"哪一类字段错了"比"第一处错在哪"有用得多。
#[test]
fn rust_core_reproduces_frozen_vectors() {
    let file = load_fixture();
    let mut failures: Vec<String> = Vec::new();
    let mut max_deviation = 0.0f64;

    for case in &file.cases {
        let expected = &case.expected;
        let actual = replay(case);

        for (label, actual_targets, expected_targets) in [
            ("开局", &actual.initial_targets, &expected.initial_targets),
            ("收局", &actual.final_targets, &expected.final_targets),
        ] {
            if actual_targets.len() != expected_targets.len() {
                failures.push(format!(
                    "[{}] {}靶子数量：{} vs {}",
                    case.name,
                    label,
                    actual_targets.len(),
                    expected_targets.len()
                ));
                continue;
            }
            for (lhs, rhs) in actual_targets.iter().zip(expected_targets.iter()) {
                if lhs.index != rhs.index {
                    failures.push(format!(
                        "[{}] {}靶子序号：{} vs {}",
                        case.name, label, lhs.index, rhs.index
                    ));
                }
                max_deviation = max_deviation.max((lhs.center.x - rhs.center.x).abs());
                max_deviation = max_deviation.max((lhs.center.y - rhs.center.y).abs());
                max_deviation = max_deviation.max((lhs.diameter - rhs.diameter).abs());
                if !close(lhs.center.x, rhs.center.x)
                    || !close(lhs.center.y, rhs.center.y)
                    || !close(lhs.diameter, rhs.diameter)
                {
                    failures.push(format!(
                        "[{}] {}靶子 #{}：({}, {}) r={} vs ({}, {}) r={}",
                        case.name,
                        label,
                        lhs.index,
                        lhs.center.x,
                        lhs.center.y,
                        lhs.diameter,
                        rhs.center.x,
                        rhs.center.y,
                        rhs.diameter
                    ));
                }
            }
        }

        if actual.shot_results.len() != expected.shot_results.len() {
            failures.push(format!(
                "[{}] 开火次数：{} vs {}",
                case.name,
                actual.shot_results.len(),
                expected.shot_results.len()
            ));
            continue;
        }
        for (index, (lhs, rhs)) in actual
            .shot_results
            .iter()
            .zip(expected.shot_results.iter())
            .enumerate()
        {
            if lhs.hit != rhs.hit || lhs.hit_index != rhs.hit_index {
                failures.push(format!(
                    "[{}] 第 {} 枪命中判定：hit={} #{} vs hit={} #{}（弹着点 ({}, {})）",
                    case.name,
                    index,
                    lhs.hit,
                    lhs.hit_index
                        .map_or_else(|| "None".to_string(), |v| v.to_string()),
                    rhs.hit,
                    rhs.hit_index
                        .map_or_else(|| "None".to_string(), |v| v.to_string()),
                    case.shots[index].x,
                    case.shots[index].y
                ));
            }
            if lhs.score != rhs.score || lhs.streak != rhs.streak {
                failures.push(format!(
                    "[{}] 第 {} 枪计分：score={} streak={} vs score={} streak={}",
                    case.name, index, lhs.score, lhs.streak, rhs.score, rhs.streak
                ));
            }
        }

        let (lhs, rhs) = (&actual.totals, &expected.totals);
        if lhs != rhs {
            failures.push(format!(
                "[{}] 总分板：score={} shots={} hits={} streak={} best={} vs score={} shots={} hits={} streak={} best={}",
                case.name, lhs.score, lhs.shots, lhs.hits, lhs.streak, lhs.best_streak,
                rhs.score, rhs.shots, rhs.hits, rhs.streak, rhs.best_streak
            ));
        }
    }

    println!(
        "对表完成：{} 个 case，浮点最大偏差 {:e}（容差 {FLOAT_TOLERANCE:e}，应当只来自 serde_json 的 1 ULP 解析）",
        file.cases.len(),
        max_deviation
    );
    assert!(
        max_deviation < FLOAT_TOLERANCE,
        "浮点偏差 {max_deviation:e} 超过容差 —— 这已经不像解析噪声了，像是逻辑抄错了"
    );
    assert!(
        failures.is_empty(),
        "Rust 核心与冻结向量不一致（{} 处）：\n{}",
        failures.len(),
        failures.join("\n")
    );
}

/// 把上面那条已查明的解析偏差**钉住**。
///
/// 这条测试红了的唯一含义是「serde_json 修好了」—— 那时请把
/// [`FLOAT_TOLERANCE`] 收紧到 0 并删掉这条测试，因为契约本可以做到逐位相等。
#[test]
fn known_float_parsing_artifact_is_pinned() {
    let literal = "39.737625314654636";
    let std_parsed: f64 = literal.parse().expect("Rust std 一定能解析这个字面量");
    let via_serde: f64 = serde_json::from_str(literal).expect("serde_json 也能解析它");

    assert_eq!(
        std_parsed.to_bits(),
        0x4043_DE6A_819D_925A,
        "Rust std 的解析应当是正确的舍入结果"
    );
    assert_eq!(
        via_serde.to_bits().wrapping_sub(std_parsed.to_bits()),
        1,
        "serde_json 现在解析正确了 —— 请把 FLOAT_TOLERANCE 收紧到 0，并删掉这条测试"
    );
}

/// 边界与顺序的定点断言 —— 这些不是"顺手多写的测试"，
/// 而是移植时最容易抄错的四处。
mod parity_edges {
    use super::*;

    #[test]
    fn radius_boundary_is_inclusive() {
        let mut field = TargetField::new(1470.0, 956.0, 1, TargetFieldParameters::default());
        field.place(0, AimTarget::new(AimPoint::new(100.0, 100.0), 40.0));
        assert_eq!(field.hit_test(AimPoint::new(120.0, 100.0)), Some(0));
        assert_eq!(field.hit_test(AimPoint::new(120.000001, 100.0)), None);
        assert_eq!(field.hit_test(AimPoint::new(80.0, 100.0)), Some(0));
        assert_eq!(field.hit_test(AimPoint::new(79.999999, 100.0)), None);
    }

    #[test]
    fn exact_tie_picks_lower_index() {
        let mut field = TargetField::new(1470.0, 956.0, 2, TargetFieldParameters::default());
        field.place(0, AimTarget::new(AimPoint::new(200.0, 300.0), 200.0));
        field.place(1, AimTarget::new(AimPoint::new(400.0, 300.0), 200.0));
        assert_eq!(field.hit_test(AimPoint::new(300.0, 300.0)), Some(0));
    }

    #[test]
    fn min_spacing_and_spawn_extent_take_the_larger_value() {
        let small = TargetField::new(1024.0, 768.0, 3, TargetFieldParameters::default());
        assert_eq!(small.min_spacing(), 110.0);
        let base = TargetField::new(1470.0, 956.0, 3, TargetFieldParameters::default());
        assert_eq!(base.min_spacing(), 147.0);
        let large = TargetField::new(2560.0, 1440.0, 3, TargetFieldParameters::default());
        assert_eq!(large.min_spacing(), 256.0);

        let tiny = TargetField::new(500.0, 400.0, 3, TargetFieldParameters::default());
        assert_eq!(tiny.spawn_extent(), AimPoint::new(180.0, 130.0));
    }

    #[test]
    fn streak_bonus_caps_at_twenty() {
        let mut board = ScoreBoard::new();
        assert_eq!(board.register_shot(true), 100);
        let mut awarded = vec![100];
        for _ in 1..25 {
            awarded.push(board.register_shot(true));
        }
        assert_eq!(awarded[19], 195);
        assert_eq!(awarded[20], 200);
        assert_eq!(awarded[24], 200);
        assert_eq!(board.score(), 20 * 100 + 5 * 190 + 5 * 200);
        assert_eq!(board.best_streak(), 25);

        board.register_shot(false);
        assert_eq!(board.streak(), 0);
        assert_eq!(board.best_streak(), 25);
        assert_eq!(board.register_shot(true), 100);
    }
}
