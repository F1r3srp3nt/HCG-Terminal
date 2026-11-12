import Foundation
@testable import TerminalUI
import XCTest

final class TerminalHeroTests: XCTestCase {
    private func conditions(_ change: (inout HeroPlaybackPolicy.Conditions) -> Void = { _ in }) -> HeroPlaybackPolicy.Conditions {
        var c = HeroPlaybackPolicy.Conditions(animationBundled: true, preferenceOn: true, reduceMotion: false, reducedEffects: false, lowPowerMode: false, appActive: true, visible: true)
        change(&c)
        return c
    }

    func testAnimatesOnlyWhenEveryConditionHolds() {
        XCTAssertTrue(HeroPlaybackPolicy.shouldAnimate(conditions()))
        XCTAssertFalse(HeroPlaybackPolicy.shouldAnimate(conditions { $0.animationBundled = false }), "no bundled video: static image")
        XCTAssertFalse(HeroPlaybackPolicy.shouldAnimate(conditions { $0.preferenceOn = false }))
        XCTAssertFalse(HeroPlaybackPolicy.shouldAnimate(conditions { $0.reduceMotion = true }))
        XCTAssertFalse(HeroPlaybackPolicy.shouldAnimate(conditions { $0.reducedEffects = true }))
        XCTAssertFalse(HeroPlaybackPolicy.shouldAnimate(conditions { $0.lowPowerMode = true }))
        XCTAssertFalse(HeroPlaybackPolicy.shouldAnimate(conditions { $0.appActive = false }), "paused in the background")
        XCTAssertFalse(HeroPlaybackPolicy.shouldAnimate(conditions { $0.visible = false }), "paused when navigating away")
    }

    func testLayoutFitsSmallPhonesAndCapsOnIPad() {
        // iPhone SE (1st gen) width 320 pt, 16 pt margins.
        let se = TerminalHeroLayout.size(availableWidth: 320, horizontalMargin: 16)
        XCTAssertEqual(se.width, 288, accuracy: 0.01)
        XCTAssertEqual(se.height, 288 / (2000.0 / 667.0), accuracy: 0.01)
        // iPhone 16 portrait 393 pt.
        XCTAssertEqual(TerminalHeroLayout.size(availableWidth: 393, horizontalMargin: 20).width, 353, accuracy: 0.01)
        // iPad 12.9" detail column: capped and therefore centred by the view.
        XCTAssertEqual(TerminalHeroLayout.size(availableWidth: 1024, horizontalMargin: 20).width, 560)
        // Landscape iPhone: smaller cap so the controls stay visible.
        let landscape = TerminalHeroLayout.size(availableWidth: 852, horizontalMargin: 20, compactHeight: true)
        XCTAssertEqual(landscape.width, 330)
        XCTAssertLessThan(landscape.height, 111)
        // Aspect ratio never changes (no stretching).
        for width in [200.0, 320, 768, 1366] {
            let size = TerminalHeroLayout.size(availableWidth: width, horizontalMargin: 0)
            XCTAssertEqual(size.width / size.height, 2000.0 / 667.0, accuracy: 0.0001)
        }
    }

    func testAnimatedHeaderPreferencePersistsAndOlderSettingsStillLoad() throws {
        let suite = "hcg-hero-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Settings saved by the previous version (no animatedHeader key).
        defaults.set(Data(#"{"theme":"system","accent":"silver","reducedEffects":true,"terminalFontSize":15}"#.utf8), forKey: AppearanceStore.key)
        let store = AppearanceStore(defaults: defaults)
        var settings = store.settings
        XCTAssertEqual(settings.theme, .system, "older values are kept")
        XCTAssertEqual(settings.terminalFontSize, 15)
        XCTAssertTrue(settings.animatedHeader, "new key gets its default")
        settings.animatedHeader = false
        store.settings = settings
        XCTAssertFalse(AppearanceStore(defaults: defaults).settings.animatedHeader)
        XCTAssertEqual(AppearanceStore(defaults: defaults).settings.accent, .silver)
    }
}
