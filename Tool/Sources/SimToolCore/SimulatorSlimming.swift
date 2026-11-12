import Foundation

/// A simulator without the background services an app under test does not
/// need — widgets and wallpaper posters, Siri and on-device intelligence,
/// Spotlight, iCloud, photo analysis, News, Health… A stock iOS 26 simulator
/// runs some 280 processes and keeps about 4 GB in them; slim, about 85 and
/// under 1 GB, and a boot costs a third of the CPU. That is what lets a Mac
/// that also builds — a CI runner — keep a simulator, or one Mac keep several.
///
/// Every simulator has its own list of launchd jobs turned off, which the
/// host's `launchd_sim` reads as the simulator boots:
/// `/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>/disabled.plist`,
/// a dictionary of job labels, `true` for off. Written while the simulator is
/// shut down, it holds from the next boot on, through reboots and `simctl
/// erase`, on iOS 18.5 and later (earlier runtimes forget it at reboot). It is
/// CoreSimulator's own and undocumented, so a slim boot is read back
/// (`launchctl print-disabled system` in the simulator). `simctl delete` leaves
/// the file behind.
///
/// The catalog of services and the ones never to turn off follow simslim's
/// (github.com/MobAI-App/simslim, MIT), which measured what each costs and
/// what wedges a simulator; Personal Voice's service is left on.
public enum SimulatorSlimming {
    public struct Category: Equatable, Sendable {
        public var id: String
        /// What stops working while the category is off.
        public var effect: String
        /// Job labels without the `com.apple.` prefix.
        public var names: [String]

        public var labels: [String] { names.map { SimulatorSlimming.prefix + $0 } }
    }

    static let prefix = "com.apple."

    public static let categories: [Category] = [
        Category(id: "widgets", effect: "Home and Lock Screen widgets, wallpaper posters and Live Activities stop updating", names: [
            "PosterBoard", "chronod", "liveactivitiesd", "navd",
        ]),
        Category(id: "siri", effect: "Siri, dictation's speech services and Apple Intelligence are unavailable", names: [
            "assistant_cdmd", "assistant_service", "siriactionsd", "siriinferenced", "siriknowledged", "sirittsd",
            "siri.context.service", "siri.acousticsignature", "corespeechd", "voiced",
            "speechmodeltrainingd", "intelligenceplatformd", "intelligencecontextd", "intelligenceflowd",
            "intelligencetasksd", "generativeexperiencesd", "knowledgeconstructiond", "naturallanguaged",
            "textunderstandingd", "modelcatalogd", "modelmanagerd", "mlhostd", "mlruntimed", "suggestd", "parsecd",
            "parsec-fbf", "proactiveeventtrackerd",
        ]),
        Category(id: "search", effect: "Spotlight and Settings search find nothing; Files' Recents and the document picker cannot load", names: [
            "searchd", "searchtoold", "spotlightknowledged", "spotlightknowledged.updater", "corespotlightservice",
        ]),
        Category(id: "icloud", effect: "iCloud, the Apple Account, iCloud Keychain sync and backups do not work (the device's own keychain does)", names: [
            "appleaccountd", "appleaccounttransparencyd", "appleidsetupd", "akd", "amsaccountsd", "amsengagementd",
            "amsondevicestoraged", "cloudd", "cloudphotod", "ckdiscretionaryd", "cloudsettingssyncagent", "bird",
            "syncdefaultsd", "cdpd", "sosd", "SecureBackupDaemon", "TrustedPeersHelper",
            "protectedcloudstorage.protectedcloudkeysyncing", "icloudmailagent", "icloudsubscriptionoptimizerd",
            "communicationtrustd",
        ]),
        Category(id: "store", effect: "push notifications, StoreKit and App Store testing, Wallet and media subscriptions do not work", names: [
            "appstored", "appstorecomponentsd", "apsd", "itunescloudd", "itunesstored", "storekitd", "amsaccountsd",
            "amsengagementd", "amsondevicestoraged", "passd", "financed", "videosubscriptionsd", "assetsubscriptiond",
            "musicd",
        ]),
        Category(id: "pim", effect: "Contacts, Calendar, Reminders and Mail — and the pickers apps show for them — may fail", names: [
            "email.maild", "exchangesyncd", "dataaccess.dataaccessd", "calaccessd", "remindd", "contactsd",
            "contacts.postersyncd", "peopled",
        ]),
        Category(id: "web", effect: "universal links, Safari sync and WebKit's background services (web push, ad attribution) do not work", names: [
            "SafariBookmarksSyncAgent", "Safari.History", "Safari.passwordbreachd", "Safari.SafeBrowsing.Service",
            "safarifetcherd", "WebBookmarks.webbookmarksd", "webkit.adattributiond", "webkit.webpushd", "webprivacyd",
            "swcd",
        ]),
        Category(id: "family", effect: "Family Sharing, Screen Time and usage tracking stop", names: [
            "familycircled", "FamilyControlsAgent", "familynotification", "askpermissiond", "asktod", "ScreenTimeAgent",
            "ScreenTimeSettingsAgent", "UsageTrackingAgent",
        ]),
        Category(id: "health", effect: "HealthKit, HomeKit and Fitness do not work", names: [
            "healthd", "healthappd", "healthcontentd", "healtheventsd", "healthrecordsd", "finhealthd", "homed",
            "homeeventsd", "fitcore", "fitcore.session", "fitnesscoachingd", "fitnessintelligenced", "activityawardsd",
            "activitysharingd",
        ]),
        Category(id: "photos", effect: "the photo picker and the Photos library may fail; photos are not analysed", names: [
            "photoanalysisd", "photosface", "mediaanalysisd", "mediaanalysisd.service", "mediastream.mstreamd",
            "medialibraryd", "assetsd", "assetsd.nebulad",
        ]),
        Category(id: "apps", effect: "News, Weather, Maps' background data, Tips and game controllers are unavailable", names: [
            "newsd", "weatherd", "Maps.mapssyncd", "Maps.mapspushd", "Maps.geocorrectiond", "maps.destinationd",
            "MapKit.SnapshotService", "jetpackassetd", "tipsd", "gamesaved", "GameController.gamecontrollerd",
        ]),
        Category(id: "messaging", effect: "iMessage, FaceTime and the identity services behind them do not work", names: [
            "identityservicesd", "ids_simd", "imautomatichistorydeletionagent", "imcore.imtransferagent",
            "imdpersistence.IMDPersistenceAgent", "facetimemessagestored", "telephonyutilities.callservicesd",
        ]),
        Category(id: "connectivity", effect: "AirDrop, Continuity, CarPlay, Watch pairing and Find My do not work", names: [
            "rapportd", "companiond", "carkitd", "wcd", "tvremoted", "avatarsd", "stickersd", "sociallayerd",
            "announced", "navd", "findmy.findmylocated",
        ]),
        Category(id: "telemetry", effect: "DeviceCheck, analytics, diagnostics and feedback services are unavailable", names: [
            "ap.adprivacyd", "ap.promotedcontentd", "diagnosticextensionsd", "feedbackd", "rtcreportingd",
            "securityuploadd", "geoanalyticsd", "triald", "followupd", "purplebuddy.budd", "devicecheckd",
        ]),
        Category(id: "mdm", effect: "MDM, declarative device management and configuration profiles that use it do not work", names: [
            "remotemanagementd", "RemoteManagementAgent", "managedassetsd",
        ]),
        Category(id: "other", effect: "Wallet, App Clips, accessibility asset downloads, merchant and business services are unavailable", names: [
            "financed", "passd", "merchantd", "coreidvd", "businessservicesd", "deviceaccessd", "replicatord", "linkd",
            "ind", "storagedatad", "StatusKitAgent", "countryd", "mobileassetd", "managedconfiguration.passcodenagd",
            "accessibility.axassetsd", "ClipServices.clipserviced",
        ]),
    ]

