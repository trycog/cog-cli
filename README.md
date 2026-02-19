<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset=".github/logo-light.svg">
  <img alt="COG" src=".github/logo-light.svg" width="248">
</picture>

**Memory, code intelligence, and debugging for AI agents.**

A single native binary that gives your AI coding agent persistent memory across sessions,<br>
structured code search that's 2.8x faster than grep/glob, and an interactive debugger.

[Install](#install) · [How It Works](#how-it-works) · [Memory](#memory) · [Code Intelligence](#code-intelligence) · [Debug](#debug) · [Extensions](#extensions)

</div>

---

## Why Cog?

AI coding agents are powerful but forgetful. Every session starts from zero — no memory of past decisions, no understanding of your codebase structure, no way to set a breakpoint.

Cog fixes that with three tools, delivered as a single MCP server:

**Memory** — A persistent knowledge graph your agent reads and writes across sessions. It learns your architecture, remembers past bugs, and builds institutional knowledge that compounds over time. Short-term memories decay in 24 hours unless reinforced, mimicking how real memory works.

**Code Intelligence** — SCIP-based symbol indexing that gives your agent structured answers in one tool call instead of 15 rounds of grep and file reads. Find definitions, references, and symbols across your entire codebase instantly.

**Debug** — An interactive debugger your agent drives directly. Set breakpoints, inspect variables, step through code, and test hypotheses — without littering your code with print statements.

### Benchmarks

Cog vs. standard agent tools (grep, glob, read) on the React codebase:

| Task | Cog | Without Cog | Speedup |
|------|-----|-------------|---------|
| Find `createElement` definition | 3.7s · 1 call | 34.1s · 15 calls | **9.2x faster, 98% fewer tokens** |
| Find `useState` references | 9.3s · 2 calls | 27.4s · 15 calls | **2.9x faster, 90% fewer tokens** |
| List `ReactFiberWorkLoop` symbols | 10.8s · 1 call | 35.7s · 13 calls | **3.3x faster, 84% fewer tokens** |
| Find `Component` class | 14.3s · 5 calls | 28.9s · 15 calls | **2.0x faster, 74% fewer tokens** |

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

The interactive setup walks you through:

1. **Memory or Tools-only** — choose full setup (with a [trycog.ai](https://trycog.ai) brain) or local tools only
2. **Agent selection** — pick which AI agents to configure
3. **Tool permissions** — optionally auto-allow all Cog tools (Claude Code, Gemini CLI, Amp)

For each selected agent, `cog init` writes the system prompt, configures the MCP server connection, and sets up hooks to keep the code index in sync.

### Supported Agents

| Agent | MCP Config | Tool Permissions |
|-------|------------|------------------|
| Claude Code | `.mcp.json` | Auto-allow |
| Gemini CLI | `.gemini/settings.json` | Auto-allow |
| Amp | `.amp/settings.json` | Auto-allow |
| GitHub Copilot | `.vscode/mcp.json` | — |
| Cursor | `.cursor/mcp.json` | — |
| OpenAI Codex CLI | `.codex/config.toml` | — |
| Roo Code | `.roo/mcp.json` | — |
| OpenCode | `opencode.json` | — |
| Windsurf | Global config | — |
| Goose | Global config | — |

---

## How It Works

Cog runs as an [MCP server](https://modelcontextprotocol.io/) over stdio. Your AI agent connects to it and discovers available tools dynamically. You don't call Cog commands directly — your agent does, through MCP tool calls.

```
Your Agent  ←→  MCP (stdio)  ←→  cog mcp
                                   ├── Memory (trycog.ai API)
                                   ├── Code Intelligence (local SCIP index)
                                   └── Debug (local daemon)
```

Tool discovery happens at runtime via `tools/list`. Tool families:

- `cog_mem_*` — Memory operations (when configured)
- `cog_code_*` — Code intelligence (query, index status, file mutations)
- `debug_*` — Debugger (launch, breakpoints, stepping, inspection)

---

## Memory

Persistent associative memory powered by a knowledge graph. Your agent learns concepts, links them with typed relationships, and recalls them using spreading activation — queries return not just direct matches but connected concepts across the graph.

Hosted on [trycog.ai](https://trycog.ai). Requires an account and API key.

### Key Concepts

- **Engram** — A concept with a term, definition, and creation date
- **Synapse** — A typed relationship between engrams (requires, enables, leads_to, etc.)
- **Short-term memory** — Decays in 24 hours unless reinforced to long-term
- **Spreading activation** — Recall traverses the graph, surfacing connected knowledge

### How Agents Use It

The agent prompt instructs your AI to follow a four-step lifecycle:

1. **Recall** — Before exploring code, query memory for relevant context
2. **Work + Record** — Learn new concepts as they're discovered during work
3. **Reinforce** — After completing work, consolidate important memories to long-term
4. **Consolidate** — Before ending, review short-term memories and reinforce or flush

<details>
<summary><strong>CLI commands</strong></summary>

<br>

Memory commands are available as both MCP tools (`cog_mem_*`) and CLI commands. In practice, your agent uses the MCP tools. The CLI is useful for manual inspection and debugging.

**Read:**

| Command | Description |
|---------|-------------|
| `mem/recall <query>` | Search with spreading activation |
| `mem/get <id>` | Retrieve engram by UUID |
| `mem/connections <id>` | List synaptic connections |
| `mem/trace <from> <to>` | Find reasoning path between concepts |
| `mem/bulk-recall <q1> <q2>...` | Multiple queries in one call |
| `mem/list-short-term` | Pending short-term memories |
| `mem/stale` | Synapses approaching staleness |
| `mem/stats` | Brain statistics |
| `mem/orphans` | Unconnected engrams |
| `mem/connectivity` | Graph connectivity analysis |
| `mem/list-terms` | All engram terms |

**Write:**

| Command | Description |
|---------|-------------|
| `mem/learn --term T --definition D` | Store a new concept |
| `mem/associate --source S --target T` | Link two concepts |
| `mem/bulk-learn --item ...` | Batch store concepts |
| `mem/bulk-associate --link ...` | Batch create links |
| `mem/update <id>` | Update term or definition |
| `mem/unlink <synapse-id>` | Remove a synapse |
| `mem/refactor --term T --definition D` | Update by term lookup |
| `mem/deprecate --term T` | Mark concept as obsolete |
| `mem/reinforce <id>` | Convert short-term to long-term |
| `mem/flush <id>` | Delete short-term memory |
| `mem/verify <synapse-id>` | Confirm synapse accuracy |
| `mem/meld --target BRAIN` | Cross-brain knowledge link |

Run `cog mem/<command> --help` for full options.

</details>

<details>
<summary><strong>Manual setup</strong></summary>

<br>

If you prefer not to use `cog init`:

**1.** Place a `.cog/settings.json` in your project (or any parent up to `$HOME`):

```json
{"brain": {"url": "https://trycog.ai/username/brain"}}
```

**2.** Set your API key:

```sh
export COG_API_KEY=your-key-here
```

Or in a `.env` file in your project root.

</details>

---

## Code Intelligence

SCIP-based code indexing powered by tree-sitter. Gives your agent structured answers — definitions, references, symbols — in a single tool call instead of multi-round file searching.

Works locally. No account required.

### Indexing

```sh
cog code/index              # Index everything
cog code/index "**/*.ts"    # Specific pattern
```

Results are stored in `.cog/index.scip`. The MCP server exposes `cog_code_query` for your agent to search the index.

### Built-in Language Support

Go, TypeScript, TSX, JavaScript, Python, Java, Rust, C, C++

Additional languages via [extensions](#extensions).

---

## Debug

An interactive debugger your agent drives through MCP `debug_*` tools. Supports breakpoints, stepping, variable inspection, stack traces, memory reads, and disassembly.

Architecture: a local daemon communicates with debug adapters (DAP) and exposes 37+ tools through MCP.

### CLI utilities

| Command | Description |
|---------|-------------|
| `debug/status` | Check daemon health and active sessions |
| `debug/dashboard` | Live session monitoring TUI |
| `debug/kill` | Stop the daemon |
| `debug/sign` | macOS code-signing for debug entitlements |

The daemon starts automatically when your agent launches a debug session. On macOS, `cog init` handles code-signing.

---

## Extensions

Add code intelligence and debugging for any language.

```sh
cog install https://github.com/trycog/cog-zig.git
```

Extensions are installed to `~/.config/cog/extensions/` and override built-in indexers for shared file types.

### Available Extensions

| Extension | Language | Code Intelligence | Debugging |
|-----------|----------|:-----------------:|:---------:|
| [cog-zig](https://github.com/trycog/cog-zig) | Zig | Yes | Yes |

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
