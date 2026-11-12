#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCore

/// The animated [ Vanilla | Unleashed ] selector.
///
/// Interaction pattern follows HCG ONE's `ExperienceSwitcher` (Website | App): a capsule track
/// on `surface2` with a 1-pt `line` stroke and 2-pt inset, icon + label segments, `.snappy`
/// animation. HCG Terminal adds a sliding thumb (`matchedGeometryEffect`) filled with the mode
/// accent, selection haptics, and an availability dot for modes that are unavailable.
///
/// Selecting a mode only changes the preferred local mode. It never interrupts SSH sessions:
/// the selector has no access to sessions at all. A mode that cannot run shows a lock; the
/// model explains it instead of switching, so the accent never suggests an absent backend.
public struct ModeSelector: View {
    let selection: ExecutionMode
    /// `true` available, `false` unavailable, `nil` still detecting.
    let availability: (ExecutionMode) -> Bool?
    var compact: Bool
    let onSelect: (ExecutionMode) -> Void

    @Namespace private var thumbNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hcgAppearance) private var appearance

    public init(selection: ExecutionMode, compact: Bool = false, availability: @escaping (ExecutionMode) -> Bool?, onSelect: @escaping (ExecutionMode) -> Void) {
        self.selection = selection
        self.compact = compact
        self.availability = availability
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(ExecutionMode.allCases) { mode in
                segment(mode)
            }
        }
        .padding(2)
        .background(HCGPalette.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(HCGPalette.line, lineWidth: 1))
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local execution mode")
    }

    private func segment(_ mode: ExecutionMode) -> some View {
        let selected = selection == mode
        let available = availability(mode)
        return Button {
            withAnimation(reduceMotion || appearance.reducedEffects ? nil : .snappy(duration: 0.28, extraBounce: 0.04)) {
                onSelect(mode)
            }
        } label: {
            HStack(spacing: 5) {
                if !compact {
                    Image(systemName: mode.symbolName)
                        .font(.caption.weight(.semibold))
                }
                Text(mode.displayName)
                    .font((compact ? Font.footnote : Font.subheadline).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                if available == false {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(HCGPalette.muted)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? Color.black.opacity(0.85) : HCGPalette.ivory.opacity(0.8))
            .padding(.horizontal, compact ? 12 : 14)
            .frame(minHeight: 44)
            .background {
                if selected {
                    Capsule()
                        .fill(ModeAccent.gradient(mode, accent: appearance.accent))
                        .shadow(color: appearance.reducedEffects ? .clear : ModeAccent.color(mode, accent: appearance.accent).opacity(0.3), radius: 6, y: 1)
                        .matchedGeometryEffect(id: "mode-thumb", in: thumbNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(mode.displayName) mode")
        .accessibilityHint(available == false ? "Not available here. Tapping explains what is missing; the current mode stays." : mode.summary)
    }
}

/// One line explaining the active mode's capability state, shown under the selector.
struct ModeStatusLine: View {
    let mode: ExecutionMode
    let available: Bool?
    @Environment(\.hcgAppearance) private var appearance

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(available == true ? ModeAccent.color(mode, accent: appearance.accent) : available == false ? HCGPalette.warn : HCGPalette.muted)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.footnote)
                .foregroundStyle(HCGPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch (mode, available) {
        case (_, nil): "Checking capabilities…"
        case (.vanilla, _): "Vanilla: HCG built-in commands on the app workspace (not a system shell). Remote development available."
        case (.unleashed, true?): "Unleashed: local capabilities available as reported. Nothing is elevated automatically."
        case (.unleashed, false?): "Unleashed is not available here (see Capabilities & Access). Vanilla and remote development remain available."
        }
    }
}
#endif
