import Foundation

/// A step of an agent's own to-do list.
public struct PlanStep: Equatable, Sendable {
    public enum State: String, Sendable { case done, current, todo }
    public var id: String
    public var text: String
    public var state: State
    public init(id: String, text: String, state: State) { self.id = id; self.text = text; self.state = state }
}

/// An agent session's to-do list and when it last changed.
public struct PlanList: Equatable, Sendable {
    public var steps: [PlanStep]
    public var updated: Date?
    public init(steps: [PlanStep], updated: Date?) { self.steps = steps; self.updated = updated }
}

/// Reads the to-do lists agents already keep, so Plan needs no tools of its own.
public enum NativePlan {
    public static var claudeTasksDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/tasks")
    }

    /// Claude Code's task list for an agent session: `<tasks dir>/<session id>/<n>.json`, each with `id`,
    /// `subject`, `status` (`pending`, `in_progress`, `completed`). Ordered by numeric id.
    public static func claudeTasks(session: String, in tasksDirectory: URL = claudeTasksDirectory) -> PlanList {
        guard WorkstreamStore.isValidID(session) else { return PlanList(steps: [], updated: nil) }
        let folder = tasksDirectory.appendingPathComponent(session)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var steps: [(order: Int, step: PlanStep)] = []
        var updated: Date?
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modified > (updated ?? .distantPast) { updated = modified }
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let subject = object["subject"] as? String, !subject.isEmpty else { continue }
            let id = (object["id"] as? String) ?? (object["id"] as? Int).map(String.init) ?? file.deletingPathExtension().lastPathComponent
            let state: PlanStep.State
            switch object["status"] as? String {
            case "completed": state = .done
            case "in_progress": state = .current
            case "pending", nil: state = .todo
            default: continue   // deleted or unknown
            }
            steps.append((Int(id) ?? Int.max, PlanStep(id: id, text: subject, state: state)))
        }
        let ordered = steps.sorted { $0.order != $1.order ? $0.order < $1.order : $0.step.id < $1.step.id }.map(\.step)
        return PlanList(steps: ordered, updated: ordered.isEmpty ? nil : updated)
    }
}
