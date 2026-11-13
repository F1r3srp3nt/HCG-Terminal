import Foundation
@testable import TerminalUI
import XCTest

final class EventHorizonTests: XCTestCase {
    // MARK: Settings

    func testDefaultsAreEventHorizonSubtleWithoutMotion() {
        let settings = AppearanceSettings()
        XCTAssertEqual(settings.style, .eventHorizon)
        XCTAssertEqual(settings.backgroundDetail, .subtle)
        XCTAssertFalse(settings.ambientMotion)
    }

    func testOlderSettingsKeepFontAndColorsAndGetNewDefaults() throws {
        let suite = "hcg-eh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"theme":"system","accent":"green","reducedEffects":false,"terminalFontSize":17,"animatedHeader":false}"#.utf8), forKey: AppearanceStore.key)
        let store = AppearanceStore(defaults: defaults)
        var settings = store.settings
        XCTAssertEqual(settings.terminalFontSize, 17, "font size preference preserved")
        XCTAssertEqual(settings.accent, .green, "colour preference preserved")
        XCTAssertEqual(settings.theme, .system)
        XCTAssertFalse(settings.animatedHeader)
        XCTAssertEqual(settings.style, .eventHorizon)
        XCTAssertEqual(settings.backgroundDetail, .subtle)
        XCTAssertFalse(settings.ambientMotion)

        settings.style = .classic
        settings.backgroundDetail = .enhanced
        settings.ambientMotion = true
        store.settings = settings
        let reloaded = AppearanceStore(defaults: defaults).settings
        XCTAssertEqual(reloaded.style, .classic)
        XCTAssertEqual(reloaded.backgroundDetail, .enhanced)
        XCTAssertTrue(reloaded.ambientMotion)
        XCTAssertEqual(reloaded.terminalFontSize, 17)
    }

