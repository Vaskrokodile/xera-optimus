# xera-optimus

An agentic coding harness in **Zig** — modeled after Codex CLI / Claude Code —
with the **Harness²** recursive self-improvement loop built in.

Single static binary (~2 MB, no runtime deps). Speaks the OpenAI-compatible
chat-completions API, so it works with OpenAI, LiteLLM, Ollama, LM Studio,
DeepSeek, Groq, and any compatible endpoint.

```
xera-optimus                 interactive TUI (chat, tools, approvals)
xera-optimus exec "task"     one-shot run, then exit
xera-optimus improve "task"  Harness² propose-probe-compose on a task
xera-optimus harness         inspect the editable harness
xera-optimus sessions        list saved sessions
xera-optimus resume <id>     resume a session
xera-optimus doctor          config + connectivity check
```

## Interactive UI

Running with no subcommand opens a full-screen Codex-style TUI
(alternate screen; falls back to plain line mode when stdin isn't a TTY,
or with `--classic`):

- **banner** — extruded 3D `XERA-OPTIMUS` logo (cyan→blue→white truecolor)
  revealed by a matrix-scramble animation on startup
- **scrollback** — user turns, streamed assistant text (markdown-lite:
  **bold**, `code`, headers, quotes, code fences), tool cells
  (`⚙ tool args` → result preview → `✓`/`✗`), status notes
- **composer** — bordered input box, UTF-8 aware cursor movement,
  up/down history recall, paste
- **command picker** — type `/` and a live dropdown opens, narrowing as
  you type; `↑`/`↓` pick, `tab` completes, `enter` runs, `esc` dismisses
- **status bar** — model · workspace · session id · approval mode
- **spinner** — `⠙ working Ns · M tool call(s)` while the agent runs
- **approvals** — `y`/`n`/`a` on `⚠ allow?` rows, or `esc` to deny
- **keys** — `enter` send · `esc` interrupt (busy) / clear (idle) ·
  `pgup`/`pgdn` scroll · `↑`/`↓` history · `ctrl+l` redraw · `ctrl+c` quit

Slash commands: `/help` `/exit` `/clear` `/auto` `/model` `/usage`
(token counters) `/summarize` (compact now) `/skills` `/agents`
`/harness` (components + validation problems) `/library` `/sessions`
`/resume <id>` `/status` `/improve`. `/model` opens a searchable model picker
for the currently configured provider; navigate with arrows/Enter or hover and
click a model. Use config (`base_url`, API key) to change providers.

## Multiplayer

Multiple people can vibe-code in **one shared session** — every participant
sees the same prompt/answer history and talks to the same shared agent.

- `/multiplayer-create` — host a session. Prints an id like
  `xmp-203.0.113.7-7777-a1b2c3` (port `7777` on your LAN ip; share it).
- `/multiplayer-join <id>` (or `/join <id>`) — join from another machine
  running xera-optimus. The joiner instantly gets the full shared history.
- Typing shows a live `● <name> is typing [ click to peek ]` line above the
  composer — click it (mouse) to see their draft.
- Every prompt gets an id (`p-1`, `p-2`, …) and is rendered with the
  author's name in their own color. `N online` in the hint bar is presence.
- `/thread <p-N>` — open a **thread** around a prompt. Each thread gets a
  dedicated agent on the host that only sees that thread's prompts.
- `/threadmonitor` (or `/threads`) — a clickable overlay listing every
  thread, message count, busy/idle state and last-activity age.
  Click a row to jump into the thread.
- `/main` — back to the shared channel. `/leave` — leave the session.

