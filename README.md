<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset=".github/logo-light.svg">
  <img alt="COG" src=".github/logo-light.svg" width="248">
</picture>

**Memory, code intelligence, and debugging for AI agents.**

[Benchmarks](#benchmarks) · [Install](#install) · [Setup](#setup) · [How It Works](#how-it-works) · [Memory](#memory) · [Code Intelligence](#code-intelligence) · [Debug](#debug) · [Extensions](#extensions) · [Diagnostics](#diagnostics)

</div>

---

## Why Cog?

AI coding can feel fast but it's still limited by suboptimal methods and tooling. Your agent doesn't remember the architectural decisions from last week. It can't look up where a function is defined without grepping through your entire codebase. When something breaks it can't set a breakpoint, inspect a variable, or step through the code. It's stuck adding print statements and guessing.

We built Cog to fix that. It's a single native binary that runs as an MCP server and gives your agent three capabilities it doesn't have on its own:

1. **Persistent memory** that carries across sessions. Your agent learns your architecture, remembers past bugs, and builds knowledge that compounds over time. Memory can run locally (SQLite) or hosted on [trycog.ai](https://trycog.ai) for team sharing.
2. **Structured code intelligence** that returns definitions, references, and symbols in one tool call instead of 15 rounds of grep and file reads.
3. **An interactive debugger** your agent drives directly. Breakpoints, variable inspection, stepping through code. No more print statement debugging.

## Benchmarks

### Memory Recall Benchmark (hosted)

We benchmarked Cog's hosted memory recall against Sonnet 4.5 doing active code exploration across 114 questions about a production codebase. The code exploration baseline used no prior model knowledge and answered every question through real-time file reads, grep, and glob. Cog answered from a knowledge graph built by an exhaustive bootstrap prompt before the benchmark started. These benchmarks use the hosted brain on [trycog.ai](https://trycog.ai).

| Metric | Cog | Code Exploration | Delta |
|--------|-----|------------------|-------|
| Accuracy | 86.0% | 89.5% | -3.9% |
| Adequate answers (>=50%) | 93.9% | 89.9% | **+4.4%** |
| Duration | 24m 39s | 61m 39s | **-60%** |
| Total tokens | 548.4K | 46.6M | **-98.8%** |
| Tokens per question | 4.6K | 391.2K | **-98.8%** |


Cog answers nearly as many questions correctly while using 98.8% fewer tokens and finishing in less than half the time. The adequate answer rate is actually higher because memory recall surfaces connected context that code exploration misses.

### Code Intelligence Benchmark

We benchmarked Cog's code intelligence against standard agent tools (grep, glob, read) on the React codebase:

| Task | Cog | Without Cog | Speedup | Token Savings |
|------|-----|-------------|---------|---------------|
| Find `createElement` definition | 3.7s, 1 call, 1.4K tokens | 34.1s, 15 calls, 78.4K tokens | **9.2x faster** | **98%** |
| Find `useState` references | 9.3s, 2 calls, 2.5K tokens | 27.4s, 15 calls, 24.1K tokens | **2.9x faster** | **90%** |
| List `ReactFiberWorkLoop` symbols | 10.8s, 1 call, 4.0K tokens | 35.7s, 13 calls, 25.2K tokens | **3.3x faster** | **84%** |
| Find `Component` class | 14.3s, 5 calls, 7.4K tokens | 28.9s, 15 calls, 28.1K tokens | **2.0x faster** | **74%** |

On average, **2.8x faster with 89% fewer tokens**.

## Install

Linux:

```sh
curl -fsSL https://trycog.ai/cli/install | bash
```

macOS:

```sh
brew install trycog/tap/cog
```

<details>
<summary>Build from source</summary>

Requires [Zig 0.15.2+](https://ziglang.org/download/).

```sh
git clone https://github.com/trycog/cog-cli.git
cd cog-cli
zig build
# Binary at zig-out/bin/cog
```

</details>

## Setup

```sh
cog init
```

That's it. The interactive setup walks you through everything:

1. **Memory backend**: local (SQLite) or hosted ([trycog.ai](https://trycog.ai))
2. **Agent selection**: pick which AI coding agents you use
3. **Tool permissions**: optionally auto-allow all Cog tools so your agent doesn't prompt you on every call

For each agent you select, `cog init` writes the system prompt, configures the MCP server connection, deploys specialized sub-agents or the closest host-native specialist surface, installs runtime policy assets where the host supports them, and, where available, auto-allows Cog tool permissions. It also writes `.cog/client-context.json` plus a local `.cog/.gitignore` for generated Cog artifacts, so the local MCP runtime can identify the installed host integrations and compile richer hosted-memory context without changing your repo-root ignore rules. Agent menus start alphabetically and then adapt over time based on your global selection history in `~/.config/cog/agent-selection-counts.json`.

### Supported agents

| Agent | MCP Config | Sub-Agents | Tool Permissions | Cog-First Override | Context Packaging | Memory Write Enrichment |
|-------|------------|:----------:|------------------|--------------------|------------------|-------------------------|
| Amp | `.amp/settings.json` | Yes | Auto-allow | Medium runtime plugins + sub-agent permissions | Yes | Runtime reminders |
| Claude Code | `.mcp.json` | Yes | Auto-allow | Hard sub-agent allowlist + hooks + project MCP approval | Yes | Hook/config reminders |
| Cursor | `.cursor/mcp.json` | | | Soft AGENTS.md + rules | Yes | Prompt guidance |
| Gemini CLI | `.gemini/settings.json` | Yes | Auto-allow | Medium hooks + sub-agent tool scoping | Yes | Hook/config reminders |
| GitHub Copilot | `.vscode/mcp.json` | Yes | | Soft specialist tool scoping | Yes | Prompt guidance |
| Goose | Global config | Yes | | Soft skill guidance | Yes | Prompt guidance |
| OpenAI Codex CLI | `.codex/config.toml` | Yes | | Soft shared-config specialist guidance | Yes | Prompt guidance |
| OpenCode | `opencode.json` | Yes | Auto-allow | Medium runtime plugins + sub-agent permissions | Yes | Runtime reminders |
| Pi | `.pi/mcp.json` | Yes | | Medium extension hooks + skills | Yes | Runtime reminders |
| Roo Code | `.roo/mcp.json` | Yes | | Medium native mode groups | Yes | Prompt guidance |
| Windsurf | Global config | Yes | | Soft skills + rules | Yes | Prompt guidance |

`cog init` now installs Cog-first code exploration guidance everywhere. Stronger enforcement depends on what each host agent can actually express: Claude Code now combines hard-scoped subagents with project hooks and a memory-completion stop gate, Gemini adds repo-local hook enforcement on top of sub-agent tool scoping, Amp ships an experimental workspace plugin with runtime memory reminders, OpenCode uses runtime plugins for code, debug, and memory workflow enforcement, Pi uses its extension system with `tool_call` hooks for runtime enforcement plus skills for specialist delegation, Windsurf and Goose use native skill folders, Roo can scope native mode groups, and Cursor falls back to AGENTS.md plus Cursor rules because Cursor does not currently expose a documented repo-local custom-subagent file format.

Hosted memory writes now pass through a client-side context compiler in `cog-cli`. When the remote brain supports enriched write APIs, Cog attaches trusted local provenance such as workspace, repo identity, MCP session, host integration, recent code/debug evidence, and write-reason hints before sending the write upstream. Legacy hosted servers still receive the original tool calls unchanged.

For hosts with runtime support, `cog init` also installs repo-local enforcement assets:

- Claude Code: `.claude/hooks/cog-pretooluse.sh`, `.claude/hooks/cog-stop-memory.sh`
- Gemini CLI: `.gemini/hooks/cog-before-tool.sh`
- Amp: `.amp/plugins/cog.ts` (experimental)
- OpenCode: `.opencode/plugins/*`
- Pi: `.pi/extensions/cog.ts`

### Host capability notes

| Capability | What it means |
|------------|---------------|
| Policy enforcement | How strongly the host can steer or block non-Cog workflows |
| Context packaging | Whether hosted memory writes get client-generated provenance from `cog-cli` |
| Memory write enrichment | Whether the host also gets prompt, hook, or plugin guidance to encourage rationale-rich architectural memory |

| Host class | Policy enforcement | Context packaging | Memory write enrichment |
|-----------|--------------------|------------------|-------------------------|
| Claude Code | Hard sub-agent scoping + advisory hook | Yes, via `cog-cli` hosted write envelopes | Hook advisories + scoped memory specialist |
| Gemini CLI | Medium hook/config scoping | Yes, via `cog-cli` hosted write envelopes | Hook advisories + scoped memory specialist |
| OpenCode | Medium runtime plugin enforcement | Yes, via `cog-cli` hosted write envelopes | Runtime plugin reminders + memory specialist |
| Amp | Medium permissions + experimental plugin | Yes, via `cog-cli` hosted write envelopes | Plugin advisories + memory skill |
| Pi | Medium extension hook enforcement | Yes, via `cog-cli` hosted write envelopes | Extension advisories + memory skill |
| Cursor / Copilot / Codex / Roo | Prompt or host-native guidance only | Yes, via `cog-cli` hosted write envelopes | Prompt-level rationale and memory-quality guidance |
| Goose / Windsurf | Portable or host-native skills + prompt guidance | Yes, via `cog-cli` hosted write envelopes | Prompt-level rationale and memory-quality guidance |

---

## How It Works

Cog runs as an [MCP server](https://modelcontextprotocol.io/) over stdio. Your AI agent connects to it and discovers tools at runtime. You don't type Cog commands yourself. Your agent calls them through MCP.

```
Your Agent  <->  MCP (stdio)  <->  cog mcp
                                     |-- Memory (local SQLite or trycog.ai)
                                     |-- Code Intelligence (local SCIP index)
                                     |-- Debug (local daemon)
```

Tool families your agent discovers:

- `cog_mem_*` for memory operations (when configured)
- `cog_code_*` for code intelligence (query, explore, index status)
- `cog_debug_*` for the debugger (36 tools: launch, breakpoints, stepping, inspection, and more)

### Sub-agents

For hosts that support specialist delegation surfaces, `cog init` deploys code-query, debug, and memory specialists as sub-agents, skills, or role configs that your primary agent can delegate to:

- **cog-code-query** — code exploration via the SCIP index. Finds definitions, references, and symbols in a single call.
- **cog-debug** — autonomous hypothesis-driven debugging. Sets breakpoints, inspects variables, steps through code, and reports findings.
- **cog-mem** — memory lifecycle management. Handles recall, consolidation, and maintenance of your agent's knowledge graph.
- **cog-mem-validate** — post-task memory validation. Consolidates short-term memories, reinforces validated knowledge, and flushes incorrect entries.

These specialists keep the primary agent's context clean by offloading specialized work.

---

## Memory

Your agent gets a persistent knowledge graph. It learns concepts, links them with typed relationships, and recalls them using spreading activation. Queries return not just direct matches but connected concepts across the graph.

Memory runs **locally** (SQLite at `.cog/brain.db`) or **hosted** on [trycog.ai](https://trycog.ai). Local memory works out of the box with no account required. Hosted memory enables team sharing and cross-project knowledge.

### How it works

- An **engram** is a concept with a term, definition, and creation date
- A **synapse** is a typed relationship between engrams (requires, enables, leads_to, and others)
- **Short-term memories** decay in 24 hours unless reinforced to long-term
- **Spreading activation** means recall traverses the graph, surfacing related knowledge you didn't explicitly search for

### How agents use it

The system prompt we inject into your agent instructs it to follow a lifecycle:

1. **Recall** before exploring code. Query memory for relevant context first.
2. **Work and record**. Learn new concepts as they come up during the session.
3. **Consolidate**. After completing work, reinforce validated memories and flush incorrect ones.

The result is an agent that gets better over time. It stops rediscovering the same solutions and starts building on what it already knows.

Cog also hardens memory reads and writes: local memory rejects obvious prompt-injection phrases and secret-like tokens during learn/update operations, and recall output wraps stored definitions in `<stored-knowledge>` tags so agents can treat recalled text as data instead of fresh instructions.

For hosted brains, Cog now prefers enriched memory writes that include provenance and session context. That metadata is compiled locally by `cog-cli`; canonical assertion semantics, rationale history, and retrieval behavior still live on the hosted brain.

<details>
<summary><strong>Bootstrap</strong></summary>

<br>

Seed your brain with knowledge from an existing codebase. Runs in two phases: first extracts concepts from each source file, then creates cross-file associations using SCIP-derived symbol relationships. Requires an existing SCIP index (`cog code:index`).

```sh
cog mem:bootstrap                        # Bootstrap with defaults
cog mem:bootstrap --concurrency 4        # 4 parallel agent invocations
cog mem:bootstrap --clean                # Reset checkpoint, start fresh
cog mem:bootstrap --timeout 15           # 15 minutes per file (default: 10)
cog mem:bootstrap --debug                # Show agent stderr output
```

On first run, `cog mem:bootstrap` presents an interactive agent selector — pick whichever AI coding agent CLI you have installed (Amp, Claude Code, Gemini CLI, Goose, OpenAI Codex CLI, OpenCode, or a custom command). The list starts alphabetically and then adapts based on your global selection history in `~/.config/cog/agent-selection-counts.json`. Progress is checkpointed to `.cog/bootstrap-checkpoint.json` so interrupted runs resume where they left off.

**Model override.** By default, bootstrap uses whichever model the selected agent is configured to use. To override this, set `memory.bootstrap.model` in `.cog/settings.json`:

```json
{
  "memory": {
    "brain": "https://trycog.ai/you/brain",
    "bootstrap": {
      "model": "claude-sonnet-4-20250514"
    }
  }
}
```

This passes `--model` to the agent CLI, useful for choosing a faster or cheaper model for bulk extraction.

</details>

<details>
<summary><strong>MCP tools</strong></summary>

<br>

Your agent interacts with memory through MCP tools (`cog_mem_*`). These are discovered dynamically from your brain's remote MCP server — not CLI commands. The full set includes:

**Read:** `recall`, `get`, `connections`, `trace`, `bulk_recall`, `list_short_term`, `stale`, `stats`, `orphans`, `connectivity`, `list_terms`

**Write:** `learn`, `associate`, `bulk_learn`, `bulk_associate`, `update`, `unlink`, `refactor`, `deprecate`, `reinforce`, `flush`, `verify`, `meld`

</details>

<details>
<summary><strong>Manual setup</strong></summary>

<br>

If you'd rather not use `cog init`, you can set things up by hand.

**1.** Place a `.cog/settings.json` in your project (or any parent directory up to `$HOME`):

For local memory:
```json
{"memory": {"brain": "file:.cog/brain.db"}}
```

For hosted memory:
```json
{"memory": {"brain": "https://trycog.ai/username/brain"}}
```

**2.** For hosted memory, set your API key:

```sh
export COG_API_KEY=your-key-here
```

Or put it in a `.env` file in your project root.

</details>

---

## Code Intelligence

SCIP-based code indexing powered by tree-sitter. Instead of your agent grepping through files across multiple rounds, it gets structured answers in a single tool call.

This runs entirely locally. No account required.

### Language support

| Language | Delivery | Notes |
|----------|----------|-------|
| Go | Built-in | Tree-sitter indexing in Cog; optional built-in SCIP/dlv integration when installed |
| JavaScript | Built-in | Includes `.js`, `.jsx`, `.mjs`, `.cjs` |
| TypeScript | Built-in | Includes `.ts`, `.mts` |
| TSX | Built-in | JSX/TSX support |
| Python | Built-in | Includes `.py`, `.pyi` |
| Java | Built-in | Tree-sitter indexing plus optional SCIP indexing when installed |
| Rust | Built-in | Tree-sitter indexing plus optional `rust-analyzer scip` when installed |
| C | Built-in | Includes `.c`, `.h` |
| C++ | Built-in | Includes `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hxx`, `.hh` |
| Markdown | Built-in | Includes `.md`, `.markdown` |
| MDX | Built-in | `.mdx` |
| YAML | Built-in | Includes `.yaml`, `.yml` |
| TOML | Built-in | `.toml` |
| JSON | Built-in | `.json` |
| JSONC | Built-in | `.jsonc` via the built-in JSON grammar |
| reStructuredText | Built-in | `.rst` |
| AsciiDoc | Built-in | Includes `.adoc`, `.asciidoc` |
| Bash | Built-in | Includes `.sh`, `.bash`, `.bats`; DAP debugging via bashdb |
| Zig | External extension | Supported via [`cog-zig`](https://github.com/trycog/cog-zig) |
| Ruby | External extension | Supported via [`cog-ruby`](https://github.com/trycog/cog-ruby) |
| Swift | External extension | Supported via [`cog-swift`](https://github.com/trycog/cog-swift) |
| Nix | External extension | Supported via [`cog-nix`](https://github.com/trycog/cog-nix) |
| Elixir | External extension | Supported via [`cog-elixir`](https://github.com/trycog/cog-elixir) |

Built-in coverage comes from the bundled grammars and extension definitions in `src/extensions.zig`. Additional repo-supported languages are available through installable extensions in the [Extensions](#extensions) section.

### Tools

| Tool | Description |
|------|-------------|
| `cog_code_explore` | Find symbols by name, return readable definition bodies, file outlines, references, and optional architecture summaries in one response. Primary tool for code exploration. |
| `cog_code_query` | Low-level index query with modes for `find`, `refs`, `symbols`, `imports`, `contains`, `calls`, `callers`, and `overview`, all returned as concise plain text. |
| `cog_code_status` | Check index availability and coverage. |

`cog init` now installs stronger Cog-first guidance for supported agents, including an OpenCode override plugin and tighter sub-agent instructions so repository understanding defaults to indexed code exploration instead of ad hoc file search.

### Pattern matching

The `name` parameter supports flexible matching:

- **Glob patterns**: `*init*`, `get*`, `Handle?`
- **Alternation**: `banner|header|splash` to search multiple names at once
- **Combined**: `*init*|setup|*boot*`

### Indexing

```sh
cog code:index              # Index everything
cog code:index "**/*.ts"    # Specific pattern
```

Results go into `.cog/index.scip`. A built-in file watcher automatically keeps the index up to date as files are created, modified, deleted, or renamed — only watching files that match the glob patterns configured in `.cog/settings.json` under `code.index`. No manual re-indexing needed after the initial build.

### File operations

CLI commands for managing files with automatic index updates:

| Command | Description |
|---------|-------------|
| `cog code:edit` | Edit files with string replacement and re-index |
| `cog code:create` | Create new files and add to index |
| `cog code:delete` | Delete files and remove from index |
| `cog code:rename` | Rename files and update index |

---

## Debug

An interactive debugger your agent controls through MCP. 36 tools covering breakpoints, stepping, variable inspection, stack traces, expression evaluation, memory reads, disassembly, and more.

Under the hood, a local daemon communicates with debug adapters (DAP). The daemon starts automatically when your agent launches its first debug session.

### Key capabilities

- **Launch or attach** to processes with full breakpoint support (line, function, exception, conditional, data watchpoints)
- **Text-first debug results** — most `cog_debug_*` tools now return readable summaries instead of JSON blobs embedded in MCP text output
- **Step-over-inspect** — step repeatedly while evaluating expressions in a single call, reducing round trips
- **Module launch mode** — debug by module name (e.g. `python -m pytest`) in addition to script path
- **Synchronous or async** — `timeout_ms` controls whether the agent blocks for results or polls asynchronously
- **Low-level access** — memory reads, disassembly, register inspection, core dump loading

### CLI utilities

| Command | Description |
|---------|-------------|
| `debug:status` | Check daemon health and active sessions |
| `debug:dashboard` | Live session monitoring TUI |
| `debug:kill` | Stop the daemon |
| `debug:sign` | macOS code-signing for debug entitlements |

On macOS, `cog init` handles the code-signing for you.

---

## Extensions

You can add code intelligence and debugging support for any language through extensions.

```sh
cog ext:install https://github.com/trycog/cog-zig.git
cog ext:install https://github.com/trycog/cog-zig --version=0.75.0
cog ext:update
cog ext:update cog-zig
```

Extensions install from GitHub release tarballs into `~/.config/cog/extensions/` and override built-in indexers for shared file types. By default, Cog installs the latest stable release tag; `--version` selects an exact released version; `cog ext:update` upgrades either all installed extensions or one named extension to the latest stable release available.

### Available extensions

| Extension | Language | Code Intelligence | Debugging |
|-----------|----------|:-----------------:|-----------|
| [cog-elixir](https://github.com/trycog/cog-elixir) | Elixir | Yes | DAP (ElixirLS) |
| [cog-nix](https://github.com/trycog/cog-nix) | Nix | Yes | |
| [cog-ruby](https://github.com/trycog/cog-ruby) | Ruby | Yes | DAP (rdbg) |
| [cog-swift](https://github.com/trycog/cog-swift) | Swift | Yes | DAP (lldb) |
| [cog-zig](https://github.com/trycog/cog-zig) | Zig | Yes | DWARF (native) |

See **[Writing a Language Extension](EXTENSIONS.md)** to build your own.

---

## Diagnostics

```sh
cog doctor
```

Validates your Cog installation: config resolution, memory backend connectivity, code index health, installed extensions, agent integration files, and debug daemon status. Reports pass/warn/fail per check with a summary line. Exits 1 on any failure — useful in CI or after setup changes.

---

## Development

```sh
zig build test            # Run tests
zig build test-indexing-integration  # Run real code:index integration coverage
zig build run             # Build and run
zig build run -- mcp      # Start MCP server
```

---

<div align="center">
<sub>Built with <a href="https://ziglang.org">Zig</a></sub>
</div>
