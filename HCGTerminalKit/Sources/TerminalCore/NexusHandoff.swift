import Foundation

/// The HCG Nexus handoff contract, version 1 (docs/NEXUS-HANDOFF.md).
///
/// HCG Nexus can bring HCG Terminal forward, or show one of Terminal's saved connections, by
/// opening a URL. Nothing a link says is ever executed: the only effects are "come to the
/// front" and "show this saved connection so the user can tap Connect". Everything else is
/// refused. This type is pure (no UI, no I/O) so every rule is unit tested on all platforms.
public enum NexusHandoff {
    /// Contract version. Published in Info.plist under `infoPlistKey`.
    public static let contractVersion = 1
    /// Info.plist key (integer) that tells Nexus this build supports the contract.
    public static let infoPlistKey = "HCGNexusHandoff"
    /// `CFBundleURLName` of the URL type that declares the scheme.
    public static let urlTypeName = "com.hakmicapitalgroup.hcgterminal.nexus-handoff"
    /// Longest URL accepted, in UTF-8 bytes.
    public static let maxURLLength = 256

    /// Parameter names refused by name, so a refusal says plainly that commands are never run.
    public static let commandParameterNames: Set<String> = ["command", "cmd", "run", "exec", "script", "input"]

    /// Each app variant has its own scheme, so iOS never has to choose between two installed
    /// apps, and each build accepts only its own.
    public enum Variant: String, Sendable, CaseIterable {
        case standard
        case unleashed

        public var scheme: String {
            switch self {
            case .standard: "hcgterminal"
            case .unleashed: "hcgterminal-unleashed"
            }
        }
    }

    public enum Route: Equatable, Sendable {
        /// `<scheme>://open`: bring the app forward. No other effect.
        case open
        /// `<scheme>://connection?id=<UUID>`: show that saved connection; the user taps Connect.
        case connection(UUID)
    }

    public enum Refusal: Error, Equatable, Sendable {
        case tooLong(Int)
        case malformed
        case wrongScheme(String?)
        case unexpectedComponent(String)
        case unknownRoute(String?)
        case commandParameter(String)
        case unexpectedParameter(String)
        case missingID
        case duplicateID
        case invalidID

        /// Shown to the user. Never repeats the link's contents beyond a parameter name.
        public var message: String {
            switch self {
            case .tooLong: "The link is longer than \(NexusHandoff.maxURLLength) characters."
            case .malformed: "The link is not a valid URL."
            case .wrongScheme: "The link is for a different app or build."
            case .unexpectedComponent(let part): "The link has an unsupported \(part)."
            case .unknownRoute: "The link asks for something HCG Terminal does not support."
            case .commandParameter(let name): "The link contains “\(Self.clipped(name))”. Links never run commands."
            case .unexpectedParameter(let name): "The link has an unsupported parameter “\(Self.clipped(name))”."
            case .missingID: "The link does not name a saved connection."
            case .duplicateID: "The link names more than one saved connection."
            case .invalidID: "The link's connection ID is not valid."
            }
        }

        /// A fixed identifier for logs. Never contains anything taken from the link.
        public var code: String {
            switch self {
            case .tooLong: "too-long"
            case .malformed: "malformed"
            case .wrongScheme: "wrong-scheme"
            case .unexpectedComponent: "unexpected-component"
            case .unknownRoute: "unknown-route"
            case .commandParameter: "command-parameter"
            case .unexpectedParameter: "unexpected-parameter"
            case .missingID: "missing-id"
            case .duplicateID: "duplicate-id"
            case .invalidID: "invalid-id"
            }
        }

        private static func clipped(_ name: String) -> String {
            name.count > 24 ? String(name.prefix(24)) + "…" : name
        }
    }

    /// Parses a handoff URL for the build `variant`. Pure: no side effects.
    public static func parse(_ url: URL, variant: Variant) -> Result<Route, Refusal> {
        parse(url.absoluteString, variant: variant)
    }

    /// Parses a handoff URL string for the build `variant`. Pure: no side effects.
    public static func parse(_ string: String, variant: Variant) -> Result<Route, Refusal> {
        let length = string.utf8.count
        guard length <= maxURLLength else { return .failure(.tooLong(length)) }
        // Printable ASCII only: no spaces, control characters or raw Unicode.
        guard !string.isEmpty, string.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              let components = URLComponents(string: string)
        else { return .failure(.malformed) }

        guard let scheme = components.scheme, scheme.lowercased() == variant.scheme else {
            return .failure(.wrongScheme(components.scheme))
        }
        // `scheme://host` form only.
        guard string.lowercased().hasPrefix(variant.scheme + "://") else { return .failure(.unknownRoute(nil)) }
        // The authority is also checked as written, so the rules do not depend on how a
        // platform's URL parser reports empty components.
        let authority = string.dropFirst(variant.scheme.count + 3).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if authority.contains("@") || components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            return .failure(.unexpectedComponent("user name or password"))
        }
        if authority.contains(":") || components.port != nil { return .failure(.unexpectedComponent("port")) }
        if string.contains("#") || components.percentEncodedFragment != nil { return .failure(.unexpectedComponent("fragment")) }
        guard components.percentEncodedPath.isEmpty else { return .failure(.unexpectedComponent("path")) }

        // Query items are checked before the route, so a command-like parameter is always
        // reported as such, whatever route it came with.
        let items = components.percentEncodedQueryItems ?? []
        if let command = items.first(where: { commandParameterNames.contains(decodedName($0).lowercased()) }) {
            return .failure(.commandParameter(decodedName(command)))
        }

        switch components.percentEncodedHost?.lowercased() {
        case "open":
            guard components.percentEncodedQuery == nil, !string.contains("?") else {
                return .failure(.unexpectedParameter(items.first.map(decodedName) ?? "?"))
            }
            return .success(.open)
        case "connection":
            guard components.percentEncodedQuery != nil, !items.isEmpty else { return .failure(.missingID) }
            if let other = items.first(where: { $0.name != "id" }) { return .failure(.unexpectedParameter(decodedName(other))) }
            guard items.count == 1 else { return .failure(.duplicateID) }
            guard let value = items[0].value, !value.isEmpty else { return .failure(.missingID) }
            guard isCanonicalUUID(value), let id = UUID(uuidString: value) else { return .failure(.invalidID) }
            return .success(.connection(id))
        case let host:
            return .failure(.unknownRoute(host))
        }
    }

    /// The link "Copy Link for HCG Nexus" puts on the pasteboard. Contains only the saved
    /// connection's ID: no hostname, user name, key or secret.
    public static func connectionLink(id: UUID, variant: Variant) -> String {
        "\(variant.scheme)://connection?id=\(id.uuidString)"
    }

    /// The link that only brings the app forward.
    public static func openLink(variant: Variant) -> String {
        "\(variant.scheme)://open"
    }

    /// 8-4-4-4-12 hexadecimal digits, nothing else (no braces, no percent-escapes).
    static func isCanonicalUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == UInt8(ascii: "-") else { return false }
            } else {
                let isHex = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
                guard isHex else { return false }
            }
        }
        return true
    }

    private static func decodedName(_ item: URLQueryItem) -> String {
        let name = item.name.removingPercentEncoding ?? item.name
        return name.isEmpty ? "(empty)" : name
    }
}
