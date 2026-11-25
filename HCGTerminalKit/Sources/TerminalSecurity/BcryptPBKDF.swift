import Crypto
import Foundation

/// `bcrypt_pbkdf` as used by OpenSSH to derive the key that protects a passphrase-protected
/// private key (`openssh-key-v1` with kdfname `bcrypt`). A direct port of OpenBSD's
/// `bcrypt_pbkdf.c` and the parts of `blowfish.c` it needs; verified against keys made by
/// `ssh-keygen` (see `OpenSSHKeyImportTests`).
enum BcryptPBKDF {
    /// Derives `length` bytes from `passphrase` and `salt` with `rounds` iterations.
    static func derive(passphrase: [UInt8], salt: [UInt8], rounds: Int, length: Int) -> [UInt8] {
        precondition(rounds >= 1 && length >= 1)
        let hashLength = 32
        let stride = (length + hashLength - 1) / hashLength
        var amount = (length + stride - 1) / stride
        let sha2pass = Array(SHA512.hash(data: passphrase))
        var key = [UInt8](repeating: 0, count: length)
        var remaining = length
        var count: UInt32 = 1
        while remaining > 0 {
            let countSalt = salt + [UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
            var sha2salt = Array(SHA512.hash(data: countSalt))
            var tmp = bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
            var out = tmp
            if rounds > 1 {
                for _ in 1..<rounds {
                    sha2salt = Array(SHA512.hash(data: tmp))
                    tmp = bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
                    for j in 0..<out.count { out[j] ^= tmp[j] }
                }
            }
            // Spread the output across the key ("bcrypt_pbkdf" interleaves blocks).
            amount = min(amount, remaining)
            var written = 0
            for i in 0..<amount {
                let destination = i * stride + Int(count - 1)
                if destination >= length { break }
                key[destination] = out[i]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return key
    }

    private static let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)

    static func bcryptHash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        state.expandState(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expand0State(key: sha2salt)
            state.expand0State(key: sha2pass)
        }
        var cdata = [UInt32](repeating: 0, count: 8)
        var j = 0
        for i in 0..<8 { cdata[i] = Blowfish.streamToWord(magic, &j) }
        for _ in 0..<64 {
            for block in 0..<4 {
                (cdata[2 * block], cdata[2 * block + 1]) = state.encipher(cdata[2 * block], cdata[2 * block + 1])
            }
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[4 * i + 3] = UInt8(cdata[i] >> 24 & 0xFF)
            out[4 * i + 2] = UInt8(cdata[i] >> 16 & 0xFF)
            out[4 * i + 1] = UInt8(cdata[i] >> 8 & 0xFF)
            out[4 * i + 0] = UInt8(cdata[i] & 0xFF)
        }
        return out
    }
}

/// The Blowfish key schedule and block encryption (no decryption is needed here).
struct Blowfish {
    var p: [UInt32] = BlowfishConstants.p
    var s: [UInt32] = BlowfishConstants.s

    /// Reads the next big-endian word from `data`, wrapping around at the end.
    static func streamToWord(_ data: [UInt8], _ j: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if j >= data.count { j = 0 }
            word = word << 8 | UInt32(data[j])
            j += 1
        }
        return word
    }

    @inline(__always)
    private func f(_ x: UInt32) -> UInt32 {
        let a = s[Int(x >> 24)]
        let b = s[256 + Int(x >> 16 & 0xFF)]
        let c = s[512 + Int(x >> 8 & 0xFF)]
        let d = s[768 + Int(x & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }

    func encipher(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
        var xl = left ^ p[0]
        var xr = right
        var i = 1
        while i <= 16 {
            xr ^= f(xl) ^ p[i]
            xl ^= f(xr) ^ p[i + 1]
            i += 2
        }
        return (xr ^ p[17], xl)
    }

    mutating func expandState(data: [UInt8], key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &j) }
        j = 0
        var l: UInt32 = 0, r: UInt32 = 0
        var i = 0
        while i < 18 {
            l ^= Self.streamToWord(data, &j)
            r ^= Self.streamToWord(data, &j)
            (l, r) = encipher(l, r)
            p[i] = l; p[i + 1] = r
            i += 2
        }
        i = 0
        while i < 1024 {
            l ^= Self.streamToWord(data, &j)
            r ^= Self.streamToWord(data, &j)
            (l, r) = encipher(l, r)
            s[i] = l; s[i + 1] = r
            i += 2
        }
    }

    mutating func expand0State(key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &j) }
        var l: UInt32 = 0, r: UInt32 = 0
        var i = 0
        while i < 18 {
            (l, r) = encipher(l, r)
            p[i] = l; p[i + 1] = r
            i += 2
        }
        i = 0
        while i < 1024 {
            (l, r) = encipher(l, r)
            s[i] = l; s[i + 1] = r
            i += 2
        }
    }
}
