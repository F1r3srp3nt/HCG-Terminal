#if canImport(UIKit) && canImport(SwiftUI)
import AVFoundation
import Combine
import SwiftUI
import UIKit

/// The bundled header animation, if the app contains one (`TerminalHero.mp4` or `.mov` in the
/// app bundle). Nothing is ever loaded from the network.
enum TerminalHeroAnimation {
    static let bundledURL: URL? =
        Bundle.main.url(forResource: "TerminalHero", withExtension: "mp4")
        ?? Bundle.main.url(forResource: "TerminalHero", withExtension: "mov")

    static var isBundled: Bool { bundledURL != nil }
}

/// The "HCG Terminal" home-screen header: the supplied artwork, scaled to fit (never stretched
/// or cropped), on a background that matches the artwork's near-black edges. If an animation is
/// bundled and allowed, it plays silently on top of the static image, which stays visible until
/// the first video frame is ready and remains as the fallback if playback fails.
///
/// VoiceOver reads it once, as the heading "HCG Terminal"; the image and video layers are hidden.
struct TerminalHeroHeader: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var visible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// One controller per header for its whole lifetime; view updates never create a player.
    @State private var playback = HeroPlaybackController()

    /// Exact colour of the artwork's outer edge, so no rectangle is visible around it.
    static let edgeColor = Color(hcgHex: 0x010305)

    private var shouldAnimate: Bool {
        HeroPlaybackPolicy.shouldAnimate(.init(
            animationBundled: TerminalHeroAnimation.isBundled,
            preferenceOn: model.appearance.animatedHeader,
            reduceMotion: reduceMotion,
            reducedEffects: model.appearance.reducedEffects,
            lowPowerMode: lowPower,
            appActive: scenePhase == .active,
            visible: visible
        ))
    }

    var body: some View {
        ZStack {
            Image("TerminalHero")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
            if let url = TerminalHeroAnimation.bundledURL, model.appearance.animatedHeader {
                HeroVideoLayer(controller: playback, url: url)
                    .aspectRatio(CGFloat(TerminalHeroLayout.aspectRatio), contentMode: .fit)
                    .opacity(playback.showsVideo ? 1 : 0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(CGFloat(TerminalHeroLayout.aspectRatio), contentMode: .fit)
        // Dark theme: the artwork's near-black edges fade into the screen background, so no box
        // is visible. Light theme: it sits on its own dark plate in the artwork's edge colour.
        .mask { if colorScheme == .dark { HeroEdgeFade() } else { Rectangle() } }
        .background { if colorScheme != .dark { Self.edgeColor } }
        .clipShape(RoundedRectangle(cornerRadius: colorScheme == .dark ? 0 : 12, style: .continuous))
        .frame(maxWidth: CGFloat(TerminalHeroLayout.maxWidth(compactHeight: verticalSizeClass == .compact)))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HCG Terminal")
        .accessibilityAddTraits(.isHeader)
        .onAppear { visible = true; update() }
        .onDisappear { visible = false; update() }
        .onChange(of: scenePhase) { _, _ in update() }
        .onChange(of: reduceMotion) { _, _ in update() }
        .onChange(of: model.appearance) { _, _ in update() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            update()
        }
    }

    private func update() {
        if shouldAnimate { playback.play() } else { playback.pause() }
    }
}

/// Fades the outer edges of the artwork (only its dark margins: the lettering lies between 22%
/// and 79% horizontally and 5% and 89% vertically).
struct HeroEdgeFade: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.10),
            .init(color: .black, location: 0.90), .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.95), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Owns the single muted looping player for one header.
@MainActor
@Observable
final class HeroPlaybackController {
    /// True once a frame is ready and playback is running; until then the static image shows.
    private(set) var showsVideo = false
    @ObservationIgnored private var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var readyObservation: NSKeyValueObservation?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var failed = false

    /// Creates the player once, for the given layer.
    func attach(url: URL, to layer: AVPlayerLayer) {
        if player == nil {
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.allowsExternalPlayback = false
            queue.preventsDisplaySleepDuringVideoPlayback = false
            queue.actionAtItemEnd = .advance
            looper = AVPlayerLooper(player: queue, templateItem: item)
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let didFail = item.status == .failed
                Task { @MainActor in
                    guard let self, didFail else { return }
                    self.failed = true
                    self.showsVideo = false
                }
            }
            player = queue
        }
        if layer.player !== player {
            layer.player = player
            readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor in self?.readyChanged(ready) }
            }
        }
        if wantsPlayback { play() }
    }

    private func readyChanged(_ ready: Bool) {
        showsVideo = ready && wantsPlayback && !failed
    }

    func play() {
        wantsPlayback = true
        guard let player, !failed else { return }
        player.play()
    }

    /// Pauses on the current frame and shows the static artwork again.
    func pause() {
        wantsPlayback = false
        player?.pause()
        showsVideo = false
    }
}

/// A plain `AVPlayerLayer` host: no controls, no audio, aspect-fit like the image beneath it.
struct HeroVideoLayer: UIViewRepresentable {
    let controller: HeroPlaybackController
    let url: URL

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.playerLayer.videoGravity = .resizeAspect
        controller.attach(url: url, to: view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        controller.attach(url: url, to: view.playerLayer)
    }
}
#endif
