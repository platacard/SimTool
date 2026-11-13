import Foundation
import XCTest
@testable import SimToolCore

// A CI archive holds the app beside its UI-test runner, nested in a build
// folder: the one asked for is found by name, and only it is unpacked.
final class SimulatorAppArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheBundlesAreTheOutermostAppsShallowestFirst() {
        let entries = [
            "Debug-iphonesimulator/",
            "Debug-iphonesimulator/Shop Debug.app/Info.plist",
            "Debug-iphonesimulator/Shop Debug.app/PlugIns/Widget.appex/Info.plist",
            "Debug-iphonesimulator/Shop Debug.app/Watch/Companion.app/Info.plist",
            "Debug-iphonesimulator/AppUITests-Runner.app/",
            "Debug-iphonesimulator/AppUITests-Runner.app/Info.plist",
            "Top.app/Info.plist",
            "__MACOSX/Debug-iphonesimulator/._Shop Debug.app",
            "Debug-iphonesimulator/notes.app",
        ]
        XCTAssertEqual(SimulatorAppArchive.appBundles(in: entries), [
            "Top.app/",
            "Debug-iphonesimulator/AppUITests-Runner.app/",
            "Debug-iphonesimulator/Shop Debug.app/",
        ])
    }

    func testTheAppIsChosenByNameOrIsTheOnlyOne() throws {
        let bundles = ["Debug-iphonesimulator/AppUITests-Runner.app/", "Debug-iphonesimulator/Shop Debug.app/"]
        XCTAssertEqual(try SimulatorAppArchive.chooseApp(among: bundles, named: "Shop Debug.app", in: "b.zip"), "Debug-iphonesimulator/Shop Debug.app/")
        XCTAssertEqual(try SimulatorAppArchive.chooseApp(among: bundles, named: "shop debug", in: "b.zip"), "Debug-iphonesimulator/Shop Debug.app/")
        XCTAssertEqual(try SimulatorAppArchive.chooseApp(among: ["X.app/"], named: nil, in: "b.zip"), "X.app/")
        XCTAssertThrowsError(try SimulatorAppArchive.chooseApp(among: bundles, named: nil, in: "b.zip")) { error in
            XCTAssertTrue(error.localizedDescription.contains("holds 2 apps — name one: AppUITests-Runner.app, Shop Debug.app"), error.localizedDescription)
        }
        XCTAssertThrowsError(try SimulatorAppArchive.chooseApp(among: bundles, named: "Other", in: "b.zip")) { error in
            XCTAssertTrue(error.localizedDescription.contains("holds no Other.app — it holds AppUITests-Runner.app, Shop Debug.app"), error.localizedDescription)
        }
        XCTAssertThrowsError(try SimulatorAppArchive.chooseApp(among: [], named: nil, in: "b.zip"))
    }

    func testOnlyTheNamedAppIsUnpackedFromAZipOrATar() async throws {
        let products = directory.appendingPathComponent("src/Debug-iphonesimulator", isDirectory: true)
        try makeApp(products.appendingPathComponent("Shop Debug.app"), bundleId: "com.example.shop", version: "2.10.0", build: "7")
        try makeApp(products.appendingPathComponent("AppUITests-Runner.app"), bundleId: "com.example.runner")
        let zip = directory.appendingPathComponent("build.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", products.path, zip.path])
        let tar = directory.appendingPathComponent("build.tar")
        try run("/usr/bin/tar", ["-cf", tar.path, "-C", directory.appendingPathComponent("src").path, "Debug-iphonesimulator"])

        for archive in [zip, tar] {
            let out = directory.appendingPathComponent("out-" + archive.pathExtension, isDirectory: true)
            let app = try await SimulatorAppArchive.unpackApp(from: archive, named: "Shop Debug", into: out)
            XCTAssertEqual(app.lastPathComponent, "Shop Debug.app", archive.lastPathComponent)
            let info = try SimulatorAppInstaller.info(of: app)
            XCTAssertEqual(info, SimulatorAppInstaller.BundleInfo(bundleId: "com.example.shop", name: "Shop Debug", version: "2.10.0", build: "7"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("Debug-iphonesimulator/AppUITests-Runner.app").path), "the runner was unpacked from \(archive.lastPathComponent)")
        }
    }

    func testABundleForAnotherPlatformIsRefused() throws {
        let app = directory.appendingPathComponent("Device.app")
        try makeApp(app, bundleId: "com.example.device", platforms: ["iPhoneOS"])
        XCTAssertThrowsError(try SimulatorAppInstaller.info(of: app)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not the simulator"), error.localizedDescription)
        }
    }

    func testTheSourceIsShownWithoutQueryOrCredentials() {
        let url = URL(string: "https://user:secret@storage.example/bucket/b.zip?X-Goog-Signature=abc#x")!
        XCTAssertEqual(SimulatorAppArchive.displaySource(url), "https://storage.example/bucket/b.zip")
    }

    func testTheCacheKeepsTheNewestBuilds() throws {
        let cache = SimulatorAppDownloadCache(directory: directory.appendingPathComponent("cache"), keep: 2)
        var keys: [String] = []
        for index in 1...3 {
            let app = directory.appendingPathComponent("tmp\(index)/A.app")
            try makeApp(app, bundleId: "com.example.a\(index)")
            let key = SimulatorAppDownloadCache.key(source: "https://b/\(index).zip", app: "A.app")
            keys.append(key)
            let kept = try cache.store(app, for: key, validators: .init(etag: "\"v\(index)\""))
            XCTAssertEqual(kept.lastPathComponent, "A.app")
            // Distinct modification times, newest last.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10))], ofItemAtPath: kept.deletingLastPathComponent().path)
        }
        XCTAssertNotEqual(SimulatorAppDownloadCache.key(source: "https://b/1.zip", app: "A.app"), SimulatorAppDownloadCache.key(source: "https://b/1.zip", app: "B.app"))
        // Storing the third dropped the oldest.
        XCTAssertNil(cache.bundle(for: keys[0], matching: .init(etag: "\"v1\"")))
        XCTAssertEqual(try cache.bundle(for: keys[2], matching: .init(etag: "\"v3\"")).map(SimulatorAppInstaller.info)?.bundleId, "com.example.a3")
        XCTAssertNotNil(cache.bundle(for: keys[1], matching: .init(etag: "\"v2\"")))
        // The same address now serving another build is not taken from the cache.
        XCTAssertNil(cache.bundle(for: keys[1], matching: .init(etag: "\"v9\"")))
        XCTAssertNil(cache.bundle(for: keys[1], matching: .init()), "nothing to compare is no match")
    }

    func testWhatSaysABuildIsTheSame() {
        typealias V = SimulatorAppArchive.Validators
        XCTAssertTrue(V(etag: "a", length: 5).matches(V(etag: "a", length: 5)))
        XCTAssertFalse(V(etag: "a", length: 5).matches(V(etag: "a", length: 6)))
        XCTAssertFalse(V(etag: "a").matches(V(etag: "b")))
        XCTAssertTrue(V(lastModified: "Thu").matches(V(lastModified: "Thu")))
        XCTAssertFalse(V(length: 5).matches(V(length: 5)))
    }

    // A redirect keeps the caller's headers only on the same origin, and never
    // goes from https down to http.
    func testARedirectCarriesTheHeadersOnlyToTheSameOrigin() {
        let origin = URL(string: "https://builds.example/a.zip")!
        func redirected(to target: String) -> URLRequest? {
            var request = URLRequest(url: URL(string: target)!)
            request.setValue("token", forHTTPHeaderField: "PRIVATE-TOKEN")
            request.setValue("keep", forHTTPHeaderField: "Accept")
            return SimulatorAppArchive.redirect(request, from: origin, headerNames: ["PRIVATE-TOKEN"])
        }
        XCTAssertEqual(redirected(to: "https://builds.example/b.zip")?.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "token")
        XCTAssertEqual(redirected(to: "https://builds.example:443/b.zip")?.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "token")
        let elsewhere = redirected(to: "https://objects.example/b.zip?sig=1")
        XCTAssertNotNil(elsewhere)
        XCTAssertNil(elsewhere?.value(forHTTPHeaderField: "PRIVATE-TOKEN"))
        XCTAssertEqual(elsewhere?.value(forHTTPHeaderField: "Accept"), "keep", "only the caller's headers go")
        XCTAssertNil(redirected(to: "https://builds.example:8443/b.zip")?.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "another port is another origin")
        XCTAssertNil(redirected(to: "http://builds.example/b.zip"), "no step down to http")
    }

    // An archive that names a place outside itself is refused before anything
    // is unpacked; a bundle whose link points out of it is refused after.
    func testAnArchiveCannotReachOutsideItself() async throws {
        XCTAssertTrue(SimulatorAppArchive.escapes("pad/../../Climb.app/Info.plist"))
        XCTAssertTrue(SimulatorAppArchive.escapes("/Applications/Climb.app/Info.plist"))
        XCTAssertFalse(SimulatorAppArchive.escapes("Debug-iphonesimulator/Shop.app/Info.plist"))
        XCTAssertFalse(SimulatorAppArchive.escapes("Shop..app/Info.plist"))

        // A zip whose entry climbs out (written by Python: zip tools refuse to).
        let climbing = directory.appendingPathComponent("climb.zip")
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('pad/../../Climb.app/Info.plist','x'); z.close()", climbing.path]
        do { try python.run() } catch { throw XCTSkip("python3 is not available to write the archive") }
        python.waitUntilExit()
        guard python.terminationStatus == 0 else { throw XCTSkip("python3 could not write the archive") }
        do {
            _ = try await SimulatorAppArchive.unpackApp(from: climbing, named: "Climb", into: directory.appendingPathComponent("out-climb"))
            XCTFail("a climbing archive was unpacked")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("holds a path outside itself"), error.localizedDescription)
        }

        // A tar whose bundle holds a link out of it.
        let source = directory.appendingPathComponent("linked", isDirectory: true)
        let app = source.appendingPathComponent("Linked.app")
        try makeApp(app, bundleId: "com.example.linked")
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("hosts").path, withDestinationPath: "/etc/hosts")
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("inside").path, withDestinationPath: "Info.plist")
        let tar = directory.appendingPathComponent("linked.tar")
        try run("/usr/bin/tar", ["-cf", tar.path, "-C", source.path, "Linked.app"])
        do {
            _ = try await SimulatorAppArchive.unpackApp(from: tar, named: nil, into: directory.appendingPathComponent("out-linked"))
            XCTFail("a bundle linking out of itself was unpacked")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("holds a link out of itself: hosts"), error.localizedDescription)
        }
    }

    func testOnlyAnHTTPAddressIsDownloaded() async {
        do {
            try await SimulatorAppArchive.download(URL(fileURLWithPath: "/etc/hosts"), to: directory.appendingPathComponent("x"))
            XCTFail("a file URL was downloaded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("over http(s)"), error.localizedDescription)
        }
    }

    private func makeApp(_ app: URL, bundleId: String, version: String = "1.0", build: String = "1", platforms: [String] = ["iPhoneSimulator"]) throws {
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleName": app.deletingPathExtension().lastPathComponent,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleSupportedPlatforms": platforms,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data("binary".utf8).write(to: app.appendingPathComponent(app.deletingPathExtension().lastPathComponent))
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments)")
    }
}
