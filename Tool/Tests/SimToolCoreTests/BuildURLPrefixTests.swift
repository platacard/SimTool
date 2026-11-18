import Foundation
import XCTest
@testable import SimToolCore

// `serve --install-from`: the places builds may come from when the network or
// another site's page asks. A URL is under one only when the Mac would ask
// that host for something inside that folder — no lookalike host, port or
// scheme, no climbing out of the folder however it is written.
final class BuildURLPrefixTests: XCTestCase {
    func testAPrefixIsAFolderAtAPlainURL() throws {
        let prefix = try XCTUnwrap(BuildURLPrefix("https://Builds.Example/simulator/"))
        XCTAssertEqual(prefix.scheme, "https")
        XCTAssertEqual(prefix.host, "builds.example")
        XCTAssertEqual(prefix.port, 443)
        XCTAssertEqual(prefix.path, "/simulator/")
        XCTAssertEqual(prefix.description, "https://builds.example/simulator/")
        XCTAssertEqual(BuildURLPrefix("https://builds.example/simulator")?.path, "/simulator/", "a folder without its trailing slash")
        XCTAssertEqual(BuildURLPrefix("https://builds.example")?.path, "/", "the whole host")
        XCTAssertEqual(BuildURLPrefix("https://builds.example:443/a/")?.description, "https://builds.example/a/")
        XCTAssertEqual(BuildURLPrefix("http://10.0.0.5:8081/repo/sim/")?.description, "http://10.0.0.5:8081/repo/sim/")
        XCTAssertEqual(BuildURLPrefix("https://builds.example/a/b/"), BuildURLPrefix("HTTPS://builds.example:443/a/b"))

        for bad in ["builds.example/simulator/", "ftp://builds.example/", "file:///tmp/", "https:///simulator/", "https://user@builds.example/",
                    "https://user:pw@builds.example/", "https://builds.example/simulator/?a=1", "https://builds.example/simulator/#x",
                    "https://builds.example/a/../b/", "https://builds.example/a/./b/", "https://builds.example/a/..", "https://builds.example//a/",
                    "https://builds.example/a%2f/", "https://builds.example/%2e%2e/", "https://builds.example/a;x/", "https://builds.example/a\\b/",
                    "https://b%75ilds.example/", "https://bad_host.example/", ""] {
            XCTAssertNil(BuildURLPrefix(bad), bad)
        }
    }

    func testAURLIsUnderTheFolderAtASegmentBoundary() throws {
        let prefix = try XCTUnwrap(BuildURLPrefix("https://builds.example/simulator/"))
        func covers(_ url: String) -> Bool { prefix.covers(URL(string: url)!) }
        XCTAssertTrue(covers("https://builds.example/simulator/app/build-123.zip"))
        XCTAssertTrue(covers("https://BUILDS.example:443/simulator/app/build.zip"), "the host's case and the scheme's own port")
        XCTAssertTrue(covers("https://builds.example/simulator/app/build.zip?X-Signature=abc&e=1"), "a signed URL's query")
        XCTAssertTrue(covers("https://builds.example/simulator/My%20App.zip"), "an encoded space is a name")
        XCTAssertTrue(covers("https://builds.example/simulator/"))
        XCTAssertFalse(covers("https://builds.example/simulator"), "the folder's name is not inside it")
        XCTAssertFalse(covers("https://builds.example/simulator-old/build.zip"), "a sibling with the same start")
        XCTAssertFalse(covers("https://builds.example/Simulator/build.zip"), "paths are compared as written")
        XCTAssertFalse(covers("https://builds.example/other/build.zip"))
    }

    func testNoLookalikeHostPortSchemeOrCredentials() throws {
        let prefix = try XCTUnwrap(BuildURLPrefix("https://builds.example/simulator/"))
        for url in ["http://builds.example/simulator/a.zip", "https://builds.example:8443/simulator/a.zip", "https://builds.example./simulator/a.zip",
                    "https://builds.example.evil.example/simulator/a.zip", "https://evil.example/simulator/a.zip", "https://sub.builds.example/simulator/a.zip",
                    "https://builds.example@evil.example/simulator/a.zip", "https://user@builds.example/simulator/a.zip",
                    "https://user:pw@builds.example/simulator/a.zip", "https://evil.example#@builds.example/simulator/a.zip",
                    "https://b%75ilds.example/simulator/a.zip"] {
            XCTAssertFalse(prefix.covers(URL(string: url)!), url)
        }
    }

    func testNoClimbingOutOfTheFolderHoweverItIsWritten() throws {
        let prefix = try XCTUnwrap(BuildURLPrefix("https://builds.example/simulator/"))
        for url in ["https://builds.example/simulator/../admin/", "https://builds.example/simulator/./a.zip", "https://builds.example/simulator/a/../../admin",
                    "https://builds.example/simulator/%2e%2e/admin", "https://builds.example/simulator/%2E%2E/admin", "https://builds.example/simulator/.%2e/admin",
                    "https://builds.example/simulator/..%2fadmin", "https://builds.example/simulator/a%2F..%2F..%2Fadmin", "https://builds.example/simulator/..%5cadmin",
                    "https://builds.example/simulator/%252e%252e/admin", "https://builds.example/simulator/..;/admin", "https://builds.example/simulator/a;jsessionid=1",
                    "https://builds.example/simulator/a%00.zip", "https://builds.example/simulator/a%0d%0aX:%20y"] {
            guard let parsed = URL(string: url) else { continue }
            XCTAssertFalse(prefix.covers(parsed), url)
        }
    }

    func testAnyOfSeveral() {
        let prefixes = ["https://builds.example/simulator/", "http://10.0.0.5:8081/sim/"].compactMap(BuildURLPrefix.init)
        XCTAssertEqual(prefixes.count, 2)
        XCTAssertTrue(BuildURLPrefix.any(prefixes, covers: URL(string: "http://10.0.0.5:8081/sim/a.zip")!))
        XCTAssertFalse(BuildURLPrefix.any(prefixes, covers: URL(string: "http://10.0.0.5/sim/a.zip")!))
        XCTAssertFalse(BuildURLPrefix.any([], covers: URL(string: "https://builds.example/simulator/a.zip")!))
    }
}
