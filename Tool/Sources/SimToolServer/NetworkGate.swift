import Foundation
import SimToolCore
import Swifter

/// What the network door asks of a request besides the same-origin rules:
/// the access key. A browser brings it once in the address (`/?key=…`, as the
/// viewer's QR code and `serve` print it) or through the key page, and keeps
/// it in a cookie from then on; a client that is not a browser sends it as
/// `Authorization: Bearer <key>`. Without it the network gets nothing but the
/// key page and SimTool's certificate — not the screen, not the input, not
/// the requests and logs (tokens are in them).
struct NetworkGate: Sendable {
    /// Where a device downloads SimTool's certificate authority, with or without the key.
    static let authorityPath = "/simtool-ca.cer"

    let key: String
    /// Names this server answers to besides IP addresses and localhost, lowercased.
    let names: Set<String>
    /// The port, which names the cookie: two servers on one Mac keep theirs apart.
    let port: UInt16
    /// Whether SimTool's own authority issued the certificate, so the pages offer it.
    let offersAuthority: Bool

    var cookieName: String { "simtool-key-\(port)" }

    enum Admission: Equatable {
        case admitted
        /// The key came in the address: kept in a cookie, the page shown again without it.
        case remember(location: String)
        /// No key, or not this server's. `page`: a browser opening a page,
        /// which is shown where to enter it.
        case refused(page: Bool, wrongKey: Bool)
    }

    func admission(method: String, path: String, query: [(String, String)], headers: [String: String]) -> Admission {
        if method == "GET" || method == "HEAD", path == Self.authorityPath { return .admitted }
        let page = method == "GET" && Self.opensPage(headers)
        if let given = query.last(where: { $0.0 == "key" })?.1, page {
            guard NetworkAccessKey.matches(given, key) else { return .refused(page: true, wrongKey: true) }
            return .remember(location: Self.location(path: path, query: query.filter { $0.0 != "key" }))
        }
        if let authorization = headers["authorization"] {
            let parts = authorization.split(separator: " ", maxSplits: 1)
            let admitted = parts.count == 2 && parts[0].lowercased() == "bearer" && NetworkAccessKey.matches(String(parts[1]), key)
            return admitted ? .admitted : .refused(page: page, wrongKey: true)
        }
        if let kept = cookie(headers["cookie"]) {
            // A key that was renewed since leaves a stale cookie behind.
            return NetworkAccessKey.matches(kept, key) ? .admitted : .refused(page: page, wrongKey: true)
        }
        return .refused(page: page, wrongKey: false)
    }

    /// Where the page is shown again without the key: on this server, never
    /// a path a browser would read as another host (`//x`, `/\x`). Swifter
    /// hands the query's items still percent-encoded, so they go back as they came.
    static func location(path: String, query: [(String, String)]) -> String {
        let safe = path.hasPrefix("/") && path.dropFirst().first != "/" && !path.contains("\\")
            && path.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
        var location = safe ? path : "/"
        let rest = query.filter { pair in (pair.0 + pair.1).unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F } }
        if !rest.isEmpty { location += "?" + rest.map { $0.1.isEmpty ? $0.0 : $0.0 + "=" + $0.1 }.joined(separator: "&") }
        return location
    }

    /// A browser opening a page — the address bar, a link, a QR code — rather
    /// than the page's own script asking for data.
    static func opensPage(_ headers: [String: String]) -> Bool {
        if let destination = headers["sec-fetch-dest"]?.lowercased() { return destination == "document" }
        return headers["accept"]?.lowercased().contains("text/html") == true
    }

    func cookie(_ header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == cookieName { return parts[1] }
        }
        return nil
    }

    /// Keeps the key for a year (renewing it ends that), sent back on this
    /// server's requests only — and on a link from elsewhere that opens it.
    func remembering(location: String) -> HttpResponse {
        .raw(303, "See Other", [
            "Location": location,
            "Set-Cookie": "\(cookieName)=\(NetworkAccessKey.normalized(key)); Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Lax",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
            "Content-Length": "0",
        ], nil)
    }

    func refusal(page: Bool, wrongKey: Bool) -> HttpResponse {
        guard page else {
            return SameOriginPolicy.jsonError(401, "Unauthorized", wrongKey
                ? "That is not this SimTool server's access key"
                : "This SimTool server is open to the network behind an access key: open its viewer with the key, or send Authorization: Bearer <key>",
                headers: ["WWW-Authenticate": "Bearer realm=\"SimTool\""])
        }
        let html = NetworkPages.keyPage(wrongKey: wrongKey, offersAuthority: offersAuthority)
        let body = Data(html.utf8)
        return .raw(401, "Unauthorized", [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(body.count)",
            "Cache-Control": "no-store",
            "Content-Security-Policy": NetworkPages.contentSecurityPolicy,
        ]) { try $0.write(body) }
    }
}

