import Foundation
import SimToolCore
import Swifter

/// Who may talk to the server: its own viewer, and clients that are not
/// browsers — the CLI, an agent's curl, the app-side loggers posting from the
/// simulator. A page on any other origin may neither read a response nor make
/// the server act (a tap, a mock, a deleted run), nor frame the viewer to
/// steer clicks into it; a name that merely resolves to this Mac — DNS
/// rebinding — does not make a page same-origin.
///
/// Browsers' own local-network protections differ, so none is relied on: a
/// browser names the page behind every request it sends (`Origin`,
/// `Sec-Fetch-Site`) and the host it thinks it is talking to (`Host`), and the
/// server refuses what is not its own. Clients that are not browsers send
/// neither page header and are let through — they could do anything anyway.
///
/// A server opened to the network has a second door (`ServerDoor.network`):
/// HTTPS, answering this Mac's names as well. Who may reach it at all is the
/// network's to decide — the Wi-Fi, a VPN, a sign-in in front of it.
///
/// Pages on origins the server was told to allow (`serve --allow-origin`) — a
/// site that hands out the simulator — may show the viewer in a frame, read
/// the server's status and start the simulator; with places builds may come
/// from (`serve --install-from`), also install one of those builds and follow
/// the install. Nothing else.
struct SameOriginPolicy: Sendable {
    /// The host the server was started on, allowed besides loopback names
    /// and IP addresses.
    let serverHost: String
    /// This Mac's names on the network — its Bonjour name, its certificate's
    /// — when the server is open to it; lowercased.
    let networkNames: Set<String>
    /// Origins whose pages may embed the viewer and use `crossOriginRoutes`,
    /// as browsers write them (`https://site.example`); lowercased.
    let allowedOrigins: Set<String>
    /// Where a build may be installed from when the network or an allowed
    /// site's page asks for it (`serve --install-from`). Empty: from the Mac
    /// itself only.
    let installSources: [BuildURLPrefix]

    /// What an allowed page may always ask of the server from its own origin.
    static let siteRoutes: Set<String> = ["GET /api/v1/status", "POST /api/v1/device/wake"]
    /// What it may ask besides when builds may come from somewhere: a build
    /// from a URL (JSON only — an upload stays the viewer's), and its job.
    static let installRoutes: Set<String> = ["POST /api/v1/app/install", "GET /api/v1/app/install"]

    /// What an allowed page may ask of the server from its own origin.
    var crossOriginRoutes: Set<String> {
        installSources.isEmpty ? Self.siteRoutes : Self.siteRoutes.union(Self.installRoutes)
    }

    /// Why a route that acts on the Mac itself — not on the simulator — is
    /// refused from the network: stopping SimTool's processes (other servers
    /// among them), the Mac's camera, its Finder, and fetching a URL from the
    /// Mac's own network — unless builds may come from somewhere, and then
    /// only from there (`remoteInstallRejection`). Nil when the route is open
    /// to the network — reading the process list and what the Mac's memory
    /// and CPU go to is.
    func macOnly(method: String, path: String, headers: [String: String]) -> String? {
        let method = method.uppercased()
        let what: String?
        if path.hasPrefix("/api/v1/processes/") || (path == "/api/v1/processes" && method != "GET" && method != "HEAD") {
            what = "Stopping SimTool's processes"
        } else if method == "POST", path == "/api/v1/camera/webcam" {
            what = "The Mac's camera"
        } else if method == "POST", path == "/api/v1/app/reveal" {
            what = "Showing files in the Mac's Finder"
        } else if method == "POST", path == "/api/v1/app/install", Self.isJSON(headers), installSources.isEmpty {
            return Self.installFromURLOnTheMac
        } else {
            what = nil
        }
        return what.map { $0 + " is open on the Mac itself, not over the network" }
    }

    static let installFromURLOnTheMac = "Installing a build from a URL is open on the Mac itself, not over the network — unless the server names where builds may come from (serve --install-from)"

    init(serverHost: String, networkNames: Set<String> = [], allowedOrigins: Set<String> = [], installSources: [BuildURLPrefix] = []) {
        self.serverHost = serverHost
        self.networkNames = networkNames
        self.allowedOrigins = Set(allowedOrigins.map { $0.lowercased() })
        self.installSources = installSources
    }

    /// The allowed origin a request comes from when it asks for one of the
    /// routes such a page may use — or, as a preflight (`OPTIONS`), asks
    /// whether it may: the value its answer names in
    /// `Access-Control-Allow-Origin`.
    func crossOrigin(method: String, path: String, headers: [String: String]) -> String? {
        guard let origin = headers["origin"]?.lowercased(), allowedOrigins.contains(origin) else { return nil }
        var method = method.uppercased()
        let preflight = method == "OPTIONS"
        if preflight {
            guard let asked = headers["access-control-request-method"] else { return nil }
            method = asked.uppercased()
        }
        guard crossOriginRoutes.contains(method + " " + path) else { return nil }
        // A build from a URL is asked for with JSON; a page posting anything
        // else there — an upload — is not the viewer.
        if !preflight, method == "POST", path == "/api/v1/app/install", !Self.isJSON(headers) { return nil }
        return origin
    }

