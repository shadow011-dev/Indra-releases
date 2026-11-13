import Foundation
import Security
import CryptoKit
import CommonCrypto

enum FaceLockSecrets {
    private static let service = "com.indra.Indra.facelock.gate"
    private static let account = "password"

    static var hasPassword: Bool { load() != nil }

    static func removePassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// New format: 1 version byte (2) + 16 byte salt + 32 byte PBKDF2-HMAC-SHA256 key. The old format (48 bytes, repeated
    /// SHA-256) is still accepted and upgraded the first time the right password is entered.
    static func setPassword(_ password: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = pbkdf2(password, salt: salt)
        guard key.count == 32 else { return }
        save(Data([2]) + salt + key)
    }

    static func verify(_ password: String) -> Bool {
        guard let blob = load() else { return false }
        if blob.count == 49, blob.first == 2 {
            let salt = Data(blob.dropFirst().prefix(16))
            return constantTimeEqual(pbkdf2(password, salt: salt), Data(blob.suffix(32)))
        }
        guard blob.count == 48 else { return false }
        let salt = Data(blob.prefix(16))
        guard constantTimeEqual(hash(password, salt: salt), Data(blob.suffix(32))) else { return false }
        setPassword(password)   // upgrade the old format now that the password is known
        return true
    }

    private static func pbkdf2(_ password: String, salt: Data) -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000,
            &derived, derived.count)
        return status == Int32(kCCSuccess) ? Data(derived) : Data()
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    private static func hash(_ password: String, salt: Data) -> Data {
        var digest = salt + Data(password.utf8)
        for _ in 0..<100_000 { digest = Data(SHA256.hash(data: digest)) }
        return digest
    }

    private static func save(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}