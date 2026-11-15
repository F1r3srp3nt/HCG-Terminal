import Foundation

/// The Unleashed build's product page on HCG Repo.
///
/// Defined here because only the Unleashed app target links this module, so the standard
/// (App Store / TestFlight) build neither shows nor contains the link. A fixed HTTPS address:
/// no query, no fragment and never an account, session or device identifier. HCG Terminal
/// never requests it; the system opens it in Safari when the user taps the row in Settings.
public enum HCGRepoPage {
    public static let url = URL(string: "https://repo.hakmicapitalgroup.com/products/hcg-terminal-unleashed/")!
}
