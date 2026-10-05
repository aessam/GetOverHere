import CryptoKit
import Foundation
import Security
import Testing
@testable import LocalLinkSecurity

@Suite struct LocalLinkSecurityTests {
    @Test func expiredStoredIdentityRenewsOnlyForANewEnrollment() throws {
        let account = "gateway-renewal-test-\(UUID().uuidString)"
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.aens.GetOverHere.LocalLinkSecurity", kSecAttrAccount: account]
        defer {
            let status = SecItemDelete(query as CFDictionary)
            #expect(status == errSecSuccess || status == errSecItemNotFound)
        }
        let now = Date()
        let expired = try LocalLinkIdentityStore.loadOrCreate(account: account, now: now.addingTimeInterval(-366 * 24 * 60 * 60))
        #expect(throws: LocalLinkSecurityError.self) { try LocalLinkIdentityStore.loadOrCreate(account: account, now: now) }
        let renewed = try LocalLinkIdentityStore.loadOrCreate(account: account, renewExpiredForEnrollment: true, now: now)
        #expect(renewed.certificateFingerprint != expired.certificateFingerprint)
        #expect(try LocalLinkIdentityStore.loadOrCreate(account: account).certificateFingerprint == renewed.certificateFingerprint)
        try renewed.validateValidity(now: now)
    }

    @Test func validityBoundariesFailClosed() throws {
        let issued = Date(timeIntervalSince1970: 1_000_000)
        let identity = try LocalLinkIdentity(privateKey: .init(), now: issued)
        try identity.validateValidity(now: issued.addingTimeInterval(-300))
        try identity.validateValidity(now: issued.addingTimeInterval(365 * 24 * 60 * 60 - 1))
        #expect(throws: LocalLinkSecurityError.self) { try identity.validateValidity(now: issued.addingTimeInterval(-301)) }
        #expect(throws: LocalLinkSecurityError.self) { try identity.validateValidity(now: issued.addingTimeInterval(365 * 24 * 60 * 60)) }
    }

    @Test func generatedIdentityMatchesKeyAndPin() throws {
        let key = P256.Signing.PrivateKey()
        let identity = try LocalLinkIdentity(privateKey: key)
        let certificate = try #require(SecCertificateCreateWithData(nil, identity.certificateDER as CFData))
        #expect(try LocalLinkIdentity.fingerprint(certificate: certificate) == identity.certificateFingerprint)
        #expect(identity.certificateFingerprint == Data(SHA256.hash(data: identity.certificateDER)))
        var privateKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity.identity, &privateKey) == errSecSuccess)
        #expect(privateKey != nil)
    }

    @Test func invalidPinCannotConfigureTLS() throws {
        let identity = try LocalLinkIdentity(privateKey: .init())
        #expect(throws: LocalLinkSecurityError.self) { try identity.tlsOptions(expectedPeerPin: Data(count: 31)) }
    }

    @Test func renewingCertificateRequiresNewPinButRestoringDoesNot() throws {
        let key = P256.Signing.PrivateKey()
        let first = try LocalLinkIdentity(privateKey: key)
        let second = try LocalLinkIdentity(privateKey: key)
        #expect(first.certificateDER != second.certificateDER)
        #expect(first.certificateFingerprint != second.certificateFingerprint)
        let restored = try LocalLinkIdentity(privateKey: key, certificateDER: first.certificateDER)
        #expect(first.certificateFingerprint == restored.certificateFingerprint)
    }
}
