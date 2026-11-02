import Foundation
import Testing
@testable import WorkstreamKit

@Suite("Working folder")
struct WorkingFolderTests {
    @Test func agentsSeeTheWorkingFolder() {
        let summary = { (w: Workstream) in
            WorkstreamSummary(workstream: w, session: nil, names: [:], plan: PlanList(steps: [], updated: nil), scheduled: [])
        }
        let named = summary(Workstream(id: "w1", name: "cold-match", folder: "/Users/a/git/app-worktrees/cold-match"))
        #expect(named.full.contains("Working folder: /Users/a/git/app-worktrees/cold-match"))
        #expect(named.compact().contains("Working folder: /Users/a/git/app-worktrees/cold-match"))
        #expect(!summary(Workstream(id: "w2")).full.contains("Working folder"))
    }
}
