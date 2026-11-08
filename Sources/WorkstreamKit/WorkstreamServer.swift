import Foundation

/// The `workstream` MCP server: JSON-RPC 2.0 over stdio, one message per line. Outside the app (and without
/// `WORKSTREAM_EVERYWHERE=1`) it offers no tools and no instructions, so other sessions get nothing extra.
public final class WorkstreamServer {
    public static let version = "1"
    public let context: AgentContext
    private var scanners: [String: (url: URL, scanner: TranscriptScanner)] = [:]
    private let now: () -> Date
    private var initialized = false
    /// Whether Claude was last told this server has tools. A session can join the app after its server started
    /// (a background session that a tab adopts); `announceIfEnabled` then tells Claude to fetch them.
    private var toldEnabled = false

    public init(context: AgentContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public static let instructions = """
    This agent is attached to an the app workstream: the shared record of this work that the user sees beside \
    the chat, and that comes back after every compaction and resume. Keeping it current is part of the job: \
    whenever the conversation changes what a section should say, update it then, without being asked. Each \
    entry is read at a glance and has a character limit, like a tweet (400 for the overview and memory, 280 for \
    FYI and questions; each tool gives its limits). Longer text is refused, so write it short the first time.
    - Overview (set_overview): what this work is for and where it stands. Set it at the start, and again when \
    the goal or the state changes.
    - Rules (add_rule): standing instructions the user gives ("never push to main"). Record each one when \
    it's stated, and follow all of them.
    - Memory (add_memory): what a later agent on this work needs and couldn't easily find: decisions and their \
    reasons, the user's preferences, facts learned the hard way, where things live. Before adding one, ask whether \
    it would change what someone does next week. Leave out what the code, docs or git history already record, \
    one-off choices that are done with, and status (that's Progress). Give each a short name; reuse a name to \
    update its item. Whenever you add one, look over the others (add_memory lists them, with dates) and remove \
    any that no longer hold or no longer matter. Memory has a size limit (25 items unless the user set another): \
    keep there only what nearly every session on this work needs, and put the rest in a notes file.
    - Progress (set_progress): a few rows for long-running work, with a bar when there's a fraction done. \
    Update it at milestones, or every few minutes during long runs; clear it when the work is done.
    - Waiting on you (ask_user): anything that's waiting on the user. Whatever you'd end a message with as \
    "still waiting on you for…", or a question whose answer changes what you do next, goes here with ask_user, \
    not only in the chat. Keep working meanwhile; the answer arrives as a chat message. If you could go ahead \
    without one, give a default and a deadline. If the user answers in the chat instead of with a button, \
    remove the ask with remove_entry right away, so it doesn't sit there unanswered.
    - FYI (tell_user): things the user should know but needn't act on.
    - Files (pin_file): files the user will want to open. open_in_viewer shows one now.
    - Tickets (link_ticket): the tickets this work is for (Linear, Jira, GitHub or any tracker), when the user names one or you create one.
    - remove_entry takes back any entry once it stops being true or needed: a rule, memory item, ask or FYI note by \
    its id, a ticket by its identifier, or a pinned file by its path.
    - Plan is your own to-do list, and Scheduled is your own cron and wake-up tools (CronCreate, \
    ScheduleWakeup): use those as usual, and they show here.
    - read_workstream returns the whole workstream or one section, but it's already in your context, so you rarely need \
    it. manage_workstreams lists, switches, starts and renames workstreams, when the user asks.
    """

    // MARK: JSON-RPC

    /// Handles one incoming line; returns the response line, or nil for notifications.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }   // a notification
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            initialized = true
            toldEnabled = context.enabled
            var result: [String: Any] = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "serverInfo": ["name": "workstream", "version": Self.version],
                "capabilities": ["tools": ["listChanged": true]],
            ]
            if toldEnabled { result["instructions"] = Self.instructions }
            return reply(id, result)
        case "ping":
            return reply(id, [:])
        case "tools/list":
            toldEnabled = context.enabled
            return reply(id, ["tools": toldEnabled ? Self.tools.map(\.json) : []])
        case "tools/call":
            guard let name = params["name"] as? String, context.enabled, Self.tools.contains(where: { $0.name == name }) else {
                return failure(id, -32602, "Unknown tool: \(params["name"] as? String ?? "")")
            }
            do {
                let text = try call(name, params["arguments"] as? [String: Any] ?? [:])
                return reply(id, ["content": [["type": "text", "text": text]]])
            } catch let error as ToolError {
                return reply(id, ["content": [["type": "text", "text": error.message]], "isError": true])
            } catch {
                return reply(id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            return failure(id, -32601, "Method not found: \(method)")
        }
    }

