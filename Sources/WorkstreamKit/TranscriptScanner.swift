import Foundation

/// What a workstream shows from an agent's transcript, beyond its schedule: the files it touched, the
/// artifacts it published or linked, its cross-session messages, and usage totals for Stats.
public struct TranscriptFacts: Codable, Equatable, Sendable {
    public struct FileActivity: Codable, Equatable, Sendable {
        public var path: String
        public var edits = 0
        public var reads = 0
        public var lastEdit: Date?
        public var lastTouch: Date
        public init(path: String, lastTouch: Date) { self.path = path; self.lastTouch = lastTouch }
    }

    public struct Artifact: Codable, Equatable, Sendable {
        public var url: String
        public var title: String?
        public var at: Date
        public init(url: String, title: String? = nil, at: Date) { self.url = url; self.title = title; self.at = at }
    }

    /// A cross-session message (Claude Code's `SendMessage` and the peer messages it delivers).
    public struct Message: Codable, Equatable, Sendable {
        /// Sent by this agent (true) or delivered to it.
        public var outgoing: Bool
        /// The other session's name (or a subagent's id).
        public var peer: String
        public var text: String
        public var at: Date
        public var id: String?
        public init(outgoing: Bool, peer: String, text: String, at: Date, id: String? = nil) {
            self.outgoing = outgoing
            self.peer = peer
            self.text = text
            self.at = at
            self.id = id
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var input = 0
        public var output = 0
        public var cacheRead = 0
        public var cacheWrite5m = 0
        public var cacheWrite1h = 0
        public init() {}
        public static func + (a: Usage, b: Usage) -> Usage {
            var r = Usage()
            r.input = a.input + b.input
            r.output = a.output + b.output
            r.cacheRead = a.cacheRead + b.cacheRead
            r.cacheWrite5m = a.cacheWrite5m + b.cacheWrite5m
            r.cacheWrite1h = a.cacheWrite1h + b.cacheWrite1h
            return r
        }
        public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
        public var allInput: Int { input + cacheRead + cacheWrite }
    }

    /// One local day's share: usage per model, and time in turns.
    public struct Day: Codable, Equatable, Sendable {
        public var usage: [String: Usage] = [:]
        public var activeSeconds: Double = 0
        public init() {}
    }

    public var files: [String: FileActivity] = [:]
    /// By local day ("2026-10-21", `dayKey`), the last `dayLimit` days with activity, for the Usage widget.
    public var days: [String: Day] = [:]
    /// Oldest first.
    public var artifacts: [Artifact] = []
    /// Oldest first.
    public var messages: [Message] = []
    /// Reply addresses of sessions that messaged in (`uds:/tmp/cc-socks/1229.sock`) and the name each last used.
    public var peerNames: [String: String] = [:]
    /// Per model, for messages that are finished (see `TranscriptScanner`, which adds the one in progress).
    public var usage: [String: Usage] = [:]
    public var linesAdded = 0
    public var linesRemoved = 0
    public var toolCalls = 0
    public var compactions = 0
    /// Time spent in turns (Claude's `turn_duration` records), in seconds.
    public var activeSeconds: Double = 0
    public var firstAt: Date?
    public var lastAt: Date?

    public init() {}

    public static let fileLimit = 3000
    public static let artifactLimit = 100
    public static let messageLimit = 60
    public static let dayLimit = 60

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Files edited, newest first.
    public func recentFiles(_ limit: Int = 8) -> [FileActivity] {
        Array(files.values.filter { $0.lastEdit != nil }.sorted { $0.lastEdit! > $1.lastEdit! }.prefix(limit))
    }

    /// Files touched most (edits and reads), most first.
    public func highActivity(_ limit: Int = 5) -> [FileActivity] {
        Array(files.values.filter { $0.edits + $0.reads > 1 }
            .sorted { ($0.edits + $0.reads, $0.lastTouch) > ($1.edits + $1.reads, $1.lastTouch) }.prefix(limit))
    }

    public var totalUsage: Usage { usage.values.reduce(Usage(), +) }

    // MARK: Recording