    /// The answer to an allowed page's preflight for one of its routes —
    /// the methods it may use there and `Content-Type` as the one header it
    /// may set — or nil when the request is not one.
    func preflight(method: String, path: String, headers: [String: String], host: String?, door: ServerDoor) -> HttpResponse? {
        guard method.uppercased() == "OPTIONS", let origin = crossOrigin(method: method, path: path, headers: headers) else { return nil }
        let methods = crossOriginRoutes.compactMap { route -> String? in
            let parts = route.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[1] == path ? String(parts[0]) : nil
        }.sorted()
        var cors = [
            "Access-Control-Allow-Methods": methods.joined(separator: ", "),
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Max-Age": "600",
        ]
        // A browser that asks before a public page reaches a private address.
        if headers["access-control-request-private-network"]?.lowercased() == "true" {
            cors["Access-Control-Allow-Private-Network"] = "true"
        }
        guard case let .raw(status, phrase, secured, writer) = self.secured(.raw(204, "No Content", [:], nil), host: host, door: door, crossOrigin: origin) else { return nil }
        return .raw(status, phrase, (secured ?? [:]).merging(cors) { $1 }, writer)
    }

    /// Why a build from `url`, asked for from the network or by an allowed
    /// site's page, is refused: no `--install-from` prefix covers the URL, or
    /// the request names headers to send with it — those go to a build's host
    /// only when asked for on the Mac itself. Nil when it may go on.
    func remoteInstallRejection(url: URL, headers: [String: String]?) -> String? {
        guard !installSources.isEmpty else { return Self.installFromURLOnTheMac }
        guard BuildURLPrefix.any(installSources, covers: url) else {
            return "\(SimulatorAppArchive.displaySource(url)) is not where builds may come from over the network: "
                + installSources.map(\.description).joined(separator: ", ")
        }
        if let headers, !headers.isEmpty {
            return "headers are sent with a build only when it is asked for on the Mac itself"
        }
        return nil
    }

    static func isJSON(_ headers: [String: String]) -> Bool {
        (headers["content-type"] ?? "").lowercased().hasPrefix("application/json")
    }

    /// Why the request is refused, or nil when it may go on. `headers` are
    /// keyed by lowercased name, as Swifter parses them; `path` has no query.
    func rejection(method: String, path: String, headers: [String: String], door: ServerDoor = .local) -> String? {
        if door == .network, let reason = macOnly(method: method, path: path, headers: headers) { return reason }
        let host = headers["host"]
        if let host, !isAllowedHost(host) {
            let open = door == .network ? "https://" + (networkNames.sorted().first ?? "<this Mac's address>") : "127.0.0.1 or localhost"
            return "Host \(host) is not an address of this SimTool server; open it at \(open)"
        }
        let allowedCrossOrigin = crossOrigin(method: method, path: path, headers: headers) != nil
        if let origin = headers["origin"], !allowedCrossOrigin {
            guard let host, origin.lowercased() == door.scheme + "://" + host.lowercased() else {
                return "Origin \(origin) is not this server's viewer; SimTool answers only its own page"
            }
        }
        // What another page sends without an Origin: an <img>, <script> or
        // <video> pointed at the server, an <iframe>, a window it opens on an
        // API route. A link elsewhere may open the viewer itself, in a tab.
        if let site = headers["sec-fetch-site"]?.lowercased(), site == "cross-site" || site == "same-site", !allowedCrossOrigin {
            let destination = headers["sec-fetch-dest"]?.lowercased()
            // In a frame only where an allowed page frames it: the browser
            // holds the page to `frame-ancestors`, which names those origins.
            let framed = !allowedOrigins.isEmpty && (destination == "iframe" || destination == "frame")
            let opensTheViewer = method == "GET" && path == "/"
                && headers["sec-fetch-mode"]?.lowercased() == "navigate"
                && (destination == "document" || framed)
            if !opensTheViewer {
                return "A \(site) request is not from this server's viewer; SimTool answers only its own page"
            }
        }
        return nil
    }

    func isAllowedHost(_ header: String) -> Bool {
        guard !header.isEmpty, header.unicodeScalars.allSatisfy(Self.hostCharacters.contains) else { return false }
        let name = Self.hostname(of: header).lowercased()
        guard !name.isEmpty else { return false }
        // Not *.localhost: a browser may resolve those through DNS, and a
        // resolver on the network then decides where they point.
        if name == "localhost" || name == serverHost.lowercased() { return true }
        // This Mac's own names, when it is open to the network: its Bonjour
        // name, and whatever its certificate is for.
        if networkNames.contains(name) || networkNames.contains(where: { Self.wildcard($0, matches: name) }) { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, name, &v4) == 1 || inet_pton(AF_INET6, name, &v6) == 1
    }

