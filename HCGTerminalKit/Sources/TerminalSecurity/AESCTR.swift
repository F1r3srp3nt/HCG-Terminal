import Foundation

#if canImport(CommonCrypto)
import CommonCrypto
#else
import Crypto
import _CryptoExtras
#endif

/// AES in counter mode with a full 128-bit big-endian counter, as OpenSSH's `aes*-ctr` ciphers
/// use it. CommonCrypto on Apple platforms (no extra library in the app); swift-crypto's
/// `_CryptoExtras` elsewhere (Linux tests).
enum AESCTR {
    enum Failure: Error { case badKeyOrIV, cryptorFailed(Int32) }

    static func crypt(_ input: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count), iv.count == 16 else { throw Failure.badKeyOrIV }
        #if canImport(CommonCrypto)
        var cryptor: CCCryptorRef?
        var status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0,
                    CCModeOptions(0x0002 /* big-endian counter (kCCModeOptionCTR_BE) */), &cryptor
                )
            }
        }
        guard Int(status) == kCCSuccess, let cryptor else { throw Failure.cryptorFailed(status) }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        status = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                CCCryptorUpdate(cryptor, inBytes.baseAddress, input.count, outBytes.baseAddress, outBytes.count, &moved)
            }
        }
        guard Int(status) == kCCSuccess, moved == input.count else { throw Failure.cryptorFailed(status) }
        return output
        #else
        let nonce = try AES._CTR.Nonce(nonceBytes: iv)
        return Array(try AES._CTR.encrypt(input, using: SymmetricKey(data: key), nonce: nonce))
        #endif
    }
}
