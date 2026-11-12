import CryptoKit
import Darwin
import Foundation
import Security
import SystemConfiguration

/// Where SimTool keeps what opening a server to the network needs from one
/// run to the next: its certificate authority, which the devices that open the
/// viewer trust once, and the access key they enter once. Per user, never in a
/// project: `SIMTOOL_NETWORK_HOME` moves it (tests, a CI machine's own place).
public enum LocalNetworkHome {
    public static let environmentVariable = "SIMTOOL_NETWORK_HOME"

    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment[environmentVariable], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("SimTool/network", isDirectory: true)
    }

    /// The directory, readable by its owner alone.
    static func ensure(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Writes a secret only its owner may read.
    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The key a device on the network enters once to use a SimTool server: the
/// viewer, its input and everything it reads (requests, tokens and logs
/// included) are behind it. One per Mac, kept until renewed, so a bookmarked
/// address keeps working across restarts; `SIMTOOL_ACCESS_KEY` sets it instead.
///
/// Twelve characters from 32 that cannot be mistaken for one another on a
/// phone's keyboard — 60 bits — written in groups of four: `k7fm-2qpx-9td3`.
/// Case, dashes and spaces do not matter when it is entered.
public enum NetworkAccessKey {
    public static let environmentVariable = "SIMTOOL_ACCESS_KEY"
    private static let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
    private static let fileName = "access-key"

    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        let characters = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: characters.count, by: 4).map { String(characters[$0..<min($0 + 4, characters.count)]) }.joined(separator: "-")
    }

    /// The key from the environment, else the one kept in `directory`, else a
    /// new one, kept there.
    public static func load(in directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let given = environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
            return given
        }
        let url = directory.appendingPathComponent(fileName)
        if let kept = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !kept.isEmpty {
            return kept
        }
        return try renew(in: directory)
    }

    /// Replaces the kept key: every device enters the new one.
    @discardableResult
    public static func renew(in directory: URL) throws -> String {
        try LocalNetworkHome.ensure(directory)
        let key = generate()
        try LocalNetworkHome.writePrivate(Data((key + "\n").utf8), to: directory.appendingPathComponent(fileName))
        return key
    }

    /// Whether `candidate` is the key, as a person may type it, compared in
    /// constant time.
    public static func matches(_ candidate: String, _ key: String) -> Bool {
        let given = Array(normalized(candidate).utf8), expected = Array(normalized(key).utf8)
        guard !expected.isEmpty, given.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= given[index] ^ expected[index] }
        return difference == 0
    }

    /// The key without case, dashes or spaces — `+` too: a form sends a
    /// space in the address as `+`.
    public static func normalized(_ key: String) -> String {
        key.lowercased().filter { $0 != "-" && $0 != "+" && !$0.isWhitespace }
    }
}

/// The names and addresses this Mac is reached by on the network, as a device
/// on the same Wi-Fi would write them.
public struct MacNetworkAddresses: Equatable, Sendable {
    /// The Bonjour name, `<name>.local`.
    public var localHostName: String?
    /// IPv4 addresses of the interfaces that are up, Wi-Fi and Ethernet first;
    /// no loopback.
    public var ipv4: [String]

    public init(localHostName: String?, ipv4: [String]) {
        self.localHostName = localHostName
        self.ipv4 = ipv4
    }

    /// The address to offer first: the first one on Wi-Fi or Ethernet that is
    /// not link-local, else any.
    public var primaryIPv4: String? {
        ipv4.first { !$0.hasPrefix("169.254.") } ?? ipv4.first
    }

    public static func current() -> MacNetworkAddresses {
        let name = (SCDynamicStoreCopyLocalHostName(nil) as String?).flatMap { $0.isEmpty ? nil : $0 + ".local" }
        return MacNetworkAddresses(localHostName: name, ipv4: interfaceAddresses())
    }

