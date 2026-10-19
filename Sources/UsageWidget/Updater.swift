import AppKit
import Observation
import UsageCore

/// Checks GitHub for a newer release and installs it with `install.sh` bundled in the app: the script is the one
/// that shipped with this version, nothing new is fetched and run, and it downloads the exact release tag.
@MainActor @Observable
final class Updater {
    enum Status: Equatable { case idle, checking, upToDate, failed(String), installing }

    /// The running version; nil outside an app bundle (`swift run`), then there is nothing to compare.
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private(set) var available: Release?
    private(set) var status: Status = .idle

    private static let lastCheckKey = "updateLastCheck"
    /// The latest release seen, `[tag, page URL]`: checks run once a day, and a restart in between
    /// must not forget a found update.
    private static let latestKey = "updateLatest"
    static let logPath = "~/Library/Logs/Agents Usage/update.log"

    init() {
        guard !Demo.isOn, let current, let saved = UserDefaults.standard.stringArray(forKey: Self.latestKey), saved.count == 2,
              let url = URL(string: saved[1]) else { return }
        let release = Release(tag: saved[0], url: url)
        if Updates.isNewer(release.version, than: current) { available = release }
    }

    /// Automatic check at launch and on popover opening, at most once a day. Only a successful check counts:
    /// without network the next popover opening tries again.
    func checkIfDue(enabled: Bool) {
        guard enabled, !Demo.isOn, status != .checking, status != .installing,
              Updates.isDue(lastCheck: UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date, now: Date())
        else { return }
        Task { await check(manual: false) }
    }

    /// A failed manual check shows its error; an automatic one stays quiet, no network is not news.
    func check(manual: Bool = true) async {
        // Demo mode keeps its hands off the real defaults; checking and installing never overlap.
        guard !Demo.isOn, let current, status != .checking, status != .installing else { return }
        status = .checking
        do {
            let latest = try await Updates.latest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            UserDefaults.standard.set([latest.tag, latest.url.absoluteString], forKey: Self.latestKey)
            available = Updates.isNewer(latest.version, than: current) ? latest : nil
            status = available == nil ? .upToDate : .idle
        } catch {
            status = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    /// The folder `install.sh` can update in place: the bundle keeps its standard name (the script installs
    /// "Agents Usage.app"), and both the folder and the bundle's own directories are writable, since the script
    /// quits the app before it deletes the bundle. Otherwise the update opens the release page.
    private var installDir: URL? {
        let app = Bundle.main.bundleURL, dir = app.deletingLastPathComponent()
        let mustWrite = [dir, app, app.appendingPathComponent("Contents"),
                         app.appendingPathComponent("Contents/MacOS"), app.appendingPathComponent("Contents/Resources")]
        guard app.lastPathComponent == "Agents Usage.app",
              mustWrite.allSatisfy({ FileManager.default.isWritableFile(atPath: $0.path) })
        else { return nil }
        return dir
    }

    var canInstall: Bool { available != nil && status != .checking && status != .installing }

    func install() {
        guard let release = available, canInstall else { return }
        guard let dir = installDir, let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            NSWorkspace.shared.open(release.url)
            return
        }
        do {
            // A copy outside the bundle, since the script replaces the bundle it would be read from.
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("agents-usage-update-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let copy = work.appendingPathComponent("install.sh")
            try fm.copyItem(at: script, to: copy)
            let log = URL(fileURLWithPath: (Self.logPath as NSString).expandingTildeInPath)
            try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [copy.path]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                                   "AGENTS_USAGE_VERSION": release.tag, "AGENTS_USAGE_DIR": dir.path]
            // Output to a file, not a pipe: the script outlives this app, and writing to a pipe with no
            // reader would kill it with SIGPIPE.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            // On success the script quits this app (pkill) before it exits, so the handler only runs on failure.
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in self?.status = .failed(L("Update failed, details in %@", Self.logPath)) }
            }
            try process.run()
            status = .installing
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
