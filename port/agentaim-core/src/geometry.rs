//! 屏幕平面上的点与靶子。刻意用 `f64` 而不是平台几何类型：
//! 这一层是要给两端共享的，不该把任何框架的类型带进来。

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AimPoint {
    pub x: f64,
    pub y: f64,
}

impl AimPoint {
    pub const ZERO: AimPoint = AimPoint { x: 0.0, y: 0.0 };

    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    /// 两点距离。
    ///
    /// 用 `sqrt(dx²+dy²)` 而不是 `hypot`：`sqrt` 由 IEEE-754 要求「正确舍入」，
    /// 任何语言、任何 CPU 上结果逐位相同；`hypot` 的实现允许有误差，
    /// 跨语言对表时会在边界靶子上产生真假难辨的 1e-16 级差异。
    pub fn distance(self, other: AimPoint) -> f64 {
        let dx = other.x - self.x;
        let dy = other.y - self.y;
        (dx * dx + dy * dy).sqrt()
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AimTarget {
    pub center: AimPoint,
    pub diameter: f64,
}

impl AimTarget {
    pub fn new(center: AimPoint, diameter: f64) -> Self {
        Self { center, diameter }
    }

    pub fn radius(&self) -> f64 {
        self.diameter / 2.0
    }

    /// 边界是**闭**的：圆心距恰好等于半径算命中。改这个会静默改变手感。
    pub fn contains(&self, point: AimPoint) -> bool {
        self.center.distance(point) <= self.radius()
    }
}

/// 带序号的目标快照，用于对表与验收。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TargetSnapshot {
    pub index: usize,
    pub center: AimPoint,
    pub diameter: f64,
}
