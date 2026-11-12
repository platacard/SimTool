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
/// HTTPS, behind the access key (`NetworkGate`), answering this Mac's names
/// as well.
struct SameOriginPolicy: Sendable {
    /// The host the server was started on, allowed besides loopback names
    /// and IP addresses.
    let serverHost: String
    /// The network door's key and names, when the server is open to the network.
    let network: NetworkGate?

    init(serverHost: String, network: NetworkGate? = nil) {
        self.serverHost = serverHost
        self.network = network
    }

    /// Why the request is refused, or nil when it may go on. `headers` are
    /// keyed by lowercased name, as Swifter parses them; `path` has no query.
    func rejection(method: String, path: String, headers: [String: String], door: ServerDoor = .local) -> String? {
        let host = headers["host"]
        if let host, !isAllowedHost(host) {
            let open = door == .network ? "https://" + (network?.names.sorted().first ?? "<this Mac's address>") : "127.0.0.1 or localhost"
            return "Host \(host) is not an address of this SimTool server; open it at \(open)"
        }
        if let origin = headers["origin"] {
            guard let host, origin.lowercased() == door.scheme + "://" + host.lowercased() else {
                return "Origin \(origin) is not this server's viewer; SimTool answers only its own page"
            }
        }
        // What another page sends without an Origin: an <img>, <script> or
        // <video> pointed at the server, an <iframe>, a window it opens on an
        // API route. A link elsewhere may open the viewer itself, in a tab.
        if let site = headers["sec-fetch-site"]?.lowercased(), site == "cross-site" || site == "same-site" {
            let opensTheViewer = method == "GET" && path == "/"
                && headers["sec-fetch-mode"]?.lowercased() == "navigate"
                && headers["sec-fetch-dest"]?.lowercased() == "document"
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
        if let network, network.names.contains(name) || network.names.contains(where: { Self.wildcard($0, matches: name) }) { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, name, &v4) == 1 || inet_pton(AF_INET6, name, &v6) == 1
    }

    /// The response as the policy lets it out: without any CORS header a route
    /// set, with `nosniff`, a same-origin resource policy and no framing by
    /// another page, and — when it is a page — with the content security policy
    /// (a page that brings its own, the key page, keeps it).
    func secured(_ response: HttpResponse, host: String?, door: ServerDoor = .local) -> HttpResponse {
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
        headers["X-Frame-Options"] = "DENY"
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
            "frame-ancestors 'none'",
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

    /// A request through either door: the network's asks for the key first.
    func dispatch(_ request: HttpRequest, door: ServerDoor) -> ([String: String], (HttpRequest) -> HttpResponse) {
        if let reason = policy.rejection(method: request.method, path: request.path, headers: request.headers, door: door) {
            DebugLog.write("server", "refused \(request.method) \(request.path): \(reason)")
            let refusal = policy.forbidden(reason)
            return ([:], { _ in refusal })
        }
        let host = request.headers["host"]
        if door == .network {
            guard let gate = policy.network else {
                let refusal = policy.forbidden("This SimTool server is not open to the network")
                return ([:], { _ in refusal })
            }
            switch gate.admission(method: request.method, path: request.path, query: request.queryParams, headers: request.headers) {
            case .admitted:
                break
            case let .remember(location):
                let answer = policy.secured(gate.remembering(location: location), host: host, door: door)
                return ([:], { _ in answer })
            case let .refused(page, wrongKey):
                if !page { DebugLog.write("server", "refused \(request.method) \(request.path) from the network: \(wrongKey ? "a wrong" : "no") access key") }
                let answer = policy.secured(gate.refusal(page: page, wrongKey: wrongKey), host: host, door: door)
                return ([:], { _ in answer })
            }
        }
        if let answer = onRequest?(request) {
            return ([:], { [policy] _ in policy.secured(answer, host: host, door: door) })
        }
        let (params, handler) = super.dispatch(request)
        return (params, { [policy] request in policy.secured(handler(request), host: host, door: door) })
    }
}

/// The server's second listener, for the network: its requests come out of
/// TLS (`NetworkDoor`) and go through the same routes as this Mac's, behind
/// the access key.
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
    /// HTTPS from the network, behind the access key.
    case network

    var scheme: String { self == .local ? "http" : "https" }
    var socketScheme: String { self == .local ? "ws" : "wss" }
}
