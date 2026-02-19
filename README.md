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

1. **Persistent memory** that carries across sessions, hosted on [trycog.ai](https://trycog.ai). Your agent learns your architecture, remembers past bugs, and builds knowledge that compounds over time. Memory can be shared across your team so everyone benefits from what any one agent learns.
2. **Structured code intelligence** that returns definitions, references, and symbols in one tool call instead of 15 rounds of grep and file reads.
3. **An interactive debugger** your agent drives directly. Breakpoints, variable inspection, stepping through code. No more print statement debugging.

### The numbers

#### Memory

We benchmarked Cog's memory recall against Sonnet 4.5 doing active code exploration across 114 questions about a production codebase. The code exploration baseline used no prior model knowledge and answered every question through real-time file reads, grep, and glob. Cog answered from a knowledge graph built by an exhaustive bootstrap prompt before the benchmark started.

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

1. **Memory or Tools-only**: full setup with a [trycog.ai](https://trycog.ai) brain, or just local code intelligence and debugging
2. **Agent selection**: pick which AI coding agents you use
3. **Tool permissions**: optionally auto-allow all Cog tools so your agent doesn't prompt you on every call

For each agent you select, `cog init` writes the system prompt, configures the MCP server connection, and sets up hooks to keep the code index in sync.

### Supported agents

| Agent | MCP Config | Tool Permissions |
|-------|------------|------------------|
| Claude Code | `.mcp.json` | Auto-allow |
| Gemini CLI | `.gemini/settings.json` | Auto-allow |
| Amp | `.amp/settings.json` | Auto-allow |
| GitHub Copilot | `.vscode/mcp.json` | |
| Cursor | `.cursor/mcp.json` | |
| OpenAI Codex CLI | `.codex/config.toml` | |
| Roo Code | `.roo/mcp.json` | |
| OpenCode | `opencode.json` | |
| Windsurf | Global config | |
| Goose | Global config | |

---

## How It Works

Cog runs as an [MCP server](https://modelcontextprotocol.io/) over stdio. Your AI agent connects to it and discovers tools at runtime. You don't type Cog commands yourself. Your agent calls them through MCP.

```
Your Agent  <->  MCP (stdio)  <->  cog mcp
                                     |-- Memory (trycog.ai API)
                                     |-- Code Intelligence (local SCIP index)
                                     |-- Debug (local daemon)
```

Tool families your agent discovers:

- `cog_mem_*` for memory operations (when configured)
- `cog_code_*` for code intelligence (query, index status, file mutations)
- `debug_*` for the debugger (launch, breakpoints, stepping, inspection)

---

## Memory

Your agent gets a persistent knowledge graph. It learns concepts, links them with typed relationships, and recalls them using spreading activation. Queries return not just direct matches but connected concepts across the graph.

Memory is hosted on [trycog.ai](https://trycog.ai) and requires an account and API key.

### How it works

- An **engram** is a concept with a term, definition, and creation date
- A **synapse** is a typed relationship between engrams (requires, enables, leads_to, and others)
- **Short-term memories** decay in 24 hours unless reinforced to long-term
- **Spreading activation** means recall traverses the graph, surfacing related knowledge you didn't explicitly search for

### How agents use it

The system prompt we inject into your agent instructs it to follow a four-step lifecycle:

1. **Recall** before exploring code. Query memory for relevant context first.
2. **Work and record**. Learn new concepts as they come up during the session.
3. **Reinforce**. After completing work, consolidate important memories to long-term.
4. **Consolidate**. Before ending the session, review short-term memories and reinforce or flush them.

The result is an agent that gets better over time. It stops rediscovering the same solutions and starts building on what it already knows.

<details>
<summary><strong>CLI commands</strong></summary>

<br>

Your agent uses memory through MCP tools (`cog_mem_*`). The CLI is there for manual inspection and debugging.

**Read:**

| Command | Description |
|---------|-------------|
| `mem:recall <query>` | Search with spreading activation |
| `mem:get <id>` | Retrieve engram by UUID |
| `mem:connections <id>` | List synaptic connections |
| `mem:trace <from> <to>` | Find reasoning path between concepts |
| `mem:bulk-recall <q1> <q2>...` | Multiple queries in one call |
| `mem:list-short-term` | Pending short-term memories |
| `mem:stale` | Synapses approaching staleness |
| `mem:stats` | Brain statistics |
| `mem:orphans` | Unconnected engrams |
| `mem:connectivity` | Graph connectivity analysis |
| `mem:list-terms` | All engram terms |

**Write:**

| Command | Description |
|---------|-------------|
| `mem:learn --term T --definition D` | Store a new concept |
| `mem:associate --source S --target T` | Link two concepts |
| `mem:bulk-learn --item ...` | Batch store concepts |
| `mem:bulk-associate --link ...` | Batch create links |
| `mem:update <id>` | Update term or definition |
| `mem:unlink <synapse-id>` | Remove a synapse |
| `mem:refactor --term T --definition D` | Update by term lookup |
| `mem:deprecate --term T` | Mark concept as obsolete |
| `mem:reinforce <id>` | Convert short-term to long-term |
| `mem:flush <id>` | Delete short-term memory |
| `mem:verify <synapse-id>` | Confirm synapse accuracy |
| `mem:meld --target BRAIN` | Cross-brain knowledge link |

Run `cog mem:<command> --help` for full options.

</details>

<details>
<summary><strong>Manual setup</strong></summary>

<br>

If you'd rather not use `cog init`, you can set things up by hand.

**1.** Place a `.cog/settings.json` in your project (or any parent directory up to `$HOME`):

```json
{"brain": {"url": "https://trycog.ai/username/brain"}}
```

**2.** Set your API key:

```sh
export COG_API_KEY=your-key-here
```

Or put it in a `.env` file in your project root.

</details>

---

## Code Intelligence

SCIP-based code indexing powered by tree-sitter. Instead of your agent grepping through files across multiple rounds, it gets structured answers (definitions, references, symbols) in a single tool call.

This runs entirely locally. No account required.

### Indexing

```sh
cog code:index              # Index everything
cog code:index "**/*.ts"    # Specific pattern
```

Results go into `.cog/index.scip`. Your agent searches it through the `cog_code_query` MCP tool.

### Built-in language support

Go, TypeScript, TSX, JavaScript, Python, Java, Rust, C, C++

Additional languages are supported through [extensions](#extensions).

---

## Debug

An interactive debugger your agent controls through MCP. It supports breakpoints, stepping, variable inspection, stack traces, memory reads, and disassembly. 37+ tools exposed through MCP.

Under the hood, a local daemon communicates with debug adapters (DAP). The daemon starts automatically when your agent launches its first debug session.

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
