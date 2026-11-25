import Foundation

/// Links other apps (HCG Nexus, HCG Sentinel, Shortcuts) may open.
///
///   hcgterminal://open/<destination>            standard build
///   hcgterminal-unleashed://open/<destination>  Unleashed build
///
/// Navigation only. A link never starts a session, runs a command, changes a setting or passes
/// text into a terminal, so another app cannot make HCG Terminal do anything on its behalf.
public enum TerminalDeepLink: Equatable, Sendable {
    public enum Destination: String, CaseIterable, Sendable {
        case dashboard, files, hosts, builds, artifacts, console, tools, diagnostics, capabilities, settings, about
    }

    case open(Destination)

    public static let schemes: Set<String> = ["hcgterminal", "hcgterminal-unleashed"]

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme),
              url.host?.lowercased() == "open" else { return nil }
        let parts = url.path.split(separator: "/").map { $0.lowercased() }
        guard parts.count == 1, url.query == nil, let destination = Destination(rawValue: parts[0]) else { return nil }
        self = .open(destination)
    }
}

/// What HCG Terminal can actually do with other HCG products today. Statuses come from the
/// products' own repositories and docs; nothing is shown as connected unless it is.
public enum HCGEcosystem {
    public struct Integration: Identifiable, Sendable, Equatable {
        public enum State: String, Sendable { case available = "Available", partial = "Partly available", notYetAvailable = "Not available yet" }
        public var id: String { product }
        public var product: String
        public var state: State
        public var detail: String
        /// A link the user can open (never followed automatically).
        public var link: URL?
    }

    public static func integrations(isUnleashed: Bool) -> [Integration] {
        [
            Integration(
                product: "HCG Repo", state: isUnleashed ? .available : .notYetAvailable,
                detail: isUnleashed
                    ? "The jailbreak edition is distributed through HCG Repo for Sileo and Zebra. Access is granted at download time; the app never locks local features."
                    : "The App Store edition is not distributed through HCG Repo.",
                link: URL(string: "https://repo.hakmicapitalgroup.com/products/hcg-terminal-unleashed/")
            ),
            Integration(
                product: "HCG Nexus", state: isUnleashed ? .available : .partial,
                detail: "Nexus opens HCG Terminal by its bundle identifier. Nexus can also open a screen directly with \(isUnleashed ? "hcgterminal-unleashed" : "hcgterminal")://open/<dashboard|tools|diagnostics|console|hosts|builds|files|settings>; links only navigate.",
                link: nil
            ),
            Integration(
                product: "HCG Sentinel", state: .partial,
                detail: "HCG Terminal can open Sentinel's Security Lab (hcgsentinel://open/securityLab) if Sentinel is installed. Sentinel does not send commands to HCG Terminal, and HCG Terminal sends nothing to Sentinel.",
                link: URL(string: "hcgsentinel://open/securityLab")
            ),
            Integration(
                product: "HCG Connect", state: .notYetAvailable,
                detail: "No HCG Connect sign-in client has been issued for HCG Terminal, so the app has no account sign-in. When one is issued it will use HCG's own sign-in (system browser, PKCE); HCG Terminal will not run its own accounts. The terminal works offline without an account.",
                link: nil
            ),
            Integration(
                product: "HCG Store licensing", state: .notYetAvailable,
                detail: "The Store's licensing service is not live. HCG Terminal checks no licence at runtime; local features stay available offline.",
                link: nil
            ),
            Integration(
                product: "HCG Server", state: .notYetAvailable,
                detail: "HCG Server's companion devices (phones pairing over mutual TLS) are designed but not built, and it has no command or build interface. Use SSH hosts in HCG Terminal instead.",
                link: nil
            ),
            Integration(
                product: "HCG Agent Runtime", state: .notYetAvailable,
                detail: "Agent Runtime exists as an HCG development project, but it has no native release yet and HCG Terminal has no integration with it. Nothing is connected.",
                link: nil
            ),
        ]
    }
}
