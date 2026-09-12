import CryptoKit
import Foundation
import Network
import Security
import X509

public enum LocalLinkSecurityError: Error {
    case invalidIdentity, invalidPin, keychain(OSStatus)
}

/// A separate hub key. It must never be used to sign tour media or admit guests.
public struct LocalLinkIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificateDER: Data
    public let certificateFingerprint: Data

    public init(privateKey: P256.Signing.PrivateKey, certificateDER storedCertificate: Data? = nil, now: Date = Date()) throws {
        let key = Certificate.PrivateKey(privateKey)
        let subject = try DistinguishedName { CommonName("GetOverHere companion") }
        let certificate = try Certificate(version: .v3, serialNumber: .init(),
            publicKey: key.publicKey, notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: now.addingTimeInterval(365 * 24 * 60 * 60), issuer: subject,
            subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try .init {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            }, issuerPrivateKey: key)
        let secCertificate: SecCertificate
        if let storedCertificate {
            guard let value = SecCertificateCreateWithData(nil, storedCertificate as CFData) else {
                throw LocalLinkSecurityError.invalidIdentity
            }
            secCertificate = value
        } else { secCertificate = try SecCertificate.makeWithCertificate(certificate) }
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(privateKey.x963Representation as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ] as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw LocalLinkSecurityError.invalidIdentity
        }
        guard let identity = SecIdentityCreate(nil, secCertificate, secKey) else {
            throw LocalLinkSecurityError.invalidIdentity
        }
        self.identity = identity
        certificateDER = SecCertificateCopyData(secCertificate) as Data
        certificateFingerprint = Data(SHA256.hash(data: certificateDER))
    }

    /// Both platforms pin the full leaf DER. Certificate renewal requires reenrollment.
    public static func fingerprint(certificate: SecCertificate) throws -> Data {
        guard let key = SecCertificateCopyKey(certificate) else { throw LocalLinkSecurityError.invalidIdentity }
        var error: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(key, &error) as Data?,
              bytes.count == 65, bytes.first == 4 else {
            if let error { throw error.takeRetainedValue() }
            throw LocalLinkSecurityError.invalidIdentity
        }
        _ = try P256.Signing.PublicKey(x963Representation: bytes)
        return Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
    }

    public func tlsOptions(expectedPeerPin: Data) throws -> NWProtocolTLS.Options {
        guard expectedPeerPin.count == 32 else { throw LocalLinkSecurityError.invalidPin }
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_tls_tickets_enabled(security, false)
        guard let identity = sec_identity_create(identity) else { throw LocalLinkSecurityError.invalidIdentity }
        sec_protocol_options_set_local_identity(security, identity)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let certificate = chain.first,
                  let parsed = try? Certificate(certificate),
                  parsed.notValidBefore <= Date(), parsed.notValidAfter > Date(),
                  let actual = try? Self.fingerprint(certificate: certificate) else {
                complete(false); return
            }
            // Explicit out-of-band key pin is the trust anchor, not WebPKI/DNS.
            complete(zip(actual, expectedPeerPin).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0)
        }, DispatchQueue(label: "com.aens.GetOverHere.companion.trust"))
        return options
    }
}

public enum LocalLinkIdentityStore {
    private struct StoredIdentity: Codable { let privateKey: Data; let certificate: Data }
    /// Keychain lock errors fail closed; they never regenerate a silently different hub.
    public static func loadOrCreate(account: String = "companion-hub-v1") throws -> LocalLinkIdentity {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.aens.GetOverHere.LocalLinkSecurity", kSecAttrAccount: account]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData: true]) { _, new in new } as CFDictionary, &result)
        if status == errSecSuccess {
            guard let bytes = result as? Data else { throw LocalLinkSecurityError.invalidIdentity }
            let stored = try JSONDecoder().decode(StoredIdentity.self, from: bytes)
            return try LocalLinkIdentity(privateKey: .init(rawRepresentation: stored.privateKey), certificateDER: stored.certificate)
        }
        guard status == errSecItemNotFound else { throw LocalLinkSecurityError.keychain(status) }
        let key = P256.Signing.PrivateKey()
        let identity = try LocalLinkIdentity(privateKey: key)
        let stored = try JSONEncoder().encode(StoredIdentity(privateKey: key.rawRepresentation, certificate: identity.certificateDER))
        let insertion = query.merging([kSecValueData: stored,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new }
        let added = SecItemAdd(insertion as CFDictionary, nil)
        guard added == errSecSuccess else { throw LocalLinkSecurityError.keychain(added) }
        return identity
    }
}
