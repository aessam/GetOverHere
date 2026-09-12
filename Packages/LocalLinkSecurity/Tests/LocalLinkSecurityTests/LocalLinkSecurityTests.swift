import CryptoKit
import Foundation
import Security
import Testing
@testable import LocalLinkSecurity

@Suite struct LocalLinkSecurityTests {
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
