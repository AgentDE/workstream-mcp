import Foundation

/// Who is calling (an agent session) and which workstream it belongs to, from the environment Claude Code
/// or Codex gives the MCP server or hook. Resolution is dynamic: an agent can switch workstreams, so its
/// workstream is looked up from the session index on every call.
public struct AgentContext: @unchecked Sendable {
    public let environment: [String: String]
    public let cwd: String
    public let store: WorkstreamStore
    /// Claude Code's folder: `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public let claudeDirectory: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                cwd: String = FileManager.default.currentDirectoryPath,
                store: WorkstreamStore? = nil, claudeDirectory: URL? = nil) {
        self.environment = environment
        self.cwd = cwd
        self.store = store ?? WorkstreamStore(directory: AgentContext.workstreamsDirectory(environment))
        self.claudeDirectory = claudeDirectory ?? environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    public static func workstreamsDirectory(_ environment: [String: String]) -> URL {
        if let dir = environment["WORKSTREAM_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/workstreams")
    }

    /// A background session (`claude --bg`, a `/fork`). It runs under Claude's daemon and inherits the
    /// daemon's environment, which belongs to whichever process started the daemon, so its `WORKSTREAM_*` values
    /// there are stale and are ignored.
    public var isBackground: Bool { !(environment["CLAUDE_JOB_DIR"] ?? "").isEmpty }

    public var session: String? {
        let id = environment["CLAUDE_CODE_SESSION_ID"] ?? environment["CODEX_SESSION_ID"] ?? environment["CODEX_THREAD_ID"]
        return id.flatMap { WorkstreamStore.isValidID($0) ? $0 : nil }
    }

    public var kind: String { environment["CLAUDE_CODE_SESSION_ID"] != nil ? "claude" : "codex" }

    /// The the app tab running this agent, when it isn't a background session.
    public var tab: String? { isBackground ? nil : nonEmpty(WorkstreamEnvironment.tabID) }

    /// The workstream the app gave the tab when it started, used until the session is indexed.
    public var hint: String? { isBackground ? nil : nonEmpty(WorkstreamEnvironment.workstreamID).flatMap { WorkstreamStore.isValidID($0) ? $0 : nil } }

    public var everywhere: Bool { environment["WORKSTREAM_EVERYWHERE"] == "1" }

    /// Whether this looks like an agent inside the app (or the server is on everywhere). Background sessions
    /// whose daemon came from an the app tab count, since the app adopts them as tabs.
    public var enabled: Bool { everywhere || nonEmpty(WorkstreamEnvironment.tabID) != nil || resolve(attach: false) != nil }

    private func nonEmpty(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }

    /// A `/fork`'s parent session, from its background job's record.
    public var forkParent: String? {
        guard let job = environment["CLAUDE_JOB_DIR"], !job.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: job).appendingPathComponent("state.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parent = object["forkParentSessionId"] as? String, WorkstreamStore.isValidID(parent) else { return nil }
        return parent
    }

    /// The calling agent's workstream. With `attach`, a session that isn't indexed yet joins one: a fork joins
    /// its parent's, an the app tab's agent joins the tab's, and with `WORKSTREAM_EVERYWHERE` any other
    /// agent gets a new one.
    public func resolve(attach: Bool) -> String? {
        let all = store.all()
        let index = WorkstreamStore.sessionIndex(all)
        guard let session else { return hint.flatMap { store.read($0) != nil ? $0 : nil } }
        if let id = index[session] { return id }
        // A resumed session goes back to the workstream it left, with its memory and ids, not the new tab's.
        if let id = WorkstreamStore.formerIndex(all)[session] {
            if attach { try? store.moveAgent(session: session, kind: kind, tab: tab, to: id, folder: cwd) }
            return id
        }
        if let parent = forkParent, let id = index[parent] {
            if attach { try? store.moveAgent(session: session, kind: kind, tab: nil, to: id, folder: cwd) }
            return id
        }
        if let hint {
            if attach { try? store.moveAgent(session: session, kind: kind, tab: tab, to: hint, folder: cwd) }
            return attach || store.read(hint) != nil ? hint : nil
        }
        if everywhere, attach {
            let id = UUID().uuidString
            try? store.moveAgent(session: session, kind: kind, tab: nil, to: id, folder: cwd)
            return id
        }
        return nil
    }
}

/// Live agent sessions from Claude Code's registry (`<claude dir>/sessions/<pid>.json`): session id → name.
public enum ClaudeRegistry {
    /// A `/fork`'s parent session, from its background job's record (`<claude dir>/jobs/<job>/state.json`).
    public static func forkParent(job: String, in claudeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")) -> String? {
        guard WorkstreamStore.isValidID(job) else { return nil }
        let url = claudeDirectory.appendingPathComponent("jobs").appendingPathComponent(job).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parent = object["forkParentSessionId"] as? String, WorkstreamStore.isValidID(parent) else { return nil }
        return parent
    }

    public static func liveSessions(in claudeDirectory: URL) -> [String: String] {
        let dir = claudeDirectory.appendingPathComponent("sessions")
        var live: [String: String] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = object["sessionId"] as? String, let pid = (object["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0 else { continue }
            live[session] = (object["name"] as? String) ?? ""
        }
        return live
    }
}

/// The environment variables an app sets in each agent's terminal so the MCP server knows where it is.
public enum WorkstreamEnvironment {
    /// The terminal's tab, as the app names it (a UUID).
    public static let tabID = "WORKSTREAM_TAB_ID"
    /// The workstream the tab shows: an agent session that isn't in one yet joins it.
    public static let workstreamID = "WORKSTREAM_ID"
}
