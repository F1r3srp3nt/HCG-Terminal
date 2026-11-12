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

    /// A color with a dark (HCG obsidian) and a light value, resolved by the system.
    init(hcgDark dark: UInt32, light: UInt32) {
        self.init(UIColor { traits in
            let hex = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}

/// HCG Terminal design tokens, taken from the app icon: obsidian and midnight surfaces,
/// brushed-metal highlights and a restrained cyan light. Unleashed uses violet. Every token has
/// a light value for the "System" theme; text tokens keep at least 4.5:1 contrast on surfaces.
public enum HCGPalette {
    // Surfaces
    public static let canvas = Color(hcgDark: 0x05080B, light: 0xF2F5F7)
    public static let midnight = Color(hcgDark: 0x0A1118, light: 0xE8EDF1)
    public static let surface = Color(hcgDark: 0x0E161E, light: 0xFFFFFF)
    public static let surface2 = Color(hcgDark: 0x15202A, light: 0xE9EEF2)
    public static let line = Color(hcgDark: 0x22313D, light: 0xCDD6DD)
    // Metal
    public static let metalHighlight = Color(hcgDark: 0xD8E0E6, light: 0x8A98A4)
    public static let metalShadow = Color(hcgDark: 0x3A4752, light: 0xB7C2CB)
    // Text
    public static let ivory = Color(hcgDark: 0xEEF3F6, light: 0x0B141B)
    public static let muted = Color(hcgDark: 0x93A1AC, light: 0x52606B)
    public static let silver = Color(hcgDark: 0xC5CDD4, light: 0x3D4A55)
    // Signals
    public static let cyan = Color(hcgDark: 0x2FD3E6, light: 0x007E8F)
    public static let ok = Color(hcgDark: 0x4CC38A, light: 0x1E7A4C)
    public static let warn = Color(hcgDark: 0xE0B064, light: 0x8A5A00)
    public static let loss = Color(hcgDark: 0xE5736F, light: 0xB3261E)
    // Modes
    public static let unleashedViolet = Color(hcgDark: 0xA996FF, light: 0x5B43C9)
    public static let unleashedVioletDeep = Color(hcgDark: 0x6E59D9, light: 0x4A35B0)

    /// Kept for older call sites: Vanilla is cyan, "available" is the info color.
    public static let vanillaBlue = cyan
    public static let vanillaGreen = ok

    public static func accent(_ accent: AppearanceSettings.Accent) -> Color {
        switch accent {
        case .cyan: cyan
        case .silver: Color(hcgDark: 0xC9D3DC, light: 0x44525E)
        case .blue: Color(hcgDark: 0x6FA8FF, light: 0x1F5FBF)
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

    var decorative: Bool { !appearance.reducedEffects && !reduceTransparency }
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
    let content: (EffectsPolicy) -> Content

    var body: some View {
        content(EffectsPolicy(appearance: appearance, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
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

/// A brushed-metal panel: midnight fill, a fine metallic top edge and, when effects are on, a
/// faint glow in the panel's tint. Flat fill and plain border with reduced effects.
struct HCGPanel: ViewModifier {
    var tint: Color? = nil
    var cornerRadius: CGFloat = 14
    @Environment(\.hcgAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let decorative = !appearance.reducedEffects && !reduceTransparency
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

extension View {
    func hcgPanel(tint: Color? = nil, cornerRadius: CGFloat = 14) -> some View {
        modifier(HCGPanel(tint: tint, cornerRadius: cornerRadius))
    }

    /// The HCG background for lists and screens.
    func hcgScreenBackground() -> some View {
        scrollContentBackground(.hidden).background(HCGPalette.canvas.ignoresSafeArea())
    }
}

/// Pill showing where a session executes: Local Vanilla, Local Unleashed or Remote Host.
struct TargetBadge: View {
    let target: ExecutionTarget

    var body: some View {
        Label(target.label, systemImage: ModeAccent.symbol(target))
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
