import Foundation
import Testing
@testable import WorkstreamKit

/// A throwaway workstreams folder and Claude folder, and an agent's environment inside AgentDE.
private struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-server-\(UUID().uuidString)")
    var workstreams: URL { root.appendingPathComponent("workstreams") }
    var claude: URL { root.appendingPathComponent("claude") }
    var cwd: String { root.appendingPathComponent("project").path }
    var store: WorkstreamStore { WorkstreamStore(directory: workstreams) }
    static let session = "11111111-1111-1111-1111-111111111111"

    init() {
        try? FileManager.default.createDirectory(atPath: root.appendingPathComponent("project").path, withIntermediateDirectories: true)
    }

    func context(_ extra: [String: String] = [:], session: String? = Sandbox.session, inApp: Bool = true) -> AgentContext {
        var env: [String: String] = [:]
        if let session { env["CLAUDE_CODE_SESSION_ID"] = session }
        if inApp {
            env["WORKSTREAM_TAB_ID"] = "TAB-1"
            env["WORKSTREAM_ID"] = "WS-1"
        }
        env.merge(extra) { _, new in new }
        return AgentContext(environment: env, cwd: cwd, store: store, claudeDirectory: claude)
    }

    func server(_ context: AgentContext, now: Date = Date()) -> WorkstreamServer { WorkstreamServer(context: context, now: { now }) }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func call(_ server: WorkstreamServer, _ name: String, _ arguments: [String: Any] = [:], id: Int = 1) -> (text: String, isError: Bool) {
    let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
    let line = String(data: try! JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
    let response = try! JSONSerialization.jsonObject(with: server.handle(line)!.data(using: .utf8)!) as! [String: Any]
    let result = response["result"] as? [String: Any] ?? [:]
    let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ((response["error"] as? [String: Any])?["message"] as? String ?? "")
    return (text, result["isError"] as? Bool == true || response["error"] != nil)
}

private func rpc(_ server: WorkstreamServer, _ object: [String: Any]) -> [String: Any]? {
    let line = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    return server.handle(line).flatMap { try? JSONSerialization.jsonObject(with: $0.data(using: .utf8)!) as? [String: Any] }
}

@Suite("workstream MCP protocol", .serialized)
struct WorkstreamProtocolTests {
    @Test func inAgentDEItOffersToolsAndInstructions() {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        let initialize = rpc(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        let result = initialize?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2025-06-18")
        #expect((result?["instructions"] as? String)?.contains("set_overview") == true)
        #expect((result?["capabilities"] as? [String: Any])?["tools"] != nil)
        let tools = (rpc(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let names = Set((tools ?? []).compactMap { $0["name"] as? String })
        #expect(names == ["read_workstream", "set_overview", "add_rule", "add_memory", "set_progress", "ask_user", "tell_user", "pin_file",
                          "link_ticket", "remove_entry", "open_in_viewer", "manage_workstreams"])
        #expect((result?["instructions"] as? String)?.contains("still waiting on you") == true)
        #expect(!names.contains("schedule_reminder"))
    }

    @Test func elsewhereItOffersNothing() {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context(inApp: false))
        let result = rpc(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])?["result"] as? [String: Any]
        #expect(result?["instructions"] == nil)
        #expect(server.announceIfEnabled() == nil)
        let tools = (rpc(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [Any]
        #expect(tools?.isEmpty == true)
        #expect(call(server, "set_overview", ["text": "x"]).isError)
        #expect(!FileManager.default.fileExists(atPath: box.workstreams.path))
    }

    @Test func aSessionThatJoinsLaterGetsItsToolsAnnounced() throws {
        let box = Sandbox(); defer { box.cleanup() }
        // A background session: no AgentDE environment, and not in any workstream yet.
        let server = box.server(box.context(inApp: false))
        _ = rpc(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        #expect(server.announceIfEnabled() == nil)
        try box.store.moveAgent(session: Sandbox.session, kind: "claude", tab: "TAB-1", to: "WS-1")   // a tab adopts it
        #expect(server.announceIfEnabled()?.contains("notifications/tools/list_changed") == true)
        #expect(server.announceIfEnabled() == nil)   // once
        let tools = (rpc(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [Any]
        #expect((tools?.count ?? 0) > 10)
    }

    @Test func handlesPingNotificationsAndErrors() {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        #expect(rpc(server, ["jsonrpc": "2.0", "id": 7, "method": "ping"])?["result"] != nil)
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect((rpc(server, ["jsonrpc": "2.0", "id": 8, "method": "resources/list"])?["error"] as? [String: Any])?["code"] as? Int == -32601)
        let parse = server.handle("{not json").flatMap { try? JSONSerialization.jsonObject(with: $0.data(using: .utf8)!) as? [String: Any] }
        #expect((parse?["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect(call(server, "no_such_tool").isError)
        #expect(call(server, "set_overview", [:]).text.contains("required"))
    }
}

@Suite("workstream MCP tools", .serialized)
struct WorkstreamToolTests {
    @Test func memoryStopsAtItsLimitButItemsCanStillBeUpdated() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        #expect(box.store.memoryLimit == 25)   // the default
        try box.store.saveSettings(.init(memoryLimit: 2))
        #expect(!call(server, "add_memory", ["name": "a", "text": "A."]).isError)
        #expect(!call(server, "add_memory", ["name": "b", "text": "B."]).isError)
        let refused = call(server, "add_memory", ["name": "c", "text": "C."])
        #expect(refused.isError && refused.text.contains("Memory is full: 2 items, and the limit is 2.")
                && refused.text.contains("- [m1] a") && refused.text.contains("notes file"))
        #expect(box.store.read("WS-1")?.memory?.items.count == 2)
        #expect(!call(server, "add_memory", ["name": "a", "text": "A, updated."]).isError)   // updating is fine
        #expect(!call(server, "remove_entry", ["id": "m2"]).isError)
        #expect(!call(server, "add_memory", ["name": "c", "text": "C."]).isError)
        try box.store.saveSettings(.init(memoryLimit: 0))   // no limit
        #expect(box.store.memoryLimit == nil && !call(server, "add_memory", ["name": "d", "text": "D."]).isError)
        #expect(box.store.all().count == 1)   // the settings file isn't a workstream
    }

    @Test func updatesEachSection() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        #expect(call(server, "set_overview", ["text": "Train the no-text arm."]).text == "Overview set.")
        #expect(call(server, "add_memory", ["name": "backup-volume", "text": "Data isn't on the backup volume."]).text == "Remembered m1 (backup-volume).")
        // Without a name (a session with the old schema), one is made from the text, and it never overwrites.
        #expect(call(server, "add_memory", ["text": "Data isn't on the backup volume, again."]).text.hasPrefix("Remembered m2 (data-isnt-on-the)."))
        #expect(call(server, "add_memory", ["text": "Data isn't on the main volume."]).text.hasPrefix("Remembered m3 (data-isnt-on-the-2)."))
        #expect(!call(server, "remove_entry", ["id": "m3"]).isError)
        #expect(!call(server, "remove_entry", ["id": "m2"]).isError)
        // Adding another lists the others, dated, to check while writing.
        let second = call(server, "add_memory", ["name": "noise-ref", "text": "Noise reference: main4 seeds."]).text
        let today = Workstream.MemoryItem.day(Date())
        // Today's items are too fresh to question.
        #expect(second == "Remembered m4 (noise-ref).")
        _ = today
        // The same name updates that item rather than adding another.
        #expect(call(server, "add_memory", ["name": "Noise-Ref", "text": "Noise reference: main5 seeds."]).text.hasPrefix("Updated m4 (Noise-Ref)."))
        #expect(box.store.read("WS-1")?.memory?.items.map(\.text) == ["Data isn't on the backup volume.", "Noise reference: main5 seeds."])
        #expect(!call(server, "remove_entry", ["id": "m1"]).isError)
        #expect(call(server, "remove_entry", ["id": "m9"]).isError)
        _ = call(server, "set_progress", ["rows": [["label": "campaign", "value": 0.72, "text": "4,375 episodes"], ["label": "backups", "text": "no pods"]]])
        #expect(call(server, "tell_user", ["text": "Pod relaunched after the outage."]).text == "Noted (f1).")
        #expect(call(server, "add_rule", ["text": "Ask before spending over $20."]).text == "Added rule r1.")
        try "x".write(toFile: box.cwd + "/REPORT.md", atomically: true, encoding: .utf8)
        _ = call(server, "pin_file", ["path": "REPORT.md", "note": "training plan"])
        let w = try #require(box.store.read("WS-1"))
        #expect(w.overview?.text == "Train the no-text arm.")
        #expect(w.memory?.items.map(\.id) == ["m4"])
        #expect(w.progress?.rows.map(\.label) == ["campaign", "backups"])
        #expect(w.progress?.rows.first?.agent == Sandbox.session)
        #expect(w.fyi?.items.first?.text == "Pod relaunched after the outage.")
        #expect(w.activeRules.map(\.by) == ["agent"])
        #expect(w.files?.items.first?.path == URL(fileURLWithPath: box.cwd + "/REPORT.md").standardizedFileURL.path)
        #expect(w.agents.map(\.session) == [Sandbox.session])
        #expect(w.agents.first?.tab == "TAB-1")
        #expect(w.folder == box.cwd)
        let details = call(server, "read_workstream").text
        for part in ["## Rules", "## Overview", "## Memory", "## Progress", "## FYI", "## Files\nPinned:", "72%"] {
            #expect(details.contains(part), "missing \(part)")
        }
        #expect(!call(server, "remove_entry", ["path": box.cwd + "/REPORT.md"]).isError)
        #expect(call(server, "remove_entry", ["id": "r1"]).text == "Removed r1.")
        #expect(call(server, "read_workstream", ["section": "rules"]).text == "No rules.")
        #expect(call(server, "remove_entry", ["id": "f1"]).text == "Removed f1.")
        #expect(call(server, "remove_entry", ["id": "x7"]).isError)
        #expect(call(server, "read_workstream", ["section": "nope"]).isError)
    }

    @Test func longTextIsRefusedNotCut() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        let long = String(repeating: "x", count: 401)
        let refused = call(server, "set_overview", ["text": long])
        #expect(refused.isError)
        #expect(refused.text.contains("401 characters, 1 over the limit of 400"))
        #expect(box.store.read("WS-1")?.overview == nil)
        #expect(!call(server, "set_overview", ["text": String(long.dropLast())]).isError)
        #expect(call(server, "set_progress", ["rows": [["label": "a", "text": String(repeating: "y", count: 141)]]]).isError)
        #expect(call(server, "ask_user", ["question": "Ship?", "options": ["yes", String(repeating: "z", count: 61)]]).isError)
        let tools = (rpc(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let overview = tools?.first { $0["name"] as? String == "set_overview" }
        let text = ((overview?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["text"] as? [String: Any]
        #expect(text?["maxLength"] as? Int == 400)
    }

    /// add_memory asks about items older than a few days only, and shows them in full.
    @Test func memoryReviewListsOnlyOlderItemsInFull() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let long = "Old fact " + String(repeating: "y", count: 200)
        _ = call(box.server(box.context(), now: now.addingTimeInterval(-5 * 86_400)), "add_memory", ["name": "old", "text": long])
        _ = call(box.server(box.context(), now: now.addingTimeInterval(-3600)), "add_memory", ["name": "fresh", "text": "New fact"])
        let reply = call(box.server(box.context(), now: now), "add_memory", ["name": "third", "text": "Third"]).text
        #expect(reply.contains("[m1]") && reply.contains(long) && !reply.contains("[m2]"))
    }

    /// merge: true changes only the rows sent; empty text removes one.
    @Test func progressRowsUpdateInPlace() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        _ = call(server, "set_progress", ["rows": [["label": "train", "value": 0.2, "text": "epoch 2"], ["label": "eval", "text": "queued"]]])
        _ = call(server, "set_progress", ["merge": true, "rows": [["label": "train", "value": 0.5, "text": "epoch 5"]]])
        #expect(box.store.read("WS-1")?.progress?.rows.map(\.text) == ["epoch 5", "queued"])
        #expect(call(server, "set_progress", ["merge": true, "rows": [["label": "eval", "text": ""]]]).text.contains("1 row"))
        #expect(box.store.read("WS-1")?.progress?.rows.map(\.label) == ["train"])
    }

    /// An open ask can be reworded in place; read_workstream shows answered ones with their answer.
    @Test func asksUpdateInPlaceAndShowTheirAnswers() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        _ = call(server, "ask_user", ["question": "Ship?", "options": ["Yes", "No"]])
        #expect(call(server, "ask_user", ["id": "a1", "question": "Ship today?", "options": ["Yes", "Tomorrow"]]).text == "Updated a1.")
        let ask = try #require(box.store.read("WS-1")?.openAsks.first)
        #expect(ask.question == "Ship today?" && ask.options == ["Yes", "Tomorrow"] && box.store.read("WS-1")?.openAsks.count == 1)
        #expect(call(server, "ask_user", ["id": "a9", "question": "?"]).isError)
        try box.store.update("WS-1") { $0.resolve(ask: "a1", by: "you", answer: "Tomorrow") }
        #expect(call(server, "read_workstream", ["section": "waiting"]).text.contains("[a1] Ship today? → answered \"Tomorrow\""))
    }

    @Test func progressKeepsOtherAgentsRows() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let other = "22222222-2222-2222-2222-222222222222"
        try box.store.update("WS-1") { w in
            w.attach(session: other, kind: "claude")
            w.progress = .init(rows: [.init(label: "theirs", text: "a", agent: other)])
        }
        let server = box.server(box.context())
        _ = call(server, "set_progress", ["rows": [["label": "mine", "value": 0.5, "text": "b"]]])
        _ = call(server, "set_progress", ["rows": [["label": "mine", "value": 0.6, "text": "c"]]])
        #expect(box.store.read("WS-1")?.progress?.rows.map(\.label) == ["theirs", "mine"])
        #expect(box.store.read("WS-1")?.progress?.rows.last?.value == 0.6)
    }

    /// Ids are never handed out twice, even after the item with the highest one is removed.
    @Test func removedIdsAreNotReused() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        _ = call(server, "add_memory", ["name": "one", "text": "first"])
        _ = call(server, "add_memory", ["name": "two", "text": "second"])
        _ = call(server, "remove_entry", ["id": "m2"])
        #expect(call(server, "add_memory", ["name": "three", "text": "third"]).text.hasPrefix("Remembered m3"))
        _ = call(server, "remove_entry", ["id": "m1"])
        _ = call(server, "remove_entry", ["id": "m3"])
        #expect(call(server, "add_memory", ["name": "four", "text": "fourth"]).text.hasPrefix("Remembered m4"))
        _ = call(server, "ask_user", ["question": "?", "options": ["Yes"]])
        _ = call(server, "remove_entry", ["id": "a1"])
        #expect(call(server, "ask_user", ["question": "?", "options": ["Yes"]]).text.hasPrefix("Asked (a2)"))
        let missing = call(server, "remove_entry", ["id": "m1"])
        #expect(missing.isError && missing.text.contains("Current ids: m4, a2"))
    }

    /// Agents often pass an item's id as its name to update it.
    @Test func anIdAsTheNameUpdatesThatItem() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        _ = call(server, "add_memory", ["name": "plan", "text": "old"])
        #expect(call(server, "add_memory", ["name": "m1", "text": "new"]).text.hasPrefix("Updated m1 (plan)"))
        let items = box.store.read("WS-1")?.memory?.items ?? []
        #expect(items.map(\.id) == ["m1"] && items.first?.text == "new" && items.first?.name == "plan")
    }

    /// Removing an ask the user already answered or dismissed explains instead of failing.
    @Test func removingAnAnsweredAskSaysSo() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        _ = call(server, "ask_user", ["question": "Ship?", "options": ["Yes", "No"]])
        _ = call(server, "ask_user", ["question": "Merge?", "options": ["Yes", "No"]])
        try box.store.update("WS-1") { $0.resolve(ask: "a1", by: "you", answer: "Yes"); $0.resolve(ask: "a2", by: "you") }
        let answered = call(server, "remove_entry", ["id": "a1"])
        #expect(!answered.isError && answered.text.contains("answered by the user (\"Yes\")"))
        #expect(call(server, "remove_entry", ["id": "a2"]).text.contains("dismissed by the user"))
    }

    /// A session whose tab closed comes back to its old workstream when resumed in a new tab.
    @Test func aResumedSessionRejoinsItsWorkstream() throws {
        let box = Sandbox(); defer { box.cleanup() }
        _ = call(box.server(box.context()), "add_memory", ["name": "keep", "text": "kept"])
        try box.store.update("WS-1") { $0.detach(session: Sandbox.session) }
        let resumed = box.context(["WORKSTREAM_TAB_ID": "TAB-2", "WORKSTREAM_ID": "WS-2"])
        #expect(resumed.resolve(attach: true) == "WS-1")
        #expect(box.store.read("WS-1")?.agents.map(\.session) == [Sandbox.session])
        #expect(box.store.read("WS-1")?.former == nil)
        // Moving to another workstream on purpose isn't leaving: no way back is recorded.
        try box.store.moveAgent(session: Sandbox.session, kind: "claude", tab: "TAB-2", to: "WS-3")
        #expect(WorkstreamStore.formerIndex(box.store.all())[Sandbox.session] == nil)
    }

    @Test func asksCarryADefaultAndADeadline() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let server = box.server(box.context(), now: now)
        let asked = call(server, "ask_user", ["question": "Seed 1 only, or both?", "options": ["Seed 1", "Both"], "default": "Seed 1", "in_minutes": 25])
        #expect(asked.text.contains("a1"))
        #expect(call(server, "ask_user", ["question": "?", "in_minutes": 5]).text == "A deadline needs a default.")
        #expect(call(server, "ask_user", ["question": "OK with a $1.5k cap?"]).text.contains("Yes / No / Discuss"))
        #expect(box.store.read("WS-1")?.openAsks.last?.options == ["Yes", "No", "Discuss"])
        let ask = try #require(box.store.read("WS-1")?.openAsks.first)
        #expect(ask.defaultOption == "Seed 1")
        #expect(ask.decideBy == now.addingTimeInterval(25 * 60))
        #expect(ask.agent == Sandbox.session)
        #expect(call(server, "read_workstream", ["section": "waiting"]).text.contains("Default: Seed 1"))
        _ = call(server, "remove_entry", ["id": "a1"])
        _ = call(server, "remove_entry", ["id": "a2"])
        let w = try #require(box.store.read("WS-1"))
        #expect(w.openAsks.isEmpty)
        #expect(w.waiting?.asks.first?.resolvedBy == "agent")
    }

    @Test func openInViewerPostsARequestAgentDETakes() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        #expect(call(server, "open_in_viewer", ["path": "missing.md"]).isError)
        try "x".write(toFile: box.cwd + "/plot.png", atomically: true, encoding: .utf8)
        #expect(!call(server, "open_in_viewer", ["path": "plot.png"]).isError)
        #expect(!call(server, "open_in_viewer", ["path": "http://localhost:5173/dash"]).isError)
        let requests = box.store.takeRequests()
        #expect(requests.map(\.action) == ["open", "open"])
        #expect(requests.first?.session == Sandbox.session)
        #expect(requests.first?.tab == "TAB-1")
        #expect(requests.last?.path == "http://localhost:5173/dash")
        #expect(box.store.takeRequests().isEmpty)
    }

    @Test func switchesAndStartsWorkstreams() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        _ = call(server, "set_overview", ["text": "first"])
        let started = call(server, "manage_workstreams", ["action": "new", "name": "Seed sweep"])
        #expect(started.text.hasPrefix("Started Seed sweep"))
        let index = WorkstreamStore.sessionIndex(box.store.all())
        let newID = try #require(index[Sandbox.session])
        #expect(newID != "WS-1")
        #expect(box.store.read("WS-1")?.agents.isEmpty == true)
        #expect(box.store.read(newID)?.folder == box.cwd)
        // The hint (the tab's starting workstream) no longer wins: the index does.
        #expect(call(server, "read_workstream", ["section": "overview"]).text == "No overview yet.")
        let listed = call(server, "manage_workstreams", ["action": "list"]).text
        #expect(listed.contains("Seed sweep") && listed.contains("WS-1"))
        _ = call(server, "manage_workstreams", ["action": "switch", "id": "WS-1"])
        #expect(WorkstreamStore.sessionIndex(box.store.all())[Sandbox.session] == "WS-1")
        #expect(call(server, "read_workstream", ["section": "overview"]).text.hasPrefix("first"))
        _ = call(server, "manage_workstreams", ["action": "rename", "name": "Main"])
        #expect(box.store.read("WS-1")?.name == "Main")
        #expect(call(server, "manage_workstreams", ["action": "switch", "id": "nope"]).isError)
    }
}

