<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset=".github/logo-light.svg">
  <img alt="COG" src=".github/logo-light.svg" width="248">
</picture>

**Tools for AI coding.**

Persistent memory, code intelligence, and debugging for developers and AI agents. A zero-dependency native CLI built in Zig.

[Getting Started](#getting-started) · [Memory](#memory) · [Code Intelligence](#code-intelligence) · [MCP Server](#mcp-server) · [Debug](#debug) · [Extensions](#extensions)

</div>

---

## Getting Started

### Homebrew

Install from the official tap:

```sh
brew install trycog/tap/cog
```

Install the latest `main` branch:

```sh
brew install --HEAD trycog/tap/cog
```

### Prerequisites

- [Zig 0.15.2+](https://ziglang.org/download/)

### Build

```sh
zig build
```

The compiled binary is at `zig-out/bin/cog`.

### Setup

Run the interactive setup:

```sh
cog init
```

You'll be prompted to choose between **Memory + Tools** (full setup with brain selection) or **Tools only** (code intelligence and debug server), then select which AI coding agents to configure. For each selected agent, `cog init` writes the system prompt, installs the skill, configures the MCP server, and sets up hooks.

**Supported agents:** Claude Code, Gemini CLI, GitHub Copilot, Windsurf, Cursor, OpenAI Codex CLI, Amp, Goose, Roo Code, OpenCode.

On macOS, `cog init` also code-signs the binary with debug entitlements for the native debugger.

<details>
<summary><strong>Manual setup (memory)</strong></summary>

<br>

**1. Create a config file**

Place a `.cog/settings.json` in your project directory (or any parent directory up to `$HOME`):

```json
{"brain": {"url": "https://trycog.ai/username/brain"}}
```

**2. Set your API key**

Export it directly:

```sh
export COG_API_KEY=your-key-here
```

Or add it to a `.env` file in your working directory:

```
COG_API_KEY=your-key-here
```

</details>

---

## Commands

```
cog <command> [options]
```

Run `cog --help` for an overview, or `cog <group> --help` to list commands in a group.

| Group | Description |
|-------|-------------|
| `mem` | Persistent associative memory powered by a knowledge graph |
| `code` | SCIP-based code indexing, querying, and file mutations |
| `mcp` | MCP server over stdio for AI agent integration |
| `debug` | Debug daemon for AI agents |
| `install` | Language extension management |
| `init` | Interactive multi-agent project setup |
| `update` | Fetch latest prompt and skill |

---

## Memory

Persistent associative memory powered by a knowledge graph. Memory is hosted as a service on [trycog.ai](https://trycog.ai) — requires an account and API key.

### Read Commands

#### `mem/recall`

Search memory using spreading activation. Returns seed matches and connected concepts discovered through the knowledge graph.

```
cog mem/recall <query> [options]
```

| Option | Description |
|--------|-------------|
| `--limit N` | Max seed results (default: 5) |
| `--predicate-filter P` | Only include these predicates (repeatable) |
| `--exclude-predicate P` | Exclude these predicates (repeatable) |
| `--created-after DATE` | Filter by creation date (ISO 8601) |
| `--created-before DATE` | Filter by creation date (ISO 8601) |
| `--no-strengthen` | Don't strengthen retrieved synapses |

```sh
cog mem/recall "authentication session lifecycle"
cog mem/recall "token refresh" --limit 3 --no-strengthen
```

#### `mem/get`

Retrieve a specific engram by its UUID. Returns the term, definition, memory type, and metadata.

```
cog mem/get <engram-id>
```

#### `mem/connections`

List all synaptic connections from a specific engram. Shows connected concepts and their relationship types.

```
cog mem/connections <engram-id> [options]
```

| Option | Description |
|--------|-------------|
| `--direction DIR` | `incoming`, `outgoing`, or `both` (default: `both`) |

#### `mem/trace`

Find the shortest reasoning path between two concepts in the knowledge graph. Returns the chain of engrams and synapses connecting them.

```
cog mem/trace <from-id> <to-id>
```

#### `mem/bulk-recall`

Search with multiple independent queries in one call. More efficient than separate recall calls.

```
cog mem/bulk-recall <query1> <query2> ... [options]
```

| Option | Description |
|--------|-------------|
| `--limit N` | Max seeds per query (default: 3) |

```sh
cog mem/bulk-recall "auth tokens" "session management"
cog mem/bulk-recall "API design" "error handling" --limit 5
```

#### `mem/list-short-term`

List short-term memories pending consolidation. Short-term memories decay within 24 hours unless reinforced.

```
cog mem/list-short-term [options]
```

| Option | Description |
|--------|-------------|
| `--limit N` | Max results (default: 20) |

#### `mem/stale`

List synapses approaching or exceeding staleness thresholds. Stale synapses may represent outdated knowledge.

```
cog mem/stale [options]
```

| Option | Description |
|--------|-------------|
| `--level LEVEL` | `warning` (3+ mo), `critical` (6+), `deprecated` (12+), `all` |
| `--limit N` | Max results (default: 20) |

#### `mem/stats`

Get brain statistics including total engram and synapse counts.

```
cog mem/stats
```

#### `mem/orphans`

List engrams with no connections. Orphaned concepts don't surface during spreading activation recall.

```
cog mem/orphans [options]
```

| Option | Description |
|--------|-------------|
| `--limit N` | Max results (default: 50) |

#### `mem/connectivity`

Analyze graph connectivity. Returns main cluster size, disconnected clusters, and isolated engrams.

```
cog mem/connectivity
```

#### `mem/list-terms`

List all engram terms in the brain.

```
cog mem/list-terms [options]
```

| Option | Description |
|--------|-------------|
| `--limit N` | Max results (default: 500) |

### Write Commands

#### `mem/learn`

Store a new concept as short-term memory. Short-term memories decay within 24 hours unless reinforced with `mem/reinforce`.

```
cog mem/learn --term TERM --definition DEF [options]
```

| Option | Description |
|--------|-------------|
| `--term TERM` | Concept name (required) |
| `--definition DEF` | Your understanding (required) |
| `--long-term` | Store as permanent long-term memory |
| `--associate ASSOC` | Link to concept (repeatable). Format: `target:Name,predicate:type` |
| `--chain CHAIN` | Create reasoning chain (repeatable) |

```sh
cog mem/learn --term "Rate Limiting" --definition "Token bucket for throttling"
cog mem/learn --term "Auth" --definition "OAuth2 with PKCE" --long-term
cog mem/learn --term "API Gateway" --definition "Entry point" \
  --associate "target:Rate Limiting,predicate:contains"
```

#### `mem/associate`

Create a typed link between two concepts. Terms are matched semantically — exact spelling is not required.

```
cog mem/associate --source TERM --target TERM [options]
```

| Option | Description |
|--------|-------------|
| `--source TERM` | Source concept (required) |
| `--target TERM` | Target concept (required) |
| `--predicate TYPE` | Relationship type (e.g. `requires`, `enables`) |

```sh
cog mem/associate --source "Auth" --target "JWT" --predicate requires
```

**Predicate types:**

| Predicate | Usage |
|-----------|-------|
| `requires` | A depends on B to function |
| `enables` | A makes B possible |
| `contains` | A includes B as a component |
| `implements` | A is a concrete realization of B |
| `derived_from` | A was discovered from or caused by B |
| `generalizes` | A is a broader principle abstracted from B |
| `leads_to` | A causally or sequentially precedes B |

#### `mem/bulk-learn`

Store multiple concepts in one batch. Deduplicates at >=90% similarity.

```
cog mem/bulk-learn --item ITEM [--item ITEM ...] [options]
```

| Option | Description |
|--------|-------------|
| `--item ITEM` | Concept to store (repeatable, required). Format: `term:Name,definition:Description` |
| `--memory TYPE` | `short` or `long` (default: `long`) |

```sh
cog mem/bulk-learn --item "term:Redis,definition:In-memory cache" \
                   --item "term:Postgres,definition:Relational DB"
```

#### `mem/bulk-associate`

Create multiple associations in one batch. Terms are matched semantically.

```
cog mem/bulk-associate --link LINK [--link LINK ...]
```

| Option | Description |
|--------|-------------|
| `--link LINK` | Association to create (repeatable, required). Format: `source:Term,target:Term,predicate:type` |

```sh
cog mem/bulk-associate --link "source:Redis,target:API,predicate:enables"
```

#### `mem/update`

Update an existing engram's term or definition by UUID.

```
cog mem/update <engram-id> [options]
```

| Option | Description |
|--------|-------------|
| `--term TERM` | New term |
| `--definition DEF` | New definition |

```sh
cog mem/update 550e8400... --definition "Updated description"
```

#### `mem/unlink`

Remove a synapse between two concepts by its UUID.

```
cog mem/unlink <synapse-id>
```

#### `mem/refactor`

Update a concept's definition by term lookup. Finds the engram semantically, updates the definition, and re-embeds. All existing synapses are preserved.

```
cog mem/refactor --term TERM --definition DEF
```

| Option | Description |
|--------|-------------|
| `--term TERM` | Concept to find (required, semantically matched) |
| `--definition DEF` | New definition (required) |

```sh
cog mem/refactor --term "Rate Limiting" --definition "Updated algorithm"
```

#### `mem/deprecate`

Mark a concept as no longer existing. Severs all synapses and converts to short-term with ~4 hour TTL.

```
cog mem/deprecate --term TERM
```

| Option | Description |
|--------|-------------|
| `--term TERM` | Concept to deprecate (required, semantically matched) |

#### `mem/reinforce`

Convert a short-term memory to long-term (memory consolidation). Connected synapses also convert when both endpoints are long-term.

```
cog mem/reinforce <engram-id>
```

#### `mem/flush`

Delete a short-term memory immediately. Only works on short-term memories.

```
cog mem/flush <engram-id>
```

#### `mem/verify`

Confirm a synapse is still accurate. Resets the staleness timer and increases the confidence score.

```
cog mem/verify <synapse-id>
```

#### `mem/meld`

Create a cross-brain connection for knowledge traversal during recall. Connected brains are queried when the search is relevant to the meld description.

```
cog mem/meld --target BRAIN [options]
```

| Option | Description |
|--------|-------------|
| `--target BRAIN` | Brain reference (required). Formats: `brain`, `user/brain`, `user:brain` |
| `--description TEXT` | Gates when meld is traversed during recall |

```sh
cog mem/meld --target "other-brain" --description "Shared architecture"
```

---

## Code Intelligence

Code indexing and querying powered by tree-sitter and [SCIP](https://github.com/sourcegraph/scip). Tree-sitter grammars are built in for 9 languages (Go, TypeScript, JavaScript, Python, Java, Rust, C, C++, TSX). Additional languages are supported via [SCIP extensions](EXTENSIONS.md). Works locally — no account required.

### Benchmarks

Cog's code intelligence gives AI agents structured answers in a single tool call instead of forcing them to grep, glob, and read files across many rounds. Benchmarked against Claude Sonnet on the React codebase:

| Task | Cog | Agent Tools | Speedup | Token Savings |
|------|-----|-------------|---------|---------------|
| Find `createElement` definition | 3.7s · 1 call · 1.4K tokens | 34.1s · 15 calls · 78.4K tokens | **9.2x** | **98%** |
| Find `useState` references | 9.3s · 2 calls · 2.5K tokens | 27.4s · 15 calls · 24.1K tokens | **2.9x** | **90%** |
| List `ReactFiberWorkLoop` symbols | 10.8s · 1 call · 4.0K tokens | 35.7s · 13 calls · 25.2K tokens | **3.3x** | **84%** |
| Find `Component` class | 14.3s · 5 calls · 7.4K tokens | 28.9s · 15 calls · 28.1K tokens | **2.0x** | **74%** |

Across these tasks, Cog averages **2.8x faster** with **89% fewer tokens** compared to standard agent tools (grep, glob, read).

### `code/index`

Build a code index. For each file, Cog tries the built-in tree-sitter indexer first, then falls back to a matching SCIP extension. Results are merged into `.cog/index.scip`.

```
cog code/index [pattern]
```

`pattern` defaults to `**/*` (all files, recursive).

**Glob syntax:**

| Pattern | Matches |
|---------|---------|
| `*` | Any characters except `/` |
| `**` | Any path segments (recursive descent) |
| `?` | Any single character except `/` |

```sh
cog code/index                  # Index everything (default **/*)
cog code/index src/main.ts      # Index a single file
cog code/index "**/*.ts"        # All .ts files recursively
cog code/index "src/**/*.go"    # All .go files under src/
cog code/index "*.py"           # .py files in current dir only
```

**Built-in tree-sitter support:**

Go, TypeScript, TSX, JavaScript, Python, Java, Rust, C, C++

**Built-in SCIP extensions** (external fallback):

| Indexer | File types |
|---------|------------|
| scip-go | `.go` |
| scip-typescript | `.ts` `.tsx` `.js` `.jsx` |
| scip-python | `.py` |
| scip-java | `.java` |
| rust-analyzer | `.rs` |

Installed extensions (`~/.config/cog/extensions/`) override built-ins. See [Writing a Language Extension](EXTENSIONS.md).

### `code/query`

Removed from CLI. Use MCP `cog_code_query`.

### `code/edit`

Removed from CLI. Use MCP `cog_code_edit`.

### `code/create`

Removed from CLI. Use MCP `cog_code_create`.

### `code/delete`

Removed from CLI. Use MCP `cog_code_delete`.

### `code/rename`

Removed from CLI. Use MCP `cog_code_rename`.

### `code/status`

Removed from CLI. Use MCP `cog_code_status`.

---

## MCP Server

MCP (Model Context Protocol) server over stdio. Exposes Cog's code intelligence tools to any MCP-compatible AI agent. Configured automatically by `cog init`.

### `mcp`

Start the MCP server. Reads JSON-RPC 2.0 messages from stdin, writes responses to stdout.

```
cog mcp
cog mcp --help
```

This is not typically run manually — agents connect to it via their MCP configuration (`.mcp.json`, `.vscode/mcp.json`, etc.).

Transport is stdio with MCP framing (`Content-Length` headers).

**Protocol methods:** `initialize`, `ping`, `tools/list`, `tools/call`, `prompts/list`, `prompts/get`, `resources/list`, `resources/read`, `shutdown`, `exit`.

**Tool discovery:**

- Use `tools/list` as the runtime source of truth for all exposed tools and schemas.
- Use `resources/read` with `cog://tools/catalog` for a stable JSON tool catalog snapshot.
- Tool families exposed by Cog include `cog_code_*`, `debug_*`, and (when configured) `cog_mem_*`.

**Prompts:**

- `cog_reference` via `prompts/get`

**Resources:**

- `cog://index/status` (JSON status of current code index)
- `cog://debug/tools` (JSON catalog of `debug_*` MCP tools)
- `cog://tools/catalog` (JSON catalog of all tools currently exposed by this runtime)

### Per-agent MCP config files

`cog init` writes project-local MCP config for agents that support it, preserving unrelated existing entries and replacing only the `cog` server block.

| Agent | Local MCP config |
|-------|------------------|
| Claude Code | `.mcp.json` (`mcpServers`) |
| Gemini CLI | `.gemini/settings.json` (`mcpServers`) |
| GitHub Copilot (VS Code) | `.vscode/mcp.json` (`servers`) |
| Cursor | `.cursor/mcp.json` (`mcpServers`) |
| OpenAI Codex CLI | `.codex/config.toml` (`[mcp_servers.cog]`) |
| Amp | `.amp/settings.json` (`amp.mcpServers`) |
| Roo Code | `.roo/mcp.json` (`mcpServers`) |
| OpenCode | `opencode.json` (`mcp`) |

Agents that currently require global-only MCP configuration:

- Windsurf (`~/.codeium/windsurf/mcp_config.json`)
- Goose (`~/.config/goose/config.yaml`)

### Hooks

`cog init` can configure hooks for agents that support them. Hooks enforce that file mutations go through Cog's MCP tools (keeping the code index in sync) and auto-reindex after changes.

| Agent | Hook mechanism |
|-------|---------------|
| Claude Code | `.claude/settings.json` — PreToolUse blocks native Edit/Write, PostToolUse reindexes |
| Gemini CLI | `.gemini/settings.json` — BeforeTool/AfterTool |
| Windsurf | `.windsurf/hooks.json` — pre/post write code |
| Cursor | `.cursor/hooks.json` — afterFileEdit |
| Amp | `.amp/settings.json` — amp.tools.disable |

Hook scripts are generated in `.cog/hooks/` and shared across agents.

---

## Debug

Debug daemon utilities. Debug tool operations are now exposed through MCP `debug_*` tools.

### `debug/serve`

Start the debug daemon. Useful for direct daemon troubleshooting.

```
cog debug/serve
```

You typically do not need this for normal MCP tool usage.

### `debug/send`

Removed from CLI. Use MCP `debug_*` tools via `tools/call`.

### `debug/dashboard`

Live debug session dashboard. Runs in a separate terminal and shows real-time state from running debug sessions.

```
cog debug/dashboard
```

### `debug/status`

Check the status of the debug daemon and list active sessions.

```
cog debug/status
```

### `debug/kill`

Stop the debug daemon.

```
cog debug/kill
```

### `debug/sign`

Code-sign the cog binary with macOS debug entitlements. Required for the debugger to attach to processes via `task_for_pid`. No-op on Linux.

```
cog debug/sign
```

Called automatically by Homebrew on install. Run manually after building from source.

---

## Extensions

### `install`

Install a language extension from a git repository. Clones the repo, reads `cog-extension.json`, runs the build command, and verifies the binary.

```
cog install <git-url>
```

```sh
cog install https://github.com/example/scip-zig.git
```

Extensions are installed to `~/.config/cog/extensions/<name>/`. Installed extensions override built-in indexers for shared file extensions.

See **[Writing a Language Extension](EXTENSIONS.md)** for a complete guide on building your own — manifest format, SCIP output, debugger support, and a worked example.

---

## Setup

### `init`

Interactive multi-agent setup for the current directory. Optionally configures memory, then sets up system prompts, skills, MCP server, and hooks for your selected AI coding agents.

```
cog init [options]
```

| Option | Description |
|--------|-------------|
| `--host HOST` | Server hostname (default: `trycog.ai`) |

### `update`

Fetch the latest system prompt and agent skill. Updates existing prompt files and the installed `SKILL.md`.

```
cog update [options]
```

| Option | Description |
|--------|-------------|
| `--host HOST` | Server hostname (default: `trycog.ai`) |

---

## Development

```sh
zig build test                       # Run tests
zig build run                        # Build and run
zig build run -- mem/stats           # Run with arguments
```

---

<div align="center">
<sub>Built with <a href="https://ziglang.org">Zig</a> · Zero dependencies</sub>
</div>
