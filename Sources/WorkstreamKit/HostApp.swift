import Foundation

/// The app showing workstreams beside agents' chats, for naming it in what agents read: the enclosing app's
/// `AgentDEBrandName` (the server runs inside the app bundle), else "AgentDE".
public enum HostApp {
    public static let name = (Bundle.main.object(forInfoDictionaryKey: "AgentDEBrandName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "AgentDE"
}
