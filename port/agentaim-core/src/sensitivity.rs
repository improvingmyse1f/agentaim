//! 游戏原生灵敏度与二维透视投影。
//!
//! 与 macOS 的 `FPSSensitivity.swift` 使用同一组常量和同一运算顺序：Raw Input
//! 鼠标计数先变成游戏中的转角，再通过对应水平 FOV 投到透明靶场。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GameProfile {
    Valorant,
    CounterStrike2,
}

impl GameProfile {
    pub fn yaw_degrees_per_count(self) -> f64 {
        match self {
            Self::Valorant => 0.07,
            Self::CounterStrike2 => 0.022,
        }
    }

    pub fn horizontal_field_of_view(self, display_mode: DisplayMode) -> f64 {
        match (self, display_mode) {
            (Self::Valorant, _) => 103.0,
            (Self::CounterStrike2, DisplayMode::Widescreen16x9) => 106.26,
            (Self::CounterStrike2, DisplayMode::Stretched4x3) => 90.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayMode {
    Widescreen16x9,
    Stretched4x3,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sensitivity {
    pub profile: GameProfile,
    pub value: f64,
    pub dpi: Option<f64>,
}

impl Sensitivity {
    pub fn new(profile: GameProfile, value: f64, dpi: Option<f64>) -> Option<Self> {
        if !value.is_finite() || value <= 0.0 {
            return None;
        }
        if dpi.is_some_and(|dpi| !dpi.is_finite() || dpi <= 0.0) {
            return None;
        }
        Some(Self {
            profile,
            value,
            dpi,
        })
    }

    pub fn default_tactical() -> Self {
        Self::new(GameProfile::Valorant, 0.327, None).expect("valid default")
    }

    pub fn degrees_per_count(self) -> f64 {
        self.profile.yaw_degrees_per_count() * self.value
    }

    pub fn centimeters_per_360(self) -> Option<f64> {
        self.dpi
            .map(|dpi| 360.0 * 2.54 / (dpi * self.degrees_per_count()))
    }

    pub fn converted(self, profile: GameProfile) -> Self {
        Self::new(
            profile,
            self.degrees_per_count() / profile.yaw_degrees_per_count(),
            self.dpi,
        )
        .expect("a valid sensitivity remains valid after conversion")
    }

    pub fn angle_delta(self, horizontal_counts: f64, vertical_counts: f64) -> AimAngles {
        AimAngles {
            yaw_degrees: horizontal_counts * self.degrees_per_count(),
            pitch_degrees: vertical_counts * self.degrees_per_count(),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct AimAngles {
    pub yaw_degrees: f64,
    pub pitch_degrees: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProjectedPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PerspectiveProjection {
    pub horizontal_field_of_view: f64,
    pub viewport_width: f64,
    pub viewport_height: f64,
    pub inset: f64,
}

impl PerspectiveProjection {
    pub fn new(
        horizontal_field_of_view: f64,
        viewport_width: f64,
        viewport_height: f64,
        inset: f64,
    ) -> Option<Self> {
        if !horizontal_field_of_view.is_finite()
            || horizontal_field_of_view <= 0.0
            || horizontal_field_of_view >= 180.0
            || !viewport_width.is_finite()
            || viewport_width <= 0.0
            || !viewport_height.is_finite()
            || viewport_height <= 0.0
            || !inset.is_finite()
            || inset < 0.0
            || inset * 2.0 >= viewport_width
            || inset * 2.0 >= viewport_height
        {
            return None;
        }
        Some(Self {
            horizontal_field_of_view,
            viewport_width,
            viewport_height,
            inset,
        })
    }

    pub fn focal_length(self) -> f64 {
        self.viewport_width / (2.0 * (self.horizontal_field_of_view.to_radians() / 2.0).tan())
    }

    pub fn clamped(self, angles: AimAngles) -> AimAngles {
        let focal_length = self.focal_length();
        let half_usable_width = self.viewport_width / 2.0 - self.inset;
        let max_yaw = (half_usable_width / focal_length).atan().to_degrees();
        let yaw_degrees = angles.yaw_degrees.clamp(-max_yaw, max_yaw);

        let half_usable_height = self.viewport_height / 2.0 - self.inset;
        let yaw_cosine = yaw_degrees.to_radians().cos();
        let max_pitch = (half_usable_height * yaw_cosine / focal_length)
            .atan()
            .to_degrees();
        let pitch_degrees = angles.pitch_degrees.clamp(-max_pitch, max_pitch);
        AimAngles {
            yaw_degrees,
            pitch_degrees,
        }
    }

    pub fn point(self, raw_angles: AimAngles) -> ProjectedPoint {
        let angles = self.clamped(raw_angles);
        let yaw = angles.yaw_degrees.to_radians();
        let pitch = angles.pitch_degrees.to_radians();
        ProjectedPoint {
            x: self.viewport_width / 2.0 + self.focal_length() * yaw.tan(),
            y: self.viewport_height / 2.0 + self.focal_length() * pitch.tan() / yaw.cos(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPSILON: f64 = 1e-12;

    #[test]
    fn defaults_match_macos() {
        let value = Sensitivity::default_tactical();
        assert_eq!(value.profile, GameProfile::Valorant);
        assert_eq!(value.value, 0.327);
        assert_eq!(value.dpi, None);
    }

    #[test]
    fn known_dpi_is_about_fifty_centimeters_per_360() {
        let value = Sensitivity::new(GameProfile::Valorant, 0.327, Some(800.0)).unwrap();
        assert!((value.centimeters_per_360().unwrap() - 49.934469200524234).abs() < EPSILON);
    }

    #[test]
    fn conversion_preserves_angular_gain() {
        let valorant = Sensitivity::new(GameProfile::Valorant, 0.327, Some(800.0)).unwrap();
        let cs2 = valorant.converted(GameProfile::CounterStrike2);
        assert!((cs2.value - 1.0404545454545455).abs() < EPSILON);
        assert!((valorant.degrees_per_count() - cs2.degrees_per_count()).abs() < EPSILON);
        assert_eq!(valorant.centimeters_per_360(), cs2.centimeters_per_360());
    }

    #[test]
    fn projection_matches_macos_reference_values() {
        let projection = PerspectiveProjection::new(103.0, 1470.0, 956.0, 14.0).unwrap();
        let point = projection.point(AimAngles {
            yaw_degrees: 12.0,
            pitch_degrees: -7.0,
        });
        assert!((point.x - 859.2702157546805).abs() < 1e-9);
        assert!((point.y - 404.61084225358854).abs() < 1e-9);
    }

    #[test]
    fn clamping_has_no_hidden_angle_overshoot() {
        let projection = PerspectiveProjection::new(90.0, 1000.0, 600.0, 20.0).unwrap();
        let clamped = projection.clamped(AimAngles {
            yaw_degrees: 999.0,
            pitch_degrees: 999.0,
        });
        let point = projection.point(clamped);
        assert!((point.x - 980.0).abs() < 1e-9);
        assert!((point.y - 580.0).abs() < 1e-9);
    }
}
