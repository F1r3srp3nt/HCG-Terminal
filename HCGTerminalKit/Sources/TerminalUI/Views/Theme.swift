#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore
import UIKit

extension Color {
    init(hcgHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// A token with dark and light values, plus optional values for Increase Contrast. Resolved
    /// by the system from the trait collection, so it follows the theme and accessibility
    /// settings without any view code.
    init(hcgDark dark: UInt32, light: UInt32, darkHighContrast: UInt32? = nil, lightHighContrast: UInt32? = nil) {
        self.init(uiColor: UIColor(hcgDark: dark, light: light, darkHighContrast: darkHighContrast, lightHighContrast: lightHighContrast))
    }
}

extension UIColor {
    convenience init(hcgHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    convenience init(hcgDark dark: UInt32, light: UInt32, darkHighContrast: UInt32? = nil, lightHighContrast: UInt32? = nil) {
        self.init(dynamicProvider: { traits in
            let high = traits.accessibilityContrast == .high
            let hex = traits.userInterfaceStyle == .light
                ? (high ? lightHighContrast ?? light : light)
                : (high ? darkHighContrast ?? dark : dark)
            return UIColor(hcgHex: hex)
        })
    }
}

/// HCG Event Horizon design tokens. Every colour in the interface comes from here; views never
/// use raw hex values. Semantic names first; the older names below are aliases kept so both
/// styles (Event Horizon and Classic) share one set of tokens.
///
/// Each token has a light value (System theme) and, where it matters, an Increase Contrast
/// value. Text tokens keep at least 4.5:1 contrast on every surface; secondary text is
/// brightened and borders strengthened under Increase Contrast.
public enum HCGPalette {
    // MARK: Semantic tokens
    /// Nearly black base behind everything.
    public static let background = Color(hcgDark: 0x05090E, light: 0xF2F5F7, darkHighContrast: 0x000000, lightHighContrast: 0xFFFFFF)
    /// Deep surface: panels, list rows.
    public static let surfaceDeep = Color(hcgDark: 0x0B141E, light: 0xFFFFFF, darkHighContrast: 0x0B141E)
    /// Elevated surface: controls, keys, selected tracks.
    public static let surfaceElevated = Color(hcgDark: 0x111F2B, light: 0xE9EEF2, darkHighContrast: 0x16293A, lightHighContrast: 0xDCE3E9)
    /// Fine borders.
    public static let border = Color(hcgDark: 0x1D2D3B, light: 0xCDD6DD, darkHighContrast: 0x5C7385, lightHighContrast: 0x6B7A86)
    /// Electric cyan: primary accent and edge lighting.
    public static let accentPrimary = Color(hcgDark: 0x27D7EA, light: 0x007E8F, darkHighContrast: 0x6BEAF7, lightHighContrast: 0x005F6B)
    /// Secondary accent (links, secondary highlights).
    public static let accentSecondary = Color(hcgDark: 0x7CA8FF, light: 0x1F5FBF, darkHighContrast: 0xA9C6FF, lightHighContrast: 0x174A96)
    public static let textPrimary = Color(hcgDark: 0xEDF5F8, light: 0x0B141B, darkHighContrast: 0xFFFFFF, lightHighContrast: 0x000000)
    public static let textSecondary = Color(hcgDark: 0xA4B5C1, light: 0x52606B, darkHighContrast: 0xD3DEE6, lightHighContrast: 0x2E3A44)
    /// Deep navy used by the background's edge glow.
    public static let glowNavy = Color(hcgDark: 0x0B2B42, light: 0xDCE8F0)
    /// The terminal surface. Always dark (ANSI colours are designed for a dark background) and
    /// fully opaque; nothing decorative is drawn on it.
    public static let terminalSurface = Color(hcgHex: 0x04080C)
    public static let terminalSurfaceUI = UIColor(hcgHex: 0x04080C)
    public static let terminalTextUI = UIColor(hcgHex: 0xEDF5F8)
    /// The header artwork's outer edge colour (so no rectangle shows around it).
    public static let heroEdge = Color(hcgHex: 0x010305)

