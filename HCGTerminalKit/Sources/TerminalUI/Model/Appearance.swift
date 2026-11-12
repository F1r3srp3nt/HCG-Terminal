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

    public init() {}

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
