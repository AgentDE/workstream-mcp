import Foundation

/// Something an agent has scheduled with Claude Code's own tools: a cron job (`CronCreate`, including
/// fixed-interval `/loop`s) or a dynamic wake-up (`ScheduleWakeup`).
public struct ScheduledItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case cron, wakeup }
    public var id: String
    public var kind: Kind
    /// The prompt (or a wake-up's reason), on one line.
    public var text: String
    public var next: Date
    /// Claude's own description of a recurring schedule, e.g. "Every hour at :13".
    public var schedule: String?
    public var recurring: Bool
    public init(id: String, kind: Kind, text: String, next: Date, schedule: String? = nil, recurring: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.next = next
        self.schedule = schedule
        self.recurring = recurring
    }
}

/// A 5-field cron expression (minute hour day-of-month month day-of-week), in local time. Supports `*`,
/// numbers, ranges, lists, steps (`*/15`, `1-30/5`), and month and weekday names. As in cron, when both
/// day fields are restricted a day matches either.
public struct CronExpression: Equatable, Sendable {
    /// The expression as written.
    public let source: String
    let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    let daysRestricted: Bool, weekdaysRestricted: Bool

    public init?(_ text: String) {
        let fields = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard fields.count == 5,
              let minutes = Self.field(fields[0], 0...59, names: [:]),
              let hours = Self.field(fields[1], 0...23, names: [:]),
              let days = Self.field(fields[2], 1...31, names: [:]),
              let months = Self.field(fields[3], 1...12, names: Self.monthNames),
              var weekdays = Self.field(fields[4], 0...7, names: Self.dayNames) else { return nil }
        if weekdays.contains(7) { weekdays.remove(7); weekdays.insert(0) }
        source = text
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = weekdays
        daysRestricted = fields[2] != "*"
        weekdaysRestricted = fields[4] != "*"
    }

    /// Equal when they match the same times, however written (`7` and `0` are both Sunday).
    public static func == (a: CronExpression, b: CronExpression) -> Bool {
        a.minutes == b.minutes && a.hours == b.hours && a.days == b.days && a.months == b.months && a.weekdays == b.weekdays
            && a.daysRestricted == b.daysRestricted && a.weekdaysRestricted == b.weekdaysRestricted
    }

    private static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                     "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let dayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]

    private static func field(_ text: String, _ range: ClosedRange<Int>, names: [String: Int]) -> Set<Int>? {
        var values = Set<Int>()
        for part in text.split(separator: ",") {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(pieces.count) else { return nil }
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { return nil }
            let base = String(pieces[0])
            func value(_ s: Substring) -> Int? { Int(s) ?? names[String(s)] }
            var lower = range.lowerBound, upper = range.upperBound
            if base != "*" {
                let bounds = base.split(separator: "-")
                guard (1...2).contains(bounds.count), let first = value(bounds[0]) else { return nil }
                lower = first
                upper = bounds.count == 2 ? (value(bounds[1]) ?? -1) : (pieces.count == 2 ? range.upperBound : first)
            }
            guard range.contains(lower), range.contains(upper), lower <= upper else { return nil }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        return values.isEmpty ? nil : values
    }

    /// The first time strictly after `date` that matches, within about a year.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard var day = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: date)) else { return nil }
        for _ in 0..<400 {
            let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
            let dayMatch: Bool
            let domOK = days.contains(parts.day!), dowOK = weekdays.contains(parts.weekday! - 1)
            if daysRestricted && weekdaysRestricted { dayMatch = domOK || dowOK } else { dayMatch = domOK && dowOK }
            if months.contains(parts.month!), dayMatch {
                for hour in hours.sorted() {
                    for minute in minutes.sorted() {
                        if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                           candidate > date { return candidate }
                    }
                }
            }
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = following
        }
        return nil
    }
}

/// An agent session's scheduling as read from its transcript: its cron jobs and its pending wake-up.
public struct Schedule: Equatable, Sendable, Codable {
    struct Cron: Equatable, Sendable, Codable {
        var id: String
        var expression: CronExpression
        var prompt: String
        var recurring: Bool
        var durable: Bool
        var created: Date
        var schedule: String?

        init(id: String, expression: CronExpression, prompt: String, recurring: Bool, durable: Bool, created: Date, schedule: String?) {
            self.id = id
            self.expression = expression
            self.prompt = prompt
            self.recurring = recurring
            self.durable = durable
            self.created = created
            self.schedule = schedule
        }

