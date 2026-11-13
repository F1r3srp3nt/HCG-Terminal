#if canImport(UIKit) && canImport(SwiftUI)
import Combine
import SwiftUI
import TerminalCore

// MARK: - Shapes

/// The HCG panel shape: a rectangle with its top-trailing and bottom-leading corners cut at 45°.
struct ChamferedRectangle: InsettableShape {
    var cut: CGFloat = 12
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = max(0, min(cut - insetAmount / 2, min(r.width, r.height) / 2))
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> ChamferedRectangle {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// A short highlight hugging a panel's top-trailing chamfer, plus a faint line along the top
/// edge that fades out towards the trailing side: the "edge lighting".
struct EdgeLight: View {
    var cut: CGFloat
    var color: Color

    var body: some View {
        ZStack {
            ChamferGlint(cut: cut)
                .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            TopEdgeLine(cut: cut)
                .stroke(
                    LinearGradient(colors: [color.opacity(0.35), color.opacity(0.05), .clear], startPoint: .leading, endPoint: .trailing),
                    lineWidth: 1
                )
        }
    }
}

private struct ChamferGlint: Shape {
    var cut: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let c = max(0, min(cut, min(r.width, r.height) / 2))
        var path = Path()
        path.move(to: CGPoint(x: max(r.minX, r.maxX - c - 28), y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        path.addLine(to: CGPoint(x: r.maxX, y: min(r.maxY, r.minY + c + 10)))
        return path
    }
}

private struct TopEdgeLine: Shape {
    var cut: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY + min(14, r.height / 2)))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - cut - 28, y: r.minY))
        return path
    }
}

/// Short accent strokes on two opposite corners of a frame, on the border only (never over the
/// content inside it).
struct CornerAccents: Shape {
    var cut: CGFloat
    var length: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        // Top-leading corner.
        path.move(to: CGPoint(x: r.minX, y: r.minY + length))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX + length, y: r.minY))
        // Bottom-trailing corner.
        path.move(to: CGPoint(x: r.maxX, y: r.maxY - length))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - length, y: r.maxY))
        return path
    }
}

/// The cached Event Horizon geometry, scaled to the view. Building the path only maps cached
/// points; nothing is generated here.
private struct CircuitShape: Shape {
    let paths: [EventHorizonGeometry.Path]

    func path(in rect: CGRect) -> Path {
        var result = Path()
        for item in paths {
            guard let first = item.points.first else { continue }
            let start = first.resolved(width: rect.width, height: rect.height)
            result.move(to: CGPoint(x: rect.minX + start.x, y: rect.minY + start.y))
            for point in item.points.dropFirst() {
                let p = point.resolved(width: rect.width, height: rect.height)
                result.addLine(to: CGPoint(x: rect.minX + p.x, y: rect.minY + p.y))
            }
        }
        return result
    }
}

/// Small vias at the inner end of each trace.
private struct NodeShape: Shape {
    let paths: [EventHorizonGeometry.Path]

    func path(in rect: CGRect) -> Path {
        var result = Path()
        for item in paths where item.endsInNode {
            guard let last = item.points.last else { continue }
            let p = last.resolved(width: rect.width, height: rect.height)
            result.addEllipse(in: CGRect(x: rect.minX + p.x - 2, y: rect.minY + p.y - 2, width: 4, height: 4))
        }
        return result
    }
}

// MARK: - Background system

/// The Event Horizon background: a nearly black base, a faint navy/cyan glow near the outer
/// edges, and sparse circuit traces and fine geometry around the perimeter. The centre stays
/// quiet. It covers the safe areas, never takes touches and is hidden from accessibility.
///
/// What it draws is decided by `BackdropPolicy` (style, detail, Reduce visual effects, Reduce
/// Transparency, Increase Contrast, light appearance → a plain opaque base). The geometry is
/// cached (`EventHorizonGeometry.cached`) and this view reads no session state, so terminal
/// output never redraws it. The optional ambient motion is a slow glow breathing that runs only
/// when `AmbientMotionPolicy` allows (never during terminal use, in the background, in Low
/// Power Mode or with Reduce Motion).
struct HCGBackdrop: View {
    /// True behind the active terminal: ambient motion is never run there.
    var terminalInUse = false

