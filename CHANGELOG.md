# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.1] - 2026-03-04

### Fixed

- Memory leak in installed extension debugger config: `adapter_transport` string leaked on every `resolveByExtension` call for extensions with a debugger section (e.g. 71 leaks for 71 Elixir files)
- Sub-slice allocation size mismatch in manifest parsing for `adapter_args`, `boundary_markers`, and `language_names` arrays

## [0.5.0] - 2026-03-04

### Added

- `mem:bootstrap` command to scan project files and populate memory from codebase
- TUI progress display for bootstrap with concurrency, per-file activity, and brain URL
- Cost warning and confirmation prompt before running bootstrap
- Per-file timeout for bootstrap (default 10 minutes)
- Auto-clear stale checkpoint when brain is empty
- Reaper process to kill orphaned children on parent SIGKILL
- Ctrl+C watchdog thread for reliable bootstrap cancellation
- Graceful signal termination of spawned agent processes
- Three-mode autonomous debugging subagent (inspect/trace/diagnose)
- `step_over_inspect` action for stepping with expression evaluation in a single call
- Module launch mode for debugging (e.g., `python -m pytest`)
- Native DWARF debug engine for Go
- JavaScript and Java debug adapters with DAP proxy improvements
- TypeScript source-map debugging support
- Exception breakpoint as safety net in inspect/trace debug modes
- Memory sub-agent prompt with recall, consolidate, and maintenance modes
- `cog_code_explore` single-call complete symbol exploration
- Query alternation with `|` separator for multi-name symbol search
- Agent selection menu for bootstrap
- Debug benchmark: 20 test programs across 4 languages
- SWE-bench Pro integration (Docker-based, replacing SWE-bench Lite)
- SWE-agent integration with debugger-subagent variant

### Changed

- Rewrote debug subagent from puppet model to autonomous agent
- Distilled subagent output before returning to primary agent
- Compressed PROMPT.md from 287 to 107 lines
- Unified language dispatch into extension-driven architecture
- Watcher events filtered using index patterns from settings.json
- Removed JSON stdout output from `cog code:index`
- Rounded cost display to nearest cent

### Fixed

- Concurrent bootstrap progress resetting to 0 on resume
- Headless debugging: detached process spawning, clean shutdown, terminal prevention
- Subagent no-output bug with JSON parsing and MCP log fallback
- Shell operator precedence in debugpy uv fallback
- Session status bug in step_over_inspect
- Thread safety: added mutexes to Runtime, DebugServer, StdoutWriter, and MCP server
- Heap-allocated debug sessions for pointer stability across concurrent access

## [0.4.0] - 2026-02-19

### Added

- File system watcher for automatic SCIP index maintenance (FSEvents on macOS, inotify on Linux)
- Index updates automatically when files are created, modified, deleted, or renamed — no manual re-indexing needed

### Changed

- All MCP tool names normalized to `cog_<feature>_<snake_case>` format (e.g., `cog_code_query`, `cog_mem_recall`, `cog_debug_launch`)
- Improved tool descriptions for all 38 MCP tools with actionable guidance for agents
- Added parameter descriptions to debug tool schemas (session_id, action enums, frame_id, variable_ref, etc.)
- Remote memory tool descriptions now rewrite `cog_*` references to `cog_mem_*` for consistency
- Agent prompt updated with `<cog:code>` section documenting auto-indexing and query rules

### Removed

- `cog_code_index` MCP tool — indexing is CLI-only (`cog code:index`), watcher handles ongoing maintenance
- `cog_code_remove` MCP tool — watcher handles file deletions automatically

## [0.3.0] - 2026-02-19

### Changed

- Command namespace separator changed from `/` to `:` (e.g., `code/index` → `code:index`)
- `code:index` now requires explicit glob patterns instead of defaulting to `**/*`
- CLI help (`cog`, `cog code`, `cog debug`) now shows built-in and installed language extensions
- `cog debug` help filters to only show extensions with debugger support
- Agent prompt updated with category-specific emoji conventions and debugger workflow

### Removed

- `cog update` command (prompt updates are now version-aligned with the CLI)
- Legacy `cog://` URL resolution from config
- MCP migration notices from `cog code` and `cog debug` help output

