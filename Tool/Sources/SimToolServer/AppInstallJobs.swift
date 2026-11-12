import Foundation
import SimToolCore

/// `POST /api/v1/app/install` with a JSON body: a build to fetch from a URL,
/// install, and maybe launch — what a page in front of a shared Mac sends when
/// someone picks a CI build to try.
struct AppInstallURLRequest: Decodable {
    var url: String?
    /// Sent to `url` alone (a bucket's bearer token); never logged or echoed.
    var headers: [String: String]?
    /// The `.app` inside the archive, when it holds several.
    var app: String?
    /// Remove the app and its data first.
    var clean: Bool?
    var launch: AppInstallLaunch?
    /// Free text the job carries back — who asked, which build.
    var label: String?
}

struct AppInstallLaunch: Codable, Equatable, Sendable {
    var arguments: [String]?
    var environment: [String: String]?
}

/// `POST /api/v1/app/launch`: launches an installed app — again, if it runs.
struct AppLaunchRequest: Decodable {
    var bundleId: String
    var arguments: [String]?
    var environment: [String: String]?
}

/// One install from a URL, as `GET /api/v1/app/install` answers it.
struct AppInstallJob: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case downloading, unpacking, installing, launching, done, failed
    }

    var id: String
    var state: State
    /// The URL without its query or credentials.
    var source: String
    var app: String?
    var label: String?
    var receivedBytes: Int64?
    var totalBytes: Int64?
    /// The build was already on this Mac: nothing was downloaded.
    var cached: Bool
    var bundleId: String?
    var name: String?
    var version: String?
    var build: String?
    var pid: Int?
    var error: String?
    var startedAt: Date
    var finishedAt: Date?

    var isRunning: Bool { state != .done && state != .failed }
}

/// The server's install from a URL: one at a time, the last one kept to be read.
final class AppInstallJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var job: AppInstallJob?

    var current: AppInstallJob? { lock.withLock { job } }

    var isRunning: Bool { lock.withLock { job?.isRunning ?? false } }

    /// Starts `candidate` unless a job runs: answers the job now in charge and
    /// whether it is the new one.
    func start(_ candidate: AppInstallJob) -> (job: AppInstallJob, started: Bool) {
        lock.withLock {
            if let running = job, running.isRunning { return (running, false) }
            job = candidate
            return (candidate, true)
        }
    }

    @discardableResult
    func update(id: String, _ change: (inout AppInstallJob) -> Void) -> AppInstallJob? {
        lock.withLock {
            guard var current = job, current.id == id else { return nil }
            change(&current)
            job = current
            return current
        }
    }

    /// How a job's progress reads in the activity feed.
    static func progressDetail(_ job: AppInstallJob) -> String {
        switch job.state {
        case .downloading:
            let received = megabytes(job.receivedBytes ?? 0)
            return job.totalBytes.map { "Downloading \(received) of \(megabytes($0)) MB" } ?? "Downloading \(received) MB"
        case .unpacking: return "Unpacking " + (job.app ?? "the app")
        case .installing: return "Installing" + (job.cached ? " (downloaded before)" : "")
        case .launching: return "Launching"
        case .done: return [job.bundleId, job.version.map { v in "v" + v + (job.build.map { " (\($0))" } ?? "") }].compactMap { $0 }.joined(separator: " · ")
        case .failed: return job.error ?? "failed"
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(Int((Double(bytes) / 1_000_000).rounded()))
    }
}