    @Environment(\.hcgAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var layers: BackdropPolicy.Layers {
        BackdropPolicy.layers(.init(
            style: appearance.style,
            detail: appearance.backgroundDetail,
            reducedEffects: appearance.reducedEffects,
            reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased,
            darkAppearance: colorScheme == .dark
        ))
    }

    private var animate: Bool {
        AmbientMotionPolicy.shouldAnimate(.init(
            preferenceOn: appearance.ambientMotion,
            backdropDrawsGlow: layers.edgeGlow,
            reduceMotion: reduceMotion,
            lowPowerMode: lowPower,
            appActive: scenePhase == .active,
            terminalInUse: terminalInUse
        ))
    }

    var body: some View {
        let layers = self.layers
        ZStack {
            HCGPalette.background
            if layers.edgeGlow {
                if animate {
                    // 15 updates a second at most, only while every condition holds.
                    TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
                        EdgeGlow(strength: AmbientMotionPolicy.glowScale(at: context.date.timeIntervalSinceReferenceDate))
                    }
                } else {
                    EdgeGlow(strength: 1)
                }
            }
            if layers.geometry != .off {
                CircuitLayer(detail: layers.geometry, opacity: layers.traceOpacity)
                    .equatable()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: DispatchQueue.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// Navy and cyan light pooled in the corners; the middle of the screen is untouched.
private struct EdgeGlow: View {
    var strength: Double

    var body: some View {
        ZStack {
            RadialGradient(colors: [HCGPalette.glowNavy.opacity(0.85 * strength), .clear], center: .topLeading, startRadius: 0, endRadius: 380)
            RadialGradient(colors: [HCGPalette.accentPrimary.opacity(0.06 * strength), .clear], center: .topTrailing, startRadius: 0, endRadius: 240)
            RadialGradient(colors: [HCGPalette.glowNavy.opacity(0.7 * strength), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 360)
            RadialGradient(colors: [HCGPalette.accentPrimary.opacity(0.045 * strength), .clear], center: .bottomLeading, startRadius: 0, endRadius: 200)
        }
    }
}

/// Circuit traces at the policy's opacity (about 3 %), and the corner fragments slightly
/// stronger so the perimeter reads as architecture rather than noise.
private struct CircuitLayer: View, Equatable {
    let detail: AppearanceSettings.BackgroundDetail
    let opacity: Double

    var body: some View {
        let geometry = EventHorizonGeometry.cached(detail)
        ZStack {
            CircuitShape(paths: geometry.traces)
                .stroke(HCGPalette.accentPrimary.opacity(opacity), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            NodeShape(paths: geometry.traces)
                .stroke(HCGPalette.accentPrimary.opacity(opacity * 1.6), lineWidth: 1)
            CircuitShape(paths: geometry.fragments + geometry.ticks)
                .stroke(HCGPalette.accentPrimary.opacity(min(0.09, opacity * 2.2)), style: StrokeStyle(lineWidth: 1, lineCap: .square, lineJoin: .miter))
        }
    }
}

/// List row fill: the deep surface in Event Horizon, the system grouped fill in Classic.
struct HCGRowBackground: View {
    @Environment(\.hcgAppearance) private var appearance

    var body: some View {
        if appearance.style == .eventHorizon {
            HCGPalette.surfaceDeep
        } else {
            Color(uiColor: .secondarySystemGroupedBackground)
        }
    }
}

// MARK: - Terminal frame

/// The frame around the terminal. The terminal surface is fully opaque, and nothing is drawn
/// over the text area: the border and corner accents sit outside the inset content.
///
/// Event Horizon: chamfered border with two short accent corners (not with Background detail
/// Off or the opaque fallback). The content inset is larger than the chamfer reaches, so no cell
/// is ever clipped. Classic: edge to edge, as before.
struct TerminalFrame<Content: View>: View {
    var accent: Color
    @ViewBuilder var content: Content

    @Environment(\.hcgAppearance) private var appearance
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static var cut: CGFloat { 8 }
    /// Inside the border. With a 8-pt chamfer, a 5-pt inset keeps the content's corner inside
    /// the cut (8 − 5 < 5).
    static var contentInset: CGFloat { 5 }

    var body: some View {
        if appearance.style == .classic {
            content.background(HCGPalette.terminalSurface)
        } else {
            let decorative = !appearance.reducedEffects && !reduceTransparency && contrast != .increased && appearance.backgroundDetail != .off
            let shape = ChamferedRectangle(cut: Self.cut)
            content
                .padding(Self.contentInset)
                .background { shape.fill(HCGPalette.terminalSurface) }
                .overlay {
                    shape.strokeBorder(HCGPalette.border, lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay {
                    if decorative {
                        CornerAccents(cut: Self.cut)
                            .stroke(accent.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, sizeClass == .regular ? 10 : 4)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - Documents

/// Opaque surface for document editors and previews: text sits on the deep surface, never on
/// the decorated background. Classic keeps the plain canvas.
private struct DocumentSurface: ViewModifier {
    @Environment(\.hcgAppearance) private var appearance
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if appearance.style == .eventHorizon {
            content
                .scrollContentBackground(.hidden)
                .padding(6)
                .background { ChamferedRectangle(cut: 10).fill(HCGPalette.surfaceDeep) }
                .overlay {
                    ChamferedRectangle(cut: 10).strokeBorder(HCGPalette.border, lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .padding(sizeClass == .regular ? 12 : 6)
        } else {
            content
                .scrollContentBackground(.hidden)
                .background(HCGPalette.canvas)
        }
    }
}

extension View {
    func hcgDocumentSurface() -> some View { modifier(DocumentSurface()) }
}

// MARK: - Empty states

/// The HCG emblem for empty states: a symbol (or the terminal prompt `>_`) in a chamfered
/// frame, with one faint outline behind it.
struct HCGEmblem: View {
    /// `nil` draws the terminal prompt.
    var systemImage: String?
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 64

    var body: some View {
        ZStack {
            ChamferedRectangle(cut: size * 0.3)
                .stroke(HCGPalette.border, lineWidth: 1)
                .frame(width: size * 1.45, height: size * 1.45)
            ChamferedRectangle(cut: size * 0.2).fill(HCGPalette.surfaceDeep)
            ChamferedRectangle(cut: size * 0.2).strokeBorder(HCGPalette.accentPrimary.opacity(0.5), lineWidth: 1)
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: size * 0.38, weight: .medium))
            } else {
                Text(">_").font(.system(size: size * 0.34, weight: .semibold, design: .monospaced))
            }
        }
        .foregroundStyle(HCGPalette.accentPrimary)
        .frame(width: size, height: size)
        .padding(size * 0.25)
        .accessibilityHidden(true)
    }
}

/// Empty state: emblem, concise title and guidance, and an optional primary action. Same
/// arguments as `ContentUnavailableView(_:systemImage:description:)`.
struct HCGEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String?
    let description: Text?
    let actions: Actions

    init(_ title: String, systemImage: String?, description: Text? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            HCGEmblem(systemImage: systemImage)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(HCGPalette.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let description {
                description
                    .font(.callout)
                    .foregroundStyle(HCGPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions.padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension HCGEmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String?, description: Text? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}

// MARK: - Controls

/// Label for the prominent primary action (New Session): a solid accent fill with dark text,
/// at least 50 pt high. Chamfered in Event Horizon, rounded in Classic. Used as a `Menu` label,
/// so it styles itself rather than relying on a button style.
struct PrimaryActionLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    @Environment(\.hcgAppearance) private var appearance

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.headline)
            .foregroundStyle(Color.black.opacity(0.88))
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background {
                if appearance.style == .eventHorizon {
                    ChamferedRectangle(cut: 10).fill(color)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color)
                }
            }
            .contentShape(Rectangle())
    }
}

/// Labels with their icon in a small dark tile. Applied only in Event Horizon (`hcgTileLabels()`).
struct HCGTileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileLabel(configuration: configuration)
    }

    private struct TileLabel: View {
        let configuration: LabelStyleConfiguration
        @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 32

        var body: some View {
            HStack(spacing: 12) {
                configuration.icon
                    .font(.body.weight(.medium))
                    .foregroundStyle(HCGPalette.accentPrimary)
                    .frame(width: tile, height: tile)
                    .background(HCGPalette.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(HCGPalette.border, lineWidth: 1))
                configuration.title
                    .foregroundStyle(HCGPalette.textPrimary)
            }
        }
    }
}

private struct HCGTileLabels: ViewModifier {
    @Environment(\.hcgAppearance) private var appearance

    func body(content: Content) -> some View {
        if appearance.style == .eventHorizon {
            content.labelStyle(HCGTileLabelStyle())
        } else {
            content
        }
    }
}

extension View {
    /// Tile icons for navigation labels in Event Horizon; system labels in Classic.
    func hcgTileLabels() -> some View { modifier(HCGTileLabels()) }
}

/// 44-pt icon button for headers (stop, information, close, back).
struct HeaderIconButton: View {
    let systemImage: String
    let label: String
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(isEnabled ? HCGPalette.silver : HCGPalette.textSecondary.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}
#endif
