import Crypto
import Foundation
@testable import TerminalSecurity
import XCTest

/// Imports keys made by the real `ssh-keygen` (and `openssl` for PKCS#8 Ed25519) and checks the
/// result against what OpenSSH itself reports. Keys are generated per run in a temporary folder,
/// so no private key is ever committed. Runs on macOS (CommonCrypto AES-CTR) and Linux
/// (swift-crypto AES-CTR); skipped where those tools do not exist (iOS Simulator).
final class OpenSSHKeyImportTests: XCTestCase {
    static let passphrase = "correct horse"
    private var folder: URL!

    override func setUpWithError() throws {
        #if os(macOS) || os(Linux)
        try XCTSkipUnless(Self.tool("ssh-keygen") != nil, "ssh-keygen not available")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #else
        throw XCTSkip("needs ssh-keygen (macOS or Linux)")
        #endif
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Helpers

    static func tool(_ name: String) -> String? {
        ["/usr/bin/\(name)", "/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    func run(_ tool: String, _ arguments: [String]) throws -> String {
        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(Self.tool(tool), "\(tool) missing"))
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
        #else
        throw XCTSkip("no Process")
        #endif
    }

    struct Generated {
        let privateKey: String
        let publicLine: String   // type + base64, without comment
        let fingerprint: String  // as ssh-keygen -lf prints it
    }

    /// `ssh-keygen -t <type> …` into the temporary folder.
    func keygen(_ name: String, type: String, bits: Int? = nil, passphrase: String = "", extra: [String] = [], comment: String = "test@hcg") throws -> Generated {
        let path = folder.appendingPathComponent(name).path
        var arguments = ["-q", "-t", type, "-N", passphrase, "-C", comment, "-f", path]
        if let bits { arguments += ["-b", String(bits)] }
        try run("ssh-keygen", arguments + extra)
        let publicLine = try String(contentsOfFile: path + ".pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        let fingerprint = String(try run("ssh-keygen", ["-lf", path + ".pub"]).split(separator: " ")[1])
        return Generated(privateKey: try String(contentsOfFile: path, encoding: .utf8), publicLine: publicLine, fingerprint: fingerprint)
    }

    func assertImports(_ generated: Generated, passphrase: String?, algorithm: String, comment: String, encrypted: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let imported = try OpenSSHKeyImport.parse(generated.privateKey, passphrase: passphrase)
        XCTAssertEqual(imported.key.algorithm, algorithm, file: file, line: line)
        XCTAssertEqual(imported.comment, comment, file: file, line: line)
        XCTAssertEqual(imported.wasEncrypted, encrypted, file: file, line: line)
        XCTAssertEqual(try imported.key.fingerprint(), generated.fingerprint, "fingerprint must match ssh-keygen -lf", file: file, line: line)
        XCTAssertEqual(try imported.key.publicKeyLine(comment: ""), generated.publicLine, "public key must match the .pub file", file: file, line: line)
        // The stored form round-trips.
        let restored = try SSHPrivateKey(algorithm: imported.key.algorithm, rawRepresentation: imported.key.rawRepresentation)
        XCTAssertEqual(restored, imported.key, file: file, line: line)
    }

    // MARK: OpenSSH format

    func testUnencryptedEd25519AndECDSA() throws {
        try assertImports(try keygen("ed", type: "ed25519", comment: "plain@ed"), passphrase: nil, algorithm: "ssh-ed25519", comment: "plain@ed", encrypted: false)
        try assertImports(try keygen("p256", type: "ecdsa", bits: 256, comment: "p256@test"), passphrase: nil, algorithm: "ecdsa-sha2-nistp256", comment: "p256@test", encrypted: false)
        XCTAssertFalse(OpenSSHKeyImport.needsPassphrase(try keygen("ed2", type: "ed25519").privateKey))
    }

    /// ssh-keygen's defaults for a passphrase-protected key: aes256-ctr, bcrypt with 16 rounds.
    func testPassphraseProtectedEd25519WithDefaults() throws {
        let generated = try keygen("ed-default", type: "ed25519", passphrase: Self.passphrase, comment: "ana@macbook")
        XCTAssertTrue(OpenSSHKeyImport.needsPassphrase(generated.privateKey))
        try assertImports(generated, passphrase: Self.passphrase, algorithm: "ssh-ed25519", comment: "ana@macbook", encrypted: true)
    }

    func testOtherCiphersAndCurves() throws {
        try assertImports(try keygen("gcm", type: "ed25519", passphrase: Self.passphrase, extra: ["-a", "4", "-Z", "aes256-gcm@openssh.com"]), passphrase: Self.passphrase, algorithm: "ssh-ed25519", comment: "test@hcg", encrypted: true)
        try assertImports(try keygen("ctr128", type: "ed25519", passphrase: Self.passphrase, extra: ["-a", "4", "-Z", "aes128-ctr"]), passphrase: Self.passphrase, algorithm: "ssh-ed25519", comment: "test@hcg", encrypted: true)
        try assertImports(try keygen("p384", type: "ecdsa", bits: 384, passphrase: Self.passphrase, extra: ["-a", "4"]), passphrase: Self.passphrase, algorithm: "ecdsa-sha2-nistp384", comment: "test@hcg", encrypted: true)
        try assertImports(try keygen("p521", type: "ecdsa", bits: 521, passphrase: Self.passphrase, extra: ["-a", "4"]), passphrase: Self.passphrase, algorithm: "ecdsa-sha2-nistp521", comment: "test@hcg", encrypted: true)
    }

    func testMissingAndWrongPassphrase() throws {
        let generated = try keygen("ed-wrong", type: "ed25519", passphrase: Self.passphrase, extra: ["-a", "4"])
        XCTAssertThrowsError(try OpenSSHKeyImport.parse(generated.privateKey, passphrase: nil)) { XCTAssertEqual($0 as? SSHKeyImportError, .passphraseRequired) }
        XCTAssertThrowsError(try OpenSSHKeyImport.parse(generated.privateKey, passphrase: "wrong")) { XCTAssertEqual($0 as? SSHKeyImportError, .wrongPassphrase) }
        let gcm = try keygen("gcm-wrong", type: "ed25519", passphrase: Self.passphrase, extra: ["-a", "4", "-Z", "aes256-gcm@openssh.com"])
        XCTAssertThrowsError(try OpenSSHKeyImport.parse(gcm.privateKey, passphrase: "wrong")) { XCTAssertEqual($0 as? SSHKeyImportError, .wrongPassphrase) }
    }

    func testUnsupportedKeysAndCiphersAreExplained() throws {
        let rsa = try keygen("rsa", type: "rsa", bits: 2048)
        XCTAssertThrowsError(try OpenSSHKeyImport.parse(rsa.privateKey, passphrase: nil)) { XCTAssertEqual($0 as? SSHKeyImportError, .unsupportedKeyType("RSA")) }
        XCTAssertThrowsError(try OpenSSHKeyImport.parse(rsa.publicLine, passphrase: nil)) { XCTAssertEqual($0 as? SSHKeyImportError, .publicKeyGiven) }
        let chacha = try keygen("chacha", type: "ed25519", passphrase: Self.passphrase, extra: ["-a", "4", "-Z", "chacha20-poly1305@openssh.com"])
        XCTAssertThrowsError(try OpenSSHKeyImport.parse(chacha.privateKey, passphrase: Self.passphrase)) {
            XCTAssertEqual($0 as? SSHKeyImportError, .unsupportedCipher("chacha20-poly1305@openssh.com"))
        }
        XCTAssertThrowsError(try OpenSSHKeyImport.parse("hello", passphrase: nil)) { XCTAssertEqual($0 as? SSHKeyImportError, .notAPrivateKey) }
        for error in [SSHKeyImportError.unsupportedKeyType("RSA"), .encryptedPEM, .unsupportedCipher("x"), .passphraseRequired] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
        XCTAssertTrue(SSHKeyImportError.unsupportedKeyType("RSA").errorDescription!.contains("Ed25519"), "says what to use instead")
    }

    // MARK: PEM

    func testPEMFormats() throws {
        try assertImports(try keygen("pem", type: "ecdsa", bits: 256, extra: ["-m", "PEM"]), passphrase: nil, algorithm: "ecdsa-sha2-nistp256", comment: "", encrypted: false)
        try assertImports(try keygen("pkcs8", type: "ecdsa", bits: 384, extra: ["-m", "PKCS8"]), passphrase: nil, algorithm: "ecdsa-sha2-nistp384", comment: "", encrypted: false)
        let encrypted = try keygen("pem-enc", type: "ecdsa", bits: 256, passphrase: Self.passphrase, extra: ["-m", "PEM"])
        XCTAssertThrowsError(try OpenSSHKeyImport.parse(encrypted.privateKey, passphrase: Self.passphrase)) { XCTAssertEqual($0 as? SSHKeyImportError, .encryptedPEM) }
    }

    func testPKCS8Ed25519FromOpenSSL() throws {
        try XCTSkipUnless(Self.tool("openssl") != nil, "openssl not available")
        let path = folder.appendingPathComponent("ed-openssl.pem").path
        try run("openssl", ["genpkey", "-algorithm", "ed25519", "-out", path])
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        let imported = try OpenSSHKeyImport.parse(pem, passphrase: nil)
        XCTAssertEqual(imported.key.algorithm, "ssh-ed25519")
        // The public key openssl reports (last 32 bytes of the SubjectPublicKeyInfo DER).
        let der = folder.appendingPathComponent("pub.der").path
        try run("openssl", ["pkey", "-in", path, "-pubout", "-outform", "DER", "-out", der])
        let publicRaw = try Data(contentsOf: URL(fileURLWithPath: der)).suffix(32)
        let expectedBlob = SSHWire.string("ssh-ed25519") + SSHWire.string(Array(publicRaw))
        XCTAssertEqual(try imported.key.publicKeyBlob(), expectedBlob)
    }

    // MARK: Storage

    func testImportStoresKeyAndRefusesDuplicates() throws {
        let credentials = InMemoryCredentialStore()
        let url = folder.appendingPathComponent("keys.json")
        let manager = SSHKeyManager(credentials: credentials, metadataURL: url)
        let generated = try keygen("store", type: "ecdsa", bits: 256, passphrase: Self.passphrase, extra: ["-a", "4"], comment: "ana@macbook")
        let imported = try OpenSSHKeyImport.parse(generated.privateKey, passphrase: Self.passphrase)
        let record = try manager.importKey(imported, comment: imported.comment)
        XCTAssertTrue(record.isImported)
        XCTAssertEqual(record.algorithm, "ecdsa-sha2-nistp256")
        XCTAssertEqual(record.fingerprint, generated.fingerprint)
        XCTAssertEqual(record.publicKeyLine, generated.publicLine + " ana@macbook")
        XCTAssertEqual(try manager.privateKey(for: record.id), imported.key)
        XCTAssertThrowsError(try manager.importKey(imported, comment: "again")) {
            XCTAssertEqual($0 as? SSHKeyImportError, .alreadyImported(fingerprint: generated.fingerprint))
        }
        // Older records (no algorithm change, no `imported` key) still decode as Ed25519 keys.
        let legacy = try manager.generateEd25519(comment: "device")
        XCTAssertFalse(legacy.isImported)
        if case .ed25519 = try manager.privateKey(for: legacy.id) {} else { XCTFail("generated key is Ed25519") }
    }

    /// bcrypt_pbkdf known-answer test: the vector from OpenBSD's regression tests
    /// (password "password", salt "salt", 4 rounds, 32 bytes).
    func testBcryptPBKDFKnownAnswer() {
        let key = BcryptPBKDF.derive(passphrase: Array("password".utf8), salt: Array("salt".utf8), rounds: 4, length: 32)
        let hex = key.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9")
    }
}
