import Foundation

/// Look-and-feel settings. Only presentation; nothing here affects what the app may do.
public struct AppearanceSettings: Codable, Hashable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Follows the system light/dark setting.
        case system
        /// Always the dark HCG obsidian theme.
        case dark
        public var id: String { rawValue }
        public var label: String { self == .system ? "System" : "Dark" }
    }

    /// Accent for Vanilla and shared interface elements. Unleashed always keeps its violet so
    /// the two modes are never confused.
    public enum Accent: String, Codable, CaseIterable, Sendable, Identifiable {
        case cyan, silver, blue, green
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    public var theme: Theme = .dark
    public var accent: Accent = .cyan
    /// No glows, gradients or translucency, and no decorative animation (in addition to the
    /// system's Reduce Motion / Reduce Transparency, which are always honored).
    public var reducedEffects: Bool = false
    /// Terminal text size in points (Dynamic Type does not apply inside the terminal grid).
    public var terminalFontSize: Double = 13
    /// Play the bundled header animation on the home screen (only offered when one is bundled).
    public var animatedHeader: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case theme, accent, reducedEffects, terminalFontSize, animatedHeader }

    /// Tolerant decoding: settings saved by an older version (without newer keys) keep their
    /// values and get defaults for the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? container.decodeIfPresent(Theme.self, forKey: .theme)) ?? .dark
        accent = (try? container.decodeIfPresent(Accent.self, forKey: .accent)) ?? .cyan
        reducedEffects = (try? container.decodeIfPresent(Bool.self, forKey: .reducedEffects)) ?? false
        terminalFontSize = (try? container.decodeIfPresent(Double.self, forKey: .terminalFontSize)) ?? 13
        animatedHeader = (try? container.decodeIfPresent(Bool.self, forKey: .animatedHeader)) ?? true
    }

    public static let terminalFontRange: ClosedRange<Double> = 9...24
}

/// Persists appearance settings in `UserDefaults`.
public final class AppearanceStore: @unchecked Sendable {
    public static let key = "hcg.terminal.appearance.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var settings: AppearanceSettings {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(AppearanceSettings.self, from: data) else { return AppearanceSettings() }
            return decoded
        }
        set {
            var value = newValue
            value.terminalFontSize = min(max(value.terminalFontSize, AppearanceSettings.terminalFontRange.lowerBound), AppearanceSettings.terminalFontRange.upperBound)
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
        }
    }
}

/// Whether the home-screen header may play its bundled animation right now. Every condition
/// must hold; otherwise the static artwork is shown.
public enum HeroPlaybackPolicy {
    public struct Conditions: Equatable, Sendable {
        public var animationBundled: Bool
        public var preferenceOn: Bool
        public var reduceMotion: Bool
        public var reducedEffects: Bool
        public var lowPowerMode: Bool
        public var appActive: Bool
        public var visible: Bool

        public init(animationBundled: Bool, preferenceOn: Bool, reduceMotion: Bool, reducedEffects: Bool, lowPowerMode: Bool, appActive: Bool, visible: Bool) {
            self.animationBundled = animationBundled
            self.preferenceOn = preferenceOn
            self.reduceMotion = reduceMotion
            self.reducedEffects = reducedEffects
            self.lowPowerMode = lowPowerMode
            self.appActive = appActive
            self.visible = visible
        }
    }

    public static func shouldAnimate(_ c: Conditions) -> Bool {
        c.animationBundled && c.preferenceOn && !c.reduceMotion && !c.reducedEffects && !c.lowPowerMode && c.appActive && c.visible
    }
}

/// Size of the 3:1 header artwork: as wide as the content area allows, never wider than
/// `maxWidth`, never stretched or cropped.
public enum TerminalHeroLayout {
    public static let aspectRatio: Double = 2000.0 / 667.0
    /// iPad and other wide layouts.
    public static let maxWidth: Double = 560
    /// Landscape iPhone (compact height): keeps the controls below it on screen.
    public static let compactHeightMaxWidth: Double = 330

    public static func maxWidth(compactHeight: Bool) -> Double { compactHeight ? compactHeightMaxWidth : maxWidth }

    public static func size(availableWidth: Double, horizontalMargin: Double, compactHeight: Bool = false) -> (width: Double, height: Double) {
        let width = max(0, min(availableWidth - 2 * horizontalMargin, maxWidth(compactHeight: compactHeight)))
        return (width, width / aspectRatio)
    }
}
