import Foundation

/// One workstream: an information-tracking and communication object attached to agents. Each agent (a tab,
/// running one agent session) has exactly one active workstream; a workstream can have several agents.
/// Stored as `<workstreams dir>/<id>.json` (see docs/WORKSTREAMS.md). Shared by the app, which shows it, and
/// the `workstream` MCP server, through which agents read and update it.
public struct Workstream: Codable, Equatable, Sendable {
    public var version = 1
    public var id: String
    /// Set when renamed; otherwise shown as its first agent's name.
    public var name: String?
    /// The folder it belongs to (its group's folder), for listing the workstreams an agent can switch to.
    public var folder: String?
    public var agents: [Agent] = []
    public var overview: TextSection?
    public var rules: RulesSection?
    public var memory: MemorySection?
    public var progress: ProgressSection?
    public var waiting: WaitingSection?
    public var fyi: FYISection?
    public var files: FilesSection?
    public var tickets: TicketsSection?
    /// Agent sessions that left when their tab closed. Resuming one brings it back here, not to a new workstream.
    public var former: [String]?
    /// The highest number each id prefix ("m", "a", "f", "r") has used, so a removed item's id is never reused.
    public var lastIDs: [String: Int]?

    public init(id: String, name: String? = nil, folder: String? = nil) {
        self.id = id
        self.name = name
        self.folder = folder
    }

    /// An agent session attached to the workstream.
    public struct Agent: Codable, Equatable, Sendable {
        public var session: String
        /// "claude" or "codex".
        public var kind: String
        /// The the app tab running it, when known.
        public var tab: String?
        public var added: Date
        public init(session: String, kind: String, tab: String? = nil, added: Date = Date()) {
            self.session = session
            self.kind = kind
            self.tab = tab
            self.added = added
        }

