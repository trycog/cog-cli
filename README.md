<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset=".github/logo-light.svg">
  <img alt="COG" src=".github/logo-light.svg" width="248">
</picture>

**Memory, code intelligence, and debugging for AI agents.**

[Install](#install) · [How It Works](#how-it-works) · [Memory](#memory) · [Code Intelligence](#code-intelligence) · [Debug](#debug) · [Extensions](#extensions)

</div>

---

## Why Cog?

AI coding can feel fast but it's still limited by suboptimal methods and tooling. Your agent doesn't remember the architectural decisions from last week. It can't look up where a function is defined without grepping through your entire codebase. When something breaks it can't set a breakpoint, inspect a variable, or step through the code. It's stuck adding print statements and guessing.

We built Cog to fix that. It's a single native binary that runs as an MCP server and gives your agent three capabilities it doesn't have on its own:

1. **Persistent memory** that carries across sessions. Your agent learns your architecture, remembers past bugs, and builds knowledge that compounds over time. Memory can run locally (SQLite) or hosted on [trycog.ai](https://trycog.ai) for team sharing.
2. **Structured code intelligence** that returns definitions, references, and symbols in one tool call instead of 15 rounds of grep and file reads.
3. **An interactive debugger** your agent drives directly. Breakpoints, variable inspection, stepping through code. No more print statement debugging.

### The numbers

#### Memory (hosted)

We benchmarked Cog's hosted memory recall against Sonnet 4.5 doing active code exploration across 114 questions about a production codebase. The code exploration baseline used no prior model knowledge and answered every question through real-time file reads, grep, and glob. Cog answered from a knowledge graph built by an exhaustive bootstrap prompt before the benchmark started. These benchmarks use the hosted brain on [trycog.ai](https://trycog.ai).

| Metric | Cog | Code Exploration | Delta |
|--------|-----|------------------|-------|
| Accuracy | 86.0% | 89.5% | -3.9% |
| Adequate answers (>=50%) | 93.9% | 89.9% | **+4.4%** |
| Duration | 24m 39s | 61m 39s | **-60%** |
| Total tokens | 548.4K | 46.6M | **-98.8%** |
| Tokens per question | 4.6K | 391.2K | **-98.8%** |


Cog answers nearly as many questions correctly while using 98.8% fewer tokens and finishing in less than half the time. The adequate answer rate is actually higher because memory recall surfaces connected context that code exploration misses.

#### Code intelligence

We benchmarked Cog's code intelligence against standard agent tools (grep, glob, read) on the React codebase:

| Task | Cog | Without Cog | Speedup | Token Savings |
|------|-----|-------------|---------|---------------|
| Find `createElement` definition | 3.7s, 1 call, 1.4K tokens | 34.1s, 15 calls, 78.4K tokens | **9.2x faster** | **98%** |
| Find `useState` references | 9.3s, 2 calls, 2.5K tokens | 27.4s, 15 calls, 24.1K tokens | **2.9x faster** | **90%** |
| List `ReactFiberWorkLoop` symbols | 10.8s, 1 call, 4.0K tokens | 35.7s, 13 calls, 25.2K tokens | **3.3x faster** | **84%** |
| Find `Component` class | 14.3s, 5 calls, 7.4K tokens | 28.9s, 15 calls, 28.1K tokens | **2.0x faster** | **74%** |

On average, **2.8x faster with 89% fewer tokens**.

---

## Install

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

For each agent you select, `cog init` writes the system prompt, configures the MCP server connection, deploys specialized sub-agents, and, where the host agent supports it, auto-allows Cog tool permissions.

### Supported agents

| Agent | MCP Config | Sub-Agents | Tool Permissions | Cog-First Override |
|-------|------------|:----------:|------------------|--------------------|
| Claude Code | `.mcp.json` | Yes | Auto-allow | Hard sub-agent allowlist |
| Gemini CLI | `.gemini/settings.json` | Yes | Auto-allow | Medium prompt + sub-agent scoping |
| Amp | `.amp/settings.json` | Yes | Auto-allow | Medium prompt + permission bootstrap |
| Cursor | `.cursor/mcp.json` | Yes | | Soft prompt guidance |
| OpenCode | `opencode.json` | Yes | Auto-allow | Medium prompt + sub-agent permissions |
| GitHub Copilot | `.vscode/mcp.json` | Yes | | Soft prompt guidance |
| OpenAI Codex CLI | `.codex/config.toml` | Yes | | Soft prompt guidance |
| Roo Code | `.roo/mcp.json` | Yes | | Soft prompt guidance |
| Windsurf | Global config | Yes | | Soft prompt guidance |
| Goose | Global config | Yes | | Soft prompt guidance |

`cog init` now installs Cog-first code exploration guidance everywhere. Stronger enforcement depends on what each host agent can actually express: Claude Code can hard-scope the code-query sub-agent, Gemini/Amp/OpenCode can partially constrain tool use, and the remaining integrations rely on prompt-level steering because their current config surfaces do not support repo-local hard denies.

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

For supported agents, `cog init` deploys specialized sub-agent prompts that your primary agent delegates to:

- **cog-code-query** — code exploration via the SCIP index. Finds definitions, references, and symbols in a single call.
- **cog-debug** — autonomous hypothesis-driven debugging. Sets breakpoints, inspects variables, steps through code, and reports findings.
- **cog-mem** — memory lifecycle management. Handles recall, consolidation, and maintenance of your agent's knowledge graph.

Sub-agents keep the primary agent's context clean by offloading specialized work.

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

On first run, `cog mem:bootstrap` presents an interactive agent selector — pick whichever AI coding agent CLI you have installed (Claude Code, Gemini CLI, Codex, Amp, Goose, OpenCode, or a custom command). Progress is checkpointed to `.cog/bootstrap-checkpoint.json` so interrupted runs resume where they left off.

**Model override.** Set `memory.model` in `.cog/settings.json` to override the model the agent uses during bootstrap:

```json
{
  "memory": {
    "brain": "https://trycog.ai/you/brain",
    "model": "claude-sonnet-4-20250514"
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

### Tools

| Tool | Description |
|------|-------------|
| `cog_code_explore` | Find symbols by name, return full definition bodies, file symbol table of contents, and references. Primary tool for code exploration. |
| `cog_code_query` | Low-level index query with three modes: `find` (locate definitions), `refs` (find all references), `symbols` (list symbols in a file). |
| `cog_code_status` | Check index availability and coverage. |

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

### Built-in language support

Go, TypeScript, TSX, JavaScript, Python, Java, Rust, C, C++

Additional languages are supported through [extensions](#extensions).

---

## Debug

An interactive debugger your agent controls through MCP. 36 tools covering breakpoints, stepping, variable inspection, stack traces, expression evaluation, memory reads, disassembly, and more.

Under the hood, a local daemon communicates with debug adapters (DAP). The daemon starts automatically when your agent launches its first debug session.

### Key capabilities

- **Launch or attach** to processes with full breakpoint support (line, function, exception, conditional, data watchpoints)
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
cog install https://github.com/trycog/cog-zig.git
```

Extensions install to `~/.config/cog/extensions/` and override built-in indexers for shared file types.

### Available extensions

| Extension | Language | Code Intelligence | Debugging |
|-----------|----------|:-----------------:|-----------|
| [cog-elixir](https://github.com/trycog/cog-elixir) | Elixir | Yes | DAP (ElixirLS) |
| [cog-ruby](https://github.com/trycog/cog-ruby) | Ruby | Yes | DAP (rdbg) |
| [cog-zig](https://github.com/trycog/cog-zig) | Zig | Yes | DWARF (native) |

See **[Writing a Language Extension](EXTENSIONS.md)** to build your own.

---

## Development

```sh
zig build test            # Run tests
zig build run             # Build and run
zig build run -- mcp      # Start MCP server
```

---

<div align="center">
<sub>Built with <a href="https://ziglang.org">Zig</a></sub>
</div>
