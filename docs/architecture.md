# MarkdownRun – Technical Architecture

This document defines the architecture for the Vim/Neovim plugin that executes shell commands embedded in markdown files, as specified in the PRD. It covers module boundaries, core flows, state management, file formats, concurrency, UI integration, configuration, and testing.

## 1. Objectives and Constraints

- Execute shell commands from markdown code blocks inside Neovim without modifying the original document
- Persist environment state (working directory, exported variables, PATH) across executions per-session
- Store structured results in JSON sidecar files; handle large/binary output externally
- Provide visual indicators (virtual text) for status and quickfix integration for errors
- Asynchronous execution with a default 30s timeout; error-gating for sequential runs
- Neovim-only, Lua-based, minimal external dependencies

Non-goals: sandboxing, input interactivity, Vim-compatibility, undo for side effects, command safety guardrails

## 2. High-Level Architecture

- Entry: Plugin commands/keymaps expose three modes: manual, next, all
- Markdown layer: Discover and identify runnable shell code blocks based on cursor and file content
- Scheduler & Execution Engine: Spawn shell processes asynchronously, pipe stdin/stdout/stderr, enforce timeouts, capture status
- Session State: Per markdown buffer/file session with current working directory and environment variables (merged with user environment)
- Results Persistence: JSON sidecar with append-merge semantics; separate artifacts for large/binary output
- UI Layer: Virtual text indicators via extmarks; floating popup to show results; quickfix error population

```
+-----------------------+       +------------------+       +---------------------+
|  Plugin Commands/UI   | <---> | Markdown Parser  | <---> | Block Identification |
+-----------------------+       +------------------+       +---------------------+
             |                                 |                       |
             v                                 v                       v
     +----------------+                +-----------------+     +---------------------+
     | Session State  | <------------> | Exec Orchestrator| --> | Results Persistence |
     +----------------+                +-----------------+     +---------------------+
             |                                 |
             v                                 v
       +-----------+                     +-----------+
       | Quickfix  |                     | Popups/UI |
       +-----------+                     +-----------+
```

## 3. Repository Layout

- `plugin/markdownrun.lua`: Entry-point, user commands, keymaps, default config bootstrap
- `lua/markdownrun/markdown.lua`: Block parsing, cursor-based detection, block IDing
- `lua/markdownrun/execution.lua`: Async jobs, timeout, environment capture, gating
- `lua/markdownrun/results.lua`: JSON schema, file IO, large/binary output handling
- `lua/markdownrun/feedback.lua`: Virtual text, popups, quickfix integration
- `lua/markdownrun/commands.lua`: Command routing, mode flows (manual/next/all)
- `lua/markdownrun/state.lua`: Session state (cwd, env), multi-buffer map
- `validate_markdown.lua` (optional): Utilities to validate code fences for testing/dev
- `doc/markdown-run.txt`: Help file (later, optional)
- `test/` specs for unit/integration

## 4. Markdown Parsing and Block Identification

- Recognize fenced code blocks:
  - Explicit shell languages: ```bash, ```sh
  - Generic triple backticks without language treated as shell by default
  - Ignore other languages (```python, ```js, etc.)
- Robust parsing across list items and blockquotes
- Determine current block from cursor using nearest enclosing fences
- Provide block metadata:
  - `start_line`, `end_line`, `lang`, `content`, `file_path`
  - `block_id`: stable identifier computed from `sha1(file_path + start_line + end_line + normalized_content)`
  - `content_hash`: hash of content alone to detect modifications

Association rule: If `content_hash` changes, previous execution association is considered stale per NFR4.

## 5. Session State Model

- Scope: One session per markdown file per Neovim instance
- Structure:
  - `current_working_directory`: starts at markdown file directory
  - `environment_variables`: map seeded from `vim.fn.environ()`; user changes merged
  - `path_separator` and platform specifics derived from `jit.os` / `vim.loop.os_uname()`
- Persistence lifecycle:
  - Created on first execution in a buffer
  - Reset on `:MarkdownRunReset` or buffer close (configurable)
  - Not shared across Neovim instances; cross-instance safety handled at results IO layer

### Capturing environment changes

The child shell cannot directly mutate the parent process. Two complementary strategies:

