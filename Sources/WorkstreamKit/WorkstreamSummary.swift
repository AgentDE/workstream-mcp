import Foundation

/// Plain-text renderings of a workstream for agents: the whole thing (`read_workstream`, and the context
/// Claude gets back after a compaction or resume) and each section on its own.
public struct WorkstreamSummary {
    public let workstream: Workstream
    /// The agent asking, marked "you".
    public let session: String?
    /// Live session names from Claude's registry.
    public let names: [String: String]
    public let plan: PlanList
    public let scheduled: [(agent: String, items: [ScheduledItem])]
    /// From the attached agents' transcripts: recent and busiest files, messages, artifacts.
    public let activity: WorkstreamActivity
    public let now: Date

    public init(workstream: Workstream, session: String?, names: [String: String], plan: PlanList,
                scheduled: [(agent: String, items: [ScheduledItem])], activity: WorkstreamActivity = WorkstreamActivity([]),
                now: Date = Date()) {
        self.workstream = workstream
        self.session = session
        self.names = names
        self.plan = plan
        self.scheduled = scheduled
        self.activity = activity
        self.now = now
    }

    /// The workstream's name: its own, else its first agent's.
    public static func name(of workstream: Workstream, names: [String: String]) -> String {
        if let name = workstream.name, !name.isEmpty { return name }
        for agent in workstream.agents { if let name = names[agent.session], !name.isEmpty { return name } }
        return "Untitled workstream"
    }

    /// Where the work happens: the group's folder, or the workstream's own worktree (New → Workstream…).
    public var folderLine: String? {
        workstream.folder.flatMap { $0.isEmpty ? nil : "Working folder: \($0)" }
    }

    public var full: String {
        var parts = ["# Workstream: \(Self.name(of: workstream, names: names))"] + [folderLine].compactMap { $0 }
            + ["\(HostApp.name) shows this beside your chat; keep it current with the mcp__workstream__ tools."]
        if !rules.isEmpty { parts.append("## Rules (follow these)\n\(rules)") }
        for (title, body) in [("Waiting on the user", waiting), ("FYI", fyi), ("Overview", overview), ("Tickets", tickets), ("Agents", agents),
                              ("Messages", messages), ("Memory", memory), ("Progress", progress), ("Plan (your to-do list)", planText),
                              ("Scheduled", scheduledText), ("Files", files), ("Artifacts", artifacts)] where !body.isEmpty {
            parts.append("## \(title)\n\(body)")
        }
        return parts.joined(separator: "\n\n")
    }

    public var rules: String {
        workstream.activeRules.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
    }

    public var overview: String { workstream.overview.map { $0.text + " (\(age($0.updated)))" } ?? "" }

    /// The tickets this work is for.
    public var tickets: String {
        (workstream.tickets?.items ?? []).map { "- \($0.identifier)" + ($0.title.map { ": \($0)" } ?? "") + ($0.url.map { " (\($0))" } ?? "") }
            .joined(separator: "\n")
    }

    public var memory: String {
        (workstream.memory?.items ?? []).map { "- [\($0.id)] \($0.line)" }.joined(separator: "\n")
    }

    public var progress: String {
        let rows = (workstream.progress?.rows ?? []).map { row in
            "- \(row.label): " + (row.value.map { "\(Int(($0 * 100).rounded()))% · " } ?? "") + row.text
        } + [planProgress].compactMap { $0 }
        guard !rows.isEmpty else { return "" }
        return rows.joined(separator: "\n") + (workstream.progress.map { "\n(updated \(age($0.updated)))" } ?? "")
    }

    /// The asking agent's Plan as a progress row, kept up to date by its own to-do list: "7 of 12 done · now: …".
    public var planProgress: String? {
        Self.planProgress(plan).map { "- Plan: \($0)" }
    }

    public static func planProgress(_ plan: PlanList) -> String? {
        guard !plan.steps.isEmpty else { return nil }
        let done = plan.steps.filter { $0.state == .done }.count
        let current = plan.steps.first { $0.state == .current }.map { " · now: \(oneLine($0.text))" } ?? ""
        return "\(done) of \(plan.steps.count) done" + current
    }

