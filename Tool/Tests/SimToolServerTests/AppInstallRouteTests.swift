import Darwin
import Foundation
import SimToolCore
import SimToolServer
import XCTest

// POST /api/v1/app/install with JSON: a build at a URL is fetched by a job the
// request only starts; GET follows the job; the same build asked for again is
// not downloaded twice; what was sent to the build's host is never echoed.
final class AppInstallRouteTests: XCTestCase {
    func testABuildAtAURLIsFetchedUnpackedAndKeptForNextTime() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-install-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let products = work.appendingPathComponent("src/Debug-iphonesimulator", isDirectory: true)
        try makeApp(products.appendingPathComponent("Probe Debug.app"), bundleId: "com.example.probe")
        try makeApp(products.appendingPathComponent("Probe-Runner.app"), bundleId: "com.example.runner")
        let zip = work.appendingPathComponent("build.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", products.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        let archive = try Data(contentsOf: zip)
        let host = try OneFileHTTPServer(body: archive, requiring: "Bearer s3cret")
        defer { host.stop() }

        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false,
                                                             downloadCacheDirectory: work.appendingPathComponent("cache")))
        try server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"

        // Nothing yet.
        let idle = try await getJSON(base + "/api/v1/app/install")
        XCTAssertEqual(idle["state"] as? String, "idle")

        // A bad request is refused before anything starts.
        for (body, expected) in [(#"{"app": "x"}"#, "url"), (#"{"url": "file:///etc/hosts"}"#, "http(s) address")] {
            let (status, answer) = try await post(base + "/api/v1/app/install", body)
            XCTAssertEqual(status, 400, body)
            XCTAssertTrue((answer["error"] as? String ?? "").contains(expected), "\(body) → \(answer)")
        }

        let request = """
        {"url": "http://127.0.0.1:\(host.port)/bucket/build.zip?X-Signature=abc", "headers": {"Authorization": "Bearer s3cret"},
         "app": "Probe Debug", "launch": {"arguments": ["-Environment", "stable"]}, "label": "main · abc123 · tester"}
        """
        let (status, started) = try await post(base + "/api/v1/app/install", request)
        XCTAssertEqual(status, 202, "\(started)")
        XCTAssertEqual(started["source"] as? String, "http://127.0.0.1:\(host.port)/bucket/build.zip")
        XCTAssertEqual(started["label"] as? String, "main · abc123 · tester")
        XCTAssertFalse(String(describing: started).contains("s3cret"), "the job echoes the build host's credentials")

        // The fake device cannot install, so the job ends failed at that step —
        // after the download and the unpacking, which is what is checked here.
        let first = try await waitForEnd(base)
        XCTAssertEqual(first["state"] as? String, "failed", "\(first)")
        XCTAssertTrue((first["error"] as? String ?? "").contains("simctl install"), "\(first)")
        XCTAssertEqual(first["bundleId"] as? String, "com.example.probe")
        XCTAssertEqual((first["receivedBytes"] as? NSNumber)?.intValue, archive.count)
        XCTAssertEqual(first["cached"] as? Bool, false)
        XCTAssertEqual(host.requests, 1)
        XCTAssertEqual(host.refused, 0, "the bearer header reached the build's host")

        // The same build again comes from the cache.
        let (again, _) = try await post(base + "/api/v1/app/install", request)
        XCTAssertEqual(again, 202)
        let second = try await waitForEnd(base)
        XCTAssertEqual(second["cached"] as? Bool, true, "\(second)")
        XCTAssertEqual(second["bundleId"] as? String, "com.example.probe")
        XCTAssertEqual(host.requests, 1, "the build was downloaded twice")
        XCTAssertGreaterThanOrEqual(host.probes, 1, "the second time asked whether it is the same build")

        // The activity feed told it as installs.
        let feed = try await getJSON(base + "/api/v1/activity")
        let titles = (feed["entries"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "install" }.compactMap { $0["title"] as? String }
        XCTAssertEqual(titles, ["Install main · abc123 · tester", "Install main · abc123 · tester"])

        // A launch names its app.
        let (launchStatus, launch) = try await post(base + "/api/v1/app/launch", #"{"bundleId": ""}"#)
        XCTAssertEqual(launchStatus, 400)
        XCTAssertTrue((launch["error"] as? String ?? "").contains("bundleId"), "\(launch)")
    }

    private func waitForEnd(_ base: String) async throws -> [String: Any] {
        for _ in 0..<200 {
            let job = try await getJSON(base + "/api/v1/app/install")
            if let state = job["state"] as? String, state == "done" || state == "failed" { return job }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func getJSON(_ url: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func post(_ url: String, _ body: String) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }

    private func makeApp(_ app: URL, bundleId: String) throws {
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleName": app.deletingPathExtension().lastPathComponent,
                                    "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    }
}

/// A host that serves one file to whoever sends the expected `Authorization`,
/// and 403 to anyone else; counts both.
private final class OneFileHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var served = 0
    private var refusals = 0

    /// Whole downloads served; a one-byte range probe (is it the same build?) is not one.
    var requests: Int { lock.withLock { served } }
    var probes: Int { lock.withLock { ranged } }
    var refused: Int { lock.withLock { refusals } }
    private var ranged = 0

    init(body: Data, requiring authorization: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = socketAddress("127.0.0.1", port: 0)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
        let listener = descriptor
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var request = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !request.contains(Data("\r\n\r\n".utf8)) {
                    let count = read(client, &buffer, buffer.count)
                    guard count > 0 else { break }
                    request.append(buffer, count: count)
                }
                let head = String(decoding: request, as: UTF8.self).lowercased()
                let allowed = head.contains("authorization: \(authorization.lowercased())")
                let probe = head.contains("range: bytes=0-0")
                lock.withLock { if !allowed { refusals += 1 } else if probe { ranged += 1 } else { served += 1 } }
                let payload = allowed ? body : Data("{\"error\": \"forbidden\"}".utf8)
                let status = allowed ? "200 OK" : "403 Forbidden"
                var response = Data("HTTP/1.1 \(status)\r\nContent-Length: \(payload.count)\r\nContent-Type: application/zip\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n".utf8)
                response.append(payload)
                response.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = write(client, raw.baseAddress! + offset, raw.count - offset)
                        guard written > 0 else { break }
                        offset += written
                    }
                }
                close(client)
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }
}
