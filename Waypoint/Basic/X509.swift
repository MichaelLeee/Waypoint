//
//  X509.swift
//  Waypoint
//  Minimal ASN.1/DER writer issuing ECDSA-P256 certificates signed by a
//  Keychain-held SecKey. Security.framework creates keys but cannot issue
//  certificates, and we deliberately avoid pulling heavyweight crypto packages
//  just for our two fixed certificate shapes (self-signed root CA, server
//  leaf with SAN entries).
//

import CryptoKit
import Foundation
import Security

enum X509Error: LocalizedError {
    case signatureFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .signatureFailed(let status):
            return "X.509 signing failed (SecKeyCreateSignature \(status))"
        }
    }
}

enum X509 {
    // MARK: - DER primitives

    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out = [tag]
        var length = content.count
        if length < 0x80 {
            out.append(UInt8(length))
        } else {
            var encoded: [UInt8] = []
            while length > 0 {
                encoded.insert(UInt8(length & 0xff), at: 0)
                length >>= 8
            }
            out.append(UInt8(0x80 | encoded.count))
            out.append(contentsOf: encoded)
        }
        out.append(contentsOf: content)
        return out
    }

    private static func sequence(_ parts: [[UInt8]]) -> [UInt8] {
        tlv(0x30, parts.flatMap { $0 })
    }

    private static func set(_ content: [UInt8]) -> [UInt8] {
        tlv(0x31, content)
    }

    private static func integer(_ raw: [UInt8]) -> [UInt8] {
        var body = raw
        while body.count > 1, body.first == 0, (body[1] & 0x80) == 0 {
            body.removeFirst()
        }
        if let first = body.first, first & 0x80 != 0 {
            body.insert(0, at: 0)
        }
        return tlv(0x02, body)
    }

    private static func booleanTrue() -> [UInt8] {
        tlv(0x01, [0xff])
    }

    private static func null() -> [UInt8] {
        [0x05, 0x00]
    }

    private static func octetString(_ content: [UInt8]) -> [UInt8] {
        tlv(0x04, content)
    }

    private static func bitString(_ content: [UInt8], unusedBits: UInt8) -> [UInt8] {
        tlv(0x03, [unusedBits] + content)
    }

    private static func utf8String(_ string: String) -> [UInt8] {
        tlv(0x0c, Array(string.utf8))
    }

    private static func ia5String(_ string: String) -> [UInt8] {
        tlv(0x16, Array(string.utf8))
    }

    /// Context-specific constructed tag, used for version + subjectAltName.
    private static func contextConstructed(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        tlv(0xa0 | number, content)
    }

    private static func oidFromDotted(_ dotted: String) -> [UInt8] {
        var components = dotted.split(separator: ".").compactMap { UInt32($0) }
        guard !components.isEmpty else { return [] }
        let first = components.removeFirst()
        var bytes: [UInt8] = []
        if components.isEmpty {
            bytes.append(UInt8(first * 40))
        } else {
            let second = components.removeFirst()
            let combined = first * 40 + min(second, 39)
            bytes.append(UInt8(combined))
        }
        for component in components {
            var value = component
            var chunk: [UInt8] = [UInt8(value & 0x7f)]
            value >>= 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7f) | 0x80, at: 0)
                value >>= 7
            }
            bytes.append(contentsOf: chunk)
        }
        return tlv(0x06, bytes)
    }

    // MARK: - Object identifiers

    private enum OID {
        static let commonName = "2.5.4.3"
        static let basicConstraints = "2.5.29.19"
        static let keyUsage = "2.5.29.15"
        static let subjectAltName = "2.5.29.17"
        static let extendedKeyUsage = "2.5.29.37"
        static let serverAuth = "1.3.6.1.5.5.7.3.1"
        static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
        static let ecPublicKey = "1.2.840.10045.2.1"
        static let prime256v1 = "1.2.840.10045.3.1.7"
    }

    // MARK: - Building blocks

    private static func distinguishedName(commonName: String) -> [UInt8] {
        sequence([
            set(sequence([
                oidFromDotted(OID.commonName),
                utf8String(commonName),
            ])),
        ])
    }

    private static func signatureAlgorithm() -> [UInt8] {
        sequence([oidFromDotted(OID.ecdsaWithSHA256), null()])
    }

    /// subjectPublicKeyInfo for an uncompressed P-256 point (`external representation`).
    private static func publicKeyInfo(uncompressedPoint: [UInt8]) -> [UInt8] {
        sequence([
            sequence([oidFromDotted(OID.ecPublicKey), oidFromDotted(OID.prime256v1)]),
            bitString(uncompressedPoint, unusedBits: 0),
        ])
    }

    private static func utctime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return tlv(0x17, Array(formatter.string(from: date).utf8))
    }

    private static func extensionItem(_ identifier: String, critical: Bool, value: [UInt8]) -> [UInt8] {
        var fields = [oidFromDotted(identifier)]
        if critical {
            fields.append(booleanTrue())
        }
        fields.append(octetString(value))
        return sequence(fields)
    }

    private static func serialBytes() -> [UInt8] {
        var serial = [UInt8]()
        for _ in 0 ..< 16 {
            serial.append(UInt8.random(in: 0 ... 255))
        }
        serial[0] &= 0x7f // keep positive
        if serial[0] == 0 {
            serial[0] = 0x01
        }
        return serial
    }

    // MARK: - TBS construction

    struct Template {
        let commonName: String
        let isCertificateAuthority: Bool
        let dnsNames: [String]

        init(commonName: String, isCertificateAuthority: Bool, dnsNames: [String] = []) {
            self.commonName = commonName
            self.isCertificateAuthority = isCertificateAuthority
            self.dnsNames = dnsNames
        }
    }

    /// Builds the `tbsCertificate` blob for `template`, wrapped around
    /// `uncompressedPoint` as public key. Validity spans ±10 years for CAs
    /// capped at 2049 so UTCTime stays valid.
    static func buildTBSCertificate(template: Template, uncompressedPoint: [UInt8]) -> [UInt8] {
        let now = Date()
        let tenYears = TimeInterval(3650 * 24 * 60 * 60)
        let notBefore = now.addingTimeInterval(-60 * 60 * 24)
        var notAfter = now.addingTimeInterval(tenYears)
        if Calendar.current.component(.year, from: notAfter) > 2049 {
            notAfter = Calendar.current.date(bySetting: .year, value: 2049, of: notAfter)!
        }

        var extensions: [[UInt8]] = []
        if template.isCertificateAuthority {
            extensions.append(extensionItem(
                OID.basicConstraints,
                critical: true,
                value: sequence([booleanTrue()])
            ))
            extensions.append(extensionItem(
                OID.keyUsage,
                critical: true,
                value: bitString([0x06], unusedBits: 1) // keyCertSign | cRLSign
            ))
        } else {
            extensions.append(extensionItem(
                OID.keyUsage,
                critical: false,
                value: bitString([0x80], unusedBits: 7) // digitalSignature
            ))
            extensions.append(extensionItem(
                OID.extendedKeyUsage,
                critical: false,
                value: sequence([oidFromDotted(OID.serverAuth)])
            ))
            let names = template.dnsNames.map { contextConstructed(2, ia5String($0)) }
            if !names.isEmpty {
                extensions.append(extensionItem(
                    OID.subjectAltName,
                    critical: false,
                    value: sequence(names)
                ))
            }
        }

        let name = distinguishedName(commonName: template.commonName)
        return sequence([
            contextConstructed(0, integer([0x02])), // v3
            integer(serialBytes()),
            signatureAlgorithm(),
            name, // issuer == subject (self-signed)
            sequence([utctime(notBefore), utctime(notAfter)]),
            name,
            publicKeyInfo(uncompressedPoint: uncompressedPoint),
            contextConstructed(3, sequence(extensions)),
        ])
    }

    private static func statusCode(of error: Unmanaged<CFError>?) -> OSStatus {
        guard let error else { return -1 }
        return OSStatus(CFErrorGetCode(error.takeRetainedValue()))
    }

    /// Signs a TBS blob with a P-256 SecKey and returns full certificate DER.
    static func sign(tbs: [UInt8], privateKey: SecKey) throws -> Data {
        let digest = SHA256.hash(data: Data(tbs))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureDigestX962SHA256,
            Data(digest) as CFData,
            &error
        ) else {
            throw X509Error.signatureFailed(statusCode(of: error))
        }
        // Convert DER-encoded r||s into the 64-byte concatenation form.
        let der = [UInt8](signature as Data)
        let (r, s) = parseTwoIntegers(der)
        var padded: [UInt8] = []
        for scalar in [r, s] {
            let trimmed = scalar.reversed().drop { $0 == 0 }.reversed()
            var fixed = [UInt8](trimmed.suffix(32))
            while fixed.count < 32 {
                fixed.insert(0, at: 0)
            }
            padded.append(contentsOf: fixed)
        }
        let certificate = sequence([
            tbs,
            signatureAlgorithm(),
            bitString(padded, unusedBits: 0),
        ])
        return Data(certificate)
    }

    private static func parseTwoIntegers(_ der: [UInt8]) -> ([UInt8], [UInt8]) {
        // DER SEQUENCE { INTEGER r, INTEGER s } — minimal scan, trusted input.
        guard der.count > 3, der[0] == 0x30 else { return ([1], [1]) }
        var position = 2 // skip tag + length (signature DER always short-form)
        var scalars: [[UInt8]] = []
        while scalars.count < 2 && position < der.count {
            guard der[position] == 0x02 else { break }
            let length = Int(der[position + 1])
            scalars.append(Array(der[(position + 2) ..< (position + 2 + length)]))
            position += 2 + length
        }
        while scalars.count < 2 {
            scalars.append([1])
        }
        return (scalars[0], scalars[1])
    }
}
