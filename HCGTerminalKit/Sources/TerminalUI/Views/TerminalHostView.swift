#if canImport(UIKit) && canImport(SwiftUI)
import SwiftTerm
import SwiftUI
import TerminalCore
import UIKit

/// Hosts SwiftTerm's xterm-compatible `TerminalView` for one session. Give each session its
/// own instance with `.id(session.id)`.
struct TerminalHostView: UIViewRepresentable {
    let session: SessionModel
    /// SwiftUI colour (from `ModeAccent`). Qualified because SwiftTerm also exports a `Color`
    /// type (its terminal palette colour), which makes the bare name ambiguous in this file.
    let accent: SwiftUI.Color
    var fontSize: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.terminalDelegate = context.coordinator
        // The terminal stays dark and fully opaque in every theme: ANSI colours are designed for a
        // dark background, and explicit ANSI background colours are drawn by SwiftTerm unchanged.
        view.nativeBackgroundColor = HCGPalette.terminalSurfaceUI
        view.nativeForegroundColor = HCGPalette.terminalTextUI
        view.isOpaque = true
        view.caretColor = UIColor(accent)
        view.keyboardAppearance = .dark
        // Our own key row (Esc, Tab, sticky Ctrl, arrows, common symbols) replaces SwiftTerm's default.
        let keyBar = TerminalKeyBar(terminalView: view, coordinator: context.coordinator, accent: UIColor(accent))
        context.coordinator.keyBar = keyBar
        view.inputAccessoryView = keyBar
        context.coordinator.bind(view)
        if Self.focusOnAppear { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        return view
    }