- Parse-and-apply (fast path):
  - Intercept `cd`, `export VAR=...`, `VAR=value`, and `PATH` modifications before launching
  - Update session state accordingly
  - Run the user command in updated `cwd`/`env`
- Shell-reported delta (accurate path):
  - Wrap user block into a subshell trailer that writes resulting `PWD` and full environment into a temp file after execution, e.g.:
    - `set -a; ( {USER_BLOCK}; status=$?; printf "__MR_PWD__=%s\n" "$PWD"; env -0 > "$STATE_FILE"; exit $status )`
  - After process exit, read `STATE_FILE` and reconcile env vars and `PWD` into the session state
  - Config flag chooses strategy; default hybrid: parse fast path, then reconcile if enabled

Edge cases: ensure we ignore transient variables; optionally maintain an allowlist (e.g., only variables changed by the block compared to baseline snapshot) to limit noise.

## 6. Execution Engine

- API: `execute_block(block: Block, session: Session, opts: ExecOptions) -> ExecResult`
- Uses `vim.fn.jobstart` or `vim.loop.spawn` for asynchronous execution
- Shell: `/bin/sh -c` by default; configurable (`bash`, `zsh`) via option
- stdin: none (NFR2)
- stdout/stderr: collected with line buffering; truncated/redirected for large outputs
- Timeout: default 30s; enforce via timer; send SIGTERM, then SIGKILL if needed
- Exit handling: capture exit code, duration, and environment reconciliation
- Error gating: for sequential and run-all, stop on first non-zero exit unless `force` is set
- Working directory: from session; absolute path resolved from markdown file directory (FR8)

## 7. Results Persistence

### File locations

- Primary JSON sidecar: `<markdown_path>.result` (same directory as markdown)
- Large/binary artifacts directory: `<markdown_path>.results/` (directory)
  - Filenames: `<timestamp>_<block_index>_<short_id>.(out|err|bin)`

### JSON schema (v1)

```json
{
  "version": 1,
  "file": "/abs/path/to/README.md",
  "executions": [
    {
      "id": "uuid-or-ulid",
      "timestamp": "2025-08-05T12:34:56Z",
      "block_id": "sha1(...)",
      "start_line": 120,
      "end_line": 144,
      "lang": "sh",
      "command": "echo hello",
      "exit_code": 0,
      "duration_ms": 42,
      "cwd": "/abs/path",
      "env_delta": {"PATH": "/new:path"},
      "stdout": {"type": "inline", "value": ["hello"]},
      "stderr": {"type": "inline", "value": []},
      "artifacts": {"stdout_file": null, "stderr_file": null, "binary_files": []},
      "content_hash": "sha1(block-content)"
    }
  ]
}
```

- For outputs > 100 lines (FR9) or binary detected (FR10), `stdout`/`stderr` use `{ "type": "file", "path": "..." }` and content is saved to artifacts
- `env_delta` is the diff compared to session state at start of execution

### Concurrency & atomicity

- Cross-instance safety (NFR3): guarded by lock files and atomic writes
  - Lock file: `<markdown_path>.result.lock`
  - Acquire via `fs_open(O_CREAT|O_EXCL)`, retry with backoff and limit
  - Read-merge-write: load current JSON, append new execution, write to temp file, `fs_rename` atomically over original
  - If lock acquisition fails repeatedly, fallback to append queue file `<markdown_path>.result.queue` and prompt user

### Cleanup

- Configurable retention policy for artifacts (FR3.2.6): keep last N or days; background cleanup on open

## 8. UI & UX Integration

### Virtual text indicators (FR5, 2.5)

- Use extmarks to place status indicators at block start line
- States: not executed, executing, success, failed
- Symbols/styles configurable; defaults e.g.: `○`, `…`, `✓`, `✗`
- Persist across sessions by reconstructing indicators from results file on buffer open

### Popups (3.1)

- Floating window shows recent result for current block
- Content: command, exit code, duration, cwd, truncated stdout/stderr + hint to open artifacts
- Dismiss on `<Esc>` or cursor move

### Quickfix (3.3)

- On failure, push entry: file, line range, command summary, stderr first lines
- Provide `:MarkdownRunQuickfix` to open most recent list

### Navigation