    /// The address of every IPv4 interface that is up, the physical ones
    /// (`en…`) first, in the order the system lists them.
    static func interfaceAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            let name = String(cString: entry.pointee.ifa_name)
            if !found.contains(where: { $0.address == text }) { found.append((name, text)) }
        }
        let physical = found.filter { $0.name.hasPrefix("en") }
        let other = found.filter { !$0.name.hasPrefix("en") }
        return (physical + other).map(\.address)
    }
}

/// A TLS server identity, ready for a listener: the private key with its
/// certificate, the certificates that lead to a root, the names and
/// addresses the certificate is for — and, when SimTool issued it, the
/// authority a device installs to trust it.
public struct NetworkServerIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    /// The chain after the server's own certificate, sent along with it.
    public let chain: [SecCertificate]
    /// DNS names the certificate covers, lowercased.
    public let names: [String]
    /// IP addresses it covers.
    public let addresses: [String]
    /// SimTool's local certificate authority (DER) — nil for a certificate
    /// someone else issued.
    public let authority: Data?

    /// The authority's SHA-256 fingerprint as iOS and Keychain Access show it
    /// (`3F 9A …`): downloaded over plain HTTP, the certificate is checked
    /// against the one this Mac prints before a device trusts it.
    public var authorityFingerprint: String? {
        authority.map { SHA256.hash(data: $0).map { String(format: "%02X", $0) }.joined(separator: " ") }
    }

    public init(identity: SecIdentity, chain: [SecCertificate], names: [String], addresses: [String], authority: Data?) {
        self.identity = identity
        self.chain = chain
        self.names = names
        self.addresses = addresses
        self.authority = authority
    }

    /// A certificate and key someone else issued — a name the company's
    /// browsers trust — read from PEM files; the certificate file may hold
    /// the chain after it.
    public static func load(certificate: URL, key: URL) async throws -> NetworkServerIdentity {
        for file in [certificate, key] where !FileManager.default.isReadableFile(atPath: file.path) {
            throw SimToolError("Cannot read \(file.path)")
        }
        let work = try OpenSSL.workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let passphrase = NetworkAccessKey.generate()
        let bundle = work.appendingPathComponent("server.p12")
        try await OpenSSL.run(["pkcs12", "-export", "-in", certificate.path, "-inkey", key.path, "-passout", "pass:\(passphrase)", "-out", bundle.path])
        let (identity, chain) = try importPKCS12(try Data(contentsOf: bundle), passphrase: passphrase)
        let covered = try await OpenSSL.subjectAlternativeNames(of: certificate)
        return NetworkServerIdentity(identity: identity, chain: chain, names: covered.names, addresses: covered.addresses, authority: nil)
    }

    /// The identity and the rest of its chain from a PKCS#12 bundle, kept in
    /// this process alone — nothing is added to a keychain.
    static func importPKCS12(_ data: Data, passphrase: String) throws -> (SecIdentity, [SecCertificate]) {
        guard #available(macOS 15.0, *) else {
            throw SimToolError("Opening SimTool to the network needs macOS 15 or later.")
        }
        var items: CFArray?
        let options = [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true] as [CFString: Any]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let entries = items as? [[String: Any]], let first = entries.first,
              let identityValue = first[kSecImportItemIdentity as String] else {
            throw SimToolError("Could not read the server certificate and key (\(SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")).")
        }
        // swiftlint:disable:next force_cast
        let identity = identityValue as! SecIdentity
        var leaf: SecCertificate?
        SecIdentityCopyCertificate(identity, &leaf)
        let leafData = leaf.map { SecCertificateCopyData($0) as Data }
        let chain = ((first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []).filter { SecCertificateCopyData($0) as Data != leafData }
        return (identity, chain)
    }
}

/// SimTool's own certificate authority on this Mac. A device trusts it once —
/// installs it and turns trust on — and then every certificate SimTool issues
/// for this Mac's names opens without a warning, whatever its address is
/// that day. It may vouch for local names and private addresses only (name
/// constraints): a copy of its key could not impersonate any public site to
/// the devices that trust it. Its key never leaves this Mac.
public struct LocalCertificateAuthority: Sendable {
    public let certificateURL: URL
    let keyURL: URL

