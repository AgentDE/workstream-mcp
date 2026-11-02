import Foundation
import Testing
@testable import WorkstreamKit

/// Lines shaped like Claude Code's transcripts (2.1.30x): conversation lines start with `parentUuid`,
/// records with `type`; an assistant message's blocks are written as consecutive lines sharing its id.
enum Fixture {
    /// A link rule like the ones extensions give the app: pages at pages.example.com/a/, titled by file name.
    static func installExampleRule() {
        ArtifactLinks.rules = [ArtifactLinks.Rule(pattern: #"https://pages\.example\.com/a/[\w.-]+"#, marker: "pages.example.com/a/",
                                                  title: { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })]
    }

    static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), encoding: .utf8)!
    }

    /// `parentUuid` first, as Claude writes it.
    static func line(_ object: [String: Any]) -> String {
        var rest = json(object)
        rest.removeFirst()
        return "{\"parentUuid\":\"p\"," + rest + "\n"
    }

    static func assistant(_ id: String, model: String = "claude-opus-5-5", output: Int = 10, cacheRead: Int = 0,
                          _ content: [[String: Any]], at: String) -> String {
        line(["isSidechain": false, "type": "assistant", "timestamp": at, "message": [
            "model": model, "id": id, "type": "message", "role": "assistant", "content": content,
            "usage": ["input_tokens": 2, "output_tokens": output, "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": 100,
                      "cache_creation": ["ephemeral_5m_input_tokens": 60, "ephemeral_1h_input_tokens": 40]]]])
    }

    static func tool(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    static func result(_ id: String, _ result: Any?, text: String = "ok", at: String) -> String {
        var object: [String: Any] = ["type": "user", "timestamp": at,
                                     "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]]]]
        if let result { object["toolUseResult"] = result }
        return line(object)
    }

    static let t0 = "2026-10-20T09:00:00.000Z", t1 = "2026-10-20T09:05:00.000Z", t2 = "2026-10-20T09:10:00.000Z"

    static var claude: [String] {
        [
            "{\"type\":\"api-request\",\"params\":{\"note\":\"https://claude.ai/artifact/SKIPSKIPSKIP1\"}}\n",
            // One message written as two lines: the last line's usage is the final one.
            assistant("msg_1", output: 1, [tool("tu1", "Edit", ["file_path": "/tmp/proj/a.swift", "old_string": "c", "new_string": "a\nb"])], at: t0),
            assistant("msg_1", output: 50, [["type": "text", "text": "Uploaded: https://pages.example.com/a/cold-doc.html, and **https://claude.ai/artifact/TEXTLINK0001**."]], at: t0),
            result("tu1", ["filePath": "/tmp/proj/a.swift", "structuredPatch": [["lines": ["+a", "+b", "-c", " d"]]]], at: t0),
            assistant("msg_2", [tool("tu2", "Write", ["file_path": "/tmp/proj/b.md", "content": "x\ny\n"]),
                                tool("tu3", "Read", ["file_path": "/tmp/proj/a.swift"]),
                                tool("tu4", "SendMessage", ["to": "worker", "message": "hello\nworld"])], at: t1),
            result("tu2", ["type": "create", "filePath": "/tmp/proj/b.md", "content": "x\ny\n", "structuredPatch": []], at: t1),
            result("tu4", ["success": true, "msg_id": "m-out"], at: t1),
            assistant("msg_3", [tool("tu5", "Artifact", ["file_path": "/tmp/proj/r.html"]), tool("tu6", "Artifact", ["action": "list"])], at: t1),
            result("tu5", ["url": "https://claude.ai/artifact/SAiZc8wc4HG3hh98xzBxUx", "title": "Report", "path": "/tmp/proj/r.html"], at: t1),
            result("tu6", ["artifacts": [["title": "Old", "url": "https://claude.ai/artifact/LISTLISTLIST1"]]],
                   text: "- Old — https://claude.ai/artifact/LISTLISTLIST1", at: t1),
            line(["isSidechain": false, "type": "attachment", "timestamp": t2, "attachment": [
                "type": "queued_command", "prompt": "<cross-session-message from-name=\"lead\">go</cross-session-message>",
                "origin": ["kind": "peer", "name": "lead", "msg_id": "m1", "body": "go"]]]),
            line(["type": "user", "timestamp": t2, "message": ["role": "user",
                  "content": "<cross-session-message from=\"uds:/tmp/x.sock\" from-name=\"lead\" from-mode=\"prompting\">\ngo\n</cross-session-message>"]]),
            // A reply taken in mid-turn is recorded only as queue operations, Claude Code records like any other
            // (line starts with "type"); the enqueue counts, its remove repeats it.
            "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"timestamp\":\"\(t2)\",\"sessionId\":\"s\",\"content\":\"<cross-session-message from=\\\"uds:/tmp/y.sock\\\" hop-chain=\\\"a\\\" from-name=\\\"taxonomy\\\" from-mode=\\\"prompting\\\">\\nEmbeddings live in gold.games\\n</cross-session-message>\"}\n",
            "{\"type\":\"queue-operation\",\"operation\":\"remove\",\"timestamp\":\"\(t2)\",\"sessionId\":\"s\",\"reason\":\"absorbed_mid_turn\",\"content\":\"<cross-session-message from=\\\"uds:/tmp/y.sock\\\" from-name=\\\"taxonomy\\\" from-mode=\\\"prompting\\\">\\nEmbeddings live in gold.games\\n</cross-session-message>\"}\n",
            line(["type": "system", "subtype": "compact_boundary", "timestamp": t2, "content": "Conversation compacted"]),
            line(["type": "system", "subtype": "turn_duration", "durationMs": 61000, "timestamp": t2]),
        ]
    }

    static func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try lines.joined().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.joined().utf8))
        try handle.close()
    }
}

