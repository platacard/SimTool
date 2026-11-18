import Foundation

/// A place builds may be installed from when the request comes from the
/// network or from another site's page (`serve --install-from`): one scheme,
/// one host and port, and a folder on it — `https://builds.example/simulator/`.
///
/// A URL is under it only when the parts the Mac will connect to and ask for
/// are exactly the prefix's: the same scheme, host and port, no credentials,
/// and a path that starts with the prefix's folder and cannot climb out of it
/// on the build's host — no `.` or `..` segment, plain or percent-encoded, no
/// encoded slash or backslash, no `;` path parameters, no encoded `%`. The
/// folder ends at a segment boundary: `/simulator/` does not cover
/// `/simulator-old/`.
public struct BuildURLPrefix: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// `https` or `http`.
    public let scheme: String
    /// Lowercased, as written — no encoding.
    public let host: String
    /// The port the Mac connects to: the scheme's own when none is written.
    public let port: Int
    /// The folder, percent-encoded as written, starting and ending with `/`.
    public let path: String

    /// Reads a prefix as the operator writes it; nil for anything but a plain
    /// http(s) address of a folder — one with credentials, a query, a
    /// fragment, a `.`/`..`/empty segment, a `;`, a `\` or any `%`. A path
    /// without a trailing slash is taken as that folder.
    public init?(_ value: String) {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let host = components.percentEncodedHost?.lowercased(), !host.isEmpty,
              host.unicodeScalars.allSatisfy(Self.hostCharacters.contains) else { return nil }
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        guard path.hasPrefix("/"), !path.contains("%"), !path.contains("\\"), !path.contains(";") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        // The trailing slash leaves one empty segment at the end; any other is `//`.
        guard !segments.dropLast().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              segments.last != ".", segments.last != ".." else { return nil }
        if !path.hasSuffix("/") { path += "/" }
        self.scheme = scheme
        self.host = host
        self.port = components.port ?? Self.defaultPort(scheme)
        self.path = path
    }

    /// Whether the Mac fetching `url` would ask this prefix's host for
    /// something inside its folder. The query (a signed URL's signature) may
    /// be anything; the fragment is never sent.
    public func covers(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.user == nil, components.password == nil,
              components.percentEncodedHost?.lowercased() == host,
              (components.port ?? Self.defaultPort(scheme)) == port else { return false }
        let raw = components.percentEncodedPath
        guard raw.hasPrefix(path), !raw.contains("\\"), !raw.contains(";"),
              let decoded = raw.removingPercentEncoding, decoded.hasPrefix(path),
              // Encoding hides no separator, parameter, escape or control character.
              decoded.filter({ $0 == "/" }).count == raw.filter({ $0 == "/" }).count,
              !decoded.contains("\\"), !decoded.contains(";"), !decoded.contains("%"),
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return !decoded.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }

    /// Whether any of `prefixes` covers `url`.
    public static func any(_ prefixes: [BuildURLPrefix], covers url: URL) -> Bool {
        prefixes.contains { $0.covers(url) }
    }

    /// As it reads back: `https://builds.example/simulator/`, a port only
    /// when it is not the scheme's own.
    public var description: String {
        let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return scheme + "://" + shownHost + (port == Self.defaultPort(scheme) ? "" : ":\(port)") + path
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }

    /// What a host is written with: a name, an IPv4 address or a bracketed
    /// IPv6 one — nothing encoded.
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:[]")
}
