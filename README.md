# workstream-mcp

An MCP server that gives coding agents (Claude Code, Codex) a shared, persistent record of their work, called a **workstream**: overview, rules, memory, questions waiting on you, FYI notes, progress, pinned files and linked tickets. Agents keep it current with the server's tools; Claude Code hooks put it back into the agent's context after every start, resume and compaction. An app can show it beside the chat (AgentDE does, with the `agentde-workstreams` extension).

- One JSON file per workstream in `~/.config/workstreams/`; nothing else to run.
- Swift, Foundation only; macOS 14 or later.
- Design, file format and details: [docs/WORKSTREAMS.md](docs/WORKSTREAMS.md).

## Tools

Claude shows them as `mcp__workstream__<name>`.

| Tool | Does |
|---|---|
| `read_workstream(section?)` | The whole workstream, or one section |
| `set_overview(text)` | Replaces the overview: what the work is for and where it stands |
| `add_rule(text)` | Records a standing rule the user states |
| `add_memory(name, text)` | Adds or updates a dated fact or decision a later agent will need; at most 25 items per workstream by default |
| `set_progress(rows, merge?)` | Sets the caller's progress rows (label, optional 0–1 bar, text) |
| `ask_user(question, options?, default?, decide_by? / in_minutes?, id?)` | Puts a question under Waiting on you without stopping; an optional default is taken when the deadline passes |
| `tell_user(text)` | Adds an FYI note |
| `pin_file(path, note?)` | Pins a file with a note |
| `link_ticket(ticket, title?)` | Links a ticket in any tracker: `ENG-123`, `acme/app#12`, or a link |
| `remove_entry(id \| path)` | Takes back a rule, memory item, ask, FYI note, ticket or pinned file |
| `open_in_viewer(path)` | Asks the app to show a file or local page beside the chat (needs an app) |
| `manage_workstreams(action, id?, name?)` | Lists, switches, starts or renames workstreams |

Text fields have short limits (a 400-character overview, 280-character questions and notes…); longer text is refused, not cut.

## Commands

| Command | What |
|---|---|
| `workstream-mcp` | Serves MCP on stdin/stdout |
| `workstream-mcp context` | Claude Code SessionStart hook: prints the workstream, rules first |
| `workstream-mcp prompt-context` | Claude Code UserPromptSubmit hook: prints the rules when they changed |
| `workstream-mcp statusline -- <command…>` | Status line wrapper: saves Claude's status JSON (for cost and context figures), then runs your command with the same input |

## Environment

| Variable | Set by | Does |
|---|---|---|
| `WORKSTREAM_EVERYWHERE=1` | You | Turns the server on for every session: each new agent gets its own workstream |
| `WORKSTREAM_TAB_ID` | An app, per terminal | The terminal (tab) running the agent; turns the server on for it |
| `WORKSTREAM_ID` | An app, per terminal | The workstream a new session in that terminal joins |
| `WORKSTREAM_DIR` | Optional | Where workstream files live (default `~/.config/workstreams`) |
| `WORKSTREAM_CACHE_DIR` | Optional | Where transcript snapshots and the status-line feed go (default `~/Library/Caches/workstreams`) |

Without `WORKSTREAM_EVERYWHERE`, `WORKSTREAM_TAB_ID` or a session already in a workstream, the server offers no tools and the hooks print nothing, so it's safe to register globally.

## Using it without AgentDE

Build it, then register it with `WORKSTREAM_EVERYWHERE=1`:

```bash
swift build -c release
BIN=$PWD/.build/release/workstream-mcp
claude mcp add --scope user workstream -e WORKSTREAM_EVERYWHERE=1 -- "$BIN"
```

For the context to come back after compactions, add the hooks to `~/.claude/settings.json`, with the same variable:

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "startup|resume|compact",
                       "hooks": [{ "type": "command", "command": "WORKSTREAM_EVERYWHERE=1 /path/to/workstream-mcp context" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "WORKSTREAM_EVERYWHERE=1 /path/to/workstream-mcp prompt-context" }] }]
  }
}
```

A session gets its workstream on its first tool call; the hooks include it from then on. Read a workstream with `read_workstream`, or open its file in `~/.config/workstreams/`.

## Building

```bash
swift build -c release      # .build/release/workstream-mcp
swift test
```

The package has two products: the `WorkstreamKit` library (file format, store, resolution, transcript reading, the server; no AppKit) for apps that show workstreams, and the `workstream-mcp` executable.

## Registering with an app

When an app bundles the server (`<App>.app/Contents/MacOS/workstream-mcp`), AgentDE's `scripts/register-workstream.sh` registers it for Claude Code and Codex: the MCP server, an allow rule for its tools, both hooks, and the status-line wrapper. It prints the changes first; `--yes` applies them and `--uninstall` takes them back. `WORKSTREAM_APP=/Applications/Some.app` picks the app (default: the installed AgentDE). Details: [docs/WORKSTREAMS.md](docs/WORKSTREAMS.md#registration).

## License

MIT; see [LICENSE](LICENSE).
