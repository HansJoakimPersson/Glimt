import Darwin
import Foundation

/// Opt-in debug log shared by the host app and both Quick Look extensions (ADR-023).
///
/// Every process appends single lines to `~/Library/Logs/Glimt/Glimt.log` while General ›
/// Debug logging is on. Messages carry only formats, counts, timings and error types; callers must
/// never pass file names, paths, window titles or file contents. Nothing is written while disabled.
final class GlimtDebugLog: @unchecked Sendable {
    /// Severity labels written to each local debug log record.
    enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR" }

    /// The process that wrote a line, so interleaved host and extension output stays readable.
    enum Role: String {
        case app, preview, thumbnail

        /// Derives the role from the running bundle's Quick Look extension point, if any.
        static var current: Role {
            let point = (Bundle.main.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])?["NSExtensionPointIdentifier"] as? String
            switch point {
            case "com.apple.quicklook.preview": return .preview
            case "com.apple.quicklook.thumbnail": return .thumbnail
            default: return .app
            }
        }
    }

    static let filename = "Glimt.log"
    static let rotatedFilename = "Glimt.log.1"
    static let defaultMaximumFileBytes = 1_048_576

    /// The real user's log, resolved like the shared settings file (ADR-020). Test processes are
    /// redirected to a temporary folder so automated runs never touch the user's log.
    static let shared: GlimtDebugLog = {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let directory = isTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("GlimtDebugLog-Tests", isDirectory: true)
            : SettingsStore.realHomeDirectory.appendingPathComponent("Library/Logs/Glimt", isDirectory: true)
        return GlimtDebugLog(directory: directory, role: .current)
    }()

    let logFileURL: URL
    private let directory: URL
    private let role: Role
    private let maximumFileBytes: Int
    private let queue = DispatchQueue(label: "com.glimt.debug-log", qos: .utility)
    private let lock = NSLock()
    private var enabled = false
    private var lastRefresh: Date?

    /// Creates a logger rooted at a directory with a role tag and rotation size limit.
    init(directory: URL, role: Role, maximumFileBytes: Int = GlimtDebugLog.defaultMaximumFileBytes) {
        self.directory = directory
        self.role = role
        self.maximumFileBytes = maximumFileBytes
        logFileURL = directory.appendingPathComponent(Self.filename, isDirectory: false)
    }

    // MARK: State

    var isEnabled: Bool { lock.withLock { enabled } }

    /// Turns logging on or off; a change is itself logged so a session's boundaries are visible.
    func setEnabled(_ newValue: Bool) {
        let previous = lock.withLock { () -> Bool in
            let previous = enabled
            enabled = newValue
            return previous
        }
        guard previous != newValue else { return }
        enqueue(.info, newValue ? "Debug logging enabled." : "Debug logging disabled.")
    }

    /// Re-reads the enabled state at most once per `interval`, for processes that cannot observe
    /// the settings session. `load` runs on the caller's thread only when a refresh is due.
    func refreshEnabled(every interval: TimeInterval = 5, now: Date = Date(), _ load: () -> Bool) {
        let due = lock.withLock { () -> Bool in
            if let lastRefresh, now.timeIntervalSince(lastRefresh) < interval { return false }
            lastRefresh = now
            return true
        }
        if due { setEnabled(load()) }
    }

    // MARK: Logging

    /// Writes an informational message when debug logging is enabled.
    func info(_ message: @autoclosure () -> String) { log(.info, message) }
    /// Writes a warning message when debug logging is enabled.
    func warning(_ message: @autoclosure () -> String) { log(.warning, message) }
    /// Writes an error message when debug logging is enabled.
    func error(_ message: @autoclosure () -> String) { log(.error, message) }

    /// Waits until every queued line has been written; used by tests and orderly shutdown.
    func flush() { queue.sync {} }

    private func log(_ level: Level, _ message: () -> String) {
        // Build the message only when it will be written.
        guard isEnabled else { return }
        enqueue(level, message())
    }

    private func enqueue(_ level: Level, _ message: String) {
        let timestamp = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
        // One record per line: embedded line breaks would let a message forge further records.
        let flat = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let line = "\(timestamp) [\(role.rawValue)] [\(level.rawValue)] \(flat)\n"
        queue.async { [self] in append(Data(line.utf8)) }
    }

    // MARK: File I/O

    /// Appends with `O_APPEND` so lines from the host and both extensions never overwrite each
    /// other, and refuses a symlink in place of the log file. Failures are dropped silently: the
    /// log is a troubleshooting aid and must never affect previews.
    private func append(_ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var descriptor = open()
        guard descriptor >= 0 else { return }
        var info = stat()
        if fstat(descriptor, &info) == 0, Int(info.st_size) + data.count > maximumFileBytes, info.st_size > 0 {
            // Best-effort rotation; a concurrent writer may rotate first, which only shortens history.
            Darwin.close(descriptor)
            let rotated = directory.appendingPathComponent(Self.rotatedFilename, isDirectory: false)
            _ = logFileURL.withUnsafeFileSystemRepresentation { from in
                rotated.withUnsafeFileSystemRepresentation { to in
                    guard let from, let to else { return Int32(-1) }
                    return rename(from, to)
                }
            }
            descriptor = open()
            guard descriptor >= 0 else { return }
        }
        defer { Darwin.close(descriptor) }
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    private func open() -> Int32 {
        logFileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
    }
}
