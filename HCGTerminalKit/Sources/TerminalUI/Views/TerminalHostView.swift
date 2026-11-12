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
        // The terminal stays dark in both themes: ANSI colors are designed for a dark background.
        view.nativeBackgroundColor = UIColor(red: 0x05 / 255, green: 0x08 / 255, blue: 0x0B / 255, alpha: 1)
        view.nativeForegroundColor = UIColor(red: 0xEE / 255, green: 0xF3 / 255, blue: 0xF6 / 255, alpha: 1)
        view.caretColor = UIColor(accent)
        view.keyboardAppearance = .dark
        // Our own key row (Esc, Tab, sticky Ctrl, arrows, common symbols) replaces SwiftTerm's default.
        let keyBar = TerminalKeyBar(terminalView: view, coordinator: context.coordinator)
        context.coordinator.keyBar = keyBar
        view.inputAccessoryView = keyBar
        context.coordinator.bind(view)
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        view.caretColor = UIColor(accent)
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
/// Keys are sent through the terminal view, so they reach whatever session it shows.
final class TerminalKeyBar: UIInputView {
    private weak var terminalView: SwiftTerm.TerminalView?
    private weak var coordinator: TerminalHostView.Coordinator?
    private var controlButton: UIButton?

    init(terminalView: SwiftTerm.TerminalView, coordinator: TerminalHostView.Coordinator) {
        self.terminalView = terminalView
        self.coordinator = coordinator
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    /// Ctrl applied to one byte: letters and @[\]^_ map to 0x00–0x1F; other bytes pass through.
    static func control(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x40...0x5F, 0x61...0x7A: byte & 0x1F
        case 0x3F: 0x7F // Ctrl-?
        default: byte
        }
    }

    func setControl(_ active: Bool) {
        controlButton?.isSelected = active
        controlButton?.configuration?.baseBackgroundColor = active ? UIColor(HCGPalette.vanillaBlue) : UIColor(HCGPalette.surface2)
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
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])

        stack.addArrangedSubview(key("esc", label: "Escape") { [weak self] in self?.send([0x1B]) })
        stack.addArrangedSubview(key("tab", label: "Tab") { [weak self] in self?.send([0x09]) })
        let control = key("ctrl", label: "Control") { [weak self] in self?.coordinator?.toggleControl() }
        controlButton = control
        stack.addArrangedSubview(control)
        for (symbol, final, label) in [("arrow.left", "D", "Left"), ("arrow.up", "A", "Up"), ("arrow.down", "B", "Down"), ("arrow.right", "C", "Right")] {
            stack.addArrangedSubview(key(nil, symbol: symbol, label: label) { [weak self] in self?.arrow(final) })
        }
        for character in ["~", "|", "/", "-", "*", "$"] {
            stack.addArrangedSubview(key(character, label: character) { [weak self] in self?.send(Array(character.utf8)) })
        }
        stack.addArrangedSubview(key(nil, symbol: "keyboard.chevron.compact.down", label: "Hide keyboard") { [weak self] in
            _ = self?.terminalView?.resignFirstResponder()
        })
    }

    private func key(_ title: String?, symbol: String? = nil, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        if let symbol { configuration.image = UIImage(systemName: symbol) }
        configuration.baseBackgroundColor = UIColor(HCGPalette.surface2)
        configuration.baseForegroundColor = UIColor(HCGPalette.ivory)
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        })
        button.accessibilityLabel = label
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
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
