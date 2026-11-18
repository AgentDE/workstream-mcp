import Foundation
import Testing
@testable import WorkstreamKit

/// Real Claude Code transcripts of one cross-session message, the sender's and the receiver's, with every name
/// and the text replaced, and everything the scanner doesn't read blanked (`Fixtures/`). They keep each
/// record Claude Code wrote about the message: the send, its result and request blob; the queue entries, the
/// attachment and the request blob that carried it to the receiver. When Claude Code changes how it records
/// messages, add a fixture from a new transcript here.
@Suite("Peer messages in real transcripts")
struct PeerMessageFixtureTests {
    static let body = "Here's the list you asked for.\n\n- **First:** a point.\n- **Second:** another point.\n\nThanks!"

    static func scan(_ name: String) -> TranscriptFacts {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        let scanner = TranscriptScanner()
        _ = scanner.scan(url)
        return scanner.facts
    }

    /// Queued, then delivered as an attachment (only that copy keeps Claude Code's notices), and echoed in the
    /// request blob: one message, in the sender's words.
    @Test func theReceiverRecordsOneMessage() {
        let messages = Self.scan("peer-receiver.jsonl").messages
        #expect(messages.count == 1)
        #expect(messages.first?.outgoing == false)
        #expect(messages.first?.peer == "agent-a")
        #expect(messages.first?.readable == Self.body)
    }

    /// The send counts once its result says it went through; the request blob repeats it.
    @Test func theSenderRecordsOneMessage() {
        let messages = Self.scan("peer-sender.jsonl").messages
        #expect(messages.count == 1)
        #expect(messages.first?.outgoing == true)
        #expect(messages.first?.readable == Self.body)
    }

    /// Both agents in one workstream: the panel lists the message once, as sent.
    @Test func bothSidesInOneWorkstreamListItOnce() {
        let rows = WorkstreamActivity([("sender", Self.scan("peer-sender.jsonl")), ("receiver", Self.scan("peer-receiver.jsonl"))]).messages()
        #expect(rows.count == 1)
        #expect(rows.first?.agent == "sender" && rows.first?.message.outgoing == true)
    }
}