        private enum CodingKeys: String, CodingKey { case session, kind, tab, added, id, agent }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Phase-1 files wrote {id, agent, added}.
            session = try c.decodeIfPresent(String.self, forKey: .session) ?? c.decode(String.self, forKey: .id)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
            tab = try c.decodeIfPresent(String.self, forKey: .tab)
            added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date(timeIntervalSince1970: 0)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(session, forKey: .session)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(tab, forKey: .tab)
            try c.encode(added, forKey: .added)
        }
    }

    public struct TextSection: Codable, Equatable, Sendable {
        public var text: String
        public var updated: Date
        public init(text: String, updated: Date = Date()) { self.text = text; self.updated = updated }
    }

    /// A standing instruction every attached agent follows ("ask before spending over $20").
    public struct Rule: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        /// "agent" or "you".
        public var by: String
        public var at: Date
        public init(id: String, text: String, by: String, at: Date = Date()) {
            self.id = id
            self.text = text
            self.by = by
            self.at = at
        }
    }

    /// Kept (with no items) after the last rule is removed, so `updated` still tells agents rules changed.
    public struct RulesSection: Codable, Equatable, Sendable {
        public var items: [Rule]
        public var updated: Date
        public init(items: [Rule], updated: Date = Date()) { self.items = items; self.updated = updated }
    }

    public struct MemoryItem: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        /// A short label (`linear-account`); adding an item with the same name updates it. Nil on older items.
        public var name: String?
        /// When it was added or last updated, so a later agent can tell what may be out of date.
        public var at: Date?
        public init(id: String, text: String, name: String? = nil, at: Date? = nil) {
            self.id = id; self.text = text; self.name = name; self.at = at
        }

        /// `linear-account (2026-10-21): text`, or just the text for an item from before names.
        public var line: String {
            let label = [name, at.map(Self.day)].compactMap { $0 }
            guard let first = label.first else { return text }
            return first + (label.count > 1 ? " (\(label[1]))" : "") + ": " + text
        }

        /// A name for an item added without one: its first few words, lowercased and dashed (`data-isnt-on-the`),
        /// with `-2`, `-3`… when that's `taken` (lowercased names already in use).
        public static func name(from text: String, taken: Set<String>) -> String {
            let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
                .map { $0.filter { $0 != "'" } }.filter { !$0.isEmpty }.prefix(4)
            var base = words.joined(separator: "-")
            if base.count > 34 { base = String(base.prefix(34)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            if base.isEmpty { base = "note" }
            var name = base, n = 2
            while taken.contains(name) { name = "\(base)-\(n)"; n += 1 }
            return name
        }

        public static func day(_ date: Date) -> String {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
    }

    public struct MemorySection: Codable, Equatable, Sendable {
        public var items: [MemoryItem]
        public var updated: Date
        public init(items: [MemoryItem], updated: Date = Date()) { self.items = items; self.updated = updated }
    }

    public struct ProgressRow: Codable, Equatable, Sendable {
        public var label: String
        /// 0…1 for a bar; nil for a text-only row.
        public var value: Double?
        public var text: String
        /// The agent session that reported it.
        public var agent: String?
        public init(label: String, value: Double? = nil, text: String, agent: String? = nil) {
            self.label = label
            self.value = value
            self.text = text
            self.agent = agent
        }

        private enum CodingKeys: String, CodingKey { case label, value, text, agent, session }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            value = try c.decodeIfPresent(Double.self, forKey: .value)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? c.decodeIfPresent(String.self, forKey: .session)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(label, forKey: .label)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(agent, forKey: .agent)
        }
    }

    public struct ProgressSection: Codable, Equatable, Sendable {
        public var rows: [ProgressRow]
        public var updated: Date
        public init(rows: [ProgressRow], updated: Date = Date()) { self.rows = rows; self.updated = updated }
    }

    public struct Ask: Codable, Equatable, Sendable {
        public var id: String
        public var question: String
        public var options: [String]
        public var asked: Date
        public var agent: String?
        /// The option taken if nobody answers by `decideBy`.
        public var defaultOption: String?
        public var decideBy: Date?
        /// Set once answered: "you", "agent" (withdrawn) or "default" (the deadline passed).
        public var resolvedBy: String?
        public var answer: String?
        public var resolvedAt: Date?

        public init(id: String, question: String, options: [String], asked: Date = Date(), agent: String? = nil,
                    defaultOption: String? = nil, decideBy: Date? = nil) {
            self.id = id
            self.question = question
            self.options = options
            self.asked = asked
            self.agent = agent
            self.defaultOption = defaultOption
            self.decideBy = decideBy
        }

        public var isOpen: Bool { resolvedBy == nil }

        /// What's typed into the agent's chat for an answer: the question too, on one line, since the agent may
        /// have asked it many turns ago (or asked several).
        public func reply(_ option: String, byDefault: Bool = false) -> String {
            byDefault ? "No answer in time to your question \"\(quoted)\" (\(id)), so going with its default: \(option)"
                      : "Answer to your question \"\(quoted)\" (\(id)): \(option)"
        }

        /// What's typed into the agent's chat when the user dismisses the ask from the panel.
        public var dismissal: String { "I dismissed your question \"\(quoted)\" (\(id)) in the panel; no answer needed." }

        private var quoted: String {
            let question = self.question.split(whereSeparator: \.isNewline).joined(separator: " ")
            return question.count > 200 ? String(question.prefix(199)) + "…" : question
        }

        private enum CodingKeys: String, CodingKey {
            case id, question, options, asked, agent, session
            case defaultOption = "default", decideBy = "decide_by", resolvedBy = "resolved_by", answer, resolvedAt = "resolved_at"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            question = try c.decode(String.self, forKey: .question)
            options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
            asked = try c.decodeIfPresent(Date.self, forKey: .asked) ?? Date()
            agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? c.decodeIfPresent(String.self, forKey: .session)
            defaultOption = try c.decodeIfPresent(String.self, forKey: .defaultOption)
            decideBy = try c.decodeIfPresent(Date.self, forKey: .decideBy)
            resolvedBy = try c.decodeIfPresent(String.self, forKey: .resolvedBy)
            answer = try c.decodeIfPresent(String.self, forKey: .answer)
            resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(question, forKey: .question)
            try c.encode(options, forKey: .options)
            try c.encode(asked, forKey: .asked)
            try c.encodeIfPresent(agent, forKey: .agent)
            try c.encodeIfPresent(defaultOption, forKey: .defaultOption)
            try c.encodeIfPresent(decideBy, forKey: .decideBy)
            try c.encodeIfPresent(resolvedBy, forKey: .resolvedBy)
            try c.encodeIfPresent(answer, forKey: .answer)
            try c.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        }
    }

    public struct WaitingSection: Codable, Equatable, Sendable {
        public var asks: [Ask]
        public var updated: Date
        public init(asks: [Ask], updated: Date = Date()) { self.asks = asks; self.updated = updated }
    }

    /// Something the user should know that needs no answer.
    public struct Note: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var agent: String?
        public var at: Date
        /// "app" for notes the app adds itself (overlapping edits); nil for an agent's.
        public var by: String?
        /// When it goes away on its own.
        public var expires: Date?
        public init(id: String, text: String, agent: String? = nil, at: Date = Date(), by: String? = nil, expires: Date? = nil) {
            self.id = id
            self.text = text
            self.agent = agent
            self.at = at
            self.by = by
            self.expires = expires
        }
    }

    public struct FYISection: Codable, Equatable, Sendable {
        public var items: [Note]
        public var updated: Date
        public init(items: [Note], updated: Date = Date()) { self.items = items; self.updated = updated }
    }

    public struct FileItem: Codable, Equatable, Sendable {
        public var path: String
        public var note: String?
        /// "agent" or "you".
        public var by: String
        public init(path: String, note: String? = nil, by: String) { self.path = path; self.note = note; self.by = by }
    }

    public struct FilesSection: Codable, Equatable, Sendable {
        public var items: [FileItem]
        public var updated: Date
        public init(items: [FileItem], updated: Date = Date()) { self.items = items; self.updated = updated }
    }

    /// A ticket this work is for, in any tracker (Linear, Jira, GitHub, GitLab, or just a link). Its title and link
    /// are kept when known; a ticket provider in the app can look up its state live.
    public struct Ticket: Codable, Equatable, Sendable {
        /// "ENG-123", "owner/repo#12", or a link without its scheme for trackers it doesn't know.
        public var identifier: String
        public var title: String?
        public var url: String?
        /// "linear", "jira", "github" or "gitlab" when the link says so; nil for a bare key or an unknown tracker.
        public var tracker: String?
        /// "agent" or "you".
        public var by: String
        public var at: Date
        public init(identifier: String, title: String? = nil, url: String? = nil, tracker: String? = nil, by: String, at: Date = Date()) {
            self.identifier = identifier
            self.title = title
            self.url = url
            self.tracker = tracker
            self.by = by
            self.at = at
        }
    }

    public struct TicketsSection: Codable, Equatable, Sendable {
        public var items: [Ticket]
        public var updated: Date
        public init(items: [Ticket], updated: Date = Date()) { self.items = items; self.updated = updated }
    }

    /// What a ticket reference names: its identifier, its tracker when the link says, and the link itself.
    public struct TicketReference: Equatable, Sendable {
        public var identifier: String
        public var tracker: String?
        public var url: String?
        public init(identifier: String, tracker: String? = nil, url: String? = nil) {
            self.identifier = identifier
            self.tracker = tracker
            self.url = url
        }
    }

    /// Reads a ticket reference: a key (`ENG-123`), `owner/repo#12`, or a link. Linear (`/issue/ENG-123`), Jira
    /// (`/browse/ENG-123` or `selectedIssue=ENG-123`), GitHub (`/issues/12`, `/pull/12`) and GitLab (`/-/issues/12`)
    /// links give the key; any other https link is kept whole, named by the link without its scheme.
    public static func ticketReference(in text: String) -> TicketReference? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func first(_ pattern: String, in string: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: string).map { String(string[$0]) } }
        }
        let key = #"([A-Za-z][A-Za-z0-9]{0,9}-[0-9]{1,7})"#
        if let found = first("^" + key + "$", in: text) { return TicketReference(identifier: found[0].uppercased()) }
        if let found = first(#"^([\w.-]+/[\w.-]+)#([0-9]{1,9})$"#, in: text) {
            return TicketReference(identifier: found[0] + "#" + found[1], tracker: "github")
        }
        guard text.hasPrefix("https://"), !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let host = url.host?.lowercased() else { return nil }
        let end = #"(?=$|[/?#&])"#
        if host.hasSuffix("linear.app"), let found = first("/issue/" + key + end, in: text) {
            return TicketReference(identifier: found[0].uppercased(), tracker: "linear", url: text)
        }
        if host.contains("atlassian") || host.contains("jira"), let found = first("(?:/browse/|selectedIssue=)" + key + end, in: text) {
            return TicketReference(identifier: found[0].uppercased(), tracker: "jira", url: text)
        }
        if host == "github.com", let found = first(#"^/([\w.-]+/[\w.-]+)/(?:issues|pull)/([0-9]{1,9})"#, in: url.path) {
            return TicketReference(identifier: found[0] + "#" + found[1], tracker: "github", url: text)
        }
        if host.contains("gitlab"), let found = first(#"^/(.+?)/-/(?:issues|merge_requests)/([0-9]{1,9})"#, in: url.path) {
            return TicketReference(identifier: found[0] + "#" + found[1], tracker: "gitlab", url: text)
        }
        var name = String(text.dropFirst("https://".count))
        if name.hasPrefix("www.") { name.removeFirst(4) }
        while name.hasSuffix("/") { name.removeLast() }
        return TicketReference(identifier: name, url: text)
    }

    /// The identifier alone; see `ticketReference(in:)`.
    public static func ticketIdentifier(in text: String) -> String? { ticketReference(in: text)?.identifier }

    /// Links a ticket, or fills in its title and link if it's already there. Returns whether anything changed.
    @discardableResult
    public mutating func linkTicket(_ identifier: String, title: String? = nil, url: String? = nil, tracker: String? = nil, by: String,
                                    at date: Date = Date()) -> Bool {
        var items = tickets?.items ?? []
        if let index = items.firstIndex(where: { $0.identifier == identifier }) {
            let before = items[index]
            if let title, !title.isEmpty { items[index].title = title }
            if let url, !url.isEmpty { items[index].url = url }
            if let tracker { items[index].tracker = tracker }
            guard items[index] != before else { return false }
        } else {
            items.append(Ticket(identifier: identifier, title: title, url: url, tracker: tracker, by: by, at: date))
        }
        tickets = TicketsSection(items: items, updated: date)
        return true
    }

    @discardableResult
    public mutating func unlinkTicket(_ identifier: String, at date: Date = Date()) -> Bool {
        guard var items = tickets?.items, let index = items.firstIndex(where: { $0.identifier == identifier }) else { return false }
        items.remove(at: index)
        tickets = items.isEmpty ? nil : TicketsSection(items: items, updated: date)
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, name, folder, agents, sessions, overview, rules, memory, progress, waiting, fyi, files, tickets, former, lastIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        // Phase-1 files called the list `sessions`.
        agents = try c.decodeIfPresent([Agent].self, forKey: .agents) ?? c.decodeIfPresent([Agent].self, forKey: .sessions) ?? []
        overview = try c.decodeIfPresent(TextSection.self, forKey: .overview)
        rules = try c.decodeIfPresent(RulesSection.self, forKey: .rules)
        memory = try c.decodeIfPresent(MemorySection.self, forKey: .memory)
        progress = try c.decodeIfPresent(ProgressSection.self, forKey: .progress)
        waiting = try c.decodeIfPresent(WaitingSection.self, forKey: .waiting)
        fyi = try c.decodeIfPresent(FYISection.self, forKey: .fyi)
        files = try c.decodeIfPresent(FilesSection.self, forKey: .files)
        tickets = try c.decodeIfPresent(TicketsSection.self, forKey: .tickets)
        former = try c.decodeIfPresent([String].self, forKey: .former)
        lastIDs = try c.decodeIfPresent([String: Int].self, forKey: .lastIDs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encode(agents, forKey: .agents)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(rules, forKey: .rules)
        try c.encodeIfPresent(memory, forKey: .memory)
        try c.encodeIfPresent(progress, forKey: .progress)
        try c.encodeIfPresent(waiting, forKey: .waiting)
        try c.encodeIfPresent(fyi, forKey: .fyi)
        try c.encodeIfPresent(files, forKey: .files)
        try c.encodeIfPresent(tickets, forKey: .tickets)
        try c.encodeIfPresent(former, forKey: .former)
        try c.encodeIfPresent(lastIDs, forKey: .lastIDs)
    }

    // MARK: Changes shared by the app and the MCP server

    /// Adds an agent session if it isn't attached yet, or records its tab. Returns whether anything changed.
    @discardableResult
    public mutating func attach(session: String, kind: String, tab: String? = nil, at date: Date = Date()) -> Bool {
        if let index = agents.firstIndex(where: { $0.session == session }) {
            guard let tab, agents[index].tab != tab else { return false }
            agents[index].tab = tab
            return true
        }
        agents.append(Agent(session: session, kind: kind, tab: tab, added: date))
        former?.removeAll { $0 == session }
        if former?.isEmpty == true { former = nil }
        return true
    }

    /// Removes an agent session. When it ended, its open asks go with it (`clearAsks`); when it only moved
    /// to another workstream they stay, since answering still reaches its chat. What it reported stays.
    @discardableResult
    public mutating func detach(session: String, clearAsks clear: Bool = true, at date: Date = Date()) -> Bool {
        guard agents.contains(where: { $0.session == session }) else { return false }
        agents.removeAll { $0.session == session }
        if clear {
            clearAsks(of: session, at: date)
            former = Array(((former ?? []).filter { $0 != session } + [session]).suffix(Self.formerLimit))
        }
        return true
    }

    /// Departed sessions remembered per workstream.
    public static let formerLimit = 50

    /// Answered asks kept for the record (newest), beyond the open ones.
    public static let resolvedAskLimit = 10

    /// Records an ask as answered (`by` "you", "agent" or "default"). Returns whether it was open.
    @discardableResult
    public mutating func resolve(ask id: String, by: String = "you", answer: String? = nil, at date: Date = Date()) -> Bool {
        guard var asks = waiting?.asks, let index = asks.firstIndex(where: { $0.id == id && $0.isOpen }) else { return false }
        asks[index].resolvedBy = by
        asks[index].answer = answer
        asks[index].resolvedAt = date
        let resolved = asks.filter { !$0.isOpen }.sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
        let dropped = Set(resolved.dropFirst(Self.resolvedAskLimit).map(\.id))
        asks.removeAll { dropped.contains($0.id) }
        waiting = WaitingSection(asks: asks, updated: date)
        return true
    }

    /// Removes an ended agent session's open asks. Returns whether there were any.
    @discardableResult
    public mutating func clearAsks(of session: String, at date: Date = Date()) -> Bool {
        guard let asks = waiting?.asks, asks.contains(where: { $0.agent == session && $0.isOpen }) else { return false }
        let kept = asks.filter { !($0.agent == session && $0.isOpen) }
        waiting = kept.isEmpty ? nil : WaitingSection(asks: kept, updated: date)
        return true
    }

    /// Pins `path` in Files, or unpins it when it's already there.
    public mutating func togglePinned(_ path: String, by: String, note: String? = nil, at date: Date = Date()) {
        var items = files?.items ?? []
        if let index = items.firstIndex(where: { $0.path == path }) {
            items.remove(at: index)
        } else {
            items.append(FileItem(path: path, note: note, by: by))
        }
        files = items.isEmpty ? nil : FilesSection(items: items, updated: date)
    }

    /// The most FYI notes kept; older ones drop off.
    public static let fyiLimit = 20

    /// Adds an FYI note (newest last in the file). Returns its id.
    @discardableResult
    public mutating func addFYI(_ text: String, agent: String?, at date: Date = Date()) -> String {
        var items = fyi?.items ?? []
        let id = newID("f", among: items.map(\.id))
        items.append(Note(id: id, text: text, agent: agent, at: date))
        if items.count > Self.fyiLimit { items.removeFirst(items.count - Self.fyiLimit) }
        fyi = FYISection(items: items, updated: date)
        return id
    }

    /// Adds a note with a fixed id unless one with that id is already there. Returns whether it was added.
    @discardableResult
    public mutating func addNote(_ note: Note, at date: Date = Date()) -> Bool {
        var items = fyi?.items ?? []
        guard !items.contains(where: { $0.id == note.id }) else { return false }
        items.append(note)
        if items.count > Self.fyiLimit { items.removeFirst(items.count - Self.fyiLimit) }
        fyi = FYISection(items: items, updated: date)
        return true
    }

    /// Adds a note, or rewrites the one with its id in place.
    public mutating func replaceNote(_ note: Note, at date: Date = Date()) {
        var items = fyi?.items ?? []
        if let index = items.firstIndex(where: { $0.id == note.id }) {
            items[index] = note
            fyi = FYISection(items: items, updated: date)
        } else {
            addNote(note, at: date)
        }
    }

    /// Removes notes past their expiry. Returns whether any went.
    @discardableResult
    public mutating func removeExpiredNotes(now: Date = Date()) -> Bool {
        guard let items = fyi?.items, items.contains(where: { ($0.expires ?? .distantFuture) <= now }) else { return false }
        let kept = items.filter { ($0.expires ?? .distantFuture) > now }
        fyi = kept.isEmpty ? nil : FYISection(items: kept, updated: now)
        return true
    }

    @discardableResult
    public mutating func dismissFYI(_ id: String, at date: Date = Date()) -> Bool {
        guard var items = fyi?.items, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        fyi = items.isEmpty ? nil : FYISection(items: items, updated: date)
        return true
    }

    @discardableResult
    public mutating func removeMemory(_ id: String, at date: Date = Date()) -> Bool {
        guard var items = memory?.items, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        memory = items.isEmpty ? nil : MemorySection(items: items, updated: date)
        return true
    }

    /// Removes one progress row: the one with this label from this agent (rows are per agent).
    @discardableResult
    public mutating func removeProgressRow(label: String, agent: String?, at date: Date = Date()) -> Bool {
        guard var rows = progress?.rows, let index = rows.firstIndex(where: { $0.label == label && $0.agent == agent }) else { return false }
        rows.remove(at: index)
        progress = rows.isEmpty ? nil : ProgressSection(rows: rows, updated: date)
        return true
    }

    /// Adds a rule. Returns its id.
    @discardableResult
    public mutating func addRule(_ text: String, by: String, at date: Date = Date()) -> String {
        var items = rules?.items ?? []
        let id = newID("r", among: items.map(\.id))
        items.append(Rule(id: id, text: text, by: by, at: date))
        rules = RulesSection(items: items, updated: date)
        return id
    }

    @discardableResult
    public mutating func removeRule(_ id: String, at date: Date = Date()) -> Bool {
        guard var items = rules?.items, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        rules = RulesSection(items: items, updated: date)
        return true
    }

    public var activeRules: [Rule] { rules?.items ?? [] }

    public var openAsks: [Ask] { (waiting?.asks ?? []).filter(\.isOpen) }

    /// Whether anything is shown for it beyond its agents.
    public var hasContent: Bool {
        overview != nil || !activeRules.isEmpty || !(memory?.items.isEmpty ?? true) || !(progress?.rows.isEmpty ?? true)
            || !openAsks.isEmpty || !(fyi?.items.isEmpty ?? true)
            || !(files?.items.isEmpty ?? true)
    }

    /// A new id with this prefix, past every one used before (even removed ones), and records it.
    public mutating func newID(_ prefix: String, among ids: [String]) -> String {
        let id = Self.nextID(prefix, in: ids + ["\(prefix)\(lastIDs?[prefix] ?? 0)"])
        lastIDs = (lastIDs ?? [:]).merging([prefix: Int(id.dropFirst(prefix.count)) ?? 0]) { _, new in new }
        return id
    }

    /// The next free id with this prefix: "m1", "m2", …
    public static func nextID(_ prefix: String, in ids: [String]) -> String {
        let used = ids.compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }
        return prefix + String((used.max() ?? 0) + 1)
    }
}