    /// For a server that started before its session joined the app: once it has, the notification that makes
    /// Claude fetch the tools again. They arrive without the server's instructions; the prompt hook sends those.
    /// Nil until then, and after.
    public func announceIfEnabled() -> String? {
        guard initialized, !toldEnabled, context.enabled else { return nil }
        toldEnabled = true
        return encode(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"])
    }

    private func reply(_ id: Any, _ result: [String: Any]) -> String? { encode(["jsonrpc": "2.0", "id": id, "result": result]) }
    private func failure(_ id: Any, _ code: Int, _ message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
    private func encode(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Tools

    struct ToolError: Error { let message: String }

    struct Tool {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
        var json: [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
    }

    /// Character limits for what agents write, so every section stays a glance. The schema states them and
    /// `call` rejects longer text, asking for a shorter version rather than cutting it off.
    enum Limit {
        static let overview = 400, memory = 400, fyi = 280, question = 280, rule = 200, memoryName = 40
        static let progressText = 140, note = 140, option = 60, name = 60, label = 32, rows = 6
    }

    private static let text = ["type": "string"]
    private static func text(_ max: Int) -> [String: Any] { ["type": "string", "maxLength": max] }
    static let sections = ["overview", "tickets", "rules", "waiting", "fyi", "memory", "progress", "plan", "scheduled", "files",
                           "messages", "artifacts", "agents"]
    static let tools: [Tool] = [
        Tool(name: "read_workstream", description: "The workstream: all of it, or one section. It's already in your context at session start and after compaction, so you rarely need this.",
             properties: ["section": ["type": "string", "enum": sections]], required: []),
        Tool(name: "set_overview", description: "Replace the overview: what this work is for and where it stands, in at most \(Limit.overview) characters.",
             properties: ["text": text(Limit.overview)], required: ["text"]),
        Tool(name: "add_rule", description: "Record a standing rule the user states, for every agent in this workstream to follow: one rule, at most \(Limit.rule) characters. Returns its id.",
             properties: ["text": text(Limit.rule)], required: ["text"]),
        Tool(name: "add_memory", description: "Add one fact or decision a later agent on this work will need (one that would change what it does, and that the code, docs or git history don't already record): a short name (at most \(Limit.memoryName) characters, like linear-account) and the text (at most \(Limit.memory)). It's dated. Using an existing name, or an item's id (m4) as the name, updates that item in place, keeping its id. Returns its id and lists the other items, to remove any that no longer hold.",
             properties: ["name": text(Limit.memoryName), "text": text(Limit.memory)], required: ["name", "text"]),
        Tool(name: "set_progress", description: "Replace your progress rows (at most \(Limit.rows); none clears them). Each row: a label of at most \(Limit.label) characters, an optional value from 0 to 1 for a bar, and text of at most \(Limit.progressText) characters. With merge: true, only the rows you send change (matched by label), your others stay, and a row with empty text is removed. Other agents' rows are always kept. Your Plan's done count shows on its own, so don't repeat it here.",
             properties: ["rows": ["type": "array", "maxItems": Limit.rows, "items": ["type": "object", "properties": ["label": text(Limit.label), "value": ["type": "number", "minimum": 0, "maximum": 1], "text": text(Limit.progressText)], "required": ["label", "text"]]],
                          "merge": ["type": "boolean"]],
             required: ["rows"]),
        Tool(name: "ask_user", description: "Put something that's waiting on the user under Waiting, without stopping: a question or a request for them to do something. The options become answer buttons; give them for every ask (for a request, e.g. Done and Can't), since without them the buttons are Yes, No and Discuss. The answer arrives as a chat message; if the user answers in the chat instead, remove the ask with remove_entry. The question is at most \(Limit.question) characters; each option and the default at most \(Limit.option). With a default and decide_by (an ISO time, or in_minutes), the default is taken and sent to you if nobody answers in time. To change an open ask instead of adding another, pass its id. Returns its id.",
             properties: ["id": text, "question": text(Limit.question), "options": ["type": "array", "items": text(Limit.option), "maxItems": 6], "default": text(Limit.option),
                          "decide_by": ["type": "string", "description": "ISO 8601 time"], "in_minutes": ["type": "number", "minimum": 1]],
             required: ["question"]),
        Tool(name: "tell_user", description: "Tell the user something they should know but needn't act on, in at most \(Limit.fyi) characters. Returns its id.", properties: ["text": text(Limit.fyi)], required: ["text"]),
        Tool(name: "pin_file", description: "Pin a file the user will want to open, with a note of at most \(Limit.note) characters (or update its note).",
             properties: ["path": text, "note": text(Limit.note)], required: ["path"]),
        Tool(name: "link_ticket", description: "Link a ticket this work is for, in any tracker: its key (ENG-123), owner/repo#12, or its link, and its title if you know it (at most \(Limit.note) characters).",
             properties: ["ticket": text, "title": text(Limit.note)], required: ["ticket"]),
        Tool(name: "remove_entry", description: "Take back an entry that's no longer true or needed: a rule, memory item, ask or FYI note by its id (r1, m1, a1, f1), a ticket by its identifier (ENG-123, owner/repo#12), or a pinned file by its path.",
             properties: ["id": text, "path": text], required: []),
        Tool(name: "open_in_viewer", description: "Show a file (or a localhost URL) in the viewer above your chat in \(HostApp.name).", properties: ["path": text], required: ["path"]),
        Tool(name: "manage_workstreams", description: "When the user asks: list the workstreams in this folder, switch to one (id), start a new one (name, at most \(Limit.name) characters), or rename yours (name).",
             properties: ["action": ["type": "string", "enum": ["list", "switch", "new", "rename"]], "id": text, "name": text(Limit.name)], required: ["action"]),
    ]

    /// What `add_memory` answers: the new id, then the earlier items (the 12 newest, one line each), so the agent
    /// checks them while it's writing and takes back any that no longer hold.
    /// How old a Memory item is before add_memory asks whether it still holds.
    static let reviewAge: TimeInterval = 3 * 86_400

    /// Why a new Memory item was refused, with every item listed (oldest first) so the agent can pick what goes.
    static func memoryFull(_ items: [Workstream.MemoryItem], limit: Int) -> String {
        "Memory is full: \(items.count) items, and the limit is \(limit). Nothing was added. Memory is for what nearly "
            + "every session on this work needs; anything else belongs in a notes file in the work's folder (pin it "
            + "with pin_file if it's worth finding). Remove items with remove_entry until there's room, moving any "
            + "still worth keeping to that file, or update an existing item by passing its name. The items:\n"
            + items.map { "- [\($0.id)] \($0.line)" }.joined(separator: "\n")
    }

    static func memoryReply(_ id: String, name: String, replaced: Bool, earlier: [Workstream.MemoryItem], now: Date = Date()) -> String {
        let done = "\(replaced ? "Updated" : "Remembered") \(id) (\(name))."
        // Only items that have sat a while, in full, so they can be judged; fresh ones are left alone.
        let cutoff = now.addingTimeInterval(-Self.reviewAge)
        let old = earlier.filter { ($0.at ?? .distantPast) < cutoff }
        guard !old.isEmpty else { return done }
        let lines = old.prefix(12).map { "- [\($0.id)] \($0.line)" }
        return done + " Are these older items still true and needed? Remove any that aren't with remove_entry:\n"
            + lines.joined(separator: "\n") + (old.count > 12 ? "\n(+\(old.count - 12) more)" : "")
    }

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        guard let id = context.resolve(attach: true) else {
            throw ToolError(message: "This agent isn't attached to a workstream yet. In \(HostApp.name) every tab's agent has one; elsewhere set WORKSTREAM_EVERYWHERE=1.")
        }
        let store = context.store
        let session = context.session
        func string(_ key: String, max: Int? = nil) throws -> String {
            guard let value = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw ToolError(message: "`\(key)` is required.")
            }
            if let max { try Self.check(value, key, max) }
            return value
        }
        switch name {
        case "read_workstream":
            let section = (args["section"] as? String)?.lowercased() ?? ""
            let s = summary(id)
            switch section {
            case "": return s.full
            case "overview": return nonEmpty(s.overview, "No overview yet.")
            case "rules": return nonEmpty(s.rules, "No rules.")
            case "memory": return nonEmpty(s.memory, "Memory is empty.")
            case "plan": return nonEmpty(s.planText, "Your to-do list is empty.")
            case "progress": return nonEmpty(s.progress, "No progress rows.")
            case "waiting": return nonEmpty(s.waiting, "Nothing is waiting on the user.")
            case "fyi": return nonEmpty(s.fyi, "No FYI notes.")
            case "scheduled": return nonEmpty(s.scheduledText, "Nothing is scheduled.")
            case "files": return nonEmpty(s.files, "No pinned or recently edited files.")
            case "tickets": return nonEmpty(s.tickets, "No tickets linked.")
            case "messages": return nonEmpty(s.messages, "No cross-session messages.")
            case "artifacts": return nonEmpty(s.artifacts, "No artifacts.")
            case "agents": return nonEmpty(s.agents, "No agents attached.")
            default: throw ToolError(message: "No section \(section). Sections: \(Self.sections.joined(separator: ", ")).")
            }
        case "set_overview":
            let text = try string("text", max: Limit.overview)
            try store.update(id) { $0.overview = Workstream.TextSection(text: text, updated: self.now()) }
            return "Overview set."
        case "add_rule":
            let text = try string("text", max: Limit.rule)
            var newID = ""
            try store.update(id) { newID = $0.addRule(text, by: "agent", at: self.now()) }
            if let session, let updated = store.read(id)?.rules?.updated { store.markRulesSeen(session: session, workstream: id, updated: updated) }
            return "Added rule \(newID)."
        case "add_memory":
            let text = try string("text", max: Limit.memory)
            // A session that started before `name` existed still has the old schema, with only `text`, while its
            // server may be the new one: it gets a name made from the text rather than an error it can't fix.
            let given = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !given.isEmpty { try Self.check(given, "name", Limit.memoryName) }
            var label = given
            var newID = ""
            var replaced = false
            var earlier: [Workstream.MemoryItem] = []
            var full: [Workstream.MemoryItem]?
            let limit = store.memoryLimit
            let now = self.now()
            try store.update(id) { w in
                var items = w.memory?.items ?? []
                if given.isEmpty {
                    label = Workstream.MemoryItem.name(from: text, taken: Set(items.compactMap { $0.name?.lowercased() }))
                }
                // The same name updates that item, so Memory holds the current version rather than a trail of them.
                // A made-up name never does: it's always a new item.
                // So does an item's id ("m4"), which agents often pass as the name; the item keeps its own name.
                let byID = items.firstIndex { $0.id.caseInsensitiveCompare(given) == .orderedSame }
                if !given.isEmpty, let i = byID ?? items.firstIndex(where: { $0.name?.caseInsensitiveCompare(label) == .orderedSame }) {
                    newID = items[i].id
                    replaced = true
                    if byID != nil { label = items[i].name ?? label }
                    items[i].text = text
                    items[i].at = now
                } else if let limit, items.count >= limit {
                    full = items   // left unchanged; the error below lists them
                    return
                } else {
                    newID = w.newID("m", among: items.map(\.id))
                    items.append(Workstream.MemoryItem(id: newID, text: text, name: label, at: now))
                }
                earlier = items.filter { $0.id != newID }
                w.memory = Workstream.MemorySection(items: items, updated: now)
            }
            if let full, let limit { throw ToolError(message: Self.memoryFull(full, limit: limit)) }
            return Self.memoryReply(newID, name: label, replaced: replaced, earlier: earlier, now: now)
        case "set_progress":
            guard let rows = args["rows"] as? [[String: Any]] else { throw ToolError(message: "`rows` is required.") }
            if rows.count > Limit.rows { throw ToolError(message: "\(rows.count) rows; the limit is \(Limit.rows). Combine some.") }
            let merge = args["merge"] as? Bool == true
            let parsed = try rows.map { row -> Workstream.ProgressRow in
                guard let label = row["label"] as? String, !label.isEmpty else { throw ToolError(message: "Each row needs a label.") }
                try Self.check(label, "label", Limit.label)
                try Self.check(row["text"] as? String ?? "", "text", Limit.progressText)
                let value = (row["value"] as? NSNumber)?.doubleValue.clamped(0, 1)
                return Workstream.ProgressRow(label: label, value: value, text: row["text"] as? String ?? "", agent: session)
            }
            var mine = 0
            try store.update(id) { w in
                var all = w.progress?.rows ?? []
                var rows = parsed
                if merge {
                    // Your other rows stay; a sent row replaces the one with its label, and empty text removes it.
                    var kept = all.filter { $0.agent == session }
                    for row in parsed {
                        if let i = kept.firstIndex(where: { $0.label == row.label }) { kept[i] = row } else { kept.append(row) }
                    }
                    rows = kept.filter { !$0.text.isEmpty }
                }
                if rows.count > Limit.rows { rows = Array(rows.suffix(Limit.rows)) }
                mine = rows.count
                let position = all.firstIndex { $0.agent == session } ?? all.count
                all.removeAll { $0.agent == session }
                all.insert(contentsOf: rows, at: min(position, all.count))
                w.progress = all.isEmpty ? nil : Workstream.ProgressSection(rows: all, updated: self.now())
            }
            return mine == 0 ? "Progress cleared." : "Progress set (\(mine) row\(mine == 1 ? "" : "s") of yours)."
        case "ask_user":
            let question = try string("question", max: Limit.question)
            var options = (args["options"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let defaulted = options.isEmpty
            // An ask with no buttons leaves the user typing into the chat; agents often forget them.
            if defaulted { options = Self.defaultAskOptions }
            let fallback = (args["default"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            if defaulted, let fallback, !options.contains(fallback) { options.insert(fallback, at: 0) }
            for option in options + [fallback].compactMap({ $0 }) { try Self.check(option, "option", Limit.option) }
            var deadline: Date?
            if let minutes = (args["in_minutes"] as? NSNumber)?.doubleValue, minutes > 0 {
                deadline = now().addingTimeInterval(minutes * 60)
            } else if let text = args["decide_by"] as? String, !text.isEmpty {
                guard let date = ScheduleScanner.parseDate(text) else { throw ToolError(message: "decide_by must be an ISO 8601 time.") }
                deadline = date
            }
            if deadline != nil, fallback == nil { throw ToolError(message: "A deadline needs a default.") }
            let editing = ((args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            if let editing {
                var found = false
                try store.update(id) { w in
                    guard var asks = w.waiting?.asks, let i = asks.firstIndex(where: { $0.id == editing && $0.isOpen }) else { return }
                    asks[i].question = question
                    asks[i].options = Array(options.prefix(6))
                    asks[i].defaultOption = fallback
                    asks[i].decideBy = deadline
                    w.waiting = Workstream.WaitingSection(asks: asks, updated: self.now())
                    found = true
                }
                if !found { throw ToolError(message: "No open ask has the id \(editing); leave out `id` to ask a new question.") }
                return "Updated \(editing)."
            }
            var newID = ""
            try store.update(id) { w in
                var asks = w.waiting?.asks ?? []
                newID = w.newID("a", among: asks.map(\.id))
                asks.append(Workstream.Ask(id: newID, question: question, options: Array(options.prefix(6)), asked: self.now(),
                                           agent: session, defaultOption: fallback, decideBy: deadline))
                w.waiting = Workstream.WaitingSection(asks: asks, updated: self.now())
            }
            return "Asked (\(newID))" + (defaulted ? " with the options " + options.joined(separator: " / ") : "")
                + ". The answer will arrive as a chat message. If the user answers in the chat instead, remove the ask with remove_entry."
        case "tell_user":
            let text = try string("text", max: Limit.fyi)
            var newID = ""
            try store.update(id) { newID = $0.addFYI(text, agent: session, at: self.now()) }
            return "Noted (\(newID))."
        case "pin_file":
            let path = absolute(try string("path"))
            let note = (args["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let note { try Self.check(note, "note", Limit.note) }
            try store.update(id) { w in
                var items = w.files?.items ?? []
                if let index = items.firstIndex(where: { $0.path == path }) {
                    if let note { items[index].note = note }
                } else {
                    items.append(Workstream.FileItem(path: path, note: note, by: "agent"))
                }
                w.files = Workstream.FilesSection(items: items, updated: self.now())
            }
            return "Pinned \(path)."
        case "link_ticket":
            let raw = try string("ticket")
            guard let ticket = Workstream.ticketReference(in: raw) else {
                throw ToolError(message: "`ticket` should be a key like ENG-123, owner/repo#12, or the ticket's link.")
            }
            let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let title { try Self.check(title, "title", Limit.note) }
            try store.update(id) { $0.linkTicket(ticket.identifier, title: title, url: ticket.url, tracker: ticket.tracker, by: "agent", at: self.now()) }
            return "Linked \(ticket.identifier)."
        case "remove_entry":
            if let raw = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                let path = absolute(raw)
                var found = false
                try store.update(id) { w in
                    guard var items = w.files?.items, let index = items.firstIndex(where: { $0.path == path }) else { return }
                    items.remove(at: index)
                    found = true
                    w.files = items.isEmpty ? nil : Workstream.FilesSection(items: items, updated: self.now())
                }
                if !found { throw ToolError(message: "\(path) isn't pinned.") }
                return "Unpinned \(path)."
            }
            guard let target = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
                throw ToolError(message: "Give an `id` (r1, m1, a1, f1, or a ticket like ENG-123) or a pinned file's `path`.")
            }
            var found = false
            if let ticket = Workstream.ticketIdentifier(in: target), target.contains(where: { "-#/".contains($0) }) {
                let linked = store.read(id)?.tickets?.items.first { $0.identifier.caseInsensitiveCompare(ticket) == .orderedSame }?.identifier ?? ticket
                try store.update(id) { found = $0.unlinkTicket(linked, at: self.now()) }
                if !found { throw ToolError(message: "\(linked) isn't linked.") }
                return "Unlinked \(linked)."
            }
            switch target.first {
            case "r":
                try store.update(id) { found = $0.removeRule(target, at: self.now()) }
                if found, let session, let updated = store.read(id)?.rules?.updated { store.markRulesSeen(session: session, workstream: id, updated: updated) }
            case "m":
                try store.update(id) { w in
                    guard var items = w.memory?.items, let index = items.firstIndex(where: { $0.id == target }) else { return }
                    items.remove(at: index)
                    found = true
                    w.memory = items.isEmpty ? nil : Workstream.MemorySection(items: items, updated: self.now())
                }
            case "a":
                try store.update(id) { found = $0.resolve(ask: target, by: "agent", at: self.now()) }
                // Already answered, dismissed or defaulted: say so rather than "nothing has that id".
                if !found, let ask = store.read(id)?.waiting?.asks.first(where: { $0.id == target }) {
                    let how = ask.resolvedBy == "you" ? (ask.answer.map { "answered by the user (\"\($0)\")" } ?? "dismissed by the user")
                        : ask.resolvedBy == "default" ? "resolved with its default" : "already removed"
                    return "\(target) was \(how); nothing to remove."
                }
            case "f": try store.update(id) { found = $0.dismissFYI(target, at: self.now()) }
            default: break
            }
            if !found {
                let w = store.read(id)
                let ids = (w?.activeRules.map(\.id) ?? []) + (w?.memory?.items.map(\.id) ?? []) + (w?.openAsks.map(\.id) ?? [])
                    + (w?.fyi?.items.map(\.id) ?? [])
                throw ToolError(message: "Nothing has the id \(target). Current ids: " + (ids.isEmpty ? "none" : ids.joined(separator: ", ")) + ".")
            }
            return "Removed \(target)."
        case "open_in_viewer":
            let raw = try string("path")
            let target: String
            if raw.hasPrefix("http://localhost") || raw.hasPrefix("http://127.0.0.1") || raw.hasPrefix("https://localhost") {
                target = raw
            } else {
                target = absolute(raw)
                guard FileManager.default.fileExists(atPath: target) else { throw ToolError(message: "\(target) doesn't exist.") }
            }
            try store.post(WorkstreamStore.Request(action: "open", session: session, tab: context.tab, path: target, at: now()))
            return "Opening \((target as NSString).lastPathComponent) in the viewer."
        case "manage_workstreams":
            switch args["action"] as? String ?? "" {
            case "list":
                let current = store.read(id)
                let folder = current?.folder ?? context.cwd
                let names = ClaudeRegistry.liveSessions(in: context.claudeDirectory)
                let listed = store.all().filter { $0.id == id || $0.folder == folder }
                    .sorted { ($0.id == id ? 0 : 1, WorkstreamSummary.name(of: $0, names: names)) < ($1.id == id ? 0 : 1, WorkstreamSummary.name(of: $1, names: names)) }
                return listed.map { w in
                    "- \(w.id): \(WorkstreamSummary.name(of: w, names: names)) (\(w.agents.count) agent\(w.agents.count == 1 ? "" : "s")\(w.id == id ? ", yours" : ""))"
                }.joined(separator: "\n")
            case "switch":
                let target = try string("id")
                guard target != id else { return "That's already your workstream." }
                guard store.read(target) != nil else { throw ToolError(message: "No workstream \(target). List them first.") }
                guard let session else { throw ToolError(message: "This agent has no session id.") }
                try store.moveAgent(session: session, kind: context.kind, tab: context.tab, to: target)
                return "Switched to \(target)."
            case "new":
                let name = try string("name", max: Limit.name)
                guard let session else { throw ToolError(message: "This agent has no session id.") }
                let folder = store.read(id)?.folder ?? context.cwd
                let newID = UUID().uuidString
                try store.update(newID) { $0.name = name; $0.folder = folder }
                try store.moveAgent(session: session, kind: context.kind, tab: context.tab, to: newID)
                return "Started \(name) (\(newID)) and switched to it."
            case "rename":
                let name = try string("name", max: Limit.name)
                try store.update(id) { $0.name = name }
                return "Renamed to \(name)."
            default:
                throw ToolError(message: "`action` is list, switch, new or rename.")
            }
        default:
            throw ToolError(message: "Unknown tool \(name).")
        }
    }

    /// The answer buttons for an ask that came without options.
    static let defaultAskOptions = Workstream.Ask.defaultAnswers

    private static func check(_ value: String, _ key: String, _ max: Int) throws {
        guard value.count > max else { return }
        throw ToolError(message: "`\(key)` is \(value.count) characters, \(value.count - max) over the limit of \(max). Shorten it and try again.")
    }

    private func nonEmpty(_ text: String, _ fallback: String) -> String { text.isEmpty ? fallback : text }

    private func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: context.cwd).appendingPathComponent(expanded)
        return url.standardizedFileURL.path
    }

    // MARK: Reading

    /// `activity` (Files' Recent and High activity, Messages, Artifacts) reads the agents' transcripts; the
    /// compact context a hook prints doesn't need it.
    func summary(_ id: String, activity withActivity: Bool = true) -> WorkstreamSummary {
        let workstream = context.store.read(id) ?? Workstream(id: id)
        let live = ClaudeRegistry.liveSessions(in: context.claudeDirectory)
        let plan = context.session.map { NativePlan.claudeTasks(session: $0, in: context.claudeDirectory.appendingPathComponent("tasks")) }
            ?? PlanList(steps: [], updated: nil)
        return WorkstreamSummary(workstream: workstream, session: context.session, names: live, plan: plan,
                                 scheduled: scheduled(workstream, live: live),
                                 activity: withActivity ? activity(workstream) : WorkstreamActivity([]), now: now())
    }

    /// The scanner for an attached agent's transcript, brought up to date. It starts from the app's snapshot
    /// when there is one, so a long transcript isn't read from the start.
    private func scanner(for agent: Workstream.Agent) -> TranscriptScanner? {
        if scanners[agent.session] == nil {
            let format: TranscriptScanner.Format = agent.kind == "codex" ? .codex : .claude
            let url = format == .codex ? CodexLogs.log(session: agent.session)
                : NativeSchedule.transcript(session: agent.session, in: context.claudeDirectory.appendingPathComponent("projects"))
            guard let url else { return nil }
            scanners[agent.session] = (url, TranscriptCache.scanner(session: agent.session, format: format,
                                                                    directory: TranscriptCache.directory(context.environment)))
        }
        guard let entry = scanners[agent.session] else { return nil }
        entry.scanner.scan(entry.url)
        return entry.scanner
    }

    func activity(_ workstream: Workstream) -> WorkstreamActivity {
        WorkstreamActivity(workstream.agents.compactMap { agent in scanner(for: agent).map { (agent.session, $0.currentFacts) } })
    }

    /// Each attached Claude agent's schedule from its transcript, plus the folder's durable jobs.
    func scheduled(_ workstream: Workstream, live: [String: String]) -> [(agent: String, items: [ScheduledItem])] {
        var result: [(agent: String, items: [ScheduledItem])] = []
        var seen = Set<String>()
        for agent in workstream.agents where agent.kind == "claude" {
            guard let scanner = scanner(for: agent) else { continue }
            let items = scanner.schedule.items(now: now(), sessionLive: live[agent.session] != nil)
            seen.formUnion(items.map(\.id))
            if !items.isEmpty { result.append((agent.session, items)) }
        }
        if let folder = workstream.folder {
            let durable = NativeSchedule.durableJobs(folder: folder, now: now()).filter { !seen.contains($0.id) }
            if !durable.isEmpty { result.append(("durable", durable)) }
        }
        return result
    }

    // MARK: Hooks

    /// The context for a hook: `input` is the hook's JSON on stdin, whose `session_id` names the session.
    static func hookAgent(input: Data, environment: [String: String], cwd: String) -> AgentContext {
        var environment = environment
        if let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
           let session = object["session_id"] as? String, WorkstreamStore.isValidID(session) {
            environment["CLAUDE_CODE_SESSION_ID"] = session
        }
        return AgentContext(environment: environment, cwd: cwd)
    }

    /// For Claude's SessionStart hook (startup, resume, compact): the whole workstream, rules first, or
    /// nothing outside the app. Records that the session has seen the current rules.
    public static func hookContext(input: Data, environment: [String: String] = ProcessInfo.processInfo.environment,
                                   cwd: String = FileManager.default.currentDirectoryPath, now: Date = Date()) -> String {
        let context = hookAgent(input: input, environment: environment, cwd: cwd)
        guard context.enabled, let id = context.resolve(attach: false) else { return "" }
        let server = WorkstreamServer(context: context, now: { now })
        let summary = server.summary(id, activity: false)
        if let session = context.session {
            context.store.markRulesSeen(session: session, workstream: id, updated: summary.workstream.rules?.updated ?? .distantPast)
        }
        return summary.compact()
    }

    /// For Claude's SubagentStart hook: the parent's workstream, so a sub-agent follows the same rules and knows
    /// the same memory. The hook's `session_id` is the parent session's. Nothing outside the app, and nothing is
    /// marked as seen: the parent still gets rule changes on its next turn.
    public static func subagentContext(input: Data, environment: [String: String] = ProcessInfo.processInfo.environment,
                                       cwd: String = FileManager.default.currentDirectoryPath) -> String {
        let context = hookAgent(input: input, environment: environment, cwd: cwd)
        guard context.enabled, let id = context.resolve(attach: false) else { return "" }
        let text = "You're a sub-agent working for an agent on this workstream: follow its rules, and use its memory "
            + "and overview as context. Leave the workstream itself (asks, progress, memory) to the agent you report to "
            + "unless it asked you to update it.\n\n" + WorkstreamServer(context: context).summary(id, activity: false).compact()
        let output = ["hookSpecificOutput": ["hookEventName": "SubagentStart", "additionalContext": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: output) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// For Claude's UserPromptSubmit hook: the workstream's rules, only when they changed since this session
    /// last received them (or it switched workstreams), so edits reach running agents on their next turn. A session
    /// no hook has reached yet gets the instructions and the whole workstream instead.
    public static func promptContext(input: Data, environment: [String: String] = ProcessInfo.processInfo.environment,
                                     cwd: String = FileManager.default.currentDirectoryPath) -> String {
        let context = hookAgent(input: input, environment: environment, cwd: cwd)
        guard context.enabled, let session = context.session, let id = context.resolve(attach: false),
              let workstream = context.store.read(id) else { return "" }
        let seen = context.store.rulesSeen(session: session)
        if seen == nil {
            // The session joined the app after it started (say, a background session a tab adopted), so it has had
            // neither the server's instructions nor the session-start context. It gets both, once.
            context.store.markRulesSeen(session: session, workstream: id, updated: workstream.rules?.updated ?? .distantPast)
            let summary = WorkstreamServer(context: context).summary(id, activity: false)
            return instructions + "If the mcp__workstream__ tools aren't available in this session, ask the user to reconnect "
                + "the `workstream` server with /mcp.\n\n" + summary.compact()
        }
        guard let rules = workstream.rules else {
            // Never had rules, or the session switched to a workstream without any.
            if let seen, seen.workstream != id {
                context.store.markRulesSeen(session: session, workstream: id, updated: .distantPast)
            }
            return ""
        }
        if let seen, seen.workstream == id, seen.updated >= rules.updated.addingTimeInterval(-0.001) { return "" }
        context.store.markRulesSeen(session: session, workstream: id, updated: rules.updated)
        if rules.items.isEmpty { return "The workstream's rules were all removed." }
        return "The workstream's rules changed. Follow these from now on:\n"
            + rules.items.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(high, Swift.max(low, self)) }
}