- `:MarkdownRunOpenResult` jumps to corresponding entry in results file
- `:MarkdownRunOpenArtifact` opens large output file

## 9. Commands, Keymaps, and Config

### Commands

- `:MarkdownRun` – execute current block (2.1)
- `:MarkdownRunNext` – execute next unexecuted block (2.3)
- `:MarkdownRunAll` – execute all blocks sequentially (2.4)
- `:MarkdownRunEnv [print <VAR>]` – show session cwd/env or value under cursor (FR15)
- `:MarkdownRunReset` – reset session state (2.2.5)
- `:MarkdownRunToggleIndicators` – toggle virtual text (2.5.6)
- `:MarkdownRunQuickfix` – open quickfix with recent errors (3.3.4)

### Default keymaps (customizable)

- `<leader>rm` → `:MarkdownRun`
- `<leader>rn` → `:MarkdownRunNext`
- `<leader>ra` → `:MarkdownRunAll`
- `<leader>re` → `:MarkdownRunEnv`

### Configuration (Lua)

```lua
require('markdownrun').setup({
  shell = '/bin/sh',            -- '/bin/bash', 'zsh', ...
  timeout_ms = 30000,
  indicator = {
    enabled = true,
    symbols = { idle = '○', running = '…', ok = '✓', err = '✗' },
    hl = { idle = 'Comment', running = 'WarningMsg', ok = 'DiagnosticOk', err = 'DiagnosticError' },
  },
  results = {
    inline_limit_lines = 100,
    base_dir = nil,            -- nil => alongside markdown; or set to custom path
    retention = { max_days = nil, max_entries = nil },
  },
  env_capture = {
    strategy = 'hybrid',       -- 'parse', 'shell', 'hybrid'
    allowlist = nil,           -- nil => auto-diff; or list of var prefixes
  },
  run_all = { stop_on_error = true, show_progress = true },
})
```

## 10. Core Flows

### Manual execution (FR1, 2.1)

1. Identify current block; validate shell type
2. Render `running` indicator
3. Prepare session cwd/env; apply parse-and-apply deltas
4. Launch async shell with wrapped command if env capture enabled
5. Stream output; enforce timeout
6. On exit: finalize indicators, build `ExecResult`, persist JSON + artifacts, show popup, quickfix on failure

### Next block (2.3)

1. From cursor, scan forward for next shell block
2. Skip already executed (based on `block_id` in results) unless forced
3. Move cursor, then run Manual execution flow

### Execute all (2.4)

1. Enumerate blocks in order
2. For each, run Manual flow; abort on first non-zero if `stop_on_error`
3. Summarize successes/failures; show popup summary

## 11. Error Handling & Timeouts

- Distinguish timeout vs non-zero exit code in UI and quickfix
- Graceful cancellation: user can send `:MarkdownRunCancel` for current job; engine sends SIGTERM then SIGKILL
- When results write fails: retry with exponential backoff; surface notification

## 12. Performance Considerations

- Use buffered appends and early truncation for large outputs
- Avoid full file scans on every action: maintain in-memory index of block ranges and IDs; refresh on buffer change events (TextChanged)
- Debounce indicator refresh

## 13. Testing Strategy (per PRD)

- Unit tests:
  - Markdown parsing and block detection
  - Block ID and staleness detection
  - Env parse fast-path and reconciliation merge
  - Results IO: locking, merge, retention
- Integration tests:
  - Async execution with timeout behavior
  - Virtual text markers and popup rendering (headless nvim)
  - Quickfix population
- Manual test files with varied markdown structures

## 14. Security & Safety Notes

- No command blacklisting or guardrails by design (NFR6)
- Make this explicit in docs; recommend using in controlled environments
- Never execute blocks without explicit user action

## 15. Extensibility

- Language adapters: future support for other block types via adapter registry
- Results schema versioning with migration hooks
- Pluggable artifact storage backends (local disk now; future: tmpdir or user path)

## 16. Open Questions

- Exact locking strategy on Windows (if support desired)
- Default shell: `sh` vs `bash` for better export semantics
- Telemetry or basic metrics (out of scope per PRD but recommended in docs)

---

This design fulfills the PRD’s functional and non-functional requirements while adhering to Neovim best practices and providing a clear path for future enhancements.