### Fixed

- Multiple `printErr` calls causing garbled output when stderr is buffered — combined into single writes

### Performance

- Debug daemon: cached CU/FDE/abbreviation tables, binary search replacing linear scans
- Debug daemon: cached macOS thread port, dual unwinding strategy, CU hint pass-through
- Dashboard TUI: buffered writer with flicker-free rendering and connection backoff
- MCP server: static response strings, CLI response extraction without full parse-reserialize
- Runtime MCP proxy with auto-allow tool permissions

## [0.2.2] - 2026-02-18

### Fixed

- External indexers now invoked per-file instead of per-project, fixing glob pattern expansion for `code:index` with SCIP extensions

### Changed

- Updated README to reflect current debug daemon architecture (`debug:send`, dashboard, status, kill, sign)

## [0.2.1] - 2026-02-17

### Fixed

- Memory leak in `resolveByExtension` when indexing projects with installed extensions

## [0.2.0] - 2026-02-17

### Changed

- Consolidated 38 `debug:send_*` commands into single `debug:send <tool>` with proper CLI flags and positional arguments instead of raw JSON

### Fixed

- `cog install` now updates existing extensions via `git pull` instead of failing when the extension directory already exists

## [0.1.0] - 2026-02-17

### Added

- `--version` flag and version display in `--help` output

## [0.0.1] - 2026-02-17

### Added

- Associative memory system with engrams, synapses, and spreading activation recall
- Memory lifecycle commands: `mem:learn`, `mem:recall`, `mem:reinforce`, `mem:flush`, `mem:deprecate`
- Bulk operations: `mem:bulk-learn`, `mem:bulk-recall`, `mem:bulk-associate`
- Graph inspection: `mem:get`, `mem:connections`, `mem:trace`, `mem:stats`, `mem:orphans`, `mem:connectivity`, `mem:list-terms`
- Memory maintenance: `mem:stale`, `mem:verify`, `mem:refactor`, `mem:update`, `mem:unlink`
- Cross-brain knowledge sharing with `mem:meld`
- Short-term memory consolidation with `mem:list-short-term`
- SCIP-based code intelligence with tree-sitter indexing
- Code index commands: `code:index`, `code:query`, `code:status`
- Index-aware file mutation commands: `code:edit`, `code:create`, `code:delete`, `code:rename`
- Symbol query modes: `--find` (definitions), `--refs` (references), `--symbols` (file symbols), `--structure` (project overview)
- Built-in tree-sitter grammars for C, C++, Go, Java, JavaScript, Python, Rust, TypeScript, and TSX
- Language extension system with `cog install` for third-party SCIP indexers
- Debug daemon with Unix domain socket transport (`debug:serve`)
- Debug dashboard for live session monitoring (`debug:dashboard`)
- Debug management commands: `debug:status`, `debug:kill`, `debug:sign`
- macOS code signing with debug entitlements for `task_for_pid`
- Interactive project setup with `cog init`
- System prompt and agent skill updates with `cog update`
- Branded TUI with cyan accent, box-drawing logo, and styled help output
- Cross-compiled release builds for darwin-arm64, darwin-x86\_64, linux-arm64, linux-x86\_64
- GitHub Actions workflow for automated releases and Homebrew tap updates
- Homebrew installation via `trycog/tap/cog`

[0.5.1]: https://github.com/trycog/cog-cli/releases/tag/v0.5.1
[0.5.0]: https://github.com/trycog/cog-cli/releases/tag/v0.5.0
[0.4.0]: https://github.com/trycog/cog-cli/releases/tag/v0.4.0
[0.3.0]: https://github.com/trycog/cog-cli/releases/tag/v0.3.0
[0.2.2]: https://github.com/trycog/cog-cli/releases/tag/v0.2.2
[0.2.1]: https://github.com/trycog/cog-cli/releases/tag/v0.2.1
[0.2.0]: https://github.com/trycog/cog-cli/releases/tag/v0.2.0
[0.1.0]: https://github.com/trycog/cog-cli/releases/tag/v0.1.0
[0.0.1]: https://github.com/trycog/cog-cli/releases/tag/v0.0.1