    /// What the authority may vouch for: Bonjour and loopback names, and the
    /// private, link-local, shared (CGNAT, VPN) and loopback IPv4 ranges.
    static let permitted = [
        "DNS:local", "DNS:localhost",
        "IP:10.0.0.0/255.0.0.0", "IP:172.16.0.0/255.240.0.0", "IP:192.168.0.0/255.255.0.0",
        "IP:169.254.0.0/255.255.0.0", "IP:100.64.0.0/255.192.0.0", "IP:127.0.0.0/255.0.0.0",
    ]

    /// Whether the authority may vouch for this name or IPv4 address.
    public static func mayCover(_ name: String) -> Bool {
        var address = in_addr()
        if inet_pton(AF_INET, name, &address) == 1 {
            let value = UInt32(bigEndian: address.s_addr)
            let ranges: [(UInt32, UInt32)] = [
                (0x0A00_0000, 0xFF00_0000), (0xAC10_0000, 0xFFF0_0000), (0xC0A8_0000, 0xFFFF_0000),
                (0xA9FE_0000, 0xFFFF_0000), (0x6440_0000, 0xFFC0_0000), (0x7F00_0000, 0xFF00_0000),
            ]
            return ranges.contains { value & $0.1 == $0.0 }
        }
        let lower = name.lowercased()
        return lower == "localhost" || (lower.hasSuffix(".local") && lower.count > ".local".count)
    }

    /// The authority kept in `directory`, made there the first time.
    public static func loadOrCreate(in directory: URL, label: String) async throws -> LocalCertificateAuthority {
        let authority = LocalCertificateAuthority(
            certificateURL: directory.appendingPathComponent("simtool-ca.pem"),
            keyURL: directory.appendingPathComponent("simtool-ca-key.pem")
        )
        let manager = FileManager.default
        if manager.fileExists(atPath: authority.certificateURL.path), manager.fileExists(atPath: authority.keyURL.path) {
            return authority
        }
        try LocalNetworkHome.ensure(directory)
        let work = try OpenSSL.workDirectory()
        defer { try? manager.removeItem(at: work) }
        let key = work.appendingPathComponent("ca-key.pem")
        let certificate = work.appendingPathComponent("ca.pem")
        try await OpenSSL.run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
        try await OpenSSL.run([
            "req", "-x509", "-new", "-key", key.path, "-sha256", "-days", "3650",
            "-subj", "/O=SimTool/CN=\(OpenSSL.subjectValue("SimTool local CA (\(label))"))",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-addext", "subjectKeyIdentifier=hash",
            "-addext", "nameConstraints=critical," + permitted.map { "permitted;" + $0 }.joined(separator: ","),
            "-out", certificate.path,
        ])
        try LocalNetworkHome.writePrivate(try Data(contentsOf: key), to: authority.keyURL)
        try Data(contentsOf: certificate).write(to: authority.certificateURL, options: [.atomic])
        return authority
    }

    /// The authority's certificate as a device downloads it (DER).
    public func certificateDER() throws -> Data {
        try OpenSSL.der(fromPEM: String(contentsOf: certificateURL, encoding: .utf8))
    }

