import Foundation

/// Claude Code's status line input, saved per session so the app's Stats can show exact numbers.
/// `workstream-mcp statusline -- <your status line command>` saves the JSON Claude sends on stdin to
/// `<cache>/statusline/<session id>.json` (see `TranscriptCache.directory`) and then runs your command with the
/// same input, printing its output unchanged. Saving never gets in the way: if it fails, the command still runs.
public enum StatusLineFeed {
    public struct Status: Equatable, Sendable {
        public var costUSD: Double?
        public var durationSeconds: Double?
        public var apiDurationSeconds: Double?
        public var linesAdded: Int?
        public var linesRemoved: Int?
        /// 0–100.
        public var contextUsedPercent: Double?
        public var contextWindow: Int?
        public var model: String?
        public var updated: Date
    }

    static func file(session: String, in directory: URL) -> URL {
        directory.appendingPathComponent("statusline").appendingPathComponent(session + ".json")
    }

    /// Saves the input when it names a session. Returns the session id saved under.
    @discardableResult
    public static func save(_ input: Data, directory: URL = TranscriptCache.directory()) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let session = object["session_id"] as? String, WorkstreamStore.isValidID(session) else { return nil }
        let url = file(session: session, in: directory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try input.write(to: url, options: .atomic)
            return session
        } catch {
            return nil
        }
    }

    public static func read(session: String, directory: URL = TranscriptCache.directory()) -> Status? {
        guard WorkstreamStore.isValidID(session) else { return nil }
        let url = file(session: session, in: directory)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return parse(object, updated: modified)
    }

    static func parse(_ object: [String: Any], updated: Date) -> Status {
        func number(_ dict: [String: Any]?, _ key: String) -> Double? { (dict?[key] as? NSNumber)?.doubleValue }
        let cost = object["cost"] as? [String: Any]
        let context = object["context_window"] as? [String: Any]
        let model = object["model"] as? [String: Any]
        return Status(costUSD: number(cost, "total_cost_usd"),
                      durationSeconds: number(cost, "total_duration_ms").map { $0 / 1000 },
                      apiDurationSeconds: number(cost, "total_api_duration_ms").map { $0 / 1000 },
                      linesAdded: number(cost, "total_lines_added").map { Int($0) },
                      linesRemoved: number(cost, "total_lines_removed").map { Int($0) },
                      contextUsedPercent: number(context, "used_percentage"),
                      contextWindow: number(context, "context_window_size").map { Int($0) },
                      model: (model?["id"] as? String) ?? (model?["display_name"] as? String),
                      updated: updated)
    }

    /// The wrapper: saves `input`, then runs `command` with it. One argument is a shell command line (run with
    /// `/bin/sh -c`); several are a program and its arguments. Returns the command's exit status.
    public static func run(input: Data, command: [String], output: FileHandle = .standardOutput,
                           error: FileHandle = .standardError, directory: URL = TranscriptCache.directory()) -> Int32 {
        save(input, directory: directory)
        guard !command.isEmpty else { return 0 }
        let process = Process()
        if command.count == 1 {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command[0]]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
        }
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = error
        // A command that exits without reading its input gets EPIPE here, not SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { return 127 }
        // A command that exits without reading its input mustn't take the wrapper down (EPIPE is an error here).
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
