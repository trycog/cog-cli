<div align="center">

# cog

**Tools for AI coding.**

A zero-dependency native CLI for [Cog](https://trycog.ai) — persistent memory (hosted on [trycog.ai](https://trycog.ai)), code intelligence, and debugging for developers and AI agents. Built in Zig.

[Getting Started](#getting-started) · [Memory](#memory) · [Code Intelligence](#code-intelligence) · [Debug](#debug) · [Extensions](#extensions)

</div>

---

## Getting Started

### Prerequisites

- [Zig 0.15.2+](https://ziglang.org/download/)
- A [Cog](https://trycog.ai) account and API key (required for memory, optional for other tools)

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

You'll be prompted to choose between **Memory + Tools** (full setup with brain selection, agent prompts, and skill installation) or **Tools only** (code intelligence and debug server without a trycog.ai account).

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
| `debug` | MCP debug server for AI agents |
| `install` | Language extension management |
| `init` | Interactive project setup |
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

SCIP-based code indexing and querying. Works locally — no account required.

### `code/index`

Build a SCIP code index. Expands a glob pattern to match files, resolves each to a language extension, invokes the indexer per-file, and merges results into `.cog/index.scip`.

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

**Built-in extensions:**

| Indexer | File types |
|---------|------------|
| scip-go | `.go` |
| scip-typescript | `.ts` `.tsx` `.js` `.jsx` |
| scip-python | `.py` |
| scip-java | `.java` |
| rust-analyzer | `.rs` |

Installed extensions (`~/.config/cog/extensions/`) override built-ins.

### `code/query`

Unified code query command. Specify exactly one query mode.

```
cog code/query --find <name> [--kind KIND] [--limit N]
cog code/query --refs <name> [--kind KIND] [--limit N]
cog code/query --symbols <file> [--kind KIND]
cog code/query --structure
```

**Modes:**

| Mode | Description |
|------|-------------|
| `--find NAME` | Find symbol definitions by name (ranked by relevance) |
| `--refs NAME` | Find all references to a symbol |
| `--symbols FILE` | List symbols defined in a file |
| `--structure` | Project structure overview |

**Options:**

| Option | Description |
|--------|-------------|
| `--kind KIND` | Filter by symbol kind (`function`, `struct`, `method`, `type`, etc.) |
| `--limit N` | Max results for `--find`/`--refs` (default: 1 for find, 100 for refs) |

```sh
cog code/query --find Server --kind struct
cog code/query --find Component --limit 10
cog code/query --refs Config --limit 20
cog code/query --symbols src/main.zig
cog code/query --structure
```

### `code/edit`

Edit a file using string replacement and re-index. Finds the exact old text, replaces with new text, then rebuilds the SCIP index to keep code intelligence current.

```
cog code/edit <file> --old OLD --new NEW
```

| Option | Description |
|--------|-------------|
| `--old TEXT` | Exact text to find (must be unique in file) |
| `--new TEXT` | Replacement text |

```sh
cog code/edit src/main.zig --old "fn old()" --new "fn new()"
```

Uses `.cog/settings.json` editor config if present, otherwise built-in string replacement.

### `code/create`

Create a new file and add it to the SCIP index.

```
cog code/create <file> [options]
```

| Option | Description |
|--------|-------------|
| `--content TEXT` | Initial file content |

```sh
cog code/create src/new.zig --content "const std = @import(\"std\");"
```

Uses `.cog/settings.json` creator config if present, otherwise built-in file creation.

### `code/delete`

Delete a file and remove it from the SCIP index.

```
cog code/delete <file>
```

```sh
cog code/delete src/old.zig
```

Uses `.cog/settings.json` deleter config if present, otherwise built-in file deletion.

### `code/rename`

Rename a file and update the SCIP index.

```
cog code/rename <old-path> --to <new-path>
```

| Option | Description |
|--------|-------------|
| `--to PATH` | New file path (required) |

```sh
cog code/rename src/old.zig --to src/new.zig
```

Uses `.cog/settings.json` renamer config if present, otherwise built-in rename.

### `code/status`

Report the status of the SCIP code index. Shows whether an index exists, document/symbol counts, and indexer info.

```
cog code/status
```

---

## Debug

MCP debug server for AI agents. Exposes debug tools over JSON-RPC stdio.

### `debug/serve`

Start an MCP debug server over stdio. Exposes debug tools that AI agents can use to step-debug programs.

```
cog debug/serve
```

**Tools:**

| Tool | Description |
|------|-------------|
| `debug_launch` | Launch a program under the debugger |
| `debug_breakpoint` | Set, remove, or list breakpoints |
| `debug_run` | Continue, step, or restart execution |
| `debug_inspect` | Evaluate expressions and inspect variables |
| `debug_stop` | Stop a debug session |

**Transport:** JSON-RPC 2.0 over stdin/stdout (one JSON object per line). Compatible with Claude Code, Cursor, and other MCP clients.

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

**Manifest format** (`cog-extension.json` in repo root):

| Field | Description |
|-------|-------------|
| `name` | Extension name (also the binary name) |
| `extensions` | File extensions this indexer handles |
| `build` | Shell command to build the indexer |
| `args` | Args template with `{file}` and `{output}` placeholders |

---

## Setup

### `init`

Interactive setup for the current directory. Verifies your API key, lets you select or create a brain, writes `.cog/settings.json`, and installs the agent skill.

```
cog init [options]
```

| Option | Description |
|--------|-------------|
| `--host HOST` | Server hostname (default: `trycog.ai`) |

### `update`

Fetch the latest system prompt and agent skill. Updates `CLAUDE.md`/`AGENTS.md` and the installed `SKILL.md`.

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
<sub>Built with <a href="https://ziglang.org">Zig</a> · Zero dependencies · <a href="https://trycog.ai">trycog.ai</a></sub>
</div>