        private enum CodingKeys: String, CodingKey { case id, cron, prompt, recurring, durable, created, schedule }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            let text = try c.decode(String.self, forKey: .cron)
            guard let expression = CronExpression(text) else {
                throw DecodingError.dataCorruptedError(forKey: .cron, in: c, debugDescription: "bad cron \(text)")
            }
            self.expression = expression
            prompt = try c.decode(String.self, forKey: .prompt)
            recurring = try c.decode(Bool.self, forKey: .recurring)
            durable = try c.decode(Bool.self, forKey: .durable)
            created = try c.decode(Date.self, forKey: .created)
            schedule = try c.decodeIfPresent(String.self, forKey: .schedule)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(expression.source, forKey: .cron)
            try c.encode(prompt, forKey: .prompt)
            try c.encode(recurring, forKey: .recurring)
            try c.encode(durable, forKey: .durable)
            try c.encode(created, forKey: .created)
            try c.encodeIfPresent(schedule, forKey: .schedule)
        }
    }

    struct Wakeup: Equatable, Sendable, Codable {
        var at: Date
        var text: String
    }

    var crons: [String: Cron] = [:]
    var wakeup: Wakeup?

    public init() {}

    /// Session-only recurring jobs expire this long after they're made (Claude Code's rule).
    public static let recurringLifetime: TimeInterval = 7 * 86_400

    public var isEmpty: Bool { crons.isEmpty && wakeup == nil }

    /// What's still scheduled. Session-only jobs and wake-ups exist only while the session runs.
    public func items(now: Date = Date(), sessionLive: Bool) -> [ScheduledItem] {
        var items: [ScheduledItem] = []
        for cron in crons.values {
            guard sessionLive || cron.durable else { continue }
            if cron.recurring {
                if !cron.durable, now.timeIntervalSince(cron.created) > Self.recurringLifetime { continue }
                guard let next = cron.expression.next(after: now) else { continue }
                items.append(ScheduledItem(id: cron.id, kind: .cron, text: ScheduleScanner.oneLine(cron.prompt), next: next,
                                           schedule: cron.schedule, recurring: true))
            } else {
                // A one-off fires at its first match after it was made, then it's gone.
                guard let fire = cron.expression.next(after: cron.created), fire > now else { continue }
                items.append(ScheduledItem(id: cron.id, kind: .cron, text: ScheduleScanner.oneLine(cron.prompt), next: fire))
            }
        }
        if sessionLive, let wakeup, wakeup.at > now {
            items.append(ScheduledItem(id: "wakeup", kind: .wakeup, text: ScheduleScanner.oneLine(wakeup.text), next: wakeup.at))
        }
        return items.sorted { $0.next < $1.next }
    }
}

/// Reads an agent session's scheduling from its Claude Code transcript, incrementally: each call reads
/// only what was appended since the last one. `CronCreate` adds a job (its id comes from the tool result),
/// `CronDelete` removes one, `ScheduleWakeup` replaces the session's pending wake-up (or stops it).
/// Not thread-safe; `schedule` is a value to hand to other threads.
public final class ScheduleScanner: @unchecked Sendable {
    private var offset: UInt64 = 0
    private var partial = Data()
    private var pending: [String: (name: String, input: [String: Any])] = [:]
    public private(set) var schedule = Schedule()

    public init() {}

    /// What a scanner fed by `TranscriptScanner` needs to resume: the schedule and the calls still waiting
    /// for their results (inputs as JSON).
    struct State: Codable {
        var schedule: Schedule
        var pending: [String: PendingCall]
        struct PendingCall: Codable { var name: String; var input: Data }
    }

    var state: State {
        State(schedule: schedule, pending: pending.mapValues {
            State.PendingCall(name: $0.name, input: (try? JSONSerialization.data(withJSONObject: $0.input)) ?? Data("{}".utf8))
        })
    }

    init(state: State) {
        schedule = state.schedule
        pending = state.pending.mapValues {
            ($0.name, ((try? JSONSerialization.jsonObject(with: $0.input)) as? [String: Any]) ?? [:])
        }
    }

    /// Handles one transcript line (for `TranscriptScanner`, which does the reading). Returns whether the
    /// schedule changed.
    func consume(_ line: Data) -> Bool { process(line) }

    func resetForRescan() { reset() }