@Suite("workstream resolution", .serialized)
struct WorkstreamResolutionTests {
    @Test func backgroundSessionsIgnoreTheDaemonsStaleEnvironment() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let job = box.root.appendingPathComponent("jobs/abcd1234")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try "{}".write(to: job.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        let context = box.context(["CLAUDE_JOB_DIR": job.path])
        #expect(context.tab == nil && context.hint == nil)
        #expect(context.enabled)          // the daemon came from an AgentDE tab
        #expect(context.resolve(attach: true) == nil)
    }

    @Test func aForkJoinsItsParentsWorkstream() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let parent = "33333333-3333-3333-3333-333333333333"
        try box.store.update("WS-PARENT") { $0.attach(session: parent, kind: "claude") }
        let job = box.root.appendingPathComponent("jobs/fork0001")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try #"{"forkParentSessionId": "\#(parent)", "forkSessionId": "\#(Sandbox.session)"}"#.write(to: job.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        let context = box.context(["CLAUDE_JOB_DIR": job.path])
        #expect(context.resolve(attach: true) == "WS-PARENT")
        #expect(box.store.read("WS-PARENT")?.agents.map(\.session) == [parent, Sandbox.session])
    }

    @Test func everywhereStartsOneForAnyAgent() {
        let box = Sandbox(); defer { box.cleanup() }
        let context = box.context(["WORKSTREAM_EVERYWHERE": "1"], inApp: false)
        let id = context.resolve(attach: true)
        #expect(id != nil)
        #expect(context.resolve(attach: true) == id)
        #expect(box.context(inApp: false).resolve(attach: true) == id)   // indexed now, so found anywhere
    }

    @Test func aSessionIsInOneWorkstream() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let store = box.store
        try store.moveAgent(session: "s-1", kind: "claude", tab: nil, to: "A")
        try store.update("A") { $0.waiting = .init(asks: [.init(id: "a1", question: "?", options: [], agent: "s-1")]) }
        try store.moveAgent(session: "s-1", kind: "claude", tab: nil, to: "B")
        #expect(store.read("A")?.agents.isEmpty == true)
        #expect(store.read("A")?.openAsks.count == 1)        // moving keeps its asks
        #expect(WorkstreamStore.sessionIndex(store.all()) == ["s-1": "B"])
        try store.update("B") { $0.detach(session: "s-1") }  // ending clears them
    }
}

