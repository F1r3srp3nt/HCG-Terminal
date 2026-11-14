import Foundation

/// An HCG Server invitation code (`hcg1-…`): the server's address, its
/// pinned key fingerprint and a single-use secret. Share only with the device
/// being enrolled.
public struct Invitation: Sendable, Equatable {
    public var invitationId: String
    public var secret: String
    public var hostDeviceId: String
    public var hostName: String
    public var hostAddress: String
    public var fingerprint: String
    public var expiresAt: Date?

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notAnInvitation
        case corrupted
        case unsupportedVersion(Int)
        case incomplete
        case expired

        public var description: String {
            switch self {
            case .notAnInvitation: return "This is not an HCG Server invitation code (it should start with hcg1-)."
            case .corrupted: return "The invitation code is damaged. Copy it again from HCG Server."
            case .unsupportedVersion(let v): return "This invitation uses version \(v), which this app does not support."
            case .incomplete: return "The invitation code is incomplete."
            case .expired: return "This invitation has expired. Create a new one in HCG Server."
            }
        }
    }

    private struct Payload: Decodable {
        var v: Int
        var id: String
        var s: String
        var hd: String
        var hn: String
        var ha: String
        var fp: String
        var exp: String?
    }

    /// Parses a code, tolerating whitespace and line breaks from copy/paste.
    public static func parse(_ code: String, now: Date = Date()) throws -> Invitation {
        let compact = code.components(separatedBy: .whitespacesAndNewlines).joined()
        guard compact.hasPrefix("hcg1-") else { throw Problem.notAnInvitation }
        guard let data = LinkCrypto.base64URLDecode(String(compact.dropFirst(5))),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { throw Problem.corrupted }
        guard p.v == 1 else { throw Problem.unsupportedVersion(p.v) }
        guard !p.id.isEmpty, !p.s.isEmpty, !p.ha.isEmpty, p.fp.count == 64,
              p.fp.allSatisfy({ $0.isHexDigit }) else { throw Problem.incomplete }
        let exp = p.exp.flatMap(LinkJSON.parseDate)
        if let exp = exp, exp < now { throw Problem.expired }
        return Invitation(invitationId: p.id, secret: p.s, hostDeviceId: p.hd, hostName: p.hn, hostAddress: p.ha,
                          fingerprint: p.fp.lowercased(), expiresAt: exp)
    }

    /// `https://host:port` of the server's device API.
    public var baseURL: URL? {
        URL(string: "https://" + hostAddress)
    }
}
