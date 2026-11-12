import Foundation
import Security
@testable import SimToolCore
import XCTest

// What opening a server to the network rests on: a key a person can type on a
// phone, and certificates Apple's TLS accepts for this Mac's local names and
// addresses — and for nothing else.
final class LocalNetworkTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-network-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - The access key

    func testAKeyIsTwelveUnmistakableCharactersInGroupsOfFour() {
        let key = NetworkAccessKey.generate()
        let groups = key.split(separator: "-")
        XCTAssertEqual(groups.map(\.count), [4, 4, 4], key)
        for character in key where character != "-" {
            XCTAssertFalse("01lo".contains(character), "\(character) reads like another character on a phone: \(key)")
        }
        XCTAssertNotEqual(NetworkAccessKey.generate(), NetworkAccessKey.generate())
    }

    func testTheKeyMatchesAsAPersonTypesIt() {
        XCTAssertTrue(NetworkAccessKey.matches("k7fm-2qpx-9td3", "k7fm-2qpx-9td3"))
        XCTAssertTrue(NetworkAccessKey.matches("K7FM 2QPX 9TD3", "k7fm-2qpx-9td3"))
        XCTAssertTrue(NetworkAccessKey.matches("k7fm2qpx9td3", "k7fm-2qpx-9td3"))
        XCTAssertTrue(NetworkAccessKey.matches("k7fm+2qpx+9td3", "k7fm-2qpx-9td3"), "a form's spaces")
        XCTAssertFalse(NetworkAccessKey.matches("k7fm-2qpx-9td4", "k7fm-2qpx-9td3"))
        XCTAssertFalse(NetworkAccessKey.matches("k7fm-2qpx", "k7fm-2qpx-9td3"))
        XCTAssertFalse(NetworkAccessKey.matches("", ""), "no key admits nobody")
    }

    func testTheKeyIsKeptPrivateAndStaysUntilRenewed() throws {
        let first = try NetworkAccessKey.load(in: home, environment: [:])
        XCTAssertEqual(try NetworkAccessKey.load(in: home, environment: [:]), first, "a bookmarked address keeps working across restarts")
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("access-key").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let renewed = try NetworkAccessKey.renew(in: home)
        XCTAssertNotEqual(renewed, first)
        XCTAssertEqual(try NetworkAccessKey.load(in: home, environment: [:]), renewed)
        XCTAssertEqual(try NetworkAccessKey.load(in: home, environment: ["SIMTOOL_ACCESS_KEY": " ci-key "]), "ci-key", "the environment wins")
    }

    func testTheHomeMovesWithTheEnvironment() {
        XCTAssertEqual(LocalNetworkHome.directory(environment: ["SIMTOOL_NETWORK_HOME": "/tmp/x"]).path, "/tmp/x")
        XCTAssertTrue(LocalNetworkHome.directory(environment: [:]).path.hasSuffix("Application Support/SimTool/network"))
    }

    // MARK: - SimTool's certificate authority

    func testTheAuthorityVouchesForLocalNamesAndPrivateAddressesOnly() {
        for name in ["my-mac.local", "MY-MAC.LOCAL", "localhost", "192.168.1.27", "10.0.0.2", "172.20.16.97", "169.254.3.4", "100.64.1.1", "127.0.0.1"] {
            XCTAssertTrue(LocalCertificateAuthority.mayCover(name), name)
        }
        for name in [".local", "local", "simtool.example.com", "8.8.8.8", "172.32.0.1", "my-mac", "::1"] {
            XCTAssertFalse(LocalCertificateAuthority.mayCover(name), name)
        }
    }

    // The same trust evaluation an iPhone runs (trustd): the certificate
    // opens for the Mac's name, its address and localhost, with SimTool's
    // authority as the only anchor.
    func testAnIssuedCertificateIsTrustedForTheMacsNameAndAddress() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs macOS 15") }
        let authority = try await LocalCertificateAuthority.loadOrCreate(in: home, label: "test-mac")
        let issued = try await authority.issue(names: ["Test-Mac.local", "localhost", "public.example.com"], addresses: ["192.168.1.27", "127.0.0.1", "8.8.8.8"])
        XCTAssertEqual(issued.names, ["test-mac.local", "localhost"], "what the authority may not vouch for is left out")
        XCTAssertEqual(issued.addresses, ["192.168.1.27", "127.0.0.1"])
        let anchor = try XCTUnwrap(SecCertificateCreateWithData(nil, try authority.certificateDER() as CFData))
        XCTAssertEqual(issued.authority, try authority.certificateDER())
        let fingerprint = try XCTUnwrap(issued.authorityFingerprint)
        XCTAssertEqual(fingerprint.split(separator: " ").count, 32, "SHA-256, byte by byte as iOS shows it: \(fingerprint)")
        XCTAssertEqual(fingerprint, fingerprint.uppercased())
        for host in ["test-mac.local", "192.168.1.27", "localhost"] {
            XCTAssertNil(try trustFailure(issued, anchor: anchor, host: host), host)
        }
        XCTAssertNotNil(try trustFailure(issued, anchor: anchor, host: "other.local"), "a name the certificate is not for")

        // A second run finds the same authority: devices that trust it keep doing so.
        let again = try await LocalCertificateAuthority.loadOrCreate(in: home, label: "test-mac")
        XCTAssertEqual(try again.certificateDER(), try authority.certificateDER())
        let keyAttributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("simtool-ca-key.pem").path)
        XCTAssertEqual((keyAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // A copy of the authority's key could not impersonate a public site to a
    // device that trusts it: its name constraints keep it to local names.
    func testTheAuthorityCannotVouchForAPublicName() async throws {
        let authority = try await LocalCertificateAuthority.loadOrCreate(in: home, label: "test-mac")
        let work = try OpenSSL.workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let key = work.appendingPathComponent("k.pem"), request = work.appendingPathComponent("r.csr")
        let certificate = work.appendingPathComponent("c.pem"), extensions = work.appendingPathComponent("e.ext")
        try await OpenSSL.run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
        try await OpenSSL.run(["req", "-new", "-key", key.path, "-subj", "/CN=www.example.com", "-out", request.path])
        try Data("extendedKeyUsage=serverAuth\nsubjectAltName=DNS:www.example.com\n".utf8).write(to: extensions)
        try await OpenSSL.run(["x509", "-req", "-in", request.path, "-CA", authority.certificateURL.path, "-CAkey", authority.keyURL.path,
                               "-set_serial", "7", "-days", "30", "-sha256", "-extfile", extensions.path, "-out", certificate.path])
        let forged = try XCTUnwrap(SecCertificateCreateWithData(nil, try OpenSSL.der(fromPEM: String(contentsOf: certificate, encoding: .utf8)) as CFData))
        let anchor = try XCTUnwrap(SecCertificateCreateWithData(nil, try authority.certificateDER() as CFData))
        XCTAssertNotNil(evaluate([forged, anchor], anchor: anchor, host: "www.example.com"))
    }

    // A certificate someone else issued (the company's, for a CI Mac's DNS
    // name) is read from PEM files, with the names it is for.
    func testAProvidedCertificateIsReadWithItsNames() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs macOS 15") }
        let authority = try await LocalCertificateAuthority.loadOrCreate(in: home, label: "test-mac")
        let work = try OpenSSL.workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let key = work.appendingPathComponent("server-key.pem"), request = work.appendingPathComponent("r.csr")
        let certificate = work.appendingPathComponent("server.pem"), extensions = work.appendingPathComponent("e.ext")
        try await OpenSSL.run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
        try await OpenSSL.run(["req", "-new", "-key", key.path, "-subj", "/CN=ci-mac.local", "-out", request.path])
        try Data("extendedKeyUsage=serverAuth\nsubjectAltName=DNS:ci-mac.local,IP:10.1.2.3\n".utf8).write(to: extensions)
        try await OpenSSL.run(["x509", "-req", "-in", request.path, "-CA", authority.certificateURL.path, "-CAkey", authority.keyURL.path,
                               "-set_serial", "9", "-days", "30", "-sha256", "-extfile", extensions.path, "-out", certificate.path])
        let loaded = try await NetworkServerIdentity.load(certificate: certificate, key: key)
        XCTAssertEqual(loaded.names, ["ci-mac.local"])
        XCTAssertEqual(loaded.addresses, ["10.1.2.3"])
        XCTAssertNil(loaded.authority, "SimTool offers only its own authority for download")
        var leaf: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(loaded.identity, &leaf), errSecSuccess)

        do {
            _ = try await NetworkServerIdentity.load(certificate: work.appendingPathComponent("missing.pem"), key: key)
            XCTFail("a missing file must say so")
        } catch {
            XCTAssertTrue("\(error)".contains("missing.pem"), "\(error)")
        }
    }

    func testAlternativeNamesAreReadFromOpenSSLText() {
        let text = """
                    X509v3 Subject Alternative Name:\u{20}
                        DNS:simtool.ci.example, DNS:*.ci.example, IP Address:10.0.0.7
        """
        let parsed = OpenSSL.parseAlternativeNames(text)
        XCTAssertEqual(parsed.names, ["simtool.ci.example", "*.ci.example"])
        XCTAssertEqual(parsed.addresses, ["10.0.0.7"])
    }

    func testTheMacsAddressesLeaveOutLoopback() {
        let addresses = MacNetworkAddresses.current()
        XCTAssertFalse(addresses.ipv4.contains { $0.hasPrefix("127.") })
        if let name = addresses.localHostName { XCTAssertTrue(name.hasSuffix(".local"), name) }
        XCTAssertEqual(MacNetworkAddresses(localHostName: nil, ipv4: ["169.254.1.1", "192.168.1.27"]).primaryIPv4, "192.168.1.27")
    }

    private func trustFailure(_ issued: NetworkServerIdentity, anchor: SecCertificate, host: String) throws -> String? {
        var leaf: SecCertificate?
        SecIdentityCopyCertificate(issued.identity, &leaf)
        return evaluate([try XCTUnwrap(leaf)] + issued.chain, anchor: anchor, host: host)
    }

    private func evaluate(_ chain: [SecCertificate], anchor: SecCertificate, host: String) -> String? {
        var trust: SecTrust?
        SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
        guard let trust else { return "no trust object" }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error) ? nil : (error.map { CFErrorCopyDescription($0) as String } ?? "untrusted")
    }
}