@Suite("workstream hooks", .serialized)
struct WorkstreamHookTests {
    private func input(_ session: String = Sandbox.session) -> Data { Data(#"{"session_id": "\#(session)", "source": "compact"}"#.utf8) }

    private func env(_ box: Sandbox) -> [String: String] {
        ["WORKSTREAM_TAB_ID": "TAB-1", "WORKSTREAM_ID": "WS-1", "WORKSTREAM_DIR": box.workstreams.path,
         "CLAUDE_CONFIG_DIR": box.claude.path]
    }

    @Test func sessionStartLeadsWithRules() throws {
        let box = Sandbox(); defer { box.cleanup() }
        try box.store.update("WS-1") { w in
            w.attach(session: Sandbox.session, kind: "claude")
            w.overview = .init(text: "Train the no-text arm.")
            w.addRule("Never push to main.", by: "you")
        }
        let text = WorkstreamServer.hookContext(input: input(), environment: env(box), cwd: box.cwd)
        #expect(text.hasPrefix("# Workstream"))
        let rules = try #require(text.range(of: "## Rules"))
        let overview = try #require(text.range(of: "## Overview"))
        #expect(rules.lowerBound < overview.lowerBound)
        #expect(!text.contains("empty so far"))
        #expect(WorkstreamServer.hookContext(input: input(), environment: [:], cwd: box.cwd).isEmpty)   // outside AgentDE
        // A resumed session's new, empty workstream: the agent is asked to fill it in.
        try box.store.update("WS-2") { $0.attach(session: "22222222-2222-2222-2222-222222222222", kind: "claude") }
        var env2 = env(box); env2["WORKSTREAM_ID"] = "WS-2"
        #expect(WorkstreamServer.hookContext(input: input("22222222-2222-2222-2222-222222222222"), environment: env2, cwd: box.cwd)
                .contains("empty so far"))
    }

    @Test func subAgentsGetTheParentsWorkstreamWithoutMarkingRulesSeen() throws {
        let box = Sandbox(); defer { box.cleanup() }
        try box.store.update("WS-1") { w in
            w.attach(session: Sandbox.session, kind: "claude")
            w.addRule("Never push to main.", by: "you")
            w.memory = .init(items: [.init(id: "m1", text: "The eval set lives in data/eval.", name: "eval-set")])
        }
        let output = WorkstreamServer.subagentContext(input: input(), environment: env(box), cwd: box.cwd)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let hook = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(hook["hookEventName"] as? String == "SubagentStart")
        let text = try #require(hook["additionalContext"] as? String)
        #expect(text.contains("Never push to main.") && text.contains("data/eval"))
        #expect(box.store.rulesSeen(session: Sandbox.session) == nil)   // the parent still gets rule changes
        #expect(WorkstreamServer.subagentContext(input: input(), environment: [:], cwd: box.cwd).isEmpty)   // outside the app
    }

    @Test func promptHookSendsRulesOnlyWhenTheyChanged() throws {
        let box = Sandbox(); defer { box.cleanup() }
        try box.store.update("WS-1") { w in
            w.attach(session: Sandbox.session, kind: "claude")
            w.addRule("Ask before spending over $20.", by: "you", at: Date(timeIntervalSince1970: 1_800_000_000))
        }
        _ = WorkstreamServer.hookContext(input: input(), environment: env(box), cwd: box.cwd)   // session start saw them
        #expect(WorkstreamServer.promptContext(input: input(), environment: env(box), cwd: box.cwd).isEmpty)
        try box.store.update("WS-1") { $0.addRule("Never push to main.", by: "you", at: Date(timeIntervalSince1970: 1_800_000_100)) }
        let changed = WorkstreamServer.promptContext(input: input(), environment: env(box), cwd: box.cwd)
        #expect(changed.contains("rules changed") && changed.contains("Never push to main."))
        #expect(WorkstreamServer.promptContext(input: input(), environment: env(box), cwd: box.cwd).isEmpty)
        try box.store.update("WS-1") { w in
            for rule in w.activeRules { w.removeRule(rule.id, at: Date(timeIntervalSince1970: 1_800_000_200)) }
        }
        #expect(WorkstreamServer.promptContext(input: input(), environment: env(box), cwd: box.cwd) == "The workstream's rules were all removed.")
    }

    @Test func aSessionNoHookReachedIsBriefedOnce() throws {
        let box = Sandbox(); defer { box.cleanup() }
        try box.store.update("WS-1") { w in
            w.attach(session: Sandbox.session, kind: "claude")
            w.overview = .init(text: "Train the no-text arm.")
        }
        let first = WorkstreamServer.promptContext(input: input(), environment: env(box), cwd: box.cwd)
        #expect(first.contains("set_overview") && first.contains("/mcp") && first.contains("Train the no-text arm."))
        #expect(WorkstreamServer.promptContext(input: input(), environment: env(box), cwd: box.cwd).isEmpty)
    }

    @Test func contextStaysWithinItsBudget() {
        var w = Workstream(id: "WS-1")
        w.overview = .init(text: "Overview text.")
        w.memory = .init(items: (1...400).map { .init(id: "m\($0)", text: "A remembered fact number \($0) with some detail.") })
        for n in 1...30 { w.addFYI("Note \(n)", agent: nil) }
        let summary = WorkstreamSummary(workstream: w, session: nil, names: [:], plan: PlanList(steps: [], updated: nil), scheduled: [])
        let text = summary.compact()
        #expect(text.utf8.count <= 6000)
        #expect(text.contains("more; read_workstream section memory for all)"))
        #expect(text.contains("## Overview"))
        let small = WorkstreamSummary(workstream: { var x = Workstream(id: "x"); for n in 1...9 { x.addFYI("Note \(n)", agent: nil) }; return x }(),
                                      session: nil, names: [:], plan: PlanList(steps: [], updated: nil), scheduled: []).compact()
        #expect(small.contains("Note 9") && small.contains("Note 5") && !small.contains("Note 4"))   // newest 5
    }
}

@Suite("Claude's own scheduling")
struct ScheduleTests {
    /// A local time, as cron reads it.
    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    @Test func cronFindsTheNextMatch() {
        let hourly = CronExpression("13 * * * *")!
        #expect(hourly.next(after: date("2026-10-20 09:20")) == date("2026-10-20 10:13"))
        #expect(hourly.next(after: date("2026-10-20 09:13")) == date("2026-10-20 10:13"))
        let weekdays = CronExpression("30 9 * * mon-fri")!
        #expect(weekdays.next(after: date("2026-10-23 10:00")) == date("2026-10-26 09:30"))   // Friday → Monday
        let steps = CronExpression("*/15 8-9 * * *")!
        #expect(steps.next(after: date("2026-10-20 09:50")) == date("2026-10-21 08:00"))
        let either = CronExpression("0 12 1 * 0")!   // the 1st, or any Sunday
        #expect(either.next(after: date("2026-10-20 13:00")) == date("2026-10-25 12:00"))
        #expect(CronExpression("61 * * * *") == nil)
        #expect(CronExpression("* * *") == nil)
        #expect(CronExpression("0 0 * * 7") == CronExpression("0 0 * * 0"))
    }

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
    }