    /// What a slim simulator keeps by default, because apps under test reach
    /// for it: a category, or a single service and why.
    public static let keptCategories: [String] = ["pim"]
    public static let keptServices: [(label: String, why: String)] = [
        ("com.apple.apsd", "push notifications"),
        ("com.apple.swcd", "universal links"),
        ("com.apple.storekitd", "StoreKit testing"),
        ("com.apple.assetsd", "the photo picker"),
        ("com.apple.assetsd.nebulad", "the photo picker"),
        ("com.apple.medialibraryd", "the photo picker"),
    ]

    /// Never turned off, whatever is asked: these wedge a simulator — every
    /// `simctl` call hangs, SpringBoard restarts in a loop, it never boots —
    /// or leak (`assistantd`, which Spotlight needs), slow app launches
    /// (`gamed`) or break share sheets (`sharingd`).
    public static let neverOff: Set<String> = [
        "nanoregistryd", "nanoregistrylaunchd", "nanoprefsyncd.2", "nanotimekitcompaniond", "nanobackupd", "sleepd",
        "appprotectiond", "ManagedSettingsAgent", "managedconfiguration.profiled", "mobiletimerd", "routined", "biomed",
        "biomesyncd", "dmd", "donotdisturbd", "assistantd", "gamed", "sharingd", "SpringBoard", "backboardd",
    ].reduce(into: Set<String>()) { $0.insert(prefix + $1) }

    /// Every label the catalog may turn off: the only ones SimTool writes.
    public static var managedLabels: Set<String> {
        Set(categories.flatMap(\.labels))
    }