    // MARK: Signals
    public static let ok = Color(hcgDark: 0x4CC38A, light: 0x1E7A4C, darkHighContrast: 0x7EE0B0)
    public static let warn = Color(hcgDark: 0xE0B064, light: 0x8A5A00, darkHighContrast: 0xF5CD8A)
    public static let loss = Color(hcgDark: 0xE5736F, light: 0xB3261E, darkHighContrast: 0xFF9C98)
    // MARK: Modes
    public static let unleashedViolet = Color(hcgDark: 0xA996FF, light: 0x5B43C9, darkHighContrast: 0xC7BAFF)
    public static let unleashedVioletDeep = Color(hcgDark: 0x6E59D9, light: 0x4A35B0)

    // MARK: Aliases (older names; same tokens)
    public static let canvas = background
    public static let midnight = surfaceDeep
    public static let surface = surfaceDeep
    public static let surface2 = surfaceElevated
    public static let line = border
    public static let ivory = textPrimary
    public static let muted = textSecondary
    public static let silver = Color(hcgDark: 0xC5D2DB, light: 0x3D4A55, darkHighContrast: 0xE6EEF3)
    public static let cyan = accentPrimary
    public static let metalHighlight = Color(hcgDark: 0xD8E0E6, light: 0x8A98A4)
    public static let metalShadow = Color(hcgDark: 0x3A4752, light: 0xB7C2CB)
    /// Kept for older call sites: Vanilla is cyan, "available" is the info color.
    public static let vanillaBlue = accentPrimary
    public static let vanillaGreen = ok

    public static func accent(_ accent: AppearanceSettings.Accent) -> Color {
        switch accent {
        case .cyan: accentPrimary
        case .silver: Color(hcgDark: 0xC9D3DC, light: 0x44525E)
        case .blue: accentSecondary
        case .green: Color(hcgDark: 0x5ED39A, light: 0x1E7A4C)
        }
    }
}

// MARK: - Appearance environment

private struct HCGAppearanceKey: EnvironmentKey {
    static let defaultValue = AppearanceSettings()
}

extension EnvironmentValues {
    /// The user's appearance settings (theme, accent, reduced effects).
    var hcgAppearance: AppearanceSettings {
        get { self[HCGAppearanceKey.self] }
        set { self[HCGAppearanceKey.self] = newValue }
    }
}

/// Whether decorative effects should be drawn: off when the user chose reduced effects or the
/// system asks for less motion or transparency.
struct EffectsPolicy {
    let appearance: AppearanceSettings
    let reduceMotion: Bool
    let reduceTransparency: Bool
    var increasedContrast: Bool = false

    var decorative: Bool { !appearance.reducedEffects && !reduceTransparency && !increasedContrast }
    var animated: Bool { !appearance.reducedEffects && !reduceMotion }
    var animation: Animation? { animated ? .smooth(duration: 0.25) : nil }
}

extension View {
    /// Applies `animation` only when motion is allowed.
    func hcgAnimation<V: Equatable>(_ effects: EffectsPolicy, value: V) -> some View {
        animation(effects.animation, value: value)
    }
}

/// Reads the effects policy from the environment.
struct WithEffects<Content: View>: View {
    @Environment(\.hcgAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let content: (EffectsPolicy) -> Content

    var body: some View {
        content(EffectsPolicy(appearance: appearance, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased))
    }
}

// MARK: - Mode accents

/// Accent colors per execution target. Vanilla follows the chosen accent; Unleashed is always
/// violet, and every place that shows a mode also names it in text.
public enum ModeAccent {
    public static func gradient(_ mode: ExecutionMode, accent: AppearanceSettings.Accent = .cyan) -> LinearGradient {
        switch mode {
        case .vanilla:
            LinearGradient(colors: [HCGPalette.accent(accent), HCGPalette.accent(accent).opacity(0.7)], startPoint: .leading, endPoint: .trailing)
        case .unleashed:
            LinearGradient(colors: [HCGPalette.unleashedViolet, HCGPalette.unleashedVioletDeep], startPoint: .leading, endPoint: .trailing)
        }
    }

    public static func color(_ mode: ExecutionMode, accent: AppearanceSettings.Accent = .cyan) -> Color {
        mode == .vanilla ? HCGPalette.accent(accent) : HCGPalette.unleashedViolet
    }

    public static func color(_ target: ExecutionTarget) -> Color {
        switch target {
        case .local(let mode): color(mode)
        case .remote: HCGPalette.silver
        }
    }

