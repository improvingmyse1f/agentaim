import Foundation

/// 游戏原生灵敏度口径。
///
/// `yawDegreesPerCount` 表示游戏灵敏度为 1 时，一个鼠标计数对应的视角角度。
/// AgentAim 仍使用移动准星；这里只把相同的角度/物理距离映射到透明靶场的屏幕平面。
public enum FPSGameProfile: String, CaseIterable, Codable, Sendable {
    case valorant
    case counterStrike2

    public var displayName: String {
        switch self {
        case .valorant: return "VALORANT"
        case .counterStrike2: return "Counter-Strike 2"
        }
    }

    public var yawDegreesPerCount: Double {
        switch self {
        case .valorant: return 0.07
        case .counterStrike2: return 0.022
        }
    }

    public func horizontalFieldOfView(displayMode: FPSDisplayMode = .widescreen16x9) -> Double {
        switch self {
        case .valorant: return 103
        case .counterStrike2:
            switch displayMode {
            case .widescreen16x9: return 106.26
            case .stretched4x3: return 90
            }
        }
    }
}

public enum FPSDisplayMode: String, CaseIterable, Codable, Sendable {
    case widescreen16x9
    case stretched4x3

    public var displayName: String {
        switch self {
        case .widescreen16x9: return "16:9"
        case .stretched4x3: return "4:3 拉伸"
        }
    }
}

public struct FPSSensitivity: Equatable, Codable, Sendable {
    public let profile: FPSGameProfile
    public let value: Double
    /// 仅用于显示物理距离；实际准星移动直接使用鼠标上报的计数，不依赖此值。
    public let dpi: Double?

    /// 默认只提供游戏内灵敏度，不猜测用户鼠标的真实 DPI。
    public static let defaultTactical = FPSSensitivity(
        profile: .valorant,
        value: 0.327,
        dpi: nil
    )!

    public init?(profile: FPSGameProfile, value: Double, dpi: Double? = nil) {
        guard value.isFinite, value > 0 else { return nil }
        if let dpi, (!dpi.isFinite || dpi <= 0) { return nil }
        self.profile = profile
        self.value = value
        self.dpi = dpi
    }

    public var degreesPerCount: Double {
        profile.yawDegreesPerCount * value
    }

    public var centimetersPer360: Double? {
        guard let dpi else { return nil }
        return 360 * 2.54 / (dpi * degreesPerCount)
    }

    /// 切换游戏配置时保持 cm/360 不变。
    public func converted(to newProfile: FPSGameProfile) -> FPSSensitivity {
        let convertedValue = degreesPerCount / newProfile.yawDegreesPerCount
        return FPSSensitivity(profile: newProfile, value: convertedValue, dpi: dpi)!
    }

    public func angleDelta(horizontalCounts: Double, verticalCounts: Double) -> FPSAimAngles {
        FPSAimAngles(
            yawDegrees: horizontalCounts * degreesPerCount,
            pitchDegrees: verticalCounts * degreesPerCount
        )
    }
}

/// 相对本局初始视线的水平/垂直转角。
///
/// 鼠标计数先变成角度，再由 `FPSPerspectiveProjection` 投到二维透明靶场；这样灵敏度
/// 仍遵守游戏原生的角度响应，而不是把游戏 FOV 误当成一个线性的屏幕倍率。
public struct FPSAimAngles: Equatable, Sendable {
    public var yawDegrees: Double
    public var pitchDegrees: Double

    public init(yawDegrees: Double = 0, pitchDegrees: Double = 0) {
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
    }
}

public struct FPSProjectedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct FPSMouseCounts: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// 真实硬件事件优先采用系统提供的未加速计数；测试或合成事件没有该字段时才回退。
    public static func preferred(
        unacceleratedX: Int64,
        unacceleratedY: Int64,
        fallbackX: Int64,
        fallbackY: Int64
    ) -> FPSMouseCounts {
        if unacceleratedX != 0 || unacceleratedY != 0 {
            return FPSMouseCounts(x: Double(unacceleratedX), y: Double(unacceleratedY))
        }
        return FPSMouseCounts(x: Double(fallbackX), y: Double(fallbackY))
    }
}

/// 用目标游戏的水平 FOV 建立一个虚拟透视相机。
///
/// AgentAim 的靶子仍固定在透明二维平面上、准星仍随鼠标移动；这里只把游戏中的相机转角
/// 投影成准星位置。对用户而言，从中心甩到某个屏幕位置所需的鼠标计数与目标游戏一致。
public struct FPSPerspectiveProjection: Equatable, Sendable {
    public let horizontalFieldOfView: Double
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let inset: Double

    public init?(
        horizontalFieldOfView: Double,
        viewportWidth: Double,
        viewportHeight: Double,
        inset: Double = 0
    ) {
        guard horizontalFieldOfView.isFinite,
              horizontalFieldOfView > 0,
              horizontalFieldOfView < 180,
              viewportWidth.isFinite,
              viewportWidth > 0,
              viewportHeight.isFinite,
              viewportHeight > 0,
              inset.isFinite,
              inset >= 0,
              inset * 2 < viewportWidth,
              inset * 2 < viewportHeight
        else { return nil }

        self.horizontalFieldOfView = horizontalFieldOfView
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.inset = inset
    }

    public var focalLength: Double {
        viewportWidth / (2 * tan(horizontalFieldOfView.radians / 2))
    }

    public func clamped(_ angles: FPSAimAngles) -> FPSAimAngles {
        let halfUsableWidth = viewportWidth / 2 - inset
        let maxYaw = atan(halfUsableWidth / focalLength).degrees
        let yaw = min(maxYaw, max(-maxYaw, angles.yawDegrees))

        // 完整的透视投影里 y = f * tan(pitch) / cos(yaw)。所以垂直可用角度会随 yaw
        // 略微收窄；在这里同步约束，准星撞边后反向移动不会出现隐藏的角度死区。
        let halfUsableHeight = viewportHeight / 2 - inset
        let yawCosine = cos(yaw.radians)
        let maxPitch = atan(halfUsableHeight * yawCosine / focalLength).degrees
        let pitch = min(maxPitch, max(-maxPitch, angles.pitchDegrees))
        return FPSAimAngles(yawDegrees: yaw, pitchDegrees: pitch)
    }

    public func point(for rawAngles: FPSAimAngles) -> FPSProjectedPoint {
        let angles = clamped(rawAngles)
        let yaw = angles.yawDegrees.radians
        let pitch = angles.pitchDegrees.radians
        let x = viewportWidth / 2 + focalLength * tan(yaw)
        let y = viewportHeight / 2 + focalLength * tan(pitch) / cos(yaw)
        return FPSProjectedPoint(x: x, y: y)
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