    func testUnknownStyleValueFallsBackInsteadOfLosingSettings() throws {
        let data = Data(#"{"style":"neon","backgroundDetail":"max","terminalFontSize":12}"#.utf8)
        let settings = try JSONDecoder().decode(AppearanceSettings.self, from: data)
        XCTAssertEqual(settings.style, .eventHorizon)
        XCTAssertEqual(settings.backgroundDetail, .subtle)
        XCTAssertEqual(settings.terminalFontSize, 12)
    }

    // MARK: Background policy

    func testBackdropLayersPerDetailLevel() {
        let off = BackdropPolicy.layers(.init(style: .eventHorizon, detail: .off))
        XCTAssertTrue(off.edgeGlow)
        XCTAssertEqual(off.geometry, .off)
        XCTAssertEqual(off.traceOpacity, 0)

        let subtle = BackdropPolicy.layers(.init(style: .eventHorizon, detail: .subtle))
        let enhanced = BackdropPolicy.layers(.init(style: .eventHorizon, detail: .enhanced))
        XCTAssertFalse(subtle.opaqueFallback)
        // The traces stay faint: roughly 2–4 %, a little more when enhanced.
        XCTAssertGreaterThanOrEqual(subtle.traceOpacity, 0.02)
        XCTAssertLessThanOrEqual(subtle.traceOpacity, 0.04)
        XCTAssertGreaterThan(enhanced.traceOpacity, subtle.traceOpacity)
        XCTAssertLessThanOrEqual(enhanced.traceOpacity, 0.05)
    }

    func testOpaqueFallbackForClassicReducedEffectsTransparencyContrastAndLight() {
        let cases: [BackdropPolicy.Conditions] = [
            .init(style: .classic, detail: .enhanced),
            .init(style: .eventHorizon, detail: .enhanced, reducedEffects: true),
            .init(style: .eventHorizon, detail: .enhanced, reduceTransparency: true),
            .init(style: .eventHorizon, detail: .enhanced, increasedContrast: true),
            .init(style: .eventHorizon, detail: .enhanced, darkAppearance: false),
        ]
        for conditions in cases {
            XCTAssertEqual(BackdropPolicy.layers(conditions), .plain, "\(conditions)")
        }
    }

    // MARK: Ambient motion

    func testAmbientMotionRunsOnlyWhenEveryConditionHolds() {
        func c(_ change: (inout AmbientMotionPolicy.Conditions) -> Void = { _ in }) -> AmbientMotionPolicy.Conditions {
            var value = AmbientMotionPolicy.Conditions(preferenceOn: true, backdropDrawsGlow: true, reduceMotion: false, lowPowerMode: false, appActive: true, terminalInUse: false)
            change(&value)
            return value
        }
        XCTAssertTrue(AmbientMotionPolicy.shouldAnimate(c()))
        XCTAssertFalse(AmbientMotionPolicy.shouldAnimate(c { $0.preferenceOn = false }), "off by default")
        XCTAssertFalse(AmbientMotionPolicy.shouldAnimate(c { $0.backdropDrawsGlow = false }))
        XCTAssertFalse(AmbientMotionPolicy.shouldAnimate(c { $0.reduceMotion = true }))
        XCTAssertFalse(AmbientMotionPolicy.shouldAnimate(c { $0.lowPowerMode = true }))
        XCTAssertFalse(AmbientMotionPolicy.shouldAnimate(c { $0.appActive = false }), "stops in the background")
        XCTAssertFalse(AmbientMotionPolicy.shouldAnimate(c { $0.terminalInUse = true }), "never during terminal use")
    }

    func testAmbientGlowIsGentle() {
        var lowest = 1.0, highest = 0.0
        for step in 0...240 {
            let value = AmbientMotionPolicy.glowScale(at: Double(step) * AmbientMotionPolicy.period / 240)
            lowest = min(lowest, value)
            highest = max(highest, value)
        }
        XCTAssertEqual(highest, 1, accuracy: 0.0001)
        XCTAssertEqual(highest - lowest, AmbientMotionPolicy.amplitude, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(AmbientMotionPolicy.period, 8, "slow: no flashing")
    }

    // MARK: Geometry

    func testGeometryIsDeterministicAndCached() {
        XCTAssertEqual(EventHorizonGeometry.make(.subtle), EventHorizonGeometry.make(.subtle))
        XCTAssertEqual(EventHorizonGeometry.cached(.subtle), EventHorizonGeometry.make(.subtle))
        XCTAssertEqual(EventHorizonGeometry.cached(.enhanced), EventHorizonGeometry.make(.enhanced))
        XCTAssertTrue(EventHorizonGeometry.cached(.off).isEmpty)
    }

    func testGeometryIsSparseAndEnhancedAddsDetail() {
        let subtle = EventHorizonGeometry.make(.subtle)
        let enhanced = EventHorizonGeometry.make(.enhanced)
        XCTAssertLessThanOrEqual(subtle.traces.count, 10, "sparse")
        XCTAssertGreaterThan(enhanced.traces.count, subtle.traces.count)
        XCTAssertTrue(subtle.ticks.isEmpty)
        XCTAssertFalse(enhanced.ticks.isEmpty)
    }

    /// Everything stays near the perimeter, so the centre of every screen shape is quiet.
    func testCentreStaysQuietOnEveryScreenShape() {
        let sizes: [(Double, Double)] = [(320, 568), (375, 667), (393, 852), (440, 956), (852, 393), (744, 1133), (1024, 1366), (1366, 1024)]
        for detail in [AppearanceSettings.BackgroundDetail.subtle, .enhanced] {
            let geometry = EventHorizonGeometry.make(detail)
            for (width, height) in sizes {
                for path in geometry.allPaths {
                    for point in path.points {
                        let (x, y) = point.resolved(width: width, height: height)
                        let distance = min(x, y, width - x, height - y)
                        XCTAssertLessThanOrEqual(distance, EventHorizonGeometry.maxDepth, "\(detail) \(width)x\(height): \(x),\(y)")
                        XCTAssertGreaterThanOrEqual(x, -3)
                        XCTAssertGreaterThanOrEqual(y, -3)
                        XCTAssertLessThanOrEqual(x, width + 3)
                        XCTAssertLessThanOrEqual(y, height + 3)
                    }
                }
            }
        }
    }

    func testTraceBendsAreRightAnglesOrDiagonals() {
        for path in EventHorizonGeometry.make(.enhanced).traces {
            for (a, b) in zip(path.points, path.points.dropFirst()) {
                let (ax, ay) = a.resolved(width: 400, height: 800)
                let (bx, by) = b.resolved(width: 400, height: 800)
                let dx = abs(bx - ax), dy = abs(by - ay)
                XCTAssertTrue(dx < 0.001 || dy < 0.001 || abs(dx - dy) < 0.001, "segment is horizontal, vertical or 45°")
            }
        }
    }

    // MARK: Header

    func testCompactWidthBannerIsReduced() {
        let phone = TerminalHeroLayout.size(availableWidth: 393, horizontalMargin: 20, compactWidth: true)
        XCTAssertEqual(phone.width, TerminalHeroLayout.compactWidthMaxWidth)
        XCTAssertLessThan(phone.height, 90, "navigation and actions stay prominent")
        XCTAssertEqual(TerminalHeroLayout.size(availableWidth: 1024, horizontalMargin: 20).width, 560, "iPad unchanged")
    }
}

final class SessionHeaderSummaryTests: XCTestCase {
    func testLineStatesRealStateAndPlace() {
        XCTAssertEqual(SessionHeaderSummary.line(state: .ready, target: .local(.vanilla)), "Ready · This device · app sandbox")
        XCTAssertEqual(SessionHeaderSummary.tone(.ready), .live)
        XCTAssertEqual(SessionHeaderSummary.tone(.connecting), .pending)
        XCTAssertEqual(SessionHeaderSummary.tone(.exited(status: 0)), .ended)
        XCTAssertEqual(SessionHeaderSummary.tone(.failed(message: "x")), .ended)
    }

    func testUnavailableUnleashedStaysHonestlyLabelled() {
        XCTAssertEqual(SessionHeaderSummary.modeNote(preferred: .unleashed, available: false, target: .local(.vanilla)), "Unleashed not available here")
        XCTAssertEqual(SessionHeaderSummary.modeNote(preferred: .unleashed, available: nil, target: .local(.vanilla)), "Checking capabilities…")
        XCTAssertEqual(SessionHeaderSummary.modeNote(preferred: .unleashed, available: true, target: .local(.vanilla)), "New local sessions: Unleashed")
        XCTAssertNil(SessionHeaderSummary.modeNote(preferred: .vanilla, available: true, target: .local(.vanilla)))
    }

    func testAccessibilityTextIsComplete() {
        let text = SessionHeaderSummary.accessibilityText(state: .ready, target: .local(.unleashed), note: "Unleashed not available here")
        XCTAssertEqual(text, "Status: Ready. Local Unleashed. This device · permitted local environment. Unleashed not available here")
    }
}