/// The two pages the network sees before the key: the key page (HTTPS) and
/// the page a plain `http://` address gets, which points to HTTPS and to the
/// certificate. No script; the styles are their own.
enum NetworkPages {
    static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

    static func keyPage(wrongKey: Bool, offersAuthority: Bool) -> String {
        page(title: "SimTool — access key", body: """
        <h1>Enter the access key</h1>
        <p>This SimTool server is open to the network behind a key. It is printed where <code>simtool serve</code> runs, and the viewer on that Mac shows it — with a QR code — under <b>Network</b> in its status bar.</p>
        \(wrongKey ? "<p class=\"err\">That is not this server's key.</p>" : "")
        <form method="get" action="/">
          <input name="key" aria-label="Access key" placeholder="xxxx-xxxx-xxxx" autocomplete="off" autocapitalize="none" autocorrect="off" spellcheck="false" autofocus required>
          <button type="submit">Open</button>
        </form>
        \(offersAuthority ? "<p class=\"note\">The browser warned that this connection is not private? Install SimTool's certificate on this device once — <a href=\"\(NetworkGate.authorityPath)\">download it</a> — and turn its trust on (the steps are on <b>http://</b> at the same address).</p>" : "")
        """)
    }

    /// For a plain `http://` request from the network: SimTool answers the
    /// network over HTTPS only. `secureURL` was built from a Host header the
    /// policy allows (letters, digits and host punctuation only).
    static func landing(secureURL: String, offersAuthority: Bool) -> String {
        let install = offersAuthority ? """
        <h2>First time on this device: trust SimTool's certificate</h2>
        <p><a class="button" href="\(NetworkGate.authorityPath)">Download the certificate</a></p>
        <ul>
          <li><b>iPhone, iPad</b> (Safari): allow the download, then Settings → <i>Profile Downloaded</i> → Install. Then Settings → General → About → Certificate Trust Settings → turn on <i>SimTool local CA</i>.</li>
          <li><b>Mac</b>: open the downloaded file; in Keychain Access open <i>SimTool local CA</i> → Trust → <i>Always Trust</i>.</li>
          <li><b>Android</b> (Chrome): Settings → Security → Encryption &amp; credentials → Install a certificate → CA certificate, and pick the downloaded file.</li>
        </ul>
        <p class="note">The certificate can vouch only for local names (<code>.local</code>) and private addresses, and only this Mac holds its key.</p>
        """ : ""
        return page(title: "SimTool", body: """
        <h1>SimTool opens over HTTPS</h1>
        <p>The simulator's stream needs a secure page. Open</p>
        <p><a class="button" href="\(secureURL)">\(secureURL)</a></p>
        <p>and enter the access key — or scan the QR code under <b>Network</b> in the viewer on the Mac that runs SimTool.</p>
        \(install)
        """)
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(title)</title>
        <style>
        :root { color-scheme: light dark; --ink: light-dark(#1b1d20, #e8eaed); --ink2: light-dark(#5b6068, #a3a8b0); --bg: light-dark(#f6f7f9, #16181b); --card: light-dark(#fff, #1f2226); --line: light-dark(#dfe2e6, #33373d); --accent: light-dark(#1f5fd6, #6aa4ff); --err: light-dark(#c62828, #ff7b72); }
        body { margin: 0; padding: 24px 16px; background: var(--bg); color: var(--ink); font: 15px/1.5 -apple-system, system-ui, sans-serif; }
        main { max-width: 560px; margin: 0 auto; background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 20px 22px; }
        h1 { font-size: 20px; margin: 0 0 8px; } h2 { font-size: 16px; margin: 20px 0 6px; }
        p, li { color: var(--ink2); } b, i, code, h1, h2 { color: var(--ink); } code { font-size: 13px; }
        a { color: var(--accent); word-break: break-all; } .err { color: var(--err); } .note { font-size: 13px; }
        .button { display: inline-block; padding: 8px 14px; border-radius: 8px; background: var(--accent); color: #fff; text-decoration: none; font-weight: 600; }
        form { display: flex; gap: 8px; margin: 12px 0; } input { flex: 1; min-width: 0; font: 17px ui-monospace, monospace; padding: 8px 10px; border-radius: 8px; border: 1px solid var(--line); background: var(--bg); color: var(--ink); }
        button { font: inherit; font-weight: 600; padding: 8px 16px; border: 0; border-radius: 8px; background: var(--accent); color: #fff; }
        ul { padding-left: 20px; }
        </style></head>
        <body><main>
        \(body)
        </main></body></html>
        """
    }
}
