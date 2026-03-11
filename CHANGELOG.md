# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.14.0] - 2026-03-11

### Added

- A Code Intelligence language matrix in the README covering all built-in languages plus the repo-supported Zig, Ruby, and Elixir extensions

### Changed

- `cog init` now generates stronger, host-aware Cog specialist support across supported agents, including config-scoped guidance, workflow runbooks, read-only specialists, and tighter tool scoping where each host allows it
- Roo Code modes now include native mode-group restrictions for code query, debug, and memory specialists
- Amp specialist support now installs as proper skill directories and the supported-agent matrix reflects the stronger per-host integration model
- Indexing progress output now reports more detailed progress and memory information during code intelligence runs

### Fixed

- Gemini and GitHub Copilot specialist definitions now expose the intended Cog code-intel, debug, and memory tool sets instead of relying on weaker generic wiring

## [0.13.0] - 2026-03-10

### Changed

- Most `cog_debug_*` MCP tools now return text-first summaries that agents can read directly instead of JSON embedded in MCP text responses
- Cog-first OpenCode workflows now require memory recall before broad indexed or grep-based exploration, with stricter guidance around durable memory writes

### Removed

- `.opencode/` agent prompt files are no longer tracked in the repository; they remain generated and ignored local integration artifacts

### Fixed

- Debug MCP tool errors now surface as plain text instead of JSON objects wrapped inside text responses

## [0.12.0] - 2026-03-10

### Added

- Negative glob patterns for `cog code:index`, including support for excluding generated directories like Phoenix `priv/static` assets
- Debug-only indexing instrumentation with per-file phase timing and resource-usage snapshots across tree-sitter and bulk external indexers

### Changed

- `cog code:index` help now documents `!pattern` exclusions with a Phoenix umbrella example

## [0.11.0] - 2026-03-10

### Added

- Bulk external indexer support via `{files}` argv expansion, letting language extensions process many files in one invocation
- Structured external indexer progress events so `cog code:index` can advance file-by-file progress while bulk extension batches are still running

### Changed

- Extension indexing now groups files per indexer and invokes external SCIP tools in bulk instead of spawning one process per file
- Extension author docs and CLI help now describe the bulk `{files}` contract and stderr progress event protocol

### Fixed

- Remove per-file parser recreation during indexing; tree-sitter parsers are designed to be reused across files via `ts_parser_set_language`, eliminating unnecessary allocation overhead on large projects

## [0.10.2] - 2026-03-10

### Fixed

- Disable Zig's UBSan (`-fno-sanitize=undefined`) for tree-sitter C code to prevent trap instructions in ReleaseSafe builds on Linux

### Added

- Dockerfile.omarchy64 for native arm64 Linux development containers

### Changed

- Dockerfile.omarchy now installs official upstream Zig instead of distro-packaged Zig

## [0.10.1] - 2026-03-10

### Fixed

- Rebuilt release artifacts with the release-build option wiring needed for the embedded OpenCode override plugin
- Refreshed the published Linux x86_64 tarball so installers receive the correct ELF binary instead of a stale cross-platform artifact

## [0.10.0] - 2026-03-09

### Added

- `cog_code_query` architecture modes for `imports`, `contains`, `calls`, `callers`, and `overview`
- Repo-level architecture summaries in `cog_code_explore`, including entrypoint, subsystem, and import fan-out context
- Embedded OpenCode override plugin to enforce Cog-first code exploration guidance during setup

### Changed

- `cog_code_explore` now returns optional relationship and architecture sections alongside symbol snippets and references
- Cog-first prompts, sub-agent instructions, and docs now steer repository analysis toward batched index queries instead of repeated file-by-file exploration
- `cog init` now prompts before overwriting generated files and can show diffs for pending replacements

### Fixed

- Restored stable `cog_` MCP tool naming in prompts, references, and benchmark configs after an accidental prefix regression

## [0.9.1] - 2026-03-09

### Changed

- `cog_code_query` and `cog_code_explore` now return compact plain-text results that agents can read directly, including symbol locations, snippets, references, and file outlines

### Fixed