    private func toolUse(_ id: String, _ name: String, _ input: [String: Any], at: String) -> String {
        line(["type": "assistant", "timestamp": at, "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }

    private func toolResult(_ id: String, _ result: [String: Any], at: String) -> String {
        line(["type": "user", "timestamp": at, "toolUseResult": result,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }

    @Test func readsCronJobsAndWakeupsIncrementally() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let created = "2026-10-20T09:00:00.000Z"
        var text = toolUse("t1", "CronCreate", ["cron": "13 * * * *", "recurring": true, "prompt": "HOURLY CHECK\nsweep pods"], at: created)
        text += toolResult("t1", ["id": "41de26ed", "humanSchedule": "Every hour at :13", "recurring": true, "durable": false], at: created)
        text += toolUse("t2", "CronCreate", ["cron": "0 3 * * *", "prompt": "nightly"], at: created)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let scanner = ScheduleScanner()
        #expect(scanner.scan(url))
        let now = ScheduleScanner.parseDate("2026-10-20T09:30:00Z")!
        var items = scanner.items(now: now, sessionLive: true)
        #expect(items.map(\.id) == ["41de26ed"])             // t2's result hasn't arrived yet
        #expect(items.first?.text == "HOURLY CHECK")
        #expect(items.first?.schedule == "Every hour at :13")
        #expect(scanner.items(now: now, sessionLive: false).isEmpty)   // session-only jobs end with the session
        // Appended later: a wake-up, then the cron's cancellation.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((toolUse("t3", "ScheduleWakeup", ["delaySeconds": 240, "reason": "Check the run", "prompt": "check"], at: created)
            + toolResult("t3", ["scheduledFor": now.addingTimeInterval(240).timeIntervalSince1970 * 1000, "clampedDelaySeconds": 240], at: created)
            + toolUse("t4", "CronDelete", ["id": "41de26ed"], at: created) + toolResult("t4", ["id": "41de26ed"], at: created)).utf8))
        try handle.close()
        #expect(scanner.scan(url))
        items = scanner.items(now: now, sessionLive: true)
        #expect(items.map(\.kind) == [ScheduledItem.Kind.wakeup])
        #expect(items.first?.text == "Check the run")
        #expect(scanner.items(now: now.addingTimeInterval(300), sessionLive: true).isEmpty)   // past: gone
        #expect(!scanner.scan(url))
    }

    @Test func readsDurableJobsDefensively() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("durable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"tasks": [{"id": "d1", "cron": "0 9 * * *", "prompt": "Morning check"}, {"id": "bad", "cron": "nope"}]}"#
            .write(to: folder.appendingPathComponent(".claude/scheduled_tasks.json"), atomically: true, encoding: .utf8)
        #expect(NativeSchedule.durableJobs(folder: folder.path).map(\.id) == ["d1"])
        #expect(NativeSchedule.durableJobs(folder: folder.appendingPathComponent("none").path).isEmpty)
    }
}

@Suite("Workstream sections")
struct WorkstreamSectionTests {
    @Test func fyiKeepsTheNewestTwenty() {
        var w = Workstream(id: "x")
        for n in 1...25 { w.addFYI("note \(n)", agent: nil) }
        #expect(w.fyi?.items.count == Workstream.fyiLimit)
        #expect(w.fyi?.items.first?.text == "note 6")
        let id = w.fyi!.items.last!.id
        let first = w.dismissFYI(id), second = w.dismissFYI(id)
        #expect(first && !second)
    }