@Suite("Transcript facts", .serialized)
struct TranscriptTests {
    /// A reply to a session's address shows its name, and a send that failed (a stale address) isn't a message.
    @Test func repliesShowNamesAndFailedSendsAreLeftOut() throws {
        let address = "uds:/tmp/cc-socks/3686.sock"
        let lines = [
            Fixture.line(["type": "user", "timestamp": Fixture.t0, "message": ["role": "user",
                          "content": "<cross-session-message from=\"\(address)\" from-name=\"meta_claude\" from-mode=\"prompting\">\n1... c5\n</cross-session-message>"]]),
            Fixture.assistant("msg_a", [Fixture.tool("s1", "SendMessage", ["to": address, "message": "2. Nf3"]),
                                        Fixture.tool("s2", "SendMessage", ["to": "uds:/tmp/cc-socks/87097.sock", "message": "Chess invite!"])], at: Fixture.t1),
            Fixture.result("s1", ["success": true, "msg_id": "m1"], at: Fixture.t1),
            Fixture.result("s2", ["success": false, "message": "Failed to send: ENOENT"], at: Fixture.t1),
        ]
        let url = try Fixture.write(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TranscriptScanner()
        #expect(scanner.scan(url))
        let messages = scanner.currentFacts.messages
        #expect(messages.map(\.peer) == ["meta_claude", "meta_claude"])
        #expect(messages.map(\.outgoing) == [false, true])
        #expect(messages.last?.text == "2. Nf3")
    }

    @Test func collectsFilesArtifactsMessagesAndUsage() throws {
        Fixture.installExampleRule()
        let url = try Fixture.write(Fixture.claude)
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TranscriptScanner()
        #expect(scanner.scan(url))
        let facts = scanner.currentFacts
        #expect(facts.files["/tmp/proj/a.swift"]?.edits == 1)
        #expect(facts.files["/tmp/proj/a.swift"]?.reads == 1)
        #expect(facts.files["/tmp/proj/b.md"]?.edits == 1)
        #expect(facts.linesAdded == 4)      // +a +b, and the new file's two lines
        #expect(facts.linesRemoved == 1)
        #expect(facts.toolCalls == 6)
        #expect(Set(facts.artifacts.map(\.url)) == [
            "https://pages.example.com/a/cold-doc.html",
            "https://claude.ai/artifact/TEXTLINK0001",
            "https://claude.ai/artifact/SAiZc8wc4HG3hh98xzBxUx",
        ])   // not the API record's link, nor the listing's
        #expect(facts.artifacts.first { $0.url.hasSuffix("SAiZc8wc4HG3hh98xzBxUx") }?.title == "Report")
        #expect(facts.messages.count == 3)  // each delivery once, however many times it's recorded
        #expect(facts.messages.first?.outgoing == true && facts.messages.first?.peer == "worker")
        #expect(facts.messages[1].peer == "lead" && facts.messages[1].text == "go")
        #expect(facts.messages.last?.outgoing == false && facts.messages.last?.peer == "taxonomy"
                && facts.messages.last?.text == "Embeddings live in gold.games")
        #expect(facts.compactions == 1)
        #expect(facts.activeSeconds == 61)
        // msg_1 counts once, with its final usage; msg_3 is still the message in progress.
        let usage = facts.usage["claude-opus-5-5"]
        #expect(usage?.output == 50 + 10 + 10)
        #expect(usage?.cacheWrite5m == 180 && usage?.cacheWrite1h == 120)
        #expect(scanner.facts.usage["claude-opus-5-5"]?.output == 60)   // without the one in progress
        #expect(facts.firstAt == ScheduleScanner.parseDate(Fixture.t0))
        #expect(facts.lastAt == ScheduleScanner.parseDate(Fixture.t2))
    }

    @Test func readsIncrementallyAndResumesFromASnapshot() throws {
        Fixture.installExampleRule()   // the fixture has an example.com page: the same rules on both reads
        let lines = Fixture.claude
        let url = try Fixture.write(Array(lines.prefix(5)))
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TranscriptScanner()
        scanner.scan(url, chunk: 64)          // small chunks: lines span reads
        let snapshot = try #require(scanner.snapshot())
        try Fixture.append(Array(lines.dropFirst(5)), to: url)
        scanner.scan(url, chunk: 64)
        #expect(!scanner.scan(url))           // nothing new
        let resumed = try #require(TranscriptScanner.resume(from: snapshot))
        resumed.scan(url)
        let whole = TranscriptScanner()
        whole.scan(url)
        #expect(resumed.currentFacts == whole.currentFacts)
        #expect(scanner.currentFacts == whole.currentFacts)
    }

    @Test func aReplacedTranscriptIsReadAgain() throws {
        let url = try Fixture.write(Fixture.claude)
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TranscriptScanner()
        scanner.scan(url)
        try Fixture.claude.prefix(4).joined().write(to: url, atomically: true, encoding: .utf8)   // shorter, new file
        scanner.scan(url)
        #expect(scanner.currentFacts.messages.isEmpty)
        #expect(scanner.currentFacts.files["/tmp/proj/a.swift"]?.edits == 1)
    }

    @Test func feedsTheScheduleToo() throws {
        let url = try Fixture.write([
            Fixture.assistant("msg_9", [Fixture.tool("w1", "ScheduleWakeup", ["delaySeconds": 600, "reason": "Check the run", "prompt": "check"])], at: Fixture.t0),
            Fixture.result("w1", ["scheduledFor": ScheduleScanner.parseDate(Fixture.t1)!.timeIntervalSince1970 * 1000], at: Fixture.t0),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TranscriptScanner()
        scanner.scan(url)
        let items = scanner.schedule.items(now: ScheduleScanner.parseDate(Fixture.t0)!, sessionLive: true)
        #expect(items.map(\.text) == ["Check the run"])
        // And it survives a snapshot.
        let snapshot = try #require(scanner.snapshot())
        let resumed = try #require(TranscriptScanner.resume(from: snapshot))
        #expect(resumed.schedule == scanner.schedule)
    }

    @Test func readsCodexPatches() throws {
        let call: [String: Any] = ["timestamp": Fixture.t1, "type": "response_item", "payload": [
            "type": "custom_tool_call", "name": "exec",
            "input": "text(await tools.apply_patch(\"*** Begin Patch\\n*** Update File: /tmp/proj/x.py\\n@@\\n-old\\n+new\\n+more\\n*** Add File: /tmp/proj/y.py\\n+y\\n*** End Patch\"))"]]
        let message: [String: Any] = ["timestamp": Fixture.t1, "type": "response_item", "payload": ["type": "message", "content": "*** Begin Patch in prose"]]
        let url = try Fixture.write([Fixture.json(call) + "\n", Fixture.json(message) + "\n"])
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TranscriptScanner(format: .codex)
        scanner.scan(url)
        #expect(Set(scanner.facts.files.keys) == ["/tmp/proj/x.py", "/tmp/proj/y.py"])
        #expect(scanner.facts.linesAdded == 3 && scanner.facts.linesRemoved == 1)
    }

    /// A fork's transcript starts at the fork and then repeats its parent's conversation, stamped earlier: that
    /// history is the parent's work, so its edits and usage don't count for the fork.
    @Test func aForkDoesNotCountItsParentsHistory() throws {
        let fork = "2026-10-20T10:00:00.000Z", later = "2026-10-20T10:05:00.000Z"
        let url = try Fixture.write([
            #"{"type":"queue-operation","operation":"dequeue","timestamp":"\#(fork)","sessionId":"s"}"# + "\n",
            Fixture.assistant("parent_1", output: 500, [Fixture.tool("e1", "Edit", ["file_path": "/tmp/proj/parent.swift", "old_string": "a", "new_string": "b"])], at: Fixture.t0),
            Fixture.result("e1", nil, at: Fixture.t0),
            Fixture.assistant("own_1", output: 7, [Fixture.tool("e2", "Edit", ["file_path": "/tmp/proj/fork.swift", "old_string": "a", "new_string": "b"])], at: later),
            Fixture.result("e2", nil, at: later),
            Fixture.assistant("own_2", output: 3, [["type": "text", "text": "done"]], at: later),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TranscriptScanner()
        scanner.scan(url)
        let facts = scanner.currentFacts
        #expect(Set(facts.files.keys) == ["/tmp/proj/fork.swift"])
        #expect(facts.toolCalls == 1)
        #expect(facts.usage["claude-opus-5-5"]?.output == 10)   // own_1 and own_2, not the parent's 500
        #expect(facts.startedAt == ScheduleScanner.parseDate(fork))
    }

    @Test func extraRulesFindTheirLinks() {
        Fixture.installExampleRule()
        #expect(ArtifactLinks.find(in: "see https://claude.ai/code/artifact/3f1c0b9e-1234-4abc-9def-001122334455.").count == 1)
        #expect(ArtifactLinks.find(in: "and https://pages.example.com/a/x.html**") == ["https://pages.example.com/a/x.html"])
        #expect(ArtifactLinks.title(for: "https://pages.example.com/a/x.html") == "x")
        #expect(ArtifactLinks.openURL("https://claude.ai/artifact/SAiZc8wc4HG3hh98xzBxUx") == "https://claude.ai/artifact/SAiZc8wc4HG3hh98xzBxUx")
        #expect(ArtifactLinks.find(in: "https://example.com/x").isEmpty)
    }

    @Test func usageAndTurnTimeAreKeptByDay() throws {
        let day1 = "2026-10-19T12:00:00.000Z", day2 = "2026-10-20T12:00:00.000Z"
        let url = try Fixture.write([
            Fixture.assistant("m1", output: 100, [["type": "text", "text": "a"]], at: day1),
            Fixture.line(["type": "system", "subtype": "turn_duration", "durationMs": 30000, "timestamp": day1]),
            Fixture.assistant("m2", output: 7, [["type": "text", "text": "b"]], at: day2),
            Fixture.line(["type": "system", "subtype": "turn_duration", "durationMs": 5000, "timestamp": day2]),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TranscriptScanner()
        scanner.scan(url)
        let facts = scanner.currentFacts   // m2 is still in progress, and counts on its own day
        let k1 = TranscriptFacts.dayKey(ScheduleScanner.parseDate(day1)!), k2 = TranscriptFacts.dayKey(ScheduleScanner.parseDate(day2)!)
        #expect(facts.days[k1]?.activeSeconds == 30 && facts.days[k2]?.activeSeconds == 5)
        #expect(facts.days[k1]?.usage["claude-opus-5-5"]?.output == 100)
        #expect(facts.days[k2]?.usage["claude-opus-5-5"]?.output == 7)
        #expect(facts.activeSeconds == 35 && facts.usage["claude-opus-5-5"]?.output == 107)

    }

    @Test func localPagesNamedInTextAreArtifacts() throws {
        let home = NSHomeDirectory()
        #expect(ArtifactLinks.localPages(in: "The local file is ~/.claude/jobs/de359a63/tmp/game-telemetry-tdd.html; that folder is deleted")
                == [home + "/.claude/jobs/de359a63/tmp/game-telemetry-tdd.html"])
        #expect(ArtifactLinks.localPages(in: "Open `/tmp/r/report.htm`. Or /tmp/r/report.htm again.") == ["/tmp/r/report.htm"])
        #expect(ArtifactLinks.localPages(in: "https://example.com/a/b.html, file:///x/y.html, /x/notes.html.bak, /x/page.html/sub, ./rel.html").isEmpty)
        #expect(ArtifactLinks.title(for: "/tmp/r/report.html") == "report")

        // Listed while the file exists, left out once it's gone.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("tdd.html")
        try "<p>hi</p>".write(to: page, atomically: true, encoding: .utf8)
        var facts = TranscriptFacts()
        for path in ArtifactLinks.localPages(in: "Wrote \(page.path) and \(dir.path)/gone.html") { facts.addArtifact(path, title: nil, at: Date()) }
        #expect(WorkstreamActivity([("A", facts)]).artifacts().map(\.artifact.url) == [page.path])
    }

    @Test func artifactsNamedTogetherKeepAStableOrder() {
        let now = Date()
        var a = TranscriptFacts(), b = TranscriptFacts()
        for url in ["https://claude.ai/artifact/1", "https://claude.ai/artifact/2", "https://claude.ai/artifact/3",
                    "https://claude.ai/artifact/4", "https://claude.ai/artifact/5"] {
            a.addArtifact(url, title: nil, at: now)   // all in one message
        }
        b.addArtifact("https://claude.ai/artifact/3", title: "Shared", at: now)
        b.addArtifact("https://claude.ai/artifact/9", title: nil, at: now.addingTimeInterval(-60))
        let expected = ["1", "2", "3", "4", "5", "9"].map { "https://claude.ai/artifact/\($0)" }
        for _ in 0..<50 {   // dictionary order differs between runs; the result mustn't
            let rows = WorkstreamActivity([("B", b), ("A", a)]).artifacts()
            #expect(rows.map(\.artifact.url) == expected)
            #expect(rows[2].agent == "A" && rows[2].artifact.title == "Shared")
        }
    }

    @Test func mergesActivityAcrossAgents() {
        var a = TranscriptFacts(), b = TranscriptFacts()
        let now = ScheduleScanner.parseDate(Fixture.t2)!
        a.touch("/p/x.swift", edit: true, at: now.addingTimeInterval(-600))
        a.touch("/p/x.swift", edit: false, at: now.addingTimeInterval(-500))
        b.touch("/p/x.swift", edit: true, at: now.addingTimeInterval(-60))
        b.touch("/p/y.swift", edit: false, at: now)
        b.addMessage(.init(outgoing: false, peer: "lead", text: "hi", at: now))
        let activity = WorkstreamActivity([("A", a), ("B", b)])
        #expect(activity.recentFiles().map(\.path) == ["/p/x.swift"])
        #expect(activity.recentFiles().first?.agents == ["A", "B"])
        #expect(activity.highActivity().first?.count == 3)
        #expect(activity.messages().first?.agent == "B")
        let overlaps = Overlaps.find([("A", a), ("B", b)], now: now)
        #expect(overlaps.map(\.path) == ["/p/x.swift"])
        #expect(Overlaps.find([("A", a), ("B", b)], window: 60, now: now).isEmpty)     // 9 minutes apart
        #expect(Overlaps.find([("A", a), ("B", b)], now: now.addingTimeInterval(2 * 86_400)).isEmpty)   // old news
    }

    @Test func summaryListsRecentFilesMessagesAndArtifacts() throws {
        let url = try Fixture.write(Fixture.claude)
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = TranscriptScanner()
        scanner.scan(url)
        let summary = WorkstreamSummary(workstream: Workstream(id: "W"), session: "S", names: [:], plan: PlanList(steps: [], updated: nil),
                                        scheduled: [], activity: WorkstreamActivity([("S", scanner.currentFacts)]),
                                        now: ScheduleScanner.parseDate(Fixture.t2)!)
        #expect(summary.files.contains("Recent:\n- /tmp/proj/b.md"))
        #expect(summary.messages.contains("you → worker"))
        #expect(summary.messages.contains("lead → you"))
        #expect(summary.artifacts.contains("Report: https://claude.ai/artifact/SAiZc8wc4HG3hh98xzBxUx"))
        #expect(summary.full.contains("## Artifacts"))
    }
}
