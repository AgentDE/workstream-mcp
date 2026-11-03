import Foundation
import Testing
@testable import WorkstreamKit

@Suite("Workstream store")
struct WorkstreamStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("workstreams-\(UUID().uuidString)")

    /// A fork starts in its parent's workstream and then starts its own (`new`). The app, working from an index
    /// read before that, must record the fork's tab where the fork is now, not move it back.
    @Test func anAppsLateAttachLeavesAnAgentThatSwitched() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkstreamStore(directory: dir)
        let parent = "11111111-1111-1111-1111-111111111111", fork = "22222222-2222-2222-2222-222222222222"
        try store.moveAgent(session: parent, kind: "claude", tab: "TAB-P", to: "WS-PARENT")
        try store.moveAgent(session: fork, kind: "claude", tab: nil, to: "WS-PARENT")   // the fork joins its parent's
        try store.moveAgent(session: fork, kind: "claude", tab: nil, to: "WS-OWN")      // then starts its own

        // The app had decided, from an index that didn't list the fork yet, that its tab belongs in WS-PARENT.
        #expect(try store.adopt(session: fork, kind: "claude", tab: "TAB-F", fallback: "WS-PARENT") == "WS-OWN")
        #expect(WorkstreamStore.sessionIndex(store.all())[fork] == "WS-OWN")
        #expect(store.read("WS-OWN")?.agents.first?.tab == "TAB-F")
        #expect(store.read("WS-PARENT")?.agents.map(\.session) == [parent])

        // A session no workstream lists yet joins the fallback.
        let fresh = "33333333-3333-3333-3333-333333333333"
        #expect(try store.adopt(session: fresh, kind: "claude", tab: "TAB-N", fallback: "WS-PARENT") == "WS-PARENT")
        #expect(store.read("WS-PARENT")?.agents.map(\.session) == [parent, fresh])

        // What the app wrote before: moving the session outright undoes the agent's switch.
        try store.moveAgent(session: fork, kind: "claude", tab: "TAB-F", to: "WS-PARENT")
        #expect(WorkstreamStore.sessionIndex(store.all())[fork] == "WS-PARENT")
    }

    @Test func roundTripsAndWritesAtomically() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkstreamStore(directory: dir)
        var workstream = Workstream(id: "ws-1")
        workstream.attach(session: "s-1", kind: "claude")
        workstream.overview = .init(text: "Training the no-text arm.")
        workstream.progress = .init(rows: [.init(label: "campaign", value: 0.72, text: "4,375 episodes"), .init(label: "backups", text: "no pods")])
        workstream.waiting = .init(asks: [.init(id: "a1", question: "Seed 1 only?", options: ["Seed 1", "Both"], agent: "s-1")])
        try store.write(workstream)
        #expect(store.read("ws-1") == roundedDates(workstream))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func updateCreatesAndOnlyWritesChanges() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkstreamStore(directory: dir)
        try store.update("ws-2") { $0.attach(session: "s-1", kind: "claude") }
        let url = try #require(store.url(for: "ws-2"))
        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        try store.update("ws-2") { $0.attach(session: "s-1", kind: "claude") }   // already attached: no write
        let second = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(first == second)
        #expect(store.read("ws-2")?.agents.map(\.session) == ["s-1"])
    }

    /// Phase-1 files listed `sessions` as {id, agent}; they still load, as agents.
    @Test func readsThePhaseOneFormat() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"version": 1, "id": "ws-3",
         "sessions": [{"id": "f65bbf83", "agent": "claude", "added": "2026-10-20T09:41:00Z"},
                      {"id": "c0de", "agent": "codex", "added": "2026-10-20T09:42:00.250Z"}],
         "overview": {"text": "Why we're here", "updated": "2026-10-20T09:41:00Z"},
         "files": {"items": [{"path": "/tmp/REPORT.md", "note": "costs", "by": "agent"}], "updated": "2026-10-20T09:41:00Z"},
         "memory": {"items": [{"id": "m1", "text": "From before names"}], "updated": "2026-10-20T09:41:00Z"}}
        """
        try json.write(to: dir.appendingPathComponent("ws-3.json"), atomically: true, encoding: .utf8)
        let workstream = try #require(WorkstreamStore(directory: dir).read("ws-3"))
        #expect(workstream.agents.map(\.kind) == ["claude", "codex"])
        #expect(workstream.files?.items.first?.note == "costs")
        // Memory items from before names and dates still load, and read as their text.
        #expect(workstream.memory?.items.first?.name == nil && workstream.memory?.items.first?.line == "From before names")
        #expect(WorkstreamStore.sessionIndex([workstream]) == ["f65bbf83": "ws-3", "c0de": "ws-3"])
    }

    @Test func idsMustBeFileNames() {
        #expect(WorkstreamStore.isValidID("6F1C0B9E-2B7A-4C1F-9A3E-1D2C3B4A5F60"))
        #expect(!WorkstreamStore.isValidID("../state"))
        #expect(!WorkstreamStore.isValidID(""))
        #expect(WorkstreamStore(directory: dir).url(for: "a/b") == nil)
    }

    /// The panel's ✕ buttons: a dismissed ask tells its agent; memory items and progress rows go one at a time.
    @Test func panelRemovesSingleEntries() {
        let ask = Workstream.Ask(id: "a3", question: "Which seed?\nPick one", options: ["1", "2"])
        #expect(ask.dismissal == "I dismissed your question \"Which seed? Pick one\" (a3) in the panel; no answer needed.")

        var w = Workstream(id: "ws-9")
        w.memory = .init(items: [.init(id: "m1", text: "a"), .init(id: "m2", text: "b")], updated: Date())
        let removedFirst = w.removeMemory("m1")
        #expect(removedFirst && w.memory?.items.map(\.id) == ["m2"])
        let removedMissing = w.removeMemory("m7")
        #expect(!removedMissing)
        let removedLast = w.removeMemory("m2")
        #expect(removedLast && w.memory == nil)

        w.progress = .init(rows: [.init(label: "run", text: "x", agent: "s1"), .init(label: "run", text: "y", agent: "s2")], updated: Date())
        let removedRow = w.removeProgressRow(label: "run", agent: "s2")
        #expect(removedRow && w.progress?.rows.map(\.text) == ["x"])
        let removedNone = w.removeProgressRow(label: "run", agent: "s3")
        #expect(!removedNone)
        let removedLastRow = w.removeProgressRow(label: "run", agent: "s1")
        #expect(removedLastRow && w.progress == nil)
    }

    @Test func asksResolveAndFilesToggle() {
        var workstream = Workstream(id: "ws-4")
        workstream.waiting = .init(asks: [.init(id: "a1", question: "?", options: ["Yes"]), .init(id: "a2", question: "??", options: [])])
        let first = workstream.resolve(ask: "a1", by: "you", answer: "Yes")
        #expect(first)
        #expect(workstream.openAsks.map(\.id) == ["a2"])
        #expect(workstream.waiting?.asks.first?.resolvedBy == "you")   // kept for the record
        let again = workstream.resolve(ask: "a1")
        #expect(!again)
        let last = workstream.resolve(ask: "a2")
        #expect(last)
        #expect(workstream.openAsks.isEmpty)
        workstream.waiting = nil
        workstream.togglePinned("/tmp/plot.png", by: "you")
        #expect(workstream.files?.items.first?.by == "you")
        workstream.togglePinned("/tmp/plot.png", by: "you")
        #expect(workstream.files == nil)
        #expect(!workstream.hasContent)
    }

    /// Dates survive encoding to whole seconds.
    private func roundedDates(_ workstream: Workstream) -> Workstream {
        let data = try! WorkstreamStore.encoder.encode(workstream)
        return try! WorkstreamStore.decoder.decode(Workstream.self, from: data)
    }
}

@Suite("Native plans")
struct NativePlanTests {
    @Test func readsClaudesTaskList() throws {
        let tasks = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tasks) }
        let session = tasks.appendingPathComponent("s-1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("10", #"{"id": "10", "subject": "Evaluate", "status": "pending", "blocks": [], "blockedBy": []}"#),
            ("2", #"{"id": "2", "subject": "Train", "status": "in_progress", "activeForm": "Training"}"#),
            ("1", #"{"id": "1", "subject": "Rebuild labels", "status": "completed"}"#),
            ("3", #"{"id": "3", "subject": "Gone", "status": "deleted"}"#),
            ("4", #"{"id": "4", "subject": ""}"#),
        ]
        for (name, json) in files { try json.write(to: session.appendingPathComponent(name + ".json"), atomically: true, encoding: .utf8) }
        try "15".write(to: session.appendingPathComponent(".highwatermark"), atomically: true, encoding: .utf8)
        let plan = NativePlan.claudeTasks(session: "s-1", in: tasks)
        #expect(plan.steps.map(\.text) == ["Rebuild labels", "Train", "Evaluate"])
        #expect(plan.steps.map(\.state) == [.done, .current, .todo])
        #expect(plan.updated != nil)
        #expect(NativePlan.claudeTasks(session: "missing", in: tasks).steps.isEmpty)
        #expect(NativePlan.claudeTasks(session: "../s-1", in: tasks).steps.isEmpty)
    }
}

@Suite("Answering asks")
struct AskReplyTests {
    /// Questions saved without options (by servers from before they were filled in) still get buttons.
    @Test func questionsWithoutOptionsOfferYesNoDiscuss() {
        #expect(Workstream.Ask(id: "a1", question: "Ship?", options: []).answers == ["Yes", "No", "Discuss"])
        #expect(Workstream.Ask(id: "a2", question: "Ship?", options: [], defaultOption: "No").answers == ["No", "Yes", "Discuss"])
        #expect(Workstream.Ask(id: "a3", question: "Ship?", options: [], defaultOption: "Later").answers == ["Later", "Yes", "No", "Discuss"])
        #expect(Workstream.Ask(id: "a4", question: "Which?", options: ["A", "B"]).answers == ["A", "B"])
    }

    @Test func theAnswerCarriesItsQuestion() {
        let ask = Workstream.Ask(id: "a3", question: "Which seed\nshould I use?", options: ["Seed 1", "Seed 2"])
        #expect(ask.reply("Seed 1") == #"Answer to your question "Which seed should I use?" (a3): Seed 1"#)
        #expect(ask.reply("Seed 2", byDefault: true) == #"No answer in time to your question "Which seed should I use?" (a3), so going with its default: Seed 2"#)
        let long = Workstream.Ask(id: "a4", question: String(repeating: "x", count: 280), options: [])
        #expect(long.reply("ok").contains(String(repeating: "x", count: 199) + "…\""))
    }
}