    @Test func rulesKeepTheirChangeTime() {
        var w = Workstream(id: "x")
        let id = w.addRule("Never push to main.", by: "you", at: Date(timeIntervalSince1970: 10))
        let removed = w.removeRule(id, at: Date(timeIntervalSince1970: 20))
        #expect(removed)
        #expect(w.activeRules.isEmpty)
        #expect(w.rules?.updated == Date(timeIntervalSince1970: 20))   // kept, so agents learn of the removal
    }

    /// Plan shows open steps and the last 5 done, plus a done count under Progress; a vanished pin is flagged.
    @Test func planIsTrimmedAndCountedAndMissingPinsFlagged() {
        let steps = (1...12).map { PlanStep(id: "\($0)", text: "step \($0)", state: $0 <= 9 ? .done : $0 == 10 ? .current : .todo) }
        var w = Workstream(id: "W")
        w.files = .init(items: [.init(path: "/nowhere/gone.md", note: "report", by: "agent")], updated: Date())
        let summary = WorkstreamSummary(workstream: w, session: nil, names: [:], plan: PlanList(steps: steps, updated: nil), scheduled: [])
        #expect(summary.planText.hasPrefix("(4 earlier steps done)\n- [x] step 5"))
        #expect(summary.planText.hasSuffix("- [>] step 10\n- [ ] step 11\n- [ ] step 12"))
        #expect(summary.progress == "- Plan: 9 of 12 done · now: step 10")
        #expect(summary.pinnedFiles.contains("gone.md — report (missing"))
    }