    mutating func touch(_ path: String, edit: Bool, at date: Date) {
        guard path.hasPrefix("/") else { return }
        var file = files[path] ?? FileActivity(path: path, lastTouch: date)
        if edit {
            file.edits += 1
            file.lastEdit = max(file.lastEdit ?? date, date)
        } else {
            file.reads += 1
        }
        file.lastTouch = max(file.lastTouch, date)
        files[path] = file
        if files.count > Self.fileLimit {
            for stale in files.values.sorted(by: { $0.lastTouch < $1.lastTouch }).prefix(files.count - Self.fileLimit) {
                files[stale.path] = nil
            }
        }
    }

    mutating func addUsage(_ added: Usage, model: String, day: String?) {
        usage[model] = (usage[model] ?? .init()) + added
        guard let day else { return }
        days[day, default: Day()].usage[model] = (days[day]?.usage[model] ?? .init()) + added
        trimDays()
    }

    mutating func addActive(_ seconds: Double, at date: Date) {
        activeSeconds += seconds
        days[Self.dayKey(date), default: Day()].activeSeconds += seconds
        trimDays()
    }

    private mutating func trimDays() {
        guard days.count > Self.dayLimit else { return }
        for key in days.keys.sorted().prefix(days.count - Self.dayLimit) { days[key] = nil }
    }

    mutating func addArtifact(_ url: String, title: String?, at date: Date) {
        if let index = artifacts.firstIndex(where: { $0.url == url }) {
            var artifact = artifacts.remove(at: index)
            artifact.at = max(artifact.at, date)
            if let title, !title.isEmpty { artifact.title = title }
            artifacts.append(artifact)
        } else {
            artifacts.append(Artifact(url: url, title: title, at: date))
        }
        if artifacts.count > Self.artifactLimit { artifacts.removeFirst(artifacts.count - Self.artifactLimit) }
    }

    mutating func addMessage(_ message: Message) {
        // A reply sent to an address (`uds:/tmp/cc-socks/…`) shows the name that address last messaged in with.
        var message = message
        if message.outgoing, message.peer.hasPrefix("uds:"), let name = peerNames[message.peer] { message.peer = name }
        // The same delivery can be recorded more than once: queued, as an attachment, and as the prompt it became,
        // which can be long after it was queued if the agent was busy.
        if messages.suffix(20).contains(where: {
            ($0.id != nil && $0.id == message.id)
                || ($0.outgoing == message.outgoing && $0.peer == message.peer && $0.text == message.text
                    && abs($0.at.timeIntervalSince(message.at)) < (message.outgoing ? 120 : 6 * 3600))
        }) { return }
        messages.append(message)
        if messages.count > Self.messageLimit { messages.removeFirst(messages.count - Self.messageLimit) }
    }
}

/// Links worth showing as artifacts: Claude artifacts, links matching the app's extra rules (an extension's
/// artifact pages, say), and local HTML pages an agent names by path.
public enum ArtifactLinks {
    /// A kind of link that counts as an artifact.
    public struct Rule: @unchecked Sendable {
        /// A regular expression matching the whole link.
        public var pattern: String
        /// Text every such link contains, to skip transcript lines quickly ("claude.ai/").
        public var marker: String
        /// One form per artifact; nil when the match names nothing.
        public var canonical: (String) -> String?
        /// The address to load.
        public var openURL: (String) -> String
        /// A title from the link itself.
        public var title: (String) -> String?
        let regex: NSRegularExpression?

        public init(pattern: String, marker: String, canonical: @escaping (String) -> String? = { $0 },
                    openURL: @escaping (String) -> String = { $0 }, title: @escaping (String) -> String? = { _ in nil }) {
            self.pattern = pattern
            self.marker = marker
            self.canonical = canonical
            self.openURL = openURL
            self.title = title
            regex = try? NSRegularExpression(pattern: pattern)
        }
    }

    /// Claude artifact links.
    public static let claude = Rule(pattern: #"https://claude\.ai/(?:code/)?artifacts?/[A-Za-z0-9_-]{8,}"#, marker: "claude.ai/",
                                    title: { _ in "Claude artifact" })

    /// Rules beyond Claude's, set by the app at launch.
    nonisolated(unsafe) public static var rules: [Rule] = []
    static var allRules: [Rule] { [claude] + rules }
    /// Text that any artifact link contains, for skipping lines quickly.
    static var markers: [Data] { allRules.map { Data($0.marker.utf8) } }