    /// Reads what's new in the transcript. Returns whether anything about the schedule changed.
    @discardableResult
    public func scan(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { reset() }   // the file was replaced
        guard size > offset else { return false }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        var buffer = partial + data
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[(newline + 1)...]
            if process(Data(line)) { changed = true }
        }
        partial = Data(buffer)
        return changed
    }

    public func items(now: Date = Date(), sessionLive: Bool) -> [ScheduledItem] { schedule.items(now: now, sessionLive: sessionLive) }

    private func reset() {
        offset = 0
        partial = Data()
        pending = [:]
        schedule = Schedule()
    }

    private static let names = ["CronCreate", "CronDelete", "ScheduleWakeup"]
    private static let markers = names.map { Data($0.utf8) }
    private static let resultMarker = Data("tool_use_id".utf8)

    private func process(_ line: Data) -> Bool {
        let interesting = Self.markers.contains { line.range(of: $0) != nil }
            || (!pending.isEmpty && line.range(of: Self.resultMarker) != nil)
        guard interesting, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return false }
        var changed = false
        let timestamp = (object["timestamp"] as? String).flatMap(Self.parseDate) ?? Date()
        for block in content {
            if block["type"] as? String == "tool_use", let name = block["name"] as? String, Self.names.contains(name),
               let id = block["id"] as? String {
                pending[id] = (name, block["input"] as? [String: Any] ?? [:])
            } else if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                      let call = pending.removeValue(forKey: id) {
                if block["is_error"] as? Bool == true { continue }
                let result = object["toolUseResult"] as? [String: Any] ?? [:]
                switch call.name {
                case "CronCreate":
                    guard let jobID = result["id"] as? String,
                          let text = call.input["cron"] as? String, let expression = CronExpression(text) else { continue }
                    schedule.crons[jobID] = Schedule.Cron(
                        id: jobID, expression: expression, prompt: call.input["prompt"] as? String ?? "",
                        recurring: (result["recurring"] as? Bool) ?? (call.input["recurring"] as? Bool) ?? true,
                        durable: (result["durable"] as? Bool) ?? (call.input["durable"] as? Bool) ?? false,
                        created: timestamp, schedule: result["humanSchedule"] as? String)
                    changed = true
                case "CronDelete":
                    if let jobID = (result["id"] as? String) ?? (call.input["id"] as? String),
                       schedule.crons.removeValue(forKey: jobID) != nil {
                        changed = true
                    }
                case "ScheduleWakeup":
                    if call.input["stop"] as? Bool == true || result["stopped"] as? Bool == true {
                        if schedule.wakeup != nil { schedule.wakeup = nil; changed = true }
                    } else if let at = (result["scheduledFor"] as? NSNumber)?.doubleValue, at > 0 {
                        let text = (call.input["reason"] as? String) ?? (call.input["prompt"] as? String) ?? ""
                        schedule.wakeup = Schedule.Wakeup(at: Date(timeIntervalSince1970: at / 1000), text: text)
                        changed = true
                    }
                default:
                    break
                }
            }
        }
        return changed
    }

    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    public static func parseDate(_ text: String) -> Date? { isoFractional.date(from: text) ?? iso.date(from: text) }
}

/// Where Claude Code keeps things the schedule is read from.
public enum NativeSchedule {
    public static var projectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// The transcript of an agent session: `<projects>/<folder>/<session id>.jsonl`.
    public static func transcript(session: String, in projects: URL = projectsDirectory) -> URL? {
        guard WorkstreamStore.isValidID(session) else { return nil }
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let file = folder.appendingPathComponent(session + ".jsonl")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    /// Durable jobs Claude keeps for a project in `<folder>/.claude/scheduled_tasks.json`. Read defensively:
    /// an array of jobs, or an object holding one under `tasks` or `jobs`; each with an id, a cron
    /// expression (`cron` or `schedule`) and a `prompt`.
    public static func durableJobs(folder: String, now: Date = Date()) -> [ScheduledItem] {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(".claude/scheduled_tasks.json")
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list = (object as? [[String: Any]])
            ?? ((object as? [String: Any]).flatMap { ($0["tasks"] ?? $0["jobs"]) as? [[String: Any]] })
            ?? ((object as? [String: Any]).map { dict in dict.compactMap { key, value -> [String: Any]? in
                guard var job = value as? [String: Any] else { return nil }
                if job["id"] == nil { job["id"] = key }
                return job
            } } ?? [])
        return list.compactMap { job in
            guard let id = (job["id"] as? String) ?? (job["id"] as? Int).map(String.init),
                  let text = (job["cron"] ?? job["schedule"]) as? String, let expression = CronExpression(text),
                  let next = expression.next(after: now) else { return nil }
            let recurring = job["recurring"] as? Bool ?? true
            return ScheduledItem(id: id, kind: .cron, text: ScheduleScanner.oneLine(job["prompt"] as? String ?? ""), next: next,
                                 schedule: job["humanSchedule"] as? String, recurring: recurring)
        }
    }
}