    @Test func resolvedAsksAreKeptForTheRecord() {
        var w = Workstream(id: "x")
        w.waiting = .init(asks: (1...15).map { .init(id: "a\($0)", question: "?", options: ["Yes"], defaultOption: "Yes") })
        for n in 1...15 { w.resolve(ask: "a\(n)", by: n == 15 ? "default" : "you", answer: "Yes", at: Date(timeIntervalSince1970: Double(n))) }
        #expect(w.openAsks.isEmpty)
        #expect(w.waiting?.asks.count == Workstream.resolvedAskLimit)
        #expect(w.waiting?.asks.contains { $0.id == "a15" && $0.resolvedBy == "default" } == true)
        #expect(Workstream.nextID("a", in: w.waiting!.asks.map(\.id)) == "a16")
    }
}

@Suite("workstream tickets", .serialized)
struct WorkstreamTicketTests {
    @Test func agentsLinkAndUnlinkTickets() throws {
        let box = Sandbox(); defer { box.cleanup() }
        let server = box.server(box.context())
        #expect(call(server, "link_ticket", ["ticket": "https://linear.app/acme/issue/eng-42/fix-the-thing", "title": "Fix the thing"]).text == "Linked ENG-42.")
        #expect(call(server, "link_ticket", ["ticket": "OPS-7"]).text == "Linked OPS-7.")
        #expect(call(server, "link_ticket", ["ticket": "not a ticket"]).isError)
        #expect(call(server, "link_ticket", ["ticket": "https://github.com/acme/app/issues/3"]).text == "Linked acme/app#3.")
        #expect(box.store.read("WS-1")?.tickets?.items.last?.tracker == "github")
        #expect(call(server, "remove_entry", ["id": "acme/app#3"]).text == "Unlinked acme/app#3.")
        #expect(call(server, "remove_entry", ["id": "ops-7"]).isError == false)
        #expect(call(server, "link_ticket", ["ticket": "OPS-7"]).text == "Linked OPS-7.")
        let tickets = try #require(box.store.read("WS-1")?.tickets?.items)
        #expect(tickets.map(\.identifier) == ["ENG-42", "OPS-7"])
        #expect(tickets.first?.url == "https://linear.app/acme/issue/eng-42/fix-the-thing" && tickets.first?.by == "agent")
        #expect(call(server, "read_workstream", ["section": "tickets"]).text.contains("ENG-42: Fix the thing"))
        #expect(call(server, "remove_entry", ["id": "ENG-42"]).text == "Unlinked ENG-42.")
        #expect(call(server, "remove_entry", ["id": "ENG-42"]).isError)
        #expect(box.store.read("WS-1")?.tickets?.items.map(\.identifier) == ["OPS-7"])
    }

