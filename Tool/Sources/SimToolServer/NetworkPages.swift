import Foundation

/// The page a plain `http://` address from the network gets — it points to
/// HTTPS and to SimTool's certificate — and where that certificate
/// downloads. No script; the styles are its own.
enum NetworkPages {
    /// Where a device downloads SimTool's certificate authority: over plain
    /// HTTP from the network too, so a device can trust it before HTTPS.
    static let authorityPath = "/simtool-ca.cer"

    static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    /// For a plain `http://` request from the network: SimTool answers the
    /// network over HTTPS only. `secureURL` was built from a Host header the
    /// policy allows (letters, digits and host punctuation only).
    static func landing(secureURL: String, offersAuthority: Bool) -> String {
        let install = offersAuthority ? """
        <h2>First time on this device: trust SimTool's certificate</h2>
        <p><a class="button" href="\(authorityPath)">Download the certificate</a></p>
        <ul>
          <li><b>iPhone, iPad</b> (Safari): allow the download, then Settings → <i>Profile Downloaded</i> → Install. Then Settings → General → About → Certificate Trust Settings → turn on <i>SimTool local CA</i>.</li>
          <li><b>Mac</b>: open the downloaded file; in Keychain Access open <i>SimTool local CA</i> → Trust → <i>Always Trust</i>.</li>
          <li><b>Android</b> (Chrome): Settings → Security → Encryption &amp; credentials → Install a certificate → CA certificate, and pick the downloaded file.</li>
        </ul>
        <p class="note">Before turning its trust on, check that the device shows the SHA-256 fingerprint <code>simtool serve</code> printed and the viewer on that Mac shows under <b>Network</b>. The certificate can vouch only for local names (<code>.local</code>) and private addresses, and only that Mac holds its key.</p>
        """ : ""
        return page(title: "SimTool", body: """
        <h1>SimTool opens over HTTPS</h1>
        <p>The simulator's stream needs a secure page. Open</p>
        <p><a class="button" href="\(secureURL)">\(secureURL)</a></p>
        <p>— or scan the QR code under <b>Network</b> in the viewer on the Mac that runs SimTool.</p>
        \(install)
        """)
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(title)</title>
        <style>
        :root { color-scheme: light dark; --ink: light-dark(#1b1d20, #e8eaed); --ink2: light-dark(#5b6068, #a3a8b0); --bg: light-dark(#f6f7f9, #16181b); --card: light-dark(#fff, #1f2226); --line: light-dark(#dfe2e6, #33373d); --accent: light-dark(#1f5fd6, #6aa4ff); }
        body { margin: 0; padding: 24px 16px; background: var(--bg); color: var(--ink); font: 15px/1.5 -apple-system, system-ui, sans-serif; }
        main { max-width: 560px; margin: 0 auto; background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 20px 22px; }
        h1 { font-size: 20px; margin: 0 0 8px; } h2 { font-size: 16px; margin: 20px 0 6px; }
        p, li { color: var(--ink2); } b, i, code, h1, h2 { color: var(--ink); } code { font-size: 13px; }
        a { color: var(--accent); word-break: break-all; } .note { font-size: 13px; }
        .button { display: inline-block; padding: 8px 14px; border-radius: 8px; background: var(--accent); color: #fff; text-decoration: none; font-weight: 600; }
        ul { padding-left: 20px; }
        </style></head>
        <body><main>
        \(body)
        </main></body></html>
        """
    }
}
