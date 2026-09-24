import Crypto
import Foundation
import Network
import NIOSSL
import SwiftASN1
import X509

/// Owns the local root CA and mints a leaf certificate per intercepted host.
final class CertificateAuthority: @unchecked Sendable {
    let certificate: Certificate
    let certificatePEM: String
    let certificateDER: [UInt8]
    let certificateURL: URL

    private let privateKey: Certificate.PrivateKey
    private let leafKeyPEM: String
    private let lock = NSLock()
    private var contexts: [String: NIOSSLContext] = [:]

    static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NetworkMonitor", isDirectory: true)
    }()

    init(directory: URL = CertificateAuthority.defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certURL = directory.appendingPathComponent("ca.pem")
        let keyURL = directory.appendingPathComponent("ca-key.pem")

        if let certPEM = try? String(contentsOf: certURL, encoding: .utf8),
           let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8) {
            certificate = try Certificate(pemEncoded: certPEM)
            privateKey = Certificate.PrivateKey(try P256.Signing.PrivateKey(pemRepresentation: keyPEM))
        } else {
            let p256 = P256.Signing.PrivateKey()
            let key = Certificate.PrivateKey(p256)
            let cert = try Self.makeRootCertificate(key: key)
            try cert.serializeAsPEM().pemString.write(to: certURL, atomically: true, encoding: .utf8)
            try p256.pemRepresentation.write(to: keyURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            certificate = cert
            privateKey = key
        }

        certificateURL = certURL
        certificatePEM = try certificate.serializeAsPEM().pemString
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        certificateDER = serializer.serializedBytes
        leafKeyPEM = P256.Signing.PrivateKey().pemRepresentation
    }

    func sslContext(for host: String) throws -> NIOSSLContext {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if let cached = contexts[key] { return cached }

        let leaf = try makeLeafCertificate(host: key)
        let leafPEM = try leaf.serializeAsPEM().pemString
        let certificate = try NIOSSLCertificate(bytes: Array(leafPEM.utf8), format: .pem)
        let privateKey = try NIOSSLPrivateKey(bytes: Array(leafKeyPEM.utf8), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(privateKey)
        )
        configuration.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: configuration)
        contexts[key] = context
        return context
    }

    // MARK: - Certificate generation

    private static func makeRootCertificate(key: Certificate.PrivateKey) throws -> Certificate {
        let name = try DistinguishedName {
            CommonName("Network Monitor Root CA")
            OrganizationName("Lumiform Dev")
        }
        let now = Date()
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            SubjectKeyIdentifier(hash: key.publicKey)
        }
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(10 * 365 * 86400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: key
        )
    }

    private func makeLeafCertificate(host: String) throws -> Certificate {
        let now = Date()
        let leafKey = try P256.Signing.PrivateKey(pemRepresentation: leafKeyPEM)
        let subject = try DistinguishedName { CommonName(host) }
        let altName: GeneralName
        if let ip = IPv4Address(host) {
            altName = .ipAddress(ASN1OctetString(contentBytes: ArraySlice(ip.rawValue)))
        } else {
            altName = .dnsName(host)
        }
        let authorityKeyID = try certificate.extensions.subjectKeyIdentifier?.keyIdentifier
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([altName])
            AuthorityKeyIdentifier(keyIdentifier: authorityKeyID)
        }
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(397 * 86400),
            issuer: certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: privateKey
        )
    }
}
