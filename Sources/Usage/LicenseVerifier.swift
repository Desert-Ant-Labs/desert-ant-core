#if canImport(CryptoKit)
import CryptoKit
import Foundation
#elseif os(Windows)
import CBCrypt
import WinSDK
#elseif os(Android)
import CHostBridge
#elseif os(WASI)
import JavaScriptEventLoop
import JavaScriptKit
#endif
#if !os(WASI)
import Dispatch
#endif

func defaultLicenseVerifier() -> (any LicenseSignatureVerifier)? {
#if canImport(CryptoKit)
    CryptoKitLicenseVerifier()
#elseif os(Windows)
    CNGLicenseVerifier()
#elseif os(Android)
    HostLicenseVerifier(verify: host_license_verify)
#elseif os(WASI)
    WebCryptoLicenseVerifier.subtle == nil ? nil : WebCryptoLicenseVerifier()
#else
    InstalledLicenseVerifier.isInstalled ? InstalledLicenseVerifier() : nil
#endif
}

#if canImport(CryptoKit)
struct CryptoKitLicenseVerifier: LicenseSignatureVerifier {
    func isValidSignature(_ signature: [UInt8], for message: [UInt8], publicKey: [UInt8]) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
#endif

#if os(Windows)
struct CNGLicenseVerifier: LicenseSignatureVerifier {
    func isValidSignature(_ signature: [UInt8], for message: [UInt8], publicKey: [UInt8]) -> Bool {
        guard signature.count == 64, publicKey.count == 65, publicKey[0] == 0x04 else { return false }
        var algorithm: BCRYPT_ALG_HANDLE?
        let opened = "ECDSA_P256".withCString(encodedAs: UTF16.self) {
            BCryptOpenAlgorithmProvider(&algorithm, $0, nil, 0)
        }
        guard opened >= 0, let algorithm else { return false }
        defer { BCryptCloseAlgorithmProvider(algorithm, 0) }

        var header = BCRYPT_ECCKEY_BLOB(dwMagic: ULONG(BCRYPT_ECDSA_PUBLIC_P256_MAGIC), cbKey: 32)
        var blob = withUnsafeBytes(of: &header) { Array($0) } + publicKey.dropFirst()
        var key: BCRYPT_KEY_HANDLE?
        let imported = "ECCPUBLICBLOB".withCString(encodedAs: UTF16.self) {
            BCryptImportKeyPair(algorithm, nil, $0, &key, &blob, ULONG(blob.count), 0)
        }
        guard imported >= 0, let key else { return false }
        defer { BCryptDestroyKey(key) }

        var hash: BCRYPT_HASH_HANDLE?
        // The SHA-256 pseudo-handle, as in ModelStore's SHA256: bcrypt.h spells it as a macro Swift cannot import.
        guard BCryptCreateHash(BCRYPT_ALG_HANDLE(bitPattern: 0x41), &hash, nil, 0, nil, 0, 0) >= 0 else { return false }
        defer { BCryptDestroyHash(hash) }
        var input = message
        var digest = [UInt8](repeating: 0, count: 32)
        guard BCryptHashData(hash, &input, ULONG(input.count), 0) >= 0,
              BCryptFinishHash(hash, &digest, ULONG(digest.count), 0) >= 0
        else { return false }

        var raw = signature
        return BCryptVerifySignature(key, nil, &digest, ULONG(digest.count), &raw, ULONG(raw.count), 0) == 0
    }
}
#endif

#if os(WASI)
struct WebCryptoLicenseVerifier: LicenseSignatureVerifier {
    // Absent on an insecure origin, where tokens then go unverified.
    static var subtle: JSObject? {
        jsProperty(JSObject.global, "crypto").object.flatMap { jsProperty($0, "subtle").object }
    }

    func isValidSignature(_ signature: [UInt8], for message: [UInt8], publicKey: [UInt8]) async -> Bool {
        guard let subtle = Self.subtle else { return false }
        let curve = JSObject.global.Object.function!.new()
        curve["name"] = "ECDSA".jsValue
        curve["namedCurve"] = "P-256".jsValue
        let scheme = JSObject.global.Object.function!.new()
        scheme["name"] = "ECDSA".jsValue
        scheme["hash"] = "SHA-256".jsValue
        guard let importing = try? subtle.throwing.importKey?(
                  "raw", JSTypedArray<UInt8>(publicKey), curve, false, ["verify"]),
              let imported = JSPromise(from: importing),
              let key = try? await imported.value,
              let verifying = try? subtle.throwing.verify?(
                  scheme, key, JSTypedArray<UInt8>(signature), JSTypedArray<UInt8>(message)),
              let verified = JSPromise(from: verifying),
              let valid = try? await verified.value
        else { return false }
        return valid.boolean ?? false
    }
}
#else
package typealias HostLicenseVerify = @convention(c) (
    UnsafePointer<UInt8>?, Int32, UnsafePointer<UInt8>?, Int32, UnsafePointer<UInt8>?, Int32
) -> Int32

struct HostLicenseVerifier: LicenseSignatureVerifier {
    let verify: HostLicenseVerify

    func isValidSignature(_ signature: [UInt8], for message: [UInt8], publicKey: [UInt8]) -> Bool {
        let result = signature.withUnsafeBufferPointer { signature in
            message.withUnsafeBufferPointer { message in
                publicKey.withUnsafeBufferPointer { publicKey in
                    verify(
                        signature.baseAddress, Int32(signature.count), message.baseAddress, Int32(message.count),
                        publicKey.baseAddress, Int32(publicKey.count))
                }
            }
        }
        return result == 1
    }
}

private let installedLicenseVerifyLock = DispatchSemaphore(value: 1)
private nonisolated(unsafe) var installedLicenseVerify: HostLicenseVerify?
private nonisolated(unsafe) var installedLicenseVerifyCalls: Int32 = 0

// Removal is refused while a call is in flight and returns that count, so an exiting host can drain them first.
package func installHostLicenseVerifier(_ verify: HostLicenseVerify?) -> Int32 {
    installedLicenseVerifyLock.wait()
    defer { installedLicenseVerifyLock.signal() }
    if verify == nil, installedLicenseVerifyCalls > 0 { return installedLicenseVerifyCalls }
    installedLicenseVerify = verify
    return 0
}

struct InstalledLicenseVerifier: LicenseSignatureVerifier {
    static var isInstalled: Bool {
        installedLicenseVerifyLock.wait()
        defer { installedLicenseVerifyLock.signal() }
        return installedLicenseVerify != nil
    }

    func isValidSignature(_ signature: [UInt8], for message: [UInt8], publicKey: [UInt8]) -> Bool {
        installedLicenseVerifyLock.wait()
        guard let verify = installedLicenseVerify else {
            installedLicenseVerifyLock.signal()
            // The host removed it on the way out; the server still checks the signature at activation.
            return true
        }
        installedLicenseVerifyCalls += 1
        installedLicenseVerifyLock.signal()
        defer {
            installedLicenseVerifyLock.wait()
            installedLicenseVerifyCalls -= 1
            installedLicenseVerifyLock.signal()
        }
        return HostLicenseVerifier(verify: verify).isValidSignature(signature, for: message, publicKey: publicKey)
    }
}
#endif