    /// The response as the policy lets it out: without any CORS header a route
    /// set, with `nosniff`, a same-origin resource policy and no framing by
    /// another page, and — when it is a page — with the content security policy
    /// (a page that brings its own keeps it).
    func secured(_ response: HttpResponse, host: String?, door: ServerDoor = .local, crossOrigin: String? = nil) -> HttpResponse {
        if case .switchProtocols = response { return response }
        var headers = response.headers().filter { !$0.key.lowercased().hasPrefix("access-control-") }
        let writer: ((HttpResponseBodyWriter) throws -> Void)?
        switch response {
        case let .raw(_, _, _, rawWriter):
            writer = rawWriter
        case let .ok(body):
            writer = Self.writer(for: body, headers: &headers)
        case let .badRequest(body?):
            writer = Self.writer(for: body, headers: &headers)
        default:
            writer = nil
            headers["Content-Length"] = "0"
        }
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Cross-Origin-Resource-Policy"] = "same-origin"
        // With allowed origins, `frame-ancestors` names who may frame it;
        // X-Frame-Options has no way to say that.
        if allowedOrigins.isEmpty { headers["X-Frame-Options"] = "DENY" }
        // An answer that may differ by the page asking is said to, so no
        // cache in between hands one page another's.
        if !allowedOrigins.isEmpty { headers["Vary"] = "Origin" }
        if let crossOrigin { headers["Access-Control-Allow-Origin"] = crossOrigin }
        let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if contentType.hasPrefix("text/html"), !headers.keys.contains(where: { $0.lowercased() == "content-security-policy" }) {
            headers["Content-Security-Policy"] = contentSecurityPolicy(host: host, door: door)
        }
        return .raw(response.statusCode, response.reasonPhrase, headers, writer)
    }

    /// What a page of this server may load and run: its own files only, no
    /// inline script, no plugin, no form posting elsewhere, no frame around it.
    /// Style attributes stay allowed — the viewer positions rulers and bars
    /// with them — while `<style>` elements must come from the server too. The
    /// live-input socket is named explicitly; not every browser counts ws: as
    /// 'self' (an IPv6 host cannot be written as a source: a viewer opened at
    /// one reaches its socket through 'self' where the browser allows it) —
    /// `wss:` behind the network door.
    func contentSecurityPolicy(host: String?, door: ServerDoor = .local) -> String {
        let socket = host.flatMap { isAllowedHost($0) && !$0.hasPrefix("[") ? " \(door.socketScheme)://\($0)" : nil } ?? ""
        return [
            "default-src 'none'",
            "script-src 'self'",
            "style-src 'self'",
            "style-src-attr 'unsafe-inline'",
            "img-src 'self' data: blob:",
            "media-src 'self' blob:",
            "connect-src 'self'\(socket)",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-ancestors " + (allowedOrigins.isEmpty ? "'none'" : allowedOrigins.sorted().joined(separator: " ")),
        ].joined(separator: "; ")
    }

    func forbidden(_ reason: String) -> HttpResponse {
        secured(Self.jsonError(403, "Forbidden", reason), host: nil)
    }

