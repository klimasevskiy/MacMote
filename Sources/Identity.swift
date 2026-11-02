import Foundation
import Security

/// Client TLS identity the TV remembers after pairing. Generated once with the system LibreSSL.
enum ClientIdentity {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacMote", isDirectory: true)
    private static let p12 = dir.appendingPathComponent("client.p12")
    private static let pass = "macmote"

    static func load() throws -> SecIdentity {
        if !FileManager.default.fileExists(atPath: p12.path) { try generate() }
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let opts: [String: Any] = [
            kSecImportExportPassphrase as String: pass,
            kSecImportToMemoryOnly as String: true,
        ]
        let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let ident = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "MacMote", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Не вдалося завантажити сертифікат (\(status))"])
        }
        return (ident as! SecIdentity)
    }

    static func reset() { try? FileManager.default.removeItem(at: p12) }

    private static func generate() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = dir.appendingPathComponent("key.pem").path
        let cert = dir.appendingPathComponent("cert.pem").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert,
                 "-days", "7300", "-nodes", "-subj", "/CN=MacMote"])
        try run(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12.path,
                 "-passout", "pass:\(pass)"])
        try? FileManager.default.removeItem(atPath: key)
        try? FileManager.default.removeItem(atPath: cert)
    }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "MacMote", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl завершився з помилкою"])
        }
    }

    /// RSA modulus and exponent (leading zeros stripped) parsed from the PKCS#1 public key.
    static func rsaComponents(of cert: SecCertificate) -> (n: Data, e: Data)? {
        guard let key = SecCertificateCopyKey(cert),
              let ext = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let b = [UInt8](ext)
        var i = 0
        func len() -> Int? {
            guard i < b.count else { return nil }
            var l = Int(b[i]); i += 1
            if l & 0x80 != 0 {
                let n = l & 0x7F; l = 0
                for _ in 0..<n { guard i < b.count else { return nil }; l = l << 8 | Int(b[i]); i += 1 }
            }
            return l
        }
        func integer() -> Data? {
            guard i < b.count, b[i] == 0x02 else { return nil }
            i += 1
            guard let l = len(), i + l <= b.count else { return nil }
            var d = Array(b[i..<i + l]); i += l
            while d.count > 1 && d[0] == 0 { d.removeFirst() }
            return Data(d)
        }
        guard b.first == 0x30 else { return nil }
        i = 1
        guard len() != nil, let n = integer(), let e = integer() else { return nil }
        return (n, e)
    }
}