    /// The keyboard opens with the terminal, except in the CI "keyboard hidden" screenshot run.
    static var focusOnAppear: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("-HCGSmokeKeyboardHidden")
        #else
        true
        #endif
    }

    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        view.caretColor = UIColor(accent)
        context.coordinator.keyBar?.accent = UIColor(accent)
        if abs(view.font.pointSize - fontSize) > 0.1 {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    static func dismantleUIView(_ view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let session: SessionModel
        weak var keyBar: TerminalKeyBar?
        /// Sticky Ctrl from the key row: applies to the next single typed key.
        private(set) var controlArmed = false {
            didSet { keyBar?.setControl(controlArmed) }
        }

        func toggleControl() { controlArmed.toggle() }

        init(session: SessionModel) {
            self.session = session
        }

        func bind(_ view: SwiftTerm.TerminalView) {
            let replay = session.replay
            if !replay.isEmpty { view.feed(byteArray: replay[...]) }
            session.outputSink = { [weak view] bytes in
                view?.feed(byteArray: bytes[...])
            }
        }

        func unbind() {
            session.outputSink = nil
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            session.resize(columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            if !title.isEmpty { session.title = title }
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            var bytes = Array(data)
            if controlArmed, bytes.count == 1 {
                bytes = [TerminalKeyBar.control(bytes[0])]
                controlArmed = false
            }
            session.send(bytes)
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: SwiftTerm.TerminalView) {}

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
/// Key row above the software keyboard: Esc, Tab, sticky Ctrl, arrows and common symbols.
/// Keys are sent through the terminal view, so they reach whatever session it shows. The system
/// keyboard itself stays under iOS control; only this row is styled.
///
/// Event Horizon styling: elevated dark keys with a fine border, 44-pt minimum width and a
/// 40-pt height; pressed keys light up in the accent; an armed Ctrl is filled with the accent
/// (and reported as selected to VoiceOver), so the modifier state never relies on colour alone.
final class TerminalKeyBar: UIInputView {
    private weak var terminalView: SwiftTerm.TerminalView?
    private weak var coordinator: TerminalHostView.Coordinator?
    private var controlButton: UIButton?
    private var buttons: [UIButton] = []
    private var controlArmed = false
    var accent: UIColor {
        didSet { if accent != oldValue { buttons.forEach { $0.setNeedsUpdateConfiguration() } } }
    }

    static let barHeight: CGFloat = 52
    static let keyHeight: CGFloat = 40

    init(terminalView: SwiftTerm.TerminalView, coordinator: TerminalHostView.Coordinator, accent: UIColor) {
        self.terminalView = terminalView
        self.coordinator = coordinator
        self.accent = accent
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.barHeight), inputViewStyle: .default)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = UIColor(HCGPalette.surfaceDeep)
        let hairline = UIView()
        hairline.backgroundColor = UIColor(HCGPalette.border)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight) }

    /// Ctrl applied to one byte: letters and @[\\]^_ map to 0x00–0x1F; other bytes pass through.
    static func control(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x40...0x5F, 0x61...0x7A: byte & 0x1F
        case 0x3F: 0x7F // Ctrl-?
        default: byte
        }
    }

    func setControl(_ active: Bool) {
        controlArmed = active
        controlButton?.isSelected = active
        controlButton?.accessibilityValue = active ? "On" : "Off"
        controlButton?.setNeedsUpdateConfiguration()
    }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: Self.keyHeight),
        ])

        stack.addArrangedSubview(key("esc", label: "Escape") { [weak self] in self?.send([0x1B]) })
        stack.addArrangedSubview(key("tab", label: "Tab") { [weak self] in self?.send([0x09]) })
        let control = key("ctrl", label: "Control", modifier: true) { [weak self] in self?.coordinator?.toggleControl() }
        control.accessibilityValue = "Off"
        control.accessibilityHint = "Applies Control to the next key you type."
        controlButton = control
        stack.addArrangedSubview(control)
        stack.addArrangedSubview(separator())
        for (symbol, final, label) in [("arrow.left", "D", "Left"), ("arrow.up", "A", "Up"), ("arrow.down", "B", "Down"), ("arrow.right", "C", "Right")] {
            stack.addArrangedSubview(key(nil, symbol: symbol, label: label) { [weak self] in self?.arrow(final) })
        }
        stack.addArrangedSubview(separator())
        for character in ["~", "|", "/", "-", "*", "$"] {
            stack.addArrangedSubview(key(character, label: character) { [weak self] in self?.send(Array(character.utf8)) })
        }
        stack.addArrangedSubview(key(nil, symbol: "keyboard.chevron.compact.down", label: "Hide keyboard") { [weak self] in
            _ = self?.terminalView?.resignFirstResponder()
        })
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor(HCGPalette.border)
        line.isAccessibilityElement = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func key(_ title: String?, symbol: String? = nil, label: String, modifier: Bool = false, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        configuration.background.cornerRadius = 8
        configuration.background.strokeWidth = 1
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        })
        button.configurationUpdateHandler = { [weak self] button in
            guard let self, var configuration = button.configuration else { return }
            let armed = modifier && self.controlArmed
            let pressed = button.isHighlighted
            configuration.background.backgroundColor = armed ? self.accent : pressed ? self.accent.withAlphaComponent(0.28) : UIColor(HCGPalette.surfaceElevated)
            configuration.background.strokeColor = armed || pressed ? self.accent : UIColor(HCGPalette.border)
            configuration.baseForegroundColor = armed ? HCGPalette.terminalSurfaceUI : UIColor(HCGPalette.textPrimary)
            button.configuration = configuration
        }
        button.accessibilityLabel = label
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        buttons.append(button)
        return button
    }

    private func send(_ bytes: [UInt8]) {
        terminalView?.send(bytes)
    }

    /// Cursor keys follow the terminal's mode: ESC O x in application-cursor mode (vim, less),
    /// ESC [ x otherwise.
    private func arrow(_ final: String) {
        let application = terminalView?.getTerminal().applicationCursor ?? false
        send(Array((application ? "\u{1B}O" : "\u{1B}[").utf8) + Array(final.utf8))
    }
}

extension TerminalKeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
#endif