    public static func symbol(_ target: ExecutionTarget) -> String {
        switch target {
        case .local(.vanilla): "iphone"
        case .local(.unleashed): "iphone.gen3.radiowaves.left.and.right"
        case .remote: "desktopcomputer"
        }
    }
}

// MARK: - Components

/// Small uppercase label. Uses a text style so it scales with Dynamic Type.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(HCGPalette.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A panel. Event Horizon: an opaque deep surface with chamfered corners, a fine border and a
/// short cyan edge light along the top. Classic: the previous brushed-metal rounded panel.
/// The opaque fallback (Reduce visual effects, Reduce Transparency, Increase Contrast) is a
/// flat fill with a plain, stronger border and no glow.
struct HCGPanel: ViewModifier {
    var tint: Color? = nil
    var cornerRadius: CGFloat = 14
    @Environment(\.hcgAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let decorative = !appearance.reducedEffects && !reduceTransparency && contrast != .increased
        if appearance.style == .eventHorizon {
            let shape = ChamferedRectangle(cut: min(cornerRadius, 12))
            content
                .background { shape.fill(HCGPalette.surfaceDeep) }
                .overlay {
                    shape.strokeBorder(contrast == .increased ? HCGPalette.border : (tint ?? HCGPalette.border).opacity(tint == nil ? 1 : 0.6), lineWidth: 1)
                }
                .overlay {
                    if decorative {
                        EdgeLight(cut: min(cornerRadius, 12), color: tint ?? HCGPalette.accentPrimary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background {
                    if decorative {
                        shape.fill(LinearGradient(colors: [HCGPalette.surface2, HCGPalette.surface], startPoint: .top, endPoint: .bottom))
                    } else {
                        shape.fill(HCGPalette.surface)
                    }
                }
                .overlay {
                    if decorative {
                        shape.strokeBorder(
                            LinearGradient(colors: [HCGPalette.metalHighlight.opacity(0.55), HCGPalette.metalShadow.opacity(0.35), (tint ?? HCGPalette.line).opacity(0.5)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                    } else {
                        shape.strokeBorder(HCGPalette.line, lineWidth: 1)
                    }
                }
                .shadow(color: decorative ? (tint ?? .clear).opacity(0.18) : .clear, radius: decorative ? 10 : 0)
        }
    }
}

extension View {
    func hcgPanel(tint: Color? = nil, cornerRadius: CGFloat = 14) -> some View {
        modifier(HCGPanel(tint: tint, cornerRadius: cornerRadius))
    }

    /// The HCG background for lists and screens: the Event Horizon backdrop (or the plain
    /// canvas), covering the safe areas, behind the content.
    func hcgScreenBackground() -> some View {
        scrollContentBackground(.hidden).background { HCGBackdrop() }
    }

    /// Themed list rows: deep surface fill and fine separators. Apply to a list's content.
    func hcgRows() -> some View {
        listRowBackground(HCGRowBackground()).listRowSeparatorTint(HCGPalette.border)
    }
}

/// Pill showing where a session executes: Local Vanilla, Local Unleashed or Remote Host.
struct TargetBadge: View {
    let target: ExecutionTarget
    /// Mode name only ("Vanilla", "Unleashed", "Remote"); the full label stays in VoiceOver.
    var compact = false

    private var shortLabel: String {
        switch target {
        case .local(let mode): mode.displayName
        case .remote: "Remote"
        }
    }

    var body: some View {
        Label(compact ? shortLabel : target.label, systemImage: ModeAccent.symbol(target))
            .font(.caption.weight(.semibold))
            .foregroundStyle(ModeAccent.color(target))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ModeAccent.color(target).opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(ModeAccent.color(target).opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Execution target: \(target.label), \(target.detail)")
    }
}

/// Status chip for a capability availability. Color is never the only signal: the chip always
/// has an icon and a text label.
struct StatusChip: View {
    let availability: CapabilityAvailability

    var body: some View {
        Label(availability.label, systemImage: availability.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Self.color(availability))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Self.color(availability).opacity(0.14), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(availability.label)")
    }

    static func color(_ availability: CapabilityAvailability) -> Color {
        switch availability {
        case .verified: HCGPalette.ok
        case .availableUntested: HCGPalette.cyan
        case .permissionDenied, .toolMissing: HCGPalette.warn
        case .notIncluded, .environmentUnknown, .disabledByUser: HCGPalette.muted
        }
    }
}

/// The HCG mark from the app icon.
struct HCGMark: View {
    var size: CGFloat = 44
    var body: some View {
        Image("HCGMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}
#endif