- Hardened `cog code:index` against tree-sitter parser state leaks by recreating the parser per indexed file, preventing Linux x86_64 illegal-instruction crashes in mixed-language repos
- Added offline indexing integration coverage to CI so real `cog code:index` runs on each release architecture, including x86_64 Ubuntu

## [0.9.0] - 2026-03-09

### Added

- Built-in document and config indexing for Markdown, MDX, reStructuredText, AsciiDoc, YAML, TOML, JSON, and JSONC
- Dedicated MDX tree-sitter indexing with heading, exported symbol, and JSX component captures

### Changed

- `cog init` now writes richer OpenCode integration config, including local plugin wiring alongside MCP setup
- Built-in language support now covers source code, documentation, and structured config files without requiring extensions

## [0.8.2] - 2026-03-08

### Removed

- x86_64 macOS release binary and CI runner (Apple Silicon only going forward)

## [0.8.1] - 2026-03-08

### Changed

- CI now tests on all 4 release architectures (x86_64/aarch64 Linux, x86_64/aarch64 macOS)
- README updated to document local SQLite memory backend and new brain config format

### Fixed

- SIGILL crash on x86_64 Linux in release builds: removed `-DNDEBUG` from tree-sitter C flags which silenced a safety assertion, allowing undefined behavior that LLVM compiled to an illegal instruction
- Memory leak in `freeExtension`: `program_field` and `args_field` were not freed for DAP debug configs

## [0.8.0] - 2026-03-08

### Added

- Local SQLite memory backend — `cog init` now offers Local (SQLite) vs Hosted (trycog.ai) as the memory backend
- Local memory tools: learn, recall, associate, deprecate, refactor, update, connectivity, and more — all backed by a local `.cog/brain.db`
- `mem:info` and `mem:upgrade` CLI commands
- SQLite wrapper module and embedded SQLite 3.47.2
- Debug log now writes diagnostic header (version, OS, arch, zig version, command line) on each invocation
- Signal handlers capture SIGILL/SIGSEGV/SIGBUS/SIGABRT crashes with stack traces to `.cog/cog.log`
- Containerfile for Alpine-based dev container with PostgreSQL, Elixir, Zig, and swap support

### Changed

- Debug log truncates on each command invocation instead of appending
- Brain config uses flat string format (e.g. `"file:.cog/brain.db"`) instead of nested object
- README clarifies memory benchmarks are for the hosted brain

### Fixed

- Memory leak in `toolConnectivity` BFS visited map
- Release workflow includes changelog body in GitHub releases

## [0.7.4] - 2026-03-07

### Fixed

- Linux CI build failure: extracted shared debug types (`WaitResult`, `RegisterState`, `FloatRegisterState`) into platform-neutral `process_types.zig` so Linux no longer transitively imports macOS-only Mach headers
- Release workflow now gates on CI tests passing on both Ubuntu and macOS before cutting a release

## [0.7.3] - 2026-03-07

### Added

- CI workflow: runs `zig build test` on Ubuntu and macOS for push/PR to main
- Indexer tests for all 9 supported languages (TypeScript, TSX, Java, Rust, C, C++, plus parser-reuse and Flow JS)

### Fixed

- Illegal instruction crash in `code:index` on Linux when tree-sitter assertion fires during error recovery (`-DNDEBUG` added to C compilation flags)

## [0.7.2] - 2026-03-06

### Changed

- Installed extensions in `--help` show language name (e.g. "elixir") instead of repo name ("cog-elixir")
- Version defined only in `build.zig.zon`; `build.zig` reads it via `@import`

### Fixed

- Ctrl+C during `mem:bootstrap` could orphan a newly spawned agent if it hadn't registered yet

## [0.7.1] - 2026-03-06

### Fixed

- Memory leak: settings not freed after checking debug flag on startup

## [0.7.0] - 2026-03-06

### Added

- `--debug` global CLI flag writes timestamped diagnostic logs to `.cog/cog.log`
- `"debug": true` in settings.json enables debug logging without the CLI flag
- Debug log calls across the codebase: HTTP requests, config resolution, index locking, MCP tool dispatch, subprocess management, file watching, and more

## [0.6.1] - 2026-03-06

### Changed

