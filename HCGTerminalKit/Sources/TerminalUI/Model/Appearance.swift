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

    /// Overall look. Event Horizon adds the background system and edge-lit panels; Classic is
    /// the previous flat obsidian look. Both use the same tokens and never change what the app may do.
    public enum Style: String, Codable, CaseIterable, Sendable, Identifiable {
        case eventHorizon, classic
        public var id: String { rawValue }
        public var label: String { self == .eventHorizon ? "Event Horizon" : "Classic" }
    }

    /// How much decorative geometry the Event Horizon background draws.
    public enum BackgroundDetail: String, Codable, CaseIterable, Sendable, Identifiable {
        case off, subtle, enhanced
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    public var theme: Theme = .dark
    public var accent: Accent = .cyan
    public var style: Style = .eventHorizon
    public var backgroundDetail: BackgroundDetail = .subtle
    /// A very slow breathing of the background edge glow. Off by default; never runs during
    /// terminal use, in the background, in Low Power Mode or with Reduce Motion.
    public var ambientMotion: Bool = false
    /// No glows, gradients or translucency, and no decorative animation (in addition to the
    /// system's Reduce Motion / Reduce Transparency, which are always honored).
    public var reducedEffects: Bool = false
    /// Terminal text size in points (Dynamic Type does not apply inside the terminal grid).
    public var terminalFontSize: Double = 13
    /// Play the bundled header animation on the home screen (only offered when one is bundled).
    public var animatedHeader: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case theme, accent, reducedEffects, terminalFontSize, animatedHeader, style, backgroundDetail, ambientMotion }

    /// Tolerant decoding: settings saved by an older version (without newer keys) keep their
    /// values and get defaults for the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? container.decodeIfPresent(Theme.self, forKey: .theme)) ?? .dark
        accent = (try? container.decodeIfPresent(Accent.self, forKey: .accent)) ?? .cyan
        reducedEffects = (try? container.decodeIfPresent(Bool.self, forKey: .reducedEffects)) ?? false
        terminalFontSize = (try? container.decodeIfPresent(Double.self, forKey: .terminalFontSize)) ?? 13
        animatedHeader = (try? container.decodeIfPresent(Bool.self, forKey: .animatedHeader)) ?? true
        style = (try? container.decodeIfPresent(Style.self, forKey: .style)) ?? .eventHorizon
        backgroundDetail = (try? container.decodeIfPresent(BackgroundDetail.self, forKey: .backgroundDetail)) ?? .subtle
        ambientMotion = (try? container.decodeIfPresent(Bool.self, forKey: .ambientMotion)) ?? false
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

/// What the Event Horizon background draws in the current conditions. Pure, so it can be tested
/// without a screen; the view only renders what this returns.
public enum BackdropPolicy {
    public struct Conditions: Equatable, Sendable {
        public var style: AppearanceSettings.Style
        public var detail: AppearanceSettings.BackgroundDetail
        public var reducedEffects: Bool
        public var reduceTransparency: Bool
        public var increasedContrast: Bool
        public var darkAppearance: Bool

        public init(style: AppearanceSettings.Style, detail: AppearanceSettings.BackgroundDetail, reducedEffects: Bool = false, reduceTransparency: Bool = false, increasedContrast: Bool = false, darkAppearance: Bool = true) {
            self.style = style
            self.detail = detail
            self.reducedEffects = reducedEffects
            self.reduceTransparency = reduceTransparency
            self.increasedContrast = increasedContrast
            self.darkAppearance = darkAppearance
        }
    }

    public struct Layers: Equatable, Sendable {
        /// Navy/cyan glow near the outer edges.
        public var edgeGlow: Bool
        /// Circuit traces and perimeter details.
        public var geometry: AppearanceSettings.BackgroundDetail
        /// Opacity of the traces (0 when none are drawn).
        public var traceOpacity: Double
        /// Opaque, flat surfaces with plain borders: no glow, gradient or translucency.
        public var opaqueFallback: Bool

        public static let plain = Layers(edgeGlow: false, geometry: .off, traceOpacity: 0, opaqueFallback: true)
    }

    public static func layers(_ c: Conditions) -> Layers {
        // Classic, the user's "Reduce visual effects", the system's Reduce Transparency and
        // Increase Contrast all give the opaque high-contrast fallback.
        if c.style == .classic || c.reducedEffects || c.reduceTransparency || c.increasedContrast || !c.darkAppearance {
            return .plain
        }
        let opacity: Double = switch c.detail {
        case .off: 0
        case .subtle: 0.03
        case .enhanced: 0.045
        }
        return Layers(edgeGlow: true, geometry: c.detail, traceOpacity: opacity, opaqueFallback: false)
    }
}

/// Whether the optional ambient motion (a slow edge-glow breathing) may run. Every condition
/// must hold.
public enum AmbientMotionPolicy {
    public struct Conditions: Equatable, Sendable {
        public var preferenceOn: Bool
        public var backdropDrawsGlow: Bool
        public var reduceMotion: Bool
        public var lowPowerMode: Bool
        public var appActive: Bool
        public var terminalInUse: Bool

        public init(preferenceOn: Bool, backdropDrawsGlow: Bool, reduceMotion: Bool, lowPowerMode: Bool, appActive: Bool, terminalInUse: Bool) {
            self.preferenceOn = preferenceOn
            self.backdropDrawsGlow = backdropDrawsGlow
            self.reduceMotion = reduceMotion
            self.lowPowerMode = lowPowerMode
            self.appActive = appActive
            self.terminalInUse = terminalInUse
        }
    }

    /// Seconds per breath: slow enough to read as stillness, never a flash.
    public static let period: Double = 12
    /// Largest change in glow strength (fraction of the base glow).
    public static let amplitude: Double = 0.18

    public static func shouldAnimate(_ c: Conditions) -> Bool {
        c.preferenceOn && c.backdropDrawsGlow && !c.reduceMotion && !c.lowPowerMode && c.appActive && !c.terminalInUse
    }

    /// Glow multiplier at time `t` (seconds); 1 when not animating.
    public static func glowScale(at t: Double) -> Double {
        1 - amplitude / 2 + (amplitude / 2) * cos(2 * Double.pi * t / period)
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
    /// iPhone portrait home list (compact width): a reduced banner, so the mode selector, New
    /// Session and navigation stay prominent.
    public static let compactWidthMaxWidth: Double = 250

    public static func maxWidth(compactHeight: Bool, compactWidth: Bool = false) -> Double {
        if compactHeight { return compactHeightMaxWidth }
        return compactWidth ? compactWidthMaxWidth : maxWidth
    }

    public static func size(availableWidth: Double, horizontalMargin: Double, compactHeight: Bool = false, compactWidth: Bool = false) -> (width: Double, height: Double) {
        let width = max(0, min(availableWidth - 2 * horizontalMargin, maxWidth(compactHeight: compactHeight, compactWidth: compactWidth)))
        return (width, width / aspectRatio)
    }
}
