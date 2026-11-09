# Workstreams

A **workstream** is the shared record of a piece of agent work: what it's for, the rules and facts it relies on, how long-running work is going, what it's waiting on you for, and which files and tickets matter. Agents keep it current through the `workstream` MCP server; an app shows it beside the agent's chat. An **agent** is one Claude Code or Codex session. Each agent has exactly one active workstream and can switch to another; a workstream can have several agents.

The design has two halves that only share a file format:

| Half | Where | What |
|---|---|---|
| Store, server and hooks | This repo: `Sources/WorkstreamKit` (format, store, resolution, transcript reading, the server and summaries; Foundation only) and the `workstream-mcp` binary (`Sources/workstream-mcp`) | Reads and writes the files; no AppKit, no app dependency |
| A viewer | AgentDE with the `agentde-workstreams` extension, which bundles `workstream-mcp` in `AgentDE.app/Contents/MacOS` | Reads the same files and renders them; one viewer of the data, not its owner |

## Vocabulary

These are AgentDE's names for what the panel is shown in.

| Name | What it is |
|---|---|
| Group | A folder plus its agents, in the sidebar |
| Tab | One terminal; an agent tab runs one agent session |
| Chat | The agent's terminal, at the bottom of the tab |
| Viewer | Above the chat: one file or page at a time (Markdown, image, PDF, code, diff, local HTML, localhost, artifacts) |
| Workstream panel | The column beside the chat, full height of the tab: the agent's active workstream |

## Workstream panel

On top, the **workstream picker**: the active workstream's name with ▾. Its menu lists the group's workstreams (switching moves this agent from the old one's agents to the new one's), **New Workstream** and **Rename…**. A workstream's name defaults to its first agent's name until it's renamed.

Then sections, each collapsible with a "last updated" time, shown when they have content:

