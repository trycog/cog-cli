# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-02-17

### Changed

- Consolidated 38 `debug/send_*` commands into single `debug/send <tool>` with proper CLI flags and positional arguments instead of raw JSON

### Fixed

- `cog install` now updates existing extensions via `git pull` instead of failing when the extension directory already exists

## [0.1.0] - 2026-02-17

### Added

- `--version` flag and version display in `--help` output

## [0.0.1] - 2026-02-17

### Added

- Associative memory system with engrams, synapses, and spreading activation recall
- Memory lifecycle commands: `mem/learn`, `mem/recall`, `mem/reinforce`, `mem/flush`, `mem/deprecate`
- Bulk operations: `mem/bulk-learn`, `mem/bulk-recall`, `mem/bulk-associate`
- Graph inspection: `mem/get`, `mem/connections`, `mem/trace`, `mem/stats`, `mem/orphans`, `mem/connectivity`, `mem/list-terms`
- Memory maintenance: `mem/stale`, `mem/verify`, `mem/refactor`, `mem/update`, `mem/unlink`
- Cross-brain knowledge sharing with `mem/meld`
- Short-term memory consolidation with `mem/list-short-term`
- SCIP-based code intelligence with tree-sitter indexing
- Code index commands: `code/index`, `code/query`, `code/status`
- Index-aware file mutation commands: `code/edit`, `code/create`, `code/delete`, `code/rename`
- Symbol query modes: `--find` (definitions), `--refs` (references), `--symbols` (file symbols), `--structure` (project overview)
- Built-in tree-sitter grammars for C, C++, Go, Java, JavaScript, Python, Rust, TypeScript, and TSX
- Language extension system with `cog install` for third-party SCIP indexers
- Debug daemon with Unix domain socket transport (`debug/serve`)
- Debug dashboard for live session monitoring (`debug/dashboard`)
- Debug management commands: `debug/status`, `debug/kill`, `debug/sign`
- macOS code signing with debug entitlements for `task_for_pid`
- Interactive project setup with `cog init`
- System prompt and agent skill updates with `cog update`
- Branded TUI with cyan accent, box-drawing logo, and styled help output
- Cross-compiled release builds for darwin-arm64, darwin-x86\_64, linux-arm64, linux-x86\_64
- GitHub Actions workflow for automated releases and Homebrew tap updates
- Homebrew installation via `trycog/tap/cog`

[0.2.0]: https://github.com/trycog/cog-cli/releases/tag/v0.2.0
[0.1.0]: https://github.com/trycog/cog-cli/releases/tag/v0.1.0
[0.0.1]: https://github.com/trycog/cog-cli/releases/tag/v0.0.1
