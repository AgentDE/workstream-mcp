import Foundation

/// Reads and writes workstream files in one folder. Writes are atomic (a temporary file renamed over the
/// old one), and `update` holds a per-workstream lock file, so the app and the MCP server can both write.
public final class WorkstreamStore: @unchecked Sendable {
    public let directory: URL

    /// `WORKSTREAM_DIR` if set, else `~/.config/workstreams`.
    public static var defaultDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["WORKSTREAM_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/workstreams")
    }

    public init(directory: URL = WorkstreamStore.defaultDirectory) {
        self.directory = directory
    }

    /// Settings for every workstream in the folder, in `.settings.json` (a dot-file, so it's never read as a
    /// workstream). Read on each use, so a change reaches running servers at once.
    public struct Settings: Codable, Equatable, Sendable {
        /// The most Memory items a workstream holds; below 1 means no limit.
        public var memoryLimit: Int?
        public static let defaultMemoryLimit = 25
        public init(memoryLimit: Int? = nil) { self.memoryLimit = memoryLimit }
    }

    public var settingsURL: URL { directory.appendingPathComponent(".settings.json") }

    public func settings() -> Settings {
        (try? Data(contentsOf: settingsURL)).flatMap { try? Self.decoder.decode(Settings.self, from: $0) } ?? Settings()
    }

    public func saveSettings(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    /// The Memory limit in force: the setting, else 25; nil when there's none.
    public var memoryLimit: Int? {
        let limit = settings().memoryLimit ?? Settings.defaultMemoryLimit
        return limit > 0 ? limit : nil
    }

    /// Workstream ids are UUIDs or similar: letters, digits and dashes only, so an id is always a file name.
    public static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    public func url(for id: String) -> URL? {
        guard Self.isValidID(id) else { return nil }
        return directory.appendingPathComponent(id + ".json")
    }

    public func read(_ id: String) -> Workstream? {
        guard let url = url(for: id), let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Workstream.self, from: data)
    }

    public func write(_ workstream: Workstream) throws {
        guard let url = url(for: workstream.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try ensureDirectory()
        let data = try Self.encoder.encode(workstream)
        let temporary = directory.appendingPathComponent(".\(workstream.id).\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        if rename(temporary.path, url.path) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Reads the workstream (or starts an empty one), applies `change`, and writes it back if it changed,
    /// all under the workstream's lock.
    @discardableResult
    public func update(_ id: String, _ change: (inout Workstream) -> Void) throws -> Workstream {
        guard Self.isValidID(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try ensureDirectory()
        let lockPath = directory.appendingPathComponent(".\(id).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        let before = read(id)
        var workstream = before ?? Workstream(id: id)
        change(&workstream)
        if workstream != before { try write(workstream) }
        return workstream
    }

    /// Every workstream in the folder.
    public func all() -> [Workstream] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { file in (try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode(Workstream.self, from: $0) } }
    }

    /// Makes `to` the agent session's workstream: detaches it from any other (keeping its open asks there)
    /// and attaches it here, so a session is in exactly one workstream.
    public func moveAgent(session: String, kind: String, tab: String?, to target: String, folder: String? = nil) throws {
        for workstream in all() where workstream.id != target && workstream.agents.contains(where: { $0.session == session }) {
            try update(workstream.id) { $0.detach(session: session, clearAsks: false) }
        }
        try update(target) { workstream in
            workstream.attach(session: session, kind: kind, tab: tab)
            if workstream.folder == nil, let folder { workstream.folder = folder }
        }
    }

    /// Records which tab runs a session, as the files stand now: where some workstream lists the session (the
    /// agent may have switched since the caller looked), only its tab is noted there; a session listed nowhere
    /// joins `fallback`. An app's view of the files can be a moment old, so it never moves an agent itself.
    /// Returns the workstream the session is in.
    @discardableResult
    public func adopt(session: String, kind: String, tab: String, fallback: String, folder: String? = nil) throws -> String {
        guard let current = Self.sessionIndex(all())[session] else {
            try moveAgent(session: session, kind: kind, tab: tab, to: fallback, folder: folder)
            return fallback
        }
        if read(current)?.agents.first(where: { $0.session == session })?.tab != tab {
            try update(current) { $0.attach(session: session, kind: kind, tab: tab) }
        }
        return current
    }

    // MARK: Rules each agent session has received

    private var rulesSeenDirectory: URL { directory.appendingPathComponent(".rules-seen") }

    /// The workstream and rules version an agent session last received through a hook.
    public func rulesSeen(session: String) -> (workstream: String, updated: Date)? {
        guard Self.isValidID(session),
              let text = try? String(contentsOf: rulesSeenDirectory.appendingPathComponent(session), encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let seconds = Double(parts[1]) else { return nil }
        return (String(parts[0]), Date(timeIntervalSince1970: seconds))
    }

    public func markRulesSeen(session: String, workstream: String, updated: Date) {
        guard Self.isValidID(session), Self.isValidID(workstream) else { return }
        try? FileManager.default.createDirectory(at: rulesSeenDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let stamp = updated == .distantPast ? 0 : updated.timeIntervalSince1970
        try? "\(workstream) \(stamp)".write(to: rulesSeenDirectory.appendingPathComponent(session), atomically: true, encoding: .utf8)
    }

    // MARK: Requests to the app

    /// Something an agent asks the app to do in the agent's tab, e.g. open a file in its viewer. A small
    /// file in `.requests/`; the app reads it and deletes it.
    public struct Request: Codable, Equatable, Sendable {
        public var action: String
        public var session: String?
        public var tab: String?
        public var path: String?
        public var at: Date
        public init(action: String, session: String?, tab: String?, path: String?, at: Date = Date()) {
            self.action = action
            self.session = session
            self.tab = tab
            self.path = path
            self.at = at
        }
    }

    nonisolated(unsafe) private static var sequence = 0
    private static let sequenceLock = NSLock()

    public var requestsDirectory: URL { directory.appendingPathComponent(".requests") }

    public func post(_ request: Request) throws {
        try FileManager.default.createDirectory(at: requestsDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Named by time, then this process's sequence, so requests are taken in the order they were made.
        Self.sequenceLock.lock()
        Self.sequence += 1
        let sequence = Self.sequence
        Self.sequenceLock.unlock()
        let name = String(format: "%013.0f-%08d-", Date().timeIntervalSince1970 * 1000, sequence) + UUID().uuidString
        let temporary = requestsDirectory.appendingPathComponent("." + name + ".tmp")
        try Self.encoder.encode(request).write(to: temporary)
        if rename(temporary.path, requestsDirectory.appendingPathComponent(name + ".json").path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Takes the pending requests (oldest first), removing their files. Requests over an hour old are dropped.
    public func takeRequests(now: Date = Date()) -> [Request] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: requestsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var requests: [Request] = []
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            let request = (try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode(Request.self, from: $0) }
            try? FileManager.default.removeItem(at: file)
            if let request, now.timeIntervalSince(request.at) < 3600 { requests.append(request) }
        }
        return requests
    }

    /// Agent session id → its workstream id, over the given workstreams.
    public static func sessionIndex(_ workstreams: [Workstream]) -> [String: String] {
        // A session is in one workstream; if a crash between two writes left it in two, the later attach wins.
        var index: [String: (id: String, added: Date)] = [:]
        for workstream in workstreams {
            for agent in workstream.agents where (index[agent.session]?.added ?? .distantPast) <= agent.added {
                index[agent.session] = (workstream.id, agent.added)
            }
        }
        return index.mapValues(\.id)
    }

    /// Agent session id → the workstream it left when its tab closed (see `Workstream.former`).
    public static func formerIndex(_ workstreams: [Workstream]) -> [String: String] {
        var index: [String: String] = [:]
        for workstream in workstreams { for session in workstream.former ?? [] { index[session] = workstream.id } }
        return index
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = iso.date(from: text) ?? isoFractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        return decoder
    }()

    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