Transport is plain TCP + newline-delimited JSON (no server needed beyond
the host's xera-optimus). The host owns the canonical log and runs all
agents; peers' prompts are forwarded and answers broadcast. Set
`XERA_NAME` to pick your display name.

## Setup

```jsonc
// ~/.xera-optimus/config.json
{
  "base_url": "https://api.openai.com/v1",
  "api_key_env": "OPENAI_API_KEY",   // or "api_key": "sk-..."
  "model": "gpt-5",
  "max_tokens": 16384,
  "approval": "ask",                  // ask | full-auto
  "stream": true
}
```

Environment overrides: `XERA_MODEL`, `XERA_BASE_URL`, `XERA_API_KEY`,
`XERA_API_KEY_ENV`, `XERA_SHELL`, `XERA_FULL_AUTO`, `XERA_NO_STREAM`.

Common flags: `-m/--model`, `--base-url`, `--api-key`, `-C/--cwd`,
`-y/--full-auto`, `--no-stream`.

## Tools the agent can call

`read_file` `write_file` `edit_file` (exact-match replace) `list_dir`
`glob` `grep` `delete` (files or trees, workspace-confined) `make_dir`
`run_shell` (cmd /c on Windows, /bin/sh elsewhere, with timeout)
`web_fetch` (URL → text, HTML stripped) `web_search` (DuckDuckGo lite)
`memory_append` `skill_load` `task` (subagent with fresh context, depth ≤ 2)

In interactive mode, write/shell tools ask for approval (`y`/`n`/`a`lways).
`exec` and `improve` run unattended (auto-approve). Writes are confined to the
workspace root. `esc` interrupts a running turn.

## The harness (Harness²)

The editable system around the model lives in
`<workspace>/.xera-optimus/harness` (falls back to `~/.xera-optimus/harness`).
The full harness2 c1..c8 surface — canonical names accepted everywhere:

```
c1  system_prompt.md | systemprompt.md | AGENTS.md      always-on prompt
c2  guardrails.md                                      hard constraints
c3  memory.md | LongTermMEMORY.md                      durable memory
c4  tool_guidance.md | tool_descriptions/tool_guidance.md
c5  subagents.md + sub_agents/<name>/AGENT.md          named personas
c6  skills/<name>.md | skills/<name>/SKILL.md          frontmatter'd skills
c7  scripts/<name>.<ext>                               helper scripts
c8  hooks.json | .codex/hooks.json                     lifecycle hooks
+   lessons.md                                         adopted lessons
```

- **skills** support frontmatter (`name:`, `description:`); descriptions are
  advertised in the system prompt and bodies load on demand via `skill_load`.
- **sub_agents** are named personas; the model spawns one with
  `task(prompt, agent="<name>")`.
- **hooks** fire inside the tool loop (the model can't skip them):
  `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `SubagentStart`/`SubagentStop`, `PreCompact`/`PostCompact`, `Stop`.
  A hook command gets a JSON event on stdin; stdout
  `{"decision":"block","reason":"..."}` blocks the tool call and feeds the
  reason back to the model — see `hooks.example.json`.
- `xera-optimus harness` and `doctor` validate the surface (frontmatter
  problems, always-on cap, untriggered skills).

All of it is injected into the system prompt and all of it is editable — by
you, or by the `improve` loop.

## `xera-optimus improve`

Recursive task-level + harnessing-level recursion:

1. **Base** — run the task with the current harness, record the trajectory.
2. **Propose** — the harness editor proposes K candidate harness edits
   (file writes/appends/deletes inside the harness dir).
3. **Probe** — each candidate is materialized into an isolated harness copy and
   executed on the same task.
4. **Compose** — the composer reads the behavioral contrasts between the base
   and probe executions, adopts or merges the best ideas, applies the final
   edits, and appends an evidence-supported **lesson** to `lessons.md` (which
   persists into every future session — harnessing-level recursion).

```
xera-optimus improve "task" -k 2 --mode parallel      # default
xera-optimus improve "task" -k 3 --mode sequential    # refine step by step
xera-optimus improve "task" --dry-run                 # propose only
```

Run artifacts land in `.xera-optimus/runs/improve-<ts>/` in the harness2
evidence layout: `context/task.md`, `context/harness/` (base copy),
`context/rollouts/`, `context/deliverables/`,
`context/pool/<cand>/{harness/,harness.diff,rollout.md,produced.md}`,
`context/decisions/`. Candidate harnesses that fail surface validation are
recorded as rejected probes instead of being executed. Adopted harnesses are
snapshotted into `~/.xera-optimus/library/<id>/` (cross-task evidence).

## Sessions

Every turn is appended as JSONL to `~/.xera-optimus/sessions/<id>.jsonl`.
`xera-optimus sessions` lists them; `xera-optimus resume <id>` or `/resume <id>`
loads one into context.

## Build

Zig **0.14.1**:

```
zig build                    # debug
zig build -Doptimize=ReleaseSafe
```

Output: `zig-out/bin/xera-optimus(.exe)`.

## Layout

```
src/main.zig      CLI dispatch (chat/exec/improve/harness/sessions/resume/doctor)
src/config.zig    config.json + env + flag resolution
src/http.zig      HTTPS client + SSE reader
src/llm.zig       OpenAI-compatible client, streaming, tool-call assembly
src/tools.zig     tool registry + implementations + approval plumbing
src/agent.zig     the agent loop: turn, tool dispatch, subagents, compaction
src/harness.zig   Harness² components: load, assemble, edit, snapshot
src/improve.zig   Propose–Probe–Compose recursion
src/session.zig   JSONL transcripts, list, resume
src/tui.zig       terminal layer: raw mode, alt screen, key input, styles
src/tui_app.zig   Codex-style TUI: scrollback blocks, composer, spinner,
                  approvals, worker thread + event queue, diffed rendering
src/repl.zig      plain line-mode fallback (--classic / non-TTY)
mock_llm.py       local OpenAI-compatible mock for offline testing
pty_test.py       ConPTY driver that screen-captures the TUI (dev)
```

## Known limits

- OpenAI-compatible endpoints only (Anthropic-native API not yet implemented)
- Shell sandboxing = approval gating only, no OS-level sandbox
- Improve probes run sequentially; parallel probes possible but not wired
- TUI is Windows + POSIX tested paths; `--classic` available everywhere
