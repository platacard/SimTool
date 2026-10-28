import Foundation

extension SimToolNetworkLogger {
    /// The SimTool release this library belongs to. One tag ships both the
    /// libraries an app links and the `simtool` CLI, and this is that tag's
    /// number: the CLI reports it as its own (`SimToolVersion.base`), and the
    /// logger sends it with every event batch and mock poll, so the server can
    /// tell when the app links a different release than the one serving it.
    /// Bump it for every release, together with `Formula/simtool.rb`.
    public static let version = "1.0.0"
}