    /// A server certificate for `names` (DNS) and `addresses` (IPv4), signed
    /// by this authority, with a fresh key — whatever this authority may not
    /// vouch for left out. Valid 397 days, inside what Apple's platforms
    /// accept for a TLS server certificate.
    public func issue(names: [String], addresses: [String]) async throws -> NetworkServerIdentity {
        let dnsNames = Self.unique(names.map { $0.lowercased() }.filter(Self.mayCover))
        let ips = Self.unique(addresses.filter(Self.mayCover))
        guard let commonName = dnsNames.first ?? ips.first else {
            throw SimToolError("No name or address of this Mac can carry a SimTool certificate.")
        }
        let work = try OpenSSL.workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let key = work.appendingPathComponent("server-key.pem")
        let request = work.appendingPathComponent("server.csr")
        let certificate = work.appendingPathComponent("server.pem")
        let extensions = work.appendingPathComponent("server.ext")
        let bundle = work.appendingPathComponent("server.p12")
        try await OpenSSL.run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
        try await OpenSSL.run(["req", "-new", "-key", key.path, "-subj", "/O=SimTool/CN=\(OpenSSL.subjectValue(commonName))", "-out", request.path])
        let alternativeNames = dnsNames.map { "DNS:" + $0 } + ips.map { "IP:" + $0 }
        try Data("""
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature
        extendedKeyUsage=serverAuth
        subjectAltName=\(alternativeNames.joined(separator: ","))
        authorityKeyIdentifier=keyid
        subjectKeyIdentifier=hash

        """.utf8).write(to: extensions)
        try await OpenSSL.run([
            "x509", "-req", "-in", request.path, "-CA", certificateURL.path, "-CAkey", keyURL.path,
            "-set_serial", OpenSSL.randomSerial(), "-days", "397", "-sha256",
            "-extfile", extensions.path, "-out", certificate.path,
        ])
        let passphrase = NetworkAccessKey.generate()
        try await OpenSSL.run([
            "pkcs12", "-export", "-inkey", key.path, "-in", certificate.path, "-certfile", certificateURL.path,
            "-passout", "pass:\(passphrase)", "-out", bundle.path,
        ])
        let (identity, chain) = try NetworkServerIdentity.importPKCS12(try Data(contentsOf: bundle), passphrase: passphrase)
        return NetworkServerIdentity(identity: identity, chain: chain, names: dnsNames, addresses: ips, authority: try certificateDER())
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// The `openssl` macOS ships (LibreSSL): what makes keys, certificates and
/// PKCS#12 bundles here, so SimTool carries no crypto library of its own.
enum OpenSSL {
    static let executable = URL(fileURLWithPath: "/usr/bin/openssl")

    static func run(_ arguments: [String]) async throws {
        let output = try await ProcessRunner.run(executable: executable, arguments: arguments, timeoutSeconds: 30)
        guard output.status == 0 else {
            let detail = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimToolError("openssl \(arguments.first ?? "") failed\(detail.isEmpty ? "" : ": " + detail)")
        }
    }

    /// A private scratch directory for keys on their way into memory.
    static func workDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-tls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// A positive 128-bit serial number, as `-set_serial` takes it.
    static func randomSerial() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] = (bytes[0] & 0x7F) | 0x10
        return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// A value for `-subj`: its separators taken out.
    static func subjectValue(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "=", with: "-")
    }

    static func der(fromPEM pem: String) throws -> Data {
        let body = pem.components(separatedBy: "\n")
            .drop { !$0.hasPrefix("-----BEGIN CERTIFICATE-----") }
            .dropFirst()
            .prefix { !$0.hasPrefix("-----END") }
            .joined()
        guard let data = Data(base64Encoded: body), !data.isEmpty else { throw SimToolError("Not a PEM certificate") }
        return data
    }

    /// The DNS names and IP addresses a certificate is for.
    static func subjectAlternativeNames(of certificate: URL) async throws -> (names: [String], addresses: [String]) {
        let output = try await ProcessRunner.run(executable: executable, arguments: ["x509", "-noout", "-text", "-in", certificate.path], timeoutSeconds: 30)
        guard output.status == 0 else { throw SimToolError("Cannot read the certificate \(certificate.path)") }
        return parseAlternativeNames(output.stdoutString)
    }

    /// `DNS:a.example, IP Address:10.0.0.2` from `openssl x509 -text`.
    static func parseAlternativeNames(_ text: String) -> (names: [String], addresses: [String]) {
        var names: [String] = [], addresses: [String] = []
        for part in text.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let item = part.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("DNS:") { names.append(String(item.dropFirst(4)).lowercased()) }
            if item.hasPrefix("IP Address:") { addresses.append(String(item.dropFirst(11))) }
        }
        return (names, addresses)
    }
}
