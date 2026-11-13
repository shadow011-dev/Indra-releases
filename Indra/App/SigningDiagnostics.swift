import Foundation
import Security

/// v421: how this copy of Indra is signed, as macOS sees it. Whether the Automation prompt (and Indra's place in the
/// Privacy & Security > Automation list) works depends on this, and until now nothing showed it.
enum SigningDiagnostics {
    static let summary: String = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "signature: unreadable" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "signature: unreadable" }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "signature: unreadable" }
        let signatureFlags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let adhoc = signatureFlags & 0x2 != 0          // kSecCodeSignatureAdhoc
        let runtime = signatureFlags & 0x10000 != 0    // kSecCodeSignatureRuntime (hardened runtime)
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let appleEvents = (entitlements?["com.apple.security.automation.apple-events"] as? Bool) == true
        let identifier = (dict[kSecCodeInfoIdentifier as String] as? String) ?? "?"
        return "signature: \(adhoc ? "ad-hoc" : "identity"), hardened runtime: \(runtime ? "on" : "off"), "
            + "Apple Events entitlement: \(appleEvents ? "yes" : "no"), id \(identifier)"
    }()
}