| Section | Shows |
|---|---|
| Waiting on you | Asks: a question and answer options (Yes, No and Discuss when the agent gives none, also for questions saved without options). An open ask doesn't stop the agent. Answering types the option into the asking agent's chat with its question and id (`Answer to your question "Which seed?" (a3): Seed 1`). An ask can carry a default and a deadline ("defaults to Yes in 25m"); when the deadline passes unanswered, the app types the default as the answer, saying it was the default, once the agent is idle, and the file records `resolved_by: "default"`. ✕ dismisses one |
| FYI | Notes that need no answer, newest first, with their age; ✕ dismisses one. The newest 20 are kept |
| Overview | What the work is for and where it stands |
| Tickets | Tickets linked by you (**Link ticket**, or ⊕ to pick one of yours from a signed-in tracker) or by an agent (`link_ticket`). With a ticket provider for its tracker (the Linear extension, say), each shows its live state, priority and title; else its identifier and whatever title the file has. ✕ unlinks one |
| Rules | Standing instructions every attached agent follows ("ask before spending over $20"). Always shown, with an **Add rule** field; ✕ removes one |
| Agents | With two or more attached agents: each one's status dot and tab name; click to select its tab |
| Messages | Claude Code's cross-session messages involving the attached agents, from their transcripts: "from → to", the first line and its age; click to read all of it. Newest first, 15 |
| Memory | What a later agent will need and couldn't easily find: decisions and reasons, preferences, hard-won facts, where things live. Folded by default |
| Progress | Rows with a label, an optional bar (0–1) and text. Dims after 30 minutes without an update |
| Plan | The agent's own to-do list, from where Claude Code keeps it (`~/.claude/tasks/<session id>/*.json`); other attached agents' lists follow, folded. A bar shows the share done; only the last 5 done steps are listed |
| Scheduled | What the attached agents scheduled with Claude Code's own tools, soonest first: "in 40m · 14:20" or "Every hour at :13 · next 14:13" |
| Files | **Pinned** (by agents and you, with notes; ◇ Pin / ◆ Pinned in the viewer), **Recent** (edited by the attached agents, newest first, 8) and **High activity** (edited and read most, 5, with the count). A file appears once, in the first subsection that has it; a pinned file that's gone is struck through and marked missing |
| Artifacts | Claude artifacts the attached agents published (the `Artifact` tool's publish results, with their titles), artifact links in their own messages, links the app's link rules claim (an extension's artifact pages, including ones tools printed), and local HTML pages they named by absolute or `~` path (while the file exists). Each is listed once, in its canonical form. Click to open it in the viewer |
| Stats | Folded; for the agent in the tab. From the transcript: cost (≈, from a price table), wall time and time in turns, tokens by model, cache hit rate, lines added and removed, files edited, tool calls, compactions; "Now": context used and the 5-hour and 7-day limits. With the status-line feed (below), Claude's own figures replace the estimates. With two or more agents, a total line |

Nothing in the panel explains itself; every word is the workstream's content or a timestamp.

**Overlapping edits.** When two agents in one group's folder edit the same file within 30 minutes of each other (from their transcripts; Claude and Codex), the app adds an FYI to each one's workstream ("train.py is also being edited by api-tests"), or one note when they share a workstream. A pair of agents gets one note, listing every file they share ("3 files are also being edited by api-tests: train.py, eval.py, data.py"), rewritten in place when another file is added. These notes carry `by: "app"` and an `expires` a day later, after which the app removes them. A fork's transcript begins with a copy of its parent's conversation, stamped before the fork; those lines are the parent's work, so they count toward neither overlaps nor the fork's Files, Stats and Usage.

An open ask from a tab's agent marks the tab with a soft amber ring. The full needs-you treatment (amber dot, dock badge, notification) stays for permission prompts, where the agent really is stopped. The panel shows for every agent tab; Layout → Side Panel (⌥⌘I) hides it per tab. On a working area under 760 pt it folds to a 28 pt strip with the status dot and the number of open asks.

### Scheduled, from Claude Code's own scheduling

Claude Code has session-scoped scheduling: `CronCreate` (cron jobs, including fixed-interval `/loop`s), `CronDelete`, and `ScheduleWakeup` (dynamic `/loop` wake-ups). The workstream shows them instead of having reminders of its own. They're read from each attached agent's transcript (`~/.claude/projects/<folder>/<session id>.jsonl`), incrementally, when the transcript changes:

| Record | Read as |
|---|---|
| `CronCreate` input `{cron, recurring, prompt}`; result `{id, humanSchedule, recurring, durable}` | A job; the next run comes from the 5-field cron expression (local time; `CronExpression`). A session-only job ends with its session and expires 7 days after it's made; a one-off is gone after its first run |
| `CronDelete` input `{id}` | Removes the job |
| `ScheduleWakeup` input `{delaySeconds, reason, prompt}` or `{stop: true}`; result `scheduledFor` (ms since 1970) | A wake-up; a later one replaces an earlier one, past ones disappear |
| `<folder>/.claude/scheduled_tasks.json` | Durable jobs: an array of jobs or an object holding them (`tasks`, `jobs`, or keyed by id), each with an id, `cron` or `schedule`, and `prompt` |

## Transcripts

Files, Messages, Artifacts, Stats and Scheduled are read from what the agents' tools already record. `TranscriptScanner` reads a transcript once and incrementally (only what was appended), in 4 MB chunks, skipping Claude Code's own records (lines starting `{"type":"`, such as the large `api-request` ones; queued peer messages are the exception) and parsing only the lines that can matter; it feeds the same lines to the schedule reader.

| Agent | Transcript | Read from it |
|---|---|---|
| Claude Code | `~/.claude/projects/<folder>/<session>.jsonl` | `Edit`/`Write`/`MultiEdit`/`NotebookEdit` (`file_path`; lines from the result's `structuredPatch`, or a new file's content), `Read`, `SendMessage` (`to`, `message`), incoming peer messages (an `attachment` with `origin.kind` `peer`; the `<cross-session-message from-name="…">` prompt it became; or a `queue-operation` `enqueue` record for a reply taken mid-turn; each delivery counted once), the `Artifact` tool's publish results (`url`, `title`), artifact links in text, `compact_boundary` and `turn_duration` records, and each assistant message's `usage` (counted once per API message) |
| Codex | `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-…-<id>.jsonl` | File edits from `apply_patch` calls, for Files and overlaps. No usage or messages |

Its state saves as a snapshot in `~/Library/Caches/workstreams/transcripts/<session>.json` (`WORKSTREAM_CACHE_DIR` replaces `~/Library/Caches/workstreams`): the app writes it every 2 MB or 2 minutes of new reading and at quit, so the next launch resumes instead of rereading. An 820 MB transcript takes about 6.5 s to read the first time, about 30 MB of memory, and milliseconds after that. The MCP server starts from the app's snapshot too.

**Status-line feed.** `workstream-mcp statusline -- '<command>'` saves the JSON Claude Code gives a status line (`session_id`, `cost.total_cost_usd`, `cost.total_duration_ms`, `cost.total_api_duration_ms`, `cost.total_lines_added/removed`, `context_window.used_percentage`, …) to `~/Library/Caches/workstreams/statusline/<session>.json`, then runs your command with the same input and prints its output unchanged. Saving can't break the status line: unreadable input is passed on as is, and the command runs regardless. It lives in the cache folder, not the workstreams folder, so a status line refreshing every few seconds doesn't wake the app's file watcher. Stats reads it at most every 10 seconds.

## Data

One file per workstream: `~/.config/workstreams/<workstream id>.json` (`WORKSTREAM_DIR` overrides; an AgentDE test instance with `AGENTDE_STATE` uses `workstreams/` beside its state file and passes it to its tabs as `WORKSTREAM_DIR`). Writes are atomic (temp file + rename) under a per-workstream lock file (`.<id>.lock`), so the app and the MCP server can both write.

```json
{
  "version": 1,
  "id": "6F1C0B9E-…",
  "name": "Seed sweep",
  "folder": "/path/to/repo",
  "agents":   [{ "session": "f65bbf83-…", "kind": "claude", "tab": "FF7AA8D9-…", "added": "2026-10-20T09:41:00Z" }],
  "overview": { "text": "…", "updated": "2026-10-20T09:41:00Z" },
  "rules":    { "items": [{ "id": "r1", "text": "Never push to main.", "by": "you", "at": "…" }], "updated": "…" },
  "memory":   { "items": [{ "id": "m1", "name": "backup-volume", "text": "…", "at": "…" }], "updated": "…" },
  "progress": { "rows": [{ "label": "campaign", "value": 0.72, "text": "…", "agent": "f65bbf83-…" }], "updated": "…" },
  "waiting":  { "asks": [{ "id": "a1", "question": "…", "options": ["Seed 1", "Both"], "default": "Seed 1",
                           "decide_by": "…", "asked": "…", "agent": "…",
                           "resolved_by": "default", "answer": "Seed 1", "resolved_at": "…" }], "updated": "…" },
  "fyi":      { "items": [{ "id": "f1", "text": "Pod relaunched; no data lost.", "agent": "…", "at": "…" }], "updated": "…" },
  "files":    { "items": [{ "path": "/abs/path", "note": "…", "by": "agent|you" }], "updated": "…" },
  "pinnedArtifacts": { "items": [{ "url": "https://…", "title": "…", "at": "…" }], "updated": "…" },   // pinned in the app only
  "tickets":  { "items": [{ "identifier": "ENG-123", "title": "…", "url": "https://…", "tracker": "linear", "by": "agent|you", "at": "…" }], "updated": "…" },
  "former":   ["9c11ec68-…"],
  "lastIDs":  { "m": 12, "a": 4, "f": 2, "r": 3 }
}
```

| Topic | How it works |
|---|---|
| Agents | A session is in exactly one workstream's `agents`; the session index (session → workstream) is the source of truth for a running agent, so when an agent switches through the server its tab follows. If a crash between two writes left a session in two, the later `added` wins. Files with the older `sessions: [{id, agent}]` still load |
| Ids | In AgentDE each tab has an active workstream id, kept with the tab (`extensionData["workstreams.id"]`). New tabs get a fresh UUID; the tab's environment carries it as `WORKSTREAM_ID` beside `WORKSTREAM_TAB_ID`, a hint the server uses until the session is indexed |
| Attaching | When a tab's Claude or Codex session appears or changes (a new agent, `/clear`, a resume) and no workstream lists it, it joins the tab's workstream (with the tab id and the group's folder). The app checks the files when it writes: a session some workstream already lists (an agent that switched, or a fork that started its own) only gets its tab noted there, never moved. Closing a tab detaches its agent (its open asks go); the workstream stays, listed in the picker |
| Leaving and coming back | Closing a tab detaches its agent and records the session in `former`. When that session is resumed in another tab, it rejoins that workstream, and the new tab switches to it. Switching workstreams on purpose isn't leaving, so it records nothing |
| Item ids | `m`, `a`, `f`, `r` ids are never reused: `lastIDs` keeps the highest number each prefix has used |
| Asks | Answered asks stay with `resolved_by` (`you`, `agent`, `default`), `answer` and `resolved_at`; the 10 newest answered ones are kept. When an agent's session ends (three registry polls without it), its open asks are cleared. Moving an agent to another workstream leaves its asks where they were asked |
| Tickets | `identifier` is a key (`ENG-123`), `owner/repo#12`, or for an unknown tracker the link without its scheme. `tracker` is `linear`, `jira`, `github` or `gitlab` when the link says so, else absent (`Workstream.ticketReference`) |
| Requests | `open_in_viewer` writes `.requests/<uuid>.json` (`{action, session, tab, path, at}`); the app takes it (reading and deleting the file) on the next folder change, finds the tab by session (else tab id), and opens the path in that tab's viewer without switching tabs |
| Watching | One FSEvents stream covers the workstreams folder (including `.requests/`), Claude's task lists and its transcripts; files are read off the main thread, with real paths. Ask deadlines use one timer for the next deadline; an overdue default whose agent is busy is delivered when the agent goes idle |

## MCP server `workstream`

JSON-RPC 2.0 over stdio, one message per line. By default it's active only for agents an app has attached: with neither `WORKSTREAM_TAB_ID` nor an indexed session (nor `WORKSTREAM_EVERYWHERE=1`), `initialize` returns no instructions and `tools/list` is empty, so other sessions get nothing extra. A session can join after its server started: a background session that a tab adopts never gets `WORKSTREAM_TAB_ID`, and is only indexed once the tab attaches it. So the server declares `tools.listChanged`, checks every 10 s until its session is in a workstream, then sends `notifications/tools/list_changed`. The instructions only go out at `initialize`, so the UserPromptSubmit hook sends them, with the whole workstream, to any session no hook has reached yet (it has no `.rules-seen` marker), once.

**Resolution** (`AgentContext.resolve`), on every call, since an agent can switch:

1. The calling session (`CLAUDE_CODE_SESSION_ID`, which Claude sets for the MCP servers it starts; or `CODEX_SESSION_ID`/`CODEX_THREAD_ID`) in the session index → that workstream.
2. A session listed in a workstream's `former` (resumed after its tab closed) → that workstream, which it rejoins.
3. A fork (a background session whose job record has `forkParentSessionId`) → its parent's workstream, which it joins.
4. Not a background session, with `WORKSTREAM_ID` → that workstream, which it joins (creating the file if needed, with the folder).
5. `WORKSTREAM_EVERYWHERE=1` → a new workstream for the session.

Background sessions are told apart by `CLAUDE_JOB_DIR`. They run under Claude's daemon and inherit the **daemon's** environment, which belongs to whichever process started the daemon, so their `WORKSTREAM_*` values are stale and ignored.

Tools (Claude shows them as `mcp__workstream__<name>`):

| Tool | Does |
|---|---|
| `read_workstream(section?)` | The whole workstream, or one section: overview, tickets, rules, waiting, fyi, memory, progress, plan, scheduled, files, messages, artifacts, agents |
| `set_overview(text)` | Replaces the overview |
| `add_rule(text)` | Records a standing rule |
| `add_memory(name, text)` | Adds a dated Memory item under a short name; an existing name, or an item's id (`m4`), updates its item. The reply lists items older than 3 days, to take back stale ones. A workstream holds at most 25 items (`memoryLimit` in the folder's `.settings.json`, set from AgentDE's Settings → Extensions → Workstreams; below 1 means no limit): past it, a new item is refused with every item listed, and the agent is told to remove some and keep the rest in a notes file. Updates still work |
| `set_progress(rows, merge?)` | Replaces the caller's progress rows, keeps other agents'. With `merge`, only the rows sent change (by label) and empty text removes one |
| `ask_user(question, options?, default?, decide_by? / in_minutes?, id?)` | Puts something under Waiting. With the `id` of an open ask, rewords it in place |
| `tell_user(text)` | Adds an FYI note |
| `pin_file(path, note?)` | Pins a file, or updates its note |
| `link_ticket(ticket, title?)` | Links a ticket in any tracker: a key (`ENG-123`), `owner/repo#12`, or a link |
| `remove_entry(id \| path)` | Takes back a rule, memory item, ask or FYI note by id (`r1`, `m1`, `a1`, `f1`), a ticket by identifier, or a pinned file by path |
| `open_in_viewer(path)` | Shows a file or local page in the tab's viewer |
| `manage_workstreams(action, id?, name?)` | `list`, `switch`, `new`, `rename` |

When to use them is in the server's own instructions, which Claude adds to the session while the server is connected: the overview at the start and when the goal or state changes; rules when the user states one; memory for decisions and facts; progress at milestones; `ask_user` for anything waiting on the user, with a default and deadline when work could go on; FYI for what the user should know; pinned files; and `remove_entry` for entries that stop being true. Plan and Scheduled come from the agent's own to-do list and scheduling tools.

Everything agents write is short by design. Longer text is refused with an error asking for a shorter version, never cut off. What you type in the panel isn't limited.

| Field | Limit (characters) |
|---|---|
| Overview, Memory item | 400 |
| FYI, ask question | 280 |
| Rule | 200 |
| Progress text, file note, ticket title | 140 |
| Ask option and default, workstream name | 60 |
| Memory name | 40 |
| Progress label | 32 |
| Progress rows per agent | 6 rows |
| Ask options | 6 options |

## Hooks

| Hook | Runs | Prints |
|---|---|---|
| SessionStart (matcher `startup\|resume\|compact`) | `workstream-mcp context` | The workstream as Markdown, within about 6 KB (~1,500 tokens): name and working folder, then Rules, Overview, open asks, Memory, Progress, Plan, Scheduled, Files, and the 5 newest FYI notes; a long list ends with "(+N more; read_workstream section <name> for all)". Records that the session has seen the current rules |
| UserPromptSubmit | `workstream-mcp prompt-context` | The rules, only when they changed since the session last received them (or it switched workstreams), so a rule you add reaches running agents on their next turn. Per-session state is `<workstreams dir>/.rules-seen/<session id>` |

Both print nothing for sessions the server isn't active for. The compaction context leaves out Messages, Artifacts and Recent files, to stay small and fast; `read_workstream` has them.

## Registration

AgentDE's `scripts/register-workstream.sh` (`make register-workstream` in the `agentde` repo) shows what it would change; `--yes` (`YES=1`) applies; `--uninstall` removes what it added. `WORKSTREAM_APP=/path/to/App.app` picks the app whose bundled server to register (default: the installed AgentDE). It:

- runs `claude mcp add --scope user workstream -- <app>/Contents/MacOS/workstream-mcp`;
- adds `mcp__workstream__*` to `permissions.allow` in `~/.claude/settings.json`, plus the SessionStart and UserPromptSubmit hooks, keeping existing hooks (a backup is written beside the file);
- wraps an existing command status line in `workstream-mcp statusline -- '<command>'` (uninstalling restores the original; a status line that isn't a command is left alone);
- adds `[mcp_servers.workstream]` to `~/.codex/config.toml`.

**Codex.** Codex sets `CODEX_THREAD_ID`, which the server accepts as the session id. The script registers only the MCP server for Codex; Codex's hooks need its trust step and a config format not verified here.

## Agents and forks

Forks and helper background sessions are new agents (tabs, through AgentDE's background-session adoption). A fork joins the workstream of the agent it came from: its job record (`~/.claude/jobs/<job>/state.json`) has `forkParentSessionId`. Any other background session gets a new workstream: Claude records no parent for a plain `claude --bg`.

## Notes

- **Codex plans** aren't shown: no Codex session log checked had a plan update, so its format couldn't be confirmed.
- **Stats isn't shown for Codex agents** (their logs have no usage), nor before an agent has used any tokens.
- **No reminders of our own.** Scheduling stays Claude Code's (cron and wake-ups), shown read-only under Scheduled; it lives in the session, not the workstream.
- **No switching sessions inside a tab.** A tab is one agent; the Agents section selects another agent's tab.
- **Claude artifact links come from publishes and the agent's own text,** not from tool output in general: the Artifact tool's listings are full of links that aren't this agent's artifacts. Links the app's link rules claim are taken from tool output as well, since uploads print them.
- **Esc closes the viewer only when the viewer has keyboard focus.** In the chat, Esc stays the agent's (it interrupts a turn).