    /// The labels to turn off. By default every category but the kept ones,
    /// without the kept services; `all` turns off the whole catalog. `keep`
    /// names more to leave on: category ids, or service labels with or
    /// without `com.apple.`.
    public static func labelsToTurnOff(all: Bool = false, keep: [String] = []) throws -> Set<String> {
        var keptLabels = Set<String>()
        var keptIDs = Set(all ? [] : keptCategories)
        if !all { keptLabels.formUnion(keptServices.map(\.label)) }
        for raw in keep.flatMap({ $0.split(separator: ",") }).map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            if categories.contains(where: { $0.id == raw.lowercased() }) {
                keptIDs.insert(raw.lowercased())
                continue
            }
            let label = raw.hasPrefix(prefix) ? raw : prefix + raw
            guard managedLabels.contains(label) else {
                throw SimToolError("\(raw) is neither a category (\(categories.map(\.id).joined(separator: ", "))) nor a service SimTool turns off")
            }
            keptLabels.insert(label)
        }
        // A label in a kept category stays on even where another category lists it.
        for category in categories where keptIDs.contains(category.id) {
            keptLabels.formUnion(category.labels)
        }
        return managedLabels.subtracting(keptLabels).subtracting(neverOff)
    }

    /// Whether the runtime keeps the list across reboots, else why not.
    /// `runtime` is CoreSimulator's identifier,
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4`.
    public static func refusal(runtime: String) -> String? {
        let name = runtime.components(separatedBy: ".").last ?? runtime
        let parts = name.split(separator: "-")
        guard parts.first == "iOS" else {
            return "SimTool slims iOS simulators; this one runs \(name)"
        }
        let numbers = parts.dropFirst().compactMap { Int($0) }
        let version = (numbers.first ?? 0, numbers.dropFirst().first ?? 0)
        guard version >= (18, 5) else {
            return "iOS \(numbers.map(String.init).joined(separator: ".")) forgets the services turned off at its next reboot; a slim simulator needs iOS 18.5 or later"
        }
        return nil
    }

    /// The simulator's list of jobs turned off, on the host.
    public static func overridesURL(udid: String, root: URL = URL(fileURLWithPath: "/private/var/tmp")) -> URL {
        root.appendingPathComponent("com.apple.CoreSimulator.SimDevice.\(udid)", isDirectory: true)
            .appendingPathComponent("disabled.plist")
    }

    /// The list as it is: label → turned off. Empty when there is none.
    public static func readOverrides(at url: URL) throws -> [String: Bool] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SimToolError("\(url.path) is not a dictionary of launchd labels")
        }
        return list.compactMapValues { $0 as? Bool }
    }

    /// Turns `off` the given labels and returns the rest of the catalog to the
    /// runtime's own defaults (their entries go); labels outside the catalog
    /// keep whatever entry they have. Written whole and in one move, the
    /// folder private to this user, as CoreSimulator makes it. No catalog
    /// entry and nothing else left: the file goes.
    public static func writeOverrides(off: Set<String>, at url: URL) throws {
        var list = try readOverrides(at: url)
        for label in managedLabels { list.removeValue(forKey: label) }
        for label in off { list[label] = true }
        let manager = FileManager.default
        if list.isEmpty {
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            return
        }
        let folder = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: folder.path) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
        let staging = folder.appendingPathComponent(".disabled.plist.\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: staging)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staging.path)
        guard rename(staging.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? manager.removeItem(at: staging)
            throw SimToolError("Could not write \(url.path): \(reason)")
        }
    }

    /// `launchctl print-disabled system` as the booted simulator answers it:
    /// `"com.apple.chronod" => disabled` lines, label → turned off.
    public static func parsePrintDisabled(_ text: String) -> [String: Bool] {
        var list: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            if state.hasPrefix("disabled") || state == "true" { list[label] = true }
            if state.hasPrefix("enabled") || state == "false" { list[label] = false }
        }
        return list
    }

    /// Which categories the given list turns off — wholly or in part.
    public static func summary(off: Set<String>) -> (off: [String], partly: [String], on: [String]) {
        var result: (off: [String], partly: [String], on: [String]) = ([], [], [])
        for category in categories {
            let count = category.labels.filter(off.contains).count
            if count == 0 { result.on.append(category.id) }
            else if count == category.labels.count { result.off.append(category.id) }
            else { result.partly.append(category.id) }
        }
        return result
    }
}

/// What `simtool device slim` did, or found with `--status`.
public struct SimulatorSlimPayload: Codable, Equatable, Sendable {
    public var udid: String
    public var name: String
    /// The catalog's services turned off.
    public var servicesOff: Int
    public var categoriesOff: [String]
    /// Categories some of whose services are kept on (`--keep`, or the defaults).
    public var categoriesPartly: [String]
    public var categoriesOn: [String]
    /// Whether the simulator was shut down and booted again to change it.
    public var rebooted: Bool
    /// Read back from the booted simulator: true when it reports exactly what
    /// was written; nil when it is shut down and the list waits for its boot.
    public var verified: Bool?
    /// Labels the booted simulator does not report as written.
    public var mismatched: [String]?
    /// The list's file on the host.
    public var overrides: String

    public init(udid: String, name: String, servicesOff: Int, categoriesOff: [String], categoriesPartly: [String], categoriesOn: [String], rebooted: Bool, verified: Bool?, mismatched: [String]?, overrides: String) {
        self.udid = udid
        self.name = name
        self.servicesOff = servicesOff
        self.categoriesOff = categoriesOff
        self.categoriesPartly = categoriesPartly
        self.categoriesOn = categoriesOn
        self.rebooted = rebooted
        self.verified = verified
        self.mismatched = mismatched
        self.overrides = overrides
    }
}
