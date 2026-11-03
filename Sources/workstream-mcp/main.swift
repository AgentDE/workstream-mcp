import Foundation
import WorkstreamKit

// workstream-mcp            serve the `workstream` MCP server on stdin/stdout
// workstream-mcp context    Claude Code SessionStart hook: print the workstream (rules first)
// workstream-mcp prompt-context
//                           Claude Code UserPromptSubmit hook: print the rules when they changed
// workstream-mcp subagent-context
//                           Claude Code SubagentStart hook: the parent's workstream, as additionalContext JSON
// workstream-mcp statusline -- <command…>
//                           status line wrapper: save Claude's status JSON for the app's Stats, then run <command>
// See docs/WORKSTREAMS.md.

setvbuf(stdout, nil, _IOLBF, 0)
switch CommandLine.arguments.dropFirst().first {
case "context":
    let text = WorkstreamServer.hookContext(input: FileHandle.standardInput.readDataToEndOfFile())
    if !text.isEmpty { print(text) }
case "prompt-context":
    let text = WorkstreamServer.promptContext(input: FileHandle.standardInput.readDataToEndOfFile())
    if !text.isEmpty { print(text) }
case "subagent-context":
    let text = WorkstreamServer.subagentContext(input: FileHandle.standardInput.readDataToEndOfFile())
    if !text.isEmpty { print(text) }
case "statusline":
    // SIGPIPE from a status line reader that went away must not kill the wrapper before the command runs.
    signal(SIGPIPE, SIG_IGN)
    var rest = Array(CommandLine.arguments.dropFirst(2))
    if rest.first == "--" { rest.removeFirst() }
    exit(StatusLineFeed.run(input: FileHandle.standardInput.readDataToEndOfFile(), command: rest))
case nil:
    let server = WorkstreamServer(context: AgentContext())
    let queue = DispatchQueue(label: "workstream-mcp")
    // A session can join the app after this server started; check now and then, and announce the tools once it has.
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 10, repeating: 10)
    timer.setEventHandler { if let line = server.announceIfEnabled() { print(line) } }
    timer.resume()
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            queue.sync { if let response = server.handle(line) { print(response) } }
        }
        exit(0)
    }
    dispatchMain()
case let other?:
    FileHandle.standardError.write(Data("usage: workstream-mcp [context | prompt-context | subagent-context | statusline -- <command>] (got \(other))\n".utf8))
    exit(2)
}