    /// Open asks, then the recently answered, dismissed or defaulted ones with what came back.
    public var waiting: String {
        let resolved = (workstream.waiting?.asks ?? []).filter { !$0.isOpen }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }.prefix(5)
            .map { ask -> String in
                let how: String
                switch ask.resolvedBy {
                case "you": how = ask.answer.map { "answered \"\($0)\"" } ?? "dismissed by the user"
                case "default": how = "took its default \"\(ask.answer ?? ask.defaultOption ?? "")\""
                default: how = "withdrawn"
                }
                return "- [\(ask.id)] \(Self.oneLine(ask.question)) → \(how)" + (ask.resolvedAt.map { " (\(age($0)))" } ?? "")
            }
        return (waitingLines + (resolved.isEmpty ? [] : ["Recently resolved:"] + resolved)).joined(separator: "\n")
    }

    var waitingLines: [String] {
        workstream.openAsks.map { ask in
            "- [\(ask.id)] \(ask.question)" + (ask.options.isEmpty ? "" : " Options: " + ask.options.joined(separator: " / "))
                + (ask.defaultOption.map { d in " Default: \(d)" + (ask.decideBy.map { " at \(clock($0))" } ?? "") + "." } ?? "")
                + " (asked \(age(ask.asked))\(ask.agent.map { $0 == session ? " by you" : " by \(agentName($0))" } ?? ""))"
        }
    }

    /// The context Claude gets after a compaction, resume or start: about `budget` bytes (~1,500 tokens),
    /// most important first. Long lists end with "(+N more; read_workstream section <name> for all)"; FYI keeps its 5 newest.
    public func compact(budget: Int = 6000) -> String {
        var header = "# Workstream: \(Self.name(of: workstream, names: names))\n"
            + (folderLine.map { $0 + "\n" } ?? "")
            + "\(HostApp.name) shows this beside your chat; keep it current with the mcp__workstream__ tools."
        // A session resumed into the app, or a new tab's, starts with an empty workstream: the agent fills it in on
        // its next turn rather than leaving the panel blank until someone asks.
        if workstream.overview == nil, workstream.memory == nil, workstream.progress == nil {
            header += "\nIt's empty so far. On your next turn, set its overview from what this conversation is about, and "
                + "add the rules, memory and progress that already apply."
        }
        let lines: (String) -> [String] = { $0.isEmpty ? [] : $0.components(separatedBy: "\n") }
        let fyiLines = liveNotes.reversed().prefix(5).map { "- \(Self.oneLine($0.text)) (\(age($0.at)))" }
        let sections: [(title: String, tool: String, lines: [String])] = [
            ("Rules (follow these)", "rules", lines(rules)),
            ("Overview", "overview", lines(overview)),
            ("Tickets", "tickets", lines(tickets)),
            ("Waiting on the user", "waiting", waitingLines),
            ("Memory", "memory", lines(memory)),
            ("Progress", "progress", lines(progress)),
            ("Plan (your to-do list)", "plan", lines(planText)),
            ("Scheduled", "scheduled", lines(scheduledText)),
            ("Files (pinned)", "files", lines(pinnedFiles)),
            ("FYI", "fyi", fyiLines),
        ]
        var out = header
        let more = { (count: Int, section: String) in "\n(+\(count) more; read_workstream section \(section) for all)" }
        // Each step keeps room for the note saying what's left out, so the result never passes the budget.
        sections: for section in sections where !section.lines.isEmpty {
            let title = "\n\n## \(section.title)"
            guard out.utf8.count + title.utf8.count + more(section.lines.count, section.tool).utf8.count <= budget else { break }
            out += title
            for (index, line) in section.lines.enumerated() {
                let after = section.lines.count - index - 1
                let reserve = after > 0 ? more(after, section.tool).utf8.count : 0
                if out.utf8.count + 1 + line.utf8.count + reserve > budget {
                    out += more(after + 1, section.tool)
                    break sections
                }
                out += "\n" + line
            }
        }
        return out
    }

    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }

    /// FYI notes not past their expiry.
    var liveNotes: [Workstream.Note] { (workstream.fyi?.items ?? []).filter { ($0.expires ?? .distantFuture) > now } }

    public var fyi: String {
        liveNotes.reversed().map { "- [\($0.id)] \($0.text) (\(age($0.at)))" }.joined(separator: "\n")
    }

    public var agents: String {
        workstream.agents.map { agent in
            "- \(agentName(agent.session)) (\(agent.kind)\(agent.session == session ? ", you" : "")\(names[agent.session] == nil ? ", not running" : ""))"
        }.joined(separator: "\n")
    }

    /// Open steps, and only the last few finished ones: long lists pile up done items.
    public var planText: String {
        let shown = Self.trimmedPlan(plan.steps)
        let hidden = plan.steps.count - shown.count
        let steps = shown.map { step in
            (step.state == .done ? "- [x] " : step.state == .current ? "- [>] " : "- [ ] ") + step.text
        }
        return ((hidden > 0 ? ["(\(hidden) earlier steps done)"] : []) + steps).joined(separator: "\n")
    }

    /// Every open step plus the last `keepDone` finished ones, in their order.
    public static func trimmedPlan(_ steps: [PlanStep], keepDone: Int = 5) -> [PlanStep] {
        let done = steps.indices.filter { steps[$0].state == .done }
        let dropped = Set(done.dropLast(keepDone))
        return steps.indices.filter { !dropped.contains($0) }.map { steps[$0] }
    }

    public var scheduledText: String {
        scheduled.flatMap { agent, items in
            items.map { item in
                let when = item.recurring ? "\(item.schedule ?? "recurring") · next \(clock(item.next))" : "in \(untilText(item.next)) (\(clock(item.next)))"
                return "- \(when): \(item.text)" + (scheduled.count > 1 ? " [\(agent == session ? "you" : agentName(agent))]" : "")
            }
        }.joined(separator: "\n")
    }

    public var pinnedFiles: String {
        (workstream.files?.items ?? []).map {
            "- \($0.path)" + ($0.note.map { " — \($0)" } ?? "") + ($0.by == "you" ? " (added by the user)" : "")
                + (FileManager.default.fileExists(atPath: $0.path) ? "" : " (missing: unpin it, or pin where it moved)")
        }
            .joined(separator: "\n")
    }

    /// Pinned, then Recent (edited by the attached agents) and High activity (touched most), from transcripts.
    public var files: String {
        var parts: [String] = []
        if !pinnedFiles.isEmpty { parts.append("Pinned:\n" + pinnedFiles) }
        let recent = activity.recentFiles()
        if !recent.isEmpty {
            parts.append("Recent:\n" + recent.map { "- \($0.path) (edited \(age($0.lastEdit!))\(byAgents($0.agents)))" }.joined(separator: "\n"))
        }
        let busy = activity.highActivity()
        if !busy.isEmpty {
            parts.append("High activity:\n" + busy.map { "- \($0.path) (\($0.count) edits and reads)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    /// Claude Code's cross-session messages involving the attached agents, newest first.
    public var messages: String {
        activity.messages(5).map { row in
            let me = row.agent == session ? "you" : agentName(row.agent)
            let (from, to) = row.message.outgoing ? (me, row.message.peer) : (row.message.peer, me)
            return "- \(from) → \(to) (\(age(row.message.at))): \(Self.oneLine(row.message.text))"
        }.joined(separator: "\n")
    }

    /// Artifacts the attached agents published or linked, newest first.
    public var artifacts: String {
        activity.artifacts().map { row in
            "- \(row.artifact.title ?? ArtifactLinks.title(for: row.artifact.url)): \(row.artifact.url) (\(age(row.artifact.at))\(byAgents([row.agent])))"
        }.joined(separator: "\n")
    }

    private func byAgents(_ agents: [String]) -> String {
        guard activity.perAgent.count > 1 else { return "" }
        return ", by " + agents.map { $0 == session ? "you" : agentName($0) }.joined(separator: ", ")
    }

    private func agentName(_ session: String) -> String {
        if let name = names[session], !name.isEmpty { return name }
        return String(session.prefix(8))
    }

    private func age(_ date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    private func untilText(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 90 { return "\(Int(seconds))s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded()))m" }
        if seconds < 172_800 { return "\(Int((seconds / 3600).rounded()))h" }
        return "\(Int((seconds / 86_400).rounded()))d"
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}