    /// An absolute or `~` path ending in .html or .htm, not part of a URL.
    nonisolated(unsafe) private static let localPagePattern = try! NSRegularExpression(
        pattern: #"(?<![\w:/.~-])(?:~/|/)[^\s"'<>`()\[\]*]+?\.html?(?!\w|/|-|\.\w)"#)

    /// The local HTML pages named in `text`, as absolute paths, in order, without duplicates.
    public static func localPages(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return localPagePattern.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            let path = (String(text[r]) as NSString).expandingTildeInPath
            return seen.insert(path).inserted ? path : nil
        }
    }

    /// The artifact links in `text`, canonical (see `canonical`), in order, without duplicates.
    public static func find(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [(Int, String)] = []
        for rule in allRules where text.contains(rule.marker) {
            for match in rule.regex?.matches(in: text, range: range) ?? [] {
                guard let r = Range(match.range, in: text), let link = canonical(String(text[r]), rule: rule) else { continue }
                found.append((match.range.location, link))
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0).inserted }
    }

    /// The rule a link matches, if any.
    static func rule(for link: String) -> Rule? {
        allRules.first { rule in
            rule.regex.map { regex in regex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)) != nil } ?? false
        }
    }

    private static func canonical(_ link: String, rule: Rule) -> String? {
        var link = link
        while let last = link.last, ".,;:!?*_'\"".contains(last) { link.removeLast() }
        return rule.canonical(link)
    }

    /// One form per artifact (a rule can map several links to one page); nil for a link that names no artifact.
    public static func canonical(_ link: String) -> String? {
        rule(for: link).flatMap { canonical(link, rule: $0) }
    }

    /// The address to load for an artifact link; anything else as it is.
    public static func openURL(_ link: String) -> String { rule(for: link)?.openURL(link) ?? link }

    /// A title from the link itself: a local page's file name without its extension, else the rule's.
    public static func title(for link: String) -> String {
        if link.hasPrefix("/") { return ((link as NSString).lastPathComponent as NSString).deletingPathExtension }
        return rule(for: link)?.title(link) ?? link
    }

    public static func isArtifact(_ link: String) -> Bool { !find(in: link).isEmpty }
}

/// Reads an agent's transcript incrementally, in chunks: each scan reads only what was appended. Collects
/// `TranscriptFacts` and feeds the same lines to a `ScheduleScanner`, so one pass covers both. Its state can
/// be saved and loaded (`snapshot`), so a long transcript is read once, not on every launch.
/// Claude Code transcripts (`~/.claude/projects/<folder>/<session>.jsonl`) and Codex session logs
/// (`~/.codex/sessions/…/rollout-…-<id>.jsonl`, file edits only) are understood.
/// Not thread-safe.
public final class TranscriptScanner: @unchecked Sendable {
    public enum Format: String, Codable, Sendable { case claude, codex }

    public let format: Format
    public private(set) var facts = TranscriptFacts()
    public private(set) var offset: UInt64 = 0
    let schedules: ScheduleScanner
    private var partial = Data()
    private var inode: UInt64 = 0
    private var pending: [String: Pending] = [:]
    /// The assistant message being written (its lines share an id; its usage is final on its last line).
    private var current: Current?

    struct Pending: Codable {
        var name: String
        var path: String?
        var action: String?
        var lines: Int?
        /// SendMessage: who it's to and what it says, recorded once the send reports success.
        var peer: String?
        var text: String?
    }

    struct Current: Codable {
        var id: String
        var model: String
        var usage: TranscriptFacts.Usage
        /// The local day it was sent (`TranscriptFacts.dayKey`).
        var day: String?
    }

    public init(format: Format = .claude) {
        self.format = format
        schedules = ScheduleScanner()
    }

    public var schedule: Schedule { schedules.schedule }

    /// Facts with the message in progress counted.
    public var currentFacts: TranscriptFacts {
        guard let current else { return facts }
        var f = facts
        f.addUsage(current.usage, model: current.model, day: current.day)
        return f
    }

    // MARK: Snapshot

    struct Snapshot: Codable {
        /// 5: names for reply addresses, sends only once they succeed (4: messages queued for the agent; 3: usage by day; 2: local HTML pages as artifacts); transcripts read
        /// before are read again.
        static let current = 5
        var version = current
        var format: Format
        var offset: UInt64
        var inode: UInt64
        var facts: TranscriptFacts
        var pending: [String: Pending]
        var current: Current?
        var schedule: ScheduleScanner.State
    }

