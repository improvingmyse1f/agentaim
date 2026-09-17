import Foundation
import Testing
@testable import AgentAimCore

struct FPSSensitivityTests {
    @Test func tacticalDefaultDoesNotGuessMouseDPI() {
        #expect(FPSSensitivity.defaultTactical.dpi == nil)
        #expect(FPSSensitivity.defaultTactical.centimetersPer360 == nil)
    }

    @Test func knownDPIProducesApproximatelyFiftyCentimetersPer360() throws {
        let sensitivity = try #require(FPSSensitivity(profile: .valorant, value: 0.327, dpi: 800))
        let distance = try #require(sensitivity.centimetersPer360)
        #expect(abs(distance - 50) < 0.2)
    }

    @Test func convertingProfilesPreservesPhysicalDistance() throws {
        let valorant = try #require(FPSSensitivity(profile: .valorant, value: 0.4, dpi: 800))
        let counterStrike = valorant.converted(to: .counterStrike2)

        #expect(abs(counterStrike.value - 1.272727) < 0.000001)
        let counterStrikeDistance = try #require(counterStrike.centimetersPer360)
        let valorantDistance = try #require(valorant.centimetersPer360)
        #expect(abs(counterStrikeDistance - valorantDistance) < 0.000001)
    }

    @Test func dpiChangesPhysicalDistanceButNotAngularGain() throws {
        let at800 = try #require(FPSSensitivity(profile: .valorant, value: 0.327, dpi: 800))
        let at1600 = try #require(FPSSensitivity(profile: .valorant, value: 0.327, dpi: 1600))

        let distanceAt800 = try #require(at800.centimetersPer360)
        let distanceAt1600 = try #require(at1600.centimetersPer360)
        #expect(abs(distanceAt1600 * 2 - distanceAt800) < 0.000001)
        #expect(at1600.degreesPerCount == at800.degreesPerCount)
    }

    @Test func missingDPIDoesNotChangeAngularGain() throws {
        let withoutDPI = try #require(FPSSensitivity(profile: .valorant, value: 0.327))
        let at800 = try #require(FPSSensitivity(profile: .valorant, value: 0.327, dpi: 800))

        #expect(withoutDPI.centimetersPer360 == nil)
        #expect(withoutDPI.degreesPerCount == at800.degreesPerCount)
    }

    @Test func defaultValorantAndConvertedCounterStrikeProduceIdenticalAngles() throws {
        let valorant = try #require(FPSSensitivity(profile: .valorant, value: 0.327, dpi: 800))
        let counterStrike = valorant.converted(to: .counterStrike2)

        #expect(abs(counterStrike.value - 1.040454545) < 0.000000001)
        let valorantDelta = valorant.angleDelta(horizontalCounts: 1_000, verticalCounts: -250)
        let counterStrikeDelta = counterStrike.angleDelta(horizontalCounts: 1_000, verticalCounts: -250)
        #expect(abs(valorantDelta.yawDegrees - counterStrikeDelta.yawDegrees) < 0.000000001)
        #expect(abs(valorantDelta.pitchDegrees - counterStrikeDelta.pitchDegrees) < 0.000000001)
    }

    @Test func repeatedProfileRoundTripsDoNotDrift() throws {
        let original = try #require(FPSSensitivity(profile: .valorant, value: 0.327, dpi: 800))
        var converted = original
        for _ in 0..<100 {
            converted = converted.converted(to: .counterStrike2).converted(to: .valorant)
        }
        #expect(abs(converted.value - original.value) < 0.000000000001)
        #expect(abs(converted.degreesPerCount - original.degreesPerCount) < 0.000000000001)
    }

    @Test func perspectiveProjectionUsesGameFOVInsteadOfLinearScreenGain() throws {
        let valorant = try #require(FPSPerspectiveProjection(
            horizontalFieldOfView: FPSGameProfile.valorant.horizontalFieldOfView(),
            viewportWidth: 1_440,
            viewportHeight: 900,
            inset: 18
        ))
        let counterStrike = try #require(FPSPerspectiveProjection(
            horizontalFieldOfView: FPSGameProfile.counterStrike2.horizontalFieldOfView(),
            viewportWidth: 1_440,
            viewportHeight: 900,
            inset: 18
        ))
        let angle = FPSAimAngles(yawDegrees: 10, pitchDegrees: 0)
        let valorantPoint = valorant.point(for: angle)
        let counterStrikePoint = counterStrike.point(for: angle)

        #expect(valorantPoint.x > counterStrikePoint.x)
        #expect(valorantPoint.y == 450)
        #expect(counterStrikePoint.y == 450)
        #expect(abs(valorantPoint.x - (720 + valorant.focalLength * tan(10 * .pi / 180))) < 0.000001)
    }

    @Test func projectionClampsAnglesWithoutHiddenEdgeOvershoot() throws {
        let projection = try #require(FPSPerspectiveProjection(
            horizontalFieldOfView: 103,
            viewportWidth: 1_440,
            viewportHeight: 900,
            inset: 18
        ))
        let clamped = projection.clamped(FPSAimAngles(yawDegrees: 500, pitchDegrees: 500))
        let point = projection.point(for: clamped)

        #expect(abs(point.x - 1_422) < 0.000001)
        #expect(abs(point.y - 882) < 0.000001)
        #expect(clamped.yawDegrees < 90)
        #expect(clamped.pitchDegrees < 90)
    }

    @Test func unacceleratedMouseCountsWinOverLegacyDelta() {
        let horizontal = FPSMouseCounts.preferred(
            unacceleratedX: 7,
            unacceleratedY: 0,
            fallbackX: 19,
            fallbackY: 4
        )
        let syntheticFallback = FPSMouseCounts.preferred(
            unacceleratedX: 0,
            unacceleratedY: 0,
            fallbackX: 19,
            fallbackY: -4
        )

        #expect(horizontal == FPSMouseCounts(x: 7, y: 0))
        #expect(syntheticFallback == FPSMouseCounts(x: 19, y: -4))
    }

    @Test func counterStrikeDisplayModeUsesTheMatchingHorizontalFOV() {
        #expect(FPSGameProfile.counterStrike2.horizontalFieldOfView(displayMode: .widescreen16x9) == 106.26)
        #expect(FPSGameProfile.counterStrike2.horizontalFieldOfView(displayMode: .stretched4x3) == 90)
        #expect(FPSGameProfile.valorant.horizontalFieldOfView(displayMode: .stretched4x3) == 103)
    }

    @Test func rejectsInvalidValues() {
        #expect(FPSSensitivity(profile: .valorant, value: 0, dpi: 800) == nil)
        #expect(FPSSensitivity(profile: .counterStrike2, value: 1, dpi: -1) == nil)
        #expect(FPSSensitivity(profile: .valorant, value: .infinity, dpi: 800) == nil)
    }
}