    static func jsonError(_ status: Int, _ phrase: String, _ reason: String, headers extra: [String: String] = [:]) -> HttpResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": reason], options: [.withoutEscapingSlashes])) ?? Data()
        return .raw(status, phrase, extra.merging(["Content-Type": "application/json", "Content-Length": "\(body.count)"]) { $1 }) {
            try $0.write(body)
        }
    }

    /// An origin as a browser writes it in `Origin`: `https://site.example`,
    /// `http://localhost:3100` — scheme and host lowercased, a port only when
    /// it is not the scheme's own, no path. Nil for anything else.
    static func normalizedOrigin(_ value: String) -> String? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty,
              host.unicodeScalars.allSatisfy(originHostCharacters.contains),
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil, url.user == nil else { return nil }
        let port = url.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
        return scheme + "://" + host + (port.map { ":\($0)" } ?? "")
    }

    /// What an origin's host is written with: nothing that could end a
    /// policy directive (`;`) or a source list.
    private static let originHostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-[]:")

    /// Letters, digits and what a host and port are written with — nothing
    /// that could end a header value or start another policy directive.
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")

    /// `*.corp.example` covers `mac.corp.example`: one label, as TLS has it.
    static func wildcard(_ pattern: String, matches name: String) -> Bool {
        guard pattern.hasPrefix("*."), let dot = name.firstIndex(of: ".") else { return false }
        return name[..<dot].count > 0 && name[dot...] == pattern.dropFirst()
    }

    /// "127.0.0.1:3200" → "127.0.0.1", "[::1]:3200" → "::1".
    private static func hostname(of header: String) -> String {
        if header.hasPrefix("[") {
            guard let close = header.firstIndex(of: "]") else { return "" }
            return String(header[header.index(after: header.startIndex)..<close])
        }
        guard let colon = header.lastIndex(of: ":") else { return header }
        return String(header[..<colon])
    }

    /// The bytes Swifter would have written for `body`, ready for `.raw`.
    private static func writer(for body: HttpResponseBody, headers: inout [String: String]) -> (HttpResponseBodyWriter) throws -> Void {
        let data: Data
        switch body {
        case let .json(object):
            data = JSONSerialization.isValidJSONObject(object) ? (try? JSONSerialization.data(withJSONObject: object)) ?? Data() : Data()
        case let .html(text), let .text(text):
            data = Data(text.utf8)
        case let .htmlBody(text):
            data = Data("<html><meta charset=\"UTF-8\"><body>\(text)</body></html>".utf8)
            headers["Content-Type"] = headers["Content-Type"] ?? "text/html"
        case let .data(bytes, _):
            data = bytes
        case let .custom(object, serialize):
            data = (try? serialize(object)).map { Data($0.utf8) } ?? Data()
        }
        headers["Content-Length"] = "\(data.count)"
        return { try $0.write(data) }
    }
}

/// An `HttpServer` whose every route — the ones there now, the ones added
/// later, Swifter's own 404 — answers through `SameOriginPolicy`: a refused
/// request never reaches its route, and every response leaves secured.
final class SameOriginHttpServer: HttpServer {
    let policy: SameOriginPolicy
    /// Hears of every request the policy lets through, before it is handled;
    /// a response it gives is the answer, and the route is not run.
    var onRequest: ((HttpRequest) -> HttpResponse?)?

    init(policy: SameOriginPolicy) {
        self.policy = policy
        super.init()
    }

    override func dispatch(_ request: HttpRequest) -> ([String: String], (HttpRequest) -> HttpResponse) {
        dispatch(request, door: .local)
    }

    /// A request through either door, under that door's scheme.
    func dispatch(_ request: HttpRequest, door: ServerDoor) -> ([String: String], (HttpRequest) -> HttpResponse) {
        if let reason = policy.rejection(method: request.method, path: request.path, headers: request.headers, door: door) {
            DebugLog.write("server", "refused \(request.method) \(request.path): \(reason)")
            let refusal = policy.forbidden(reason)
            return ([:], { _ in refusal })
        }
        let host = request.headers["host"]
        if let preflight = policy.preflight(method: request.method, path: request.path, headers: request.headers, host: host, door: door) {
            return ([:], { _ in preflight })
        }
        let crossOrigin = policy.crossOrigin(method: request.method, path: request.path, headers: request.headers)
        if let answer = onRequest?(request) {
            return ([:], { [policy] _ in policy.secured(answer, host: host, door: door, crossOrigin: crossOrigin) })
        }
        let passage = RequestPassage(door: door, crossOrigin: crossOrigin)
        let (params, handler) = super.dispatch(request)
        return (params, { [policy] request in
            let response = RequestPassage.$current.withValue(passage) { handler(request) }
            return policy.secured(response, host: host, door: door, crossOrigin: crossOrigin)
        })
    }
}

/// How the request a route is handling came in: bound around every route's
/// handler, for what a route allows only on the Mac itself.
struct RequestPassage: Sendable {
    let door: ServerDoor
    /// The allowed site whose page asks, when it is not the server's own.
    let crossOrigin: String?

    /// From another device, or from another site's page: not the Mac's own
    /// viewer, CLI or agent.
    var isRemote: Bool { door == .network || crossOrigin != nil }

    @TaskLocal static var current: RequestPassage?
}

/// The server's second listener, for the network: its requests come out of
/// TLS (`NetworkDoor`) and go through the same routes as this Mac's, as an
/// HTTPS origin.
final class NetworkDoorServer: HttpServer {
    private unowned let server: SameOriginHttpServer

    init(server: SameOriginHttpServer) {
        self.server = server
        super.init()
    }

    override func dispatch(_ request: HttpRequest) -> ([String: String], (HttpRequest) -> HttpResponse) {
        server.dispatch(request, door: .network)
    }
}

/// Which way a request came in.
enum ServerDoor: Sendable {
    /// Plain HTTP on loopback: this Mac — its browser, the CLI, the loggers
    /// in the simulator.
    case local
    /// HTTPS from the network.
    case network

    var scheme: String { self == .local ? "http" : "https" }
    var socketScheme: String { self == .local ? "ws" : "wss" }
}
