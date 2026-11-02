import Foundation
import Testing
@testable import WorkstreamKit

@Suite("Status line feed")
struct StatusLineTests {
    @Test func statusLineWrapperSavesAndPassesThrough() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("statusline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = "22222222-2222-2222-2222-222222222222"
        let input = Data(Fixture.json(["session_id": session, "cost": ["total_cost_usd": 876.17, "total_duration_ms": 913_500_000,
                                                                       "total_lines_added": 43000],
                                       "context_window": ["used_percentage": 41]]).utf8)
        let output = Pipe()
        let status = StatusLineFeed.run(input: input, command: ["tr a-z A-Z"], output: output.fileHandleForWriting, directory: dir)
        try output.fileHandleForWriting.close()
        #expect(status == 0)
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed.contains("SESSION_ID"))      // the command saw the same input
        let saved = try #require(StatusLineFeed.read(session: session, directory: dir))
        #expect(saved.costUSD == 876.17 && saved.linesAdded == 43000 && saved.contextUsedPercent == 41)
        // Input it can't read is still passed through.
        let garbled = Pipe()
        #expect(StatusLineFeed.run(input: Data("not json".utf8), command: ["cat"], output: garbled.fileHandleForWriting, directory: dir) == 0)
        try garbled.fileHandleForWriting.close()
        #expect(String(decoding: garbled.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "not json")
        // A command that ignores its input doesn't break the wrapper.
        #expect(StatusLineFeed.run(input: Data(repeating: 0x41, count: 1 << 20), command: ["true"], output: .nullDevice, directory: dir) == 0)
    }
}