- Bootstrap prompt refined: 4 dimensions (from 6), concrete example, predicate quality guidance, lower volume targets
- System prompt (PROMPT.md) updated with term quality examples and predicate strength recommendations
- `mem:bootstrap` now requires `.cog/MEM_BOOTSTRAP.md` files from `cog init` instead of falling back to embedded copies

### Fixed

- Illegal instruction crash in `code:index` when parsing JavaScript after other grammars (missing `ts_parser_reset`)
- O(n²) memory allocation in `code:index` for projects with 1000+ files (grow-by-1 document array replaced with ArrayList)
- Extension manifest re-read from disk for every file during indexing (now cached by file extension)
- Memory leak: `language_names` not freed in `listInstalled` (leaked on `cog --help` with installed extensions)

## [0.6.0] - 2026-03-06

### Added

- Configurable model for `mem:bootstrap` via `memory.model` in settings.json
- Bootstrap files filtered through `code.index` patterns in settings.json

### Changed

- Rewrote bootstrap extraction prompt: 6 optional dimensions (from 5 mandatory), 7 categories (from 14), explicit volume guidance
- Removed "Connect Orphans" step from bootstrap association prompt (expensive, marginal value)
- Updated README and help text with `--concurrency`, `--timeout`, and model override documentation

### Fixed

- Ctrl+C during concurrent bootstrap now kills all spawned agents (was only killing one)
- `cog init` no longer overwrites `memory.model` and other sibling keys in settings.json
- Memory leak: freed `program_field` and `args_field` in debugger alloc cleanup
- OOM during bootstrap by not fully decoding SCIP index
- DAP proxy for adapters that don't support `stopOnEntry` (e.g. ElixirLS)

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

[0.14.0]: https://github.com/trycog/cog-cli/releases/tag/v0.14.0
[0.8.2]: https://github.com/trycog/cog-cli/releases/tag/v0.8.2
[0.8.1]: https://github.com/trycog/cog-cli/releases/tag/v0.8.1
[0.8.0]: https://github.com/trycog/cog-cli/releases/tag/v0.8.0
[0.7.4]: https://github.com/trycog/cog-cli/releases/tag/v0.7.4
[0.7.3]: https://github.com/trycog/cog-cli/releases/tag/v0.7.3
[0.7.2]: https://github.com/trycog/cog-cli/releases/tag/v0.7.2
[0.7.1]: https://github.com/trycog/cog-cli/releases/tag/v0.7.1
[0.7.0]: https://github.com/trycog/cog-cli/releases/tag/v0.7.0
[0.6.1]: https://github.com/trycog/cog-cli/releases/tag/v0.6.1
[0.6.0]: https://github.com/trycog/cog-cli/releases/tag/v0.6.0
[0.5.1]: https://github.com/trycog/cog-cli/releases/tag/v0.5.1
[0.5.0]: https://github.com/trycog/cog-cli/releases/tag/v0.5.0
[0.4.0]: https://github.com/trycog/cog-cli/releases/tag/v0.4.0
[0.3.0]: https://github.com/trycog/cog-cli/releases/tag/v0.3.0
[0.2.2]: https://github.com/trycog/cog-cli/releases/tag/v0.2.2
[0.2.1]: https://github.com/trycog/cog-cli/releases/tag/v0.2.1
[0.2.0]: https://github.com/trycog/cog-cli/releases/tag/v0.2.0
[0.1.0]: https://github.com/trycog/cog-cli/releases/tag/v0.1.0
[0.0.1]: https://github.com/trycog/cog-cli/releases/tag/v0.0.1
[0.13.0]: https://github.com/trycog/cog-cli/releases/tag/v0.13.0
[0.12.0]: https://github.com/trycog/cog-cli/releases/tag/v0.12.0
[0.11.0]: https://github.com/trycog/cog-cli/releases/tag/v0.11.0
[0.10.2]: https://github.com/trycog/cog-cli/releases/tag/v0.10.2
[0.10.1]: https://github.com/trycog/cog-cli/releases/tag/v0.10.1
[0.10.0]: https://github.com/trycog/cog-cli/releases/tag/v0.10.0
[0.9.1]: https://github.com/trycog/cog-cli/releases/tag/v0.9.1
[0.9.0]: https://github.com/trycog/cog-cli/releases/tag/v0.9.0