    @Test func identifiersComeFromTextOrLinks() {
        #expect(Workstream.ticketIdentifier(in: " eng-123 ") == "ENG-123")
        #expect(Workstream.ticketIdentifier(in: "https://linear.app/team/issue/AB2-9/slug?x=1") == "AB2-9")
        #expect(Workstream.ticketIdentifier(in: "https://linear.app/team/issue/AB-9") == "AB-9")
        #expect(Workstream.ticketIdentifier(in: "see ENG-1 later") == nil)
        #expect(Workstream.ticketIdentifier(in: "r1") == nil)
        #expect(Workstream.ticketReference(in: "https://acme.atlassian.net/browse/OPS-12")
                == .init(identifier: "OPS-12", tracker: "jira", url: "https://acme.atlassian.net/browse/OPS-12"))
        #expect(Workstream.ticketReference(in: "https://jira.acme.com/secure/RapidBoard.jspa?selectedIssue=OPS-3")?.identifier == "OPS-3")
        #expect(Workstream.ticketReference(in: "https://github.com/acme/app/issues/42")
                == .init(identifier: "acme/app#42", tracker: "github", url: "https://github.com/acme/app/issues/42"))
        #expect(Workstream.ticketReference(in: "https://github.com/acme/app/pull/7")?.identifier == "acme/app#7")
        #expect(Workstream.ticketReference(in: "acme/app#42")?.identifier == "acme/app#42")
        #expect(Workstream.ticketReference(in: "https://gitlab.com/group/sub/app/-/issues/5")?.identifier == "group/sub/app#5")
        #expect(Workstream.ticketReference(in: "https://app.asana.com/0/123/456/")
                == .init(identifier: "app.asana.com/0/123/456", url: "https://app.asana.com/0/123/456/"))
        #expect(Workstream.ticketReference(in: "http://insecure.example/1") == nil)
        var w = Workstream(id: "x")
        let linked = w.linkTicket("ENG-1", by: "you")
        let again = w.linkTicket("ENG-1", by: "you")
        let titled = w.linkTicket("ENG-1", title: "Title", by: "agent")
        #expect(linked && !again && titled)
        #expect(w.tickets?.items.first?.title == "Title" && w.tickets?.items.first?.by == "you")
        let unlinked = w.unlinkTicket("ENG-1")
        #expect(unlinked && w.tickets == nil)
    }
}