    /// The scanner's state as JSON, to resume from later (`resume(from:)`).
    public func snapshot() -> Data? {
        // Up to the last whole line: the rest is read again on resume.
        let snap = Snapshot(format: format, offset: offset - UInt64(partial.count), inode: inode, facts: facts, pending: pending, current: current,
                            schedule: schedules.state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(snap)
    }

    /// A scanner resuming from `data`, or nil when it's unreadable or of another format.
    public static func resume(from data: Data) -> TranscriptScanner? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snap = try? decoder.decode(Snapshot.self, from: data), snap.version == Snapshot.current else { return nil }
        let scanner = TranscriptScanner(format: snap.format, schedules: ScheduleScanner(state: snap.schedule))
        scanner.offset = snap.offset
        scanner.inode = snap.inode
        scanner.facts = snap.facts
        scanner.pending = snap.pending
        scanner.current = snap.current
        return scanner
    }

    private init(format: Format, schedules: ScheduleScanner) {
        self.format = format
        self.schedules = schedules
    }

    // MARK: Reading

    /// Reads what's new. Returns whether anything changed. A file that shrank or was replaced is read again
    /// from the start.
    @discardableResult
    public func scan(_ url: URL, chunk: Int = 4 << 20) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let node = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset || (inode != 0 && node != 0 && node != inode) { reset() }
        inode = node
        guard size > offset else { return false }
        try? handle.seek(toOffset: offset)
        var changed = false
        while offset < size {
            // Each chunk's parsed JSON is released before the next one is read.
            let more: Bool = autoreleasepool {
                guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { return false }
                offset += UInt64(data.count)
                let buffer = partial.isEmpty ? data : partial + data
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    if process(buffer[start..<newline]) { changed = true }
                    start = buffer.index(after: newline)
                }
                partial = Data(buffer[start...])
                return true
            }
            if !more { break }
        }
        return changed
    }

    private func reset() {
        offset = 0
        partial = Data()
        pending = [:]
        current = nil
        facts = TranscriptFacts()
        schedules.resetForRescan()
    }

    /// Claude Code's own records (`{"type":"api-request…`, titles, queue operations, last prompts) start with
    /// their type; conversation lines (user, assistant, attachment, system) start with `parentUuid`.
    private static let recordPrefix = Data(#"{"type":""#.utf8)
    private static let systemMarker = Data(#""type":"system""#.utf8)
    private static let attachmentMarker = Data(#""type":"attachment""#.utf8)
    private static let peerMarker = Data(#""kind":"peer""#.utf8)
    private static let crossSessionMarker = Data("<cross-session-message".utf8)
    private static let enqueuePrefix = Data(#"{"type":"queue-operation","operation":"enqueue""#.utf8)
    private static let toolResultMarker = Data(#""tool_result""#.utf8)
    private static let patchMarker = Data("*** ".utf8)

    private func process(_ line: Data) -> Bool {
        guard !line.isEmpty else { return false }
        switch format {
        case .codex: return processCodex(line)
        case .claude:
            if line.starts(with: Self.recordPrefix) {
                // A message from another session is queued for the agent and recorded only here when it's taken
                // in mid-turn, so this is the one kind of Claude Code record read.
                return line.starts(with: Self.enqueuePrefix) && line.range(of: Self.crossSessionMarker) != nil && queued(line)
            }
            var changed = schedules.consume(line)
            let role = Self.role(of: line)
            if role == "assistant" {
                changed = assistant(line) || changed
            } else if role == nil, line.range(of: Self.systemMarker) != nil {
                changed = system(line) || changed
            } else if role == nil, line.range(of: Self.attachmentMarker) != nil {
                if line.range(of: Self.peerMarker) != nil { changed = attachment(line) || changed }
            } else {
                let interesting = (!pending.isEmpty && line.range(of: Self.toolResultMarker) != nil)
                    || line.range(of: Self.crossSessionMarker) != nil
                    || ArtifactLinks.markers.contains { line.range(of: $0) != nil }
                if interesting { changed = user(line) || changed }
                else { stamp(line) }
            }
            return changed
        }
    }

    private static let roleKey = Data(#""role":""#.utf8)

    /// The role of the line's message: the first `"role":"…"` in it (the message comes before any tool
    /// result, which can hold messages of its own). Nil for system records and attachments.
    static func role(of line: Data) -> String? {
        guard let key = line.range(of: roleKey) else { return nil }
        let start = key.upperBound
        guard let end = line[start...].prefix(16).firstIndex(of: 0x22) else { return nil }
        return String(decoding: line[start..<end], as: UTF8.self)
    }

    private static let timestampKey = Data(#""timestamp":""#.utf8)

    /// The line's top-level timestamp: the last `"timestamp":"…"` in it (it follows the message object).
    static func timestamp(of line: Data) -> Date? {
        guard let key = line.range(of: timestampKey, options: .backwards) else { return nil }
        let start = key.upperBound
        guard let end = line[start...].firstIndex(of: 0x22) else { return nil }
        return ScheduleScanner.parseDate(String(decoding: line[start..<end], as: UTF8.self))
    }

    private func stamp(_ line: Data) {
        if let date = Self.timestamp(of: line) { note(date) }
    }

    private func note(_ date: Date) {
        if facts.firstAt == nil || date < facts.firstAt! { facts.firstAt = date }
        if facts.lastAt == nil || date > facts.lastAt! { facts.lastAt = date }
    }

    private func object(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private func date(_ object: [String: Any]) -> Date {
        let date = (object["timestamp"] as? String).flatMap(ScheduleScanner.parseDate) ?? facts.lastAt ?? Date()
        note(date)
        return date
    }

    private static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private func assistant(_ line: Data) -> Bool {
        guard let object = object(line), let message = object["message"] as? [String: Any] else { return false }
        let at = date(object)
        var changed = false
        if let id = message["id"] as? String, let model = message["model"] as? String, model != "<synthetic>",
           let usage = message["usage"] as? [String: Any] {
            let parsed = Self.usage(usage)
            if current?.id == id {
                current?.usage = parsed
            } else {
                if let current { facts.addUsage(current.usage, model: current.model, day: current.day) }
                current = Current(id: id, model: Self.shortModel(model), usage: parsed, day: TranscriptFacts.dayKey(at))
            }
            changed = true
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                facts.toolCalls += 1
                changed = true
                if Self.editTools.contains(name), let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                    facts.touch(path, edit: true, at: at)
                    pending[id] = Pending(name: name, path: path,
                                          lines: name == "Write" ? (input["content"] as? String).map(Self.lineCount) : nil)
                } else if name == "Read", let path = input["file_path"] as? String {
                    facts.touch(path, edit: false, at: at)
                } else if name == "SendMessage", let to = (input["to"] ?? input["recipient"]) as? String,
                          let text = (input["message"] ?? input["content"]) as? String {
                    pending[id] = Pending(name: name, peer: to, text: text)
                } else if name == "Artifact" {
                    pending[id] = Pending(name: name, action: (input["action"] as? String) ?? "publish")
                }
            case "text":
                let text = block["text"] as? String ?? ""
                for link in ArtifactLinks.find(in: text) + ArtifactLinks.localPages(in: text) {
                    facts.addArtifact(link, title: nil, at: at)
                    changed = true
                }
            default:
                break
            }
        }
        if pending.count > 500 { pending.removeAll() }
        return changed
    }

    private func user(_ line: Data) -> Bool {
        guard let object = object(line), let message = object["message"] as? [String: Any] else { return false }
        let at = date(object)
        var changed = false
        if let text = message["content"] as? String {
            if let peer = Self.crossSession(text) {
                if let address = peer.address { facts.peerNames[address] = peer.from }
                facts.addMessage(.init(outgoing: false, peer: peer.from, text: peer.body, at: at))
                changed = true
            }
            for link in ArtifactLinks.find(in: text) { facts.addArtifact(link, title: nil, at: at); changed = true }
            return changed
        }
        let result = object["toolUseResult"]
        for block in message["content"] as? [[String: Any]] ?? [] {
            if block["type"] as? String == "text", let text = block["text"] as? String {
                for link in ArtifactLinks.find(in: text) { facts.addArtifact(link, title: nil, at: at); changed = true }
                continue
            }
            guard block["type"] as? String == "tool_result" else { continue }
            let call = (block["tool_use_id"] as? String).flatMap { pending.removeValue(forKey: $0) }
            let failed = block["is_error"] as? Bool == true
            if let call, !failed {
                switch call.name {
                case "SendMessage":
                    // A send to an address that's gone (a session that restarted) fails, and wasn't a message.
                    if (result as? [String: Any])?["success"] as? Bool != false, let peer = call.peer, let text = call.text {
                        facts.addMessage(.init(outgoing: true, peer: peer, text: text, at: at, id: block["tool_use_id"] as? String))
                        changed = true
                    }
                    continue
                case "Artifact":
                    if let result = result as? [String: Any], let url = result["url"] as? String,
                       ["publish", "create"].contains(call.action ?? "publish") || result["path"] != nil,
                       let link = ArtifactLinks.canonical(url), link.hasPrefix("https://claude.ai/") {
                        facts.addArtifact(link, title: result["title"] as? String, at: at)
                        changed = true
                    }
                    continue   // its listings and type links aren't this agent's artifacts
                default:
                    if Self.editTools.contains(call.name) {
                        let (added, removed) = Self.patchLines(result, fallbackAdded: call.lines)
                        facts.linesAdded += added
                        facts.linesRemoved += removed
                        changed = true
                    }
                }
            }
            // Artifact links (from the app's rules) a tool printed (an upload, say). Claude artifact links in tool output are
            // mostly listings, so they come only from publishes and the agent's own text.
            for link in ArtifactLinks.find(in: Self.text(of: block["content"])) where !link.hasPrefix("https://claude.ai/") {
                facts.addArtifact(link, title: nil, at: at)
                changed = true
            }
        }
        return changed
    }

    private func attachment(_ line: Data) -> Bool {
        guard let object = object(line), let attachment = object["attachment"] as? [String: Any],
              let origin = attachment["origin"] as? [String: Any], origin["kind"] as? String == "peer",
              let body = origin["body"] as? String else { return false }
        let at = date(object)
        let peer = (origin["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "another session"
        facts.addMessage(.init(outgoing: false, peer: peer, text: body, at: at, id: origin["msg_id"] as? String))
        return true
    }

    /// `{"type":"queue-operation","operation":"enqueue","content":"<cross-session-message …>body</…>"}`: a peer
    /// message as Claude Code queues it. (Its later `remove` record repeats the content; only the enqueue counts.)
    private func queued(_ line: Data) -> Bool {
        guard let object = object(line), let content = object["content"] as? String,
              let peer = Self.crossSession(content) else { return false }
        if let address = peer.address { facts.peerNames[address] = peer.from }
        facts.addMessage(.init(outgoing: false, peer: peer.from, text: peer.body, at: date(object)))
        return true
    }

    private func system(_ line: Data) -> Bool {
        guard let object = object(line) else { return false }
        let at = date(object)
        switch object["subtype"] as? String {
        case "compact_boundary":
            facts.compactions += 1
            return true
        case "turn_duration":
            if let ms = (object["durationMs"] as? NSNumber)?.doubleValue { facts.addActive(ms / 1000, at: at) }
            return true
        default:
            return false
        }
    }

    // MARK: Codex

    private func processCodex(_ line: Data) -> Bool {
        guard line.range(of: Self.patchMarker) != nil, let object = object(line),
              let payload = object["payload"] as? [String: Any] else {
            if line.count < 4096 { stamp(line) }
            return false
        }
        guard ["custom_tool_call", "function_call", "local_shell_call"].contains(payload["type"] as? String ?? "") else { return false }
        var input = (payload["input"] as? String) ?? (payload["arguments"] as? String) ?? ""
        guard input.contains("*** Begin Patch") else { return false }
        let at = date(object)
        // The patch is often a string literal inside the call (its newlines escaped).
        if !input.contains("\n*** ") { input = input.replacingOccurrences(of: "\\n", with: "\n") }
        var changed = false
        for raw in input.components(separatedBy: "\n") {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where raw.hasPrefix(prefix) {
                facts.touch(String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces), edit: true, at: at)
                changed = true
            }
            if raw.hasPrefix("+"), !raw.hasPrefix("+++") { facts.linesAdded += 1 }
            if raw.hasPrefix("-"), !raw.hasPrefix("---") { facts.linesRemoved += 1 }
        }
        if changed { facts.toolCalls += 1 }
        return changed
    }

    // MARK: Helpers

    static func usage(_ object: [String: Any]) -> TranscriptFacts.Usage {
        func int(_ key: String, _ from: [String: Any] = object) -> Int { (from[key] as? NSNumber)?.intValue ?? 0 }
        var usage = TranscriptFacts.Usage()
        usage.input = int("input_tokens")
        usage.output = int("output_tokens")
        usage.cacheRead = int("cache_read_input_tokens")
        if let creation = object["cache_creation"] as? [String: Any] {
            usage.cacheWrite5m = int("ephemeral_5m_input_tokens", creation)
            usage.cacheWrite1h = int("ephemeral_1h_input_tokens", creation)
        } else {
            usage.cacheWrite5m = int("cache_creation_input_tokens")
        }
        return usage
    }

    /// "claude-opus-5-5-20260101" → "claude-opus-5-5"; other names unchanged.
    static func shortModel(_ model: String) -> String {
        model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
    }

    /// Lines added and removed by an edit's result (`structuredPatch` hunks of "+…"/"-…" lines); a new file
    /// written whole counts its lines as added.
    static func patchLines(_ result: Any?, fallbackAdded: Int?) -> (Int, Int) {
        guard let result = result as? [String: Any] else { return (fallbackAdded ?? 0, 0) }
        var added = 0, removed = 0
        for hunk in result["structuredPatch"] as? [[String: Any]] ?? [] {
            for line in hunk["lines"] as? [String] ?? [] {
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
            }
        }
        if added == 0, removed == 0, result["type"] as? String == "create" {
            added = (result["content"] as? String).map(lineCount) ?? fallbackAdded ?? 0
        }
        return (added, removed)
    }

    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] { return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }

    /// A peer message as the prompt it became: `<cross-session-message from="uds:…" from-name="x" …>body</…>`: the sender's name, its reply address and the body.
    static func crossSession(_ text: String) -> (from: String, address: String?, body: String)? {
        guard let open = text.range(of: "<cross-session-message"), let close = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return nil }
        let attributes = String(text[open.upperBound..<close.lowerBound])
        func attribute(_ key: String) -> String? {
            attributes.range(of: " \(key)=\"[^\"]*\"", options: .regularExpression).map {
                String(String(attributes[$0]).dropFirst(key.count + 3).dropLast())
            }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let end = text.range(of: "</cross-session-message>", range: close.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        return (attribute("from-name") ?? "another session", attribute("from"),
                String(text[close.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Where transcripts' scan snapshots are kept: `~/Library/Caches/workstreams/transcripts/` (`WORKSTREAM_CACHE_DIR`
/// overrides). the app writes them; the MCP server reads them to start where the app left off.
public enum TranscriptCache {
    public static func directory(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["WORKSTREAM_CACHE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("workstreams")
    }

    static func file(session: String, in directory: URL) -> URL {
        directory.appendingPathComponent("transcripts").appendingPathComponent(session + ".json")
    }

    /// A scanner for this session's transcript, resumed from its snapshot when there is one.
    public static func scanner(session: String, format: TranscriptScanner.Format, directory: URL = directory()) -> TranscriptScanner {
        if WorkstreamStore.isValidID(session), let data = try? Data(contentsOf: file(session: session, in: directory)),
           let scanner = TranscriptScanner.resume(from: data), scanner.format == format {
            return scanner
        }
        return TranscriptScanner(format: format)
    }

    public static func save(_ scanner: TranscriptScanner, session: String, directory: URL = directory()) {
        guard WorkstreamStore.isValidID(session), let data = scanner.snapshot() else { return }
        let url = file(session: session, in: directory)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Codex session logs: `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<time>-<id>.jsonl`.
public enum CodexLogs {
    public static var directory: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions") }

    public static func log(session: String, in directory: URL = directory) -> URL? {
        guard WorkstreamStore.isValidID(session),
              let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let suffix = "-" + session + ".jsonl"
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) { return url }
        return nil
    }
}

/// The transcript facts of a workstream's agents, merged for display: Files' Recent and High activity,
/// Messages and Artifacts.
public struct WorkstreamActivity: Sendable {
    public struct File: Equatable, Sendable {
        public var path: String
        public var lastEdit: Date?
        public var count: Int
        public var agents: [String]
    }

    public struct AgentMessage: Equatable, Sendable {
        /// The agent session whose transcript it's in.
        public var agent: String
        public var message: TranscriptFacts.Message
    }

    public struct AgentArtifact: Equatable, Sendable {
        public var agent: String
        public var artifact: TranscriptFacts.Artifact
    }

    public let perAgent: [(agent: String, facts: TranscriptFacts)]

    public init(_ perAgent: [(agent: String, facts: TranscriptFacts)]) { self.perAgent = perAgent }

    public var isEmpty: Bool { perAgent.isEmpty }

    public func recentFiles(_ limit: Int = 8) -> [File] {
        var byPath: [String: File] = [:]
        for (agent, facts) in perAgent {
            for file in facts.files.values where file.lastEdit != nil {
                var merged = byPath[file.path] ?? File(path: file.path, lastEdit: nil, count: 0, agents: [])
                merged.lastEdit = max(merged.lastEdit ?? .distantPast, file.lastEdit!)
                merged.count += file.edits
                if !merged.agents.contains(agent) { merged.agents.append(agent) }
                byPath[file.path] = merged
            }
        }
        return Array(byPath.values.sorted { $0.lastEdit! > $1.lastEdit! }.prefix(limit))
    }

    public func highActivity(_ limit: Int = 5) -> [File] {
        var byPath: [String: File] = [:]
        for (agent, facts) in perAgent {
            for file in facts.files.values {
                var merged = byPath[file.path] ?? File(path: file.path, lastEdit: file.lastEdit, count: 0, agents: [])
                merged.count += file.edits + file.reads
                if let edit = file.lastEdit { merged.lastEdit = max(merged.lastEdit ?? edit, edit) }
                if !merged.agents.contains(agent) { merged.agents.append(agent) }
                byPath[file.path] = merged
            }
        }
        return Array(byPath.values.filter { $0.count > 1 }.sorted { ($0.count, $0.path) > ($1.count, $1.path) }.prefix(limit))
    }

    /// Newest first.
    public func messages(_ limit: Int = 15) -> [AgentMessage] {
        perAgent.flatMap { agent, facts in facts.messages.map { AgentMessage(agent: agent, message: $0) } }
            .sorted { $0.message.at > $1.message.at }.prefix(limit).map { $0 }
    }

    /// Newest first, one row per link; local pages that are gone (a job's temporary folder, say) are left out.
    /// Links named at the same moment (several in one message) keep the order they were named in, and the same
    /// link from two agents at once goes to the first agent by id, so rows don't swap between refreshes.
    public func artifacts(_ limit: Int = 20) -> [AgentArtifact] {
        var byURL: [String: (row: AgentArtifact, order: Int)] = [:]
        for (agent, facts) in perAgent.sorted(by: { $0.agent < $1.agent }) {
            for (order, artifact) in facts.artifacts.enumerated()
            where !artifact.url.hasPrefix("/") || FileManager.default.fileExists(atPath: artifact.url) {
                if let existing = byURL[artifact.url], existing.row.artifact.at >= artifact.at {
                    if existing.row.artifact.title == nil, artifact.title != nil { byURL[artifact.url]?.row.artifact.title = artifact.title }
                    continue
                }
                var row = AgentArtifact(agent: agent, artifact: artifact)
                if row.artifact.title == nil { row.artifact.title = byURL[artifact.url]?.row.artifact.title }
                byURL[artifact.url] = (row, order)
            }
        }
        let sorted = byURL.values.sorted { a, b in
            if a.row.artifact.at != b.row.artifact.at { return a.row.artifact.at > b.row.artifact.at }
            if a.row.agent != b.row.agent { return a.row.agent < b.row.agent }
            return a.order < b.order
        }
        return Array(sorted.prefix(limit).map(\.row))
    }
}

/// Two agents editing the same file close together: worth telling both.
public enum Overlaps {
    public struct Overlap: Equatable, Sendable {
        public var path: String
        /// The two agents' ids, in the order given.
        public var first: String
        public var second: String
        /// The later of the two edits.
        public var at: Date
    }

    /// Files edited by two of these agents within `window` of each other, the later edit within `recent` of `now`.
    public static func find(_ agents: [(id: String, facts: TranscriptFacts)], window: TimeInterval = 30 * 60,
                            recent: TimeInterval = 86_400, now: Date = Date()) -> [Overlap] {
        var found: [Overlap] = []
        for i in agents.indices {
            for j in agents.indices where j > i && agents[j].id != agents[i].id {
                for (path, a) in agents[i].facts.files {
                    guard let ea = a.lastEdit, let eb = agents[j].facts.files[path]?.lastEdit else { continue }
                    let later = max(ea, eb)
                    guard abs(ea.timeIntervalSince(eb)) <= window, now.timeIntervalSince(later) <= recent else { continue }
                    found.append(Overlap(path: path, first: agents[i].id, second: agents[j].id, at: later))
                }
            }
        }
        return found.sorted { $0.at > $1.at }
    }
}
