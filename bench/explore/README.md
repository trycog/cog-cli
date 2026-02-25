# Explore Benchmark: `cog_code_explore` Across Languages

Systematic benchmark comparing `cog_code_explore` (single MCP tool call) vs traditional tools (Grep + Read + Glob) across 4 languages.

## Repos

| Language | Repo | Tag | Paradigm |
|----------|------|-----|----------|
| JavaScript | facebook/react | v19.0.0 | Prototype-based OO, hooks |
| Go | gin-gonic/gin | v1.10.0 | Interfaces, middleware |
| Python | pallets/flask | 3.1.0 | Decorators, class-based views |
| Rust | BurntSushi/ripgrep | 14.1.1 | Traits, generics, multi-crate |

## Setup

```bash
# From repo root — clones all 4 repos and builds cog indexes
bash bench/explore/setup.sh
```

Requires the `cog` binary (`zig build` runs automatically if needed).

## Running

Each language has a prompt file with 5 test cases. Each test case has two variants:

- **Agent A (Explore)**: Uses only `cog_code_explore`
- **Agent B (Traditional)**: Uses only Grep, Read, Glob

### Per test case:

1. `cd` into the repo directory (e.g. `bench/explore/gin`)
2. Start a fresh Claude Code session: `claude`
3. Paste the **Explore** prompt — observe tool calls, time, answer quality
4. Start another fresh session: `claude`
5. Paste the **Traditional** prompt — observe tool calls, time, answer quality
6. Record results in `results.md`

### Prompt files

- `react.md` — 5 JavaScript test cases
- `gin.md` — 5 Go test cases
- `flask.md` — 5 Python test cases
- `ripgrep.md` — 5 Rust test cases

## Test Case Categories

| Category | What it tests | Test cases |
|----------|--------------|------------|
| Single symbol | Full body extraction | 1, 6, 11, 16 |
| Multi-symbol batch | Batch coherence | 2, 7, 12, 17 |
| Module structure | file_symbols TOC | 3, 8, 13, 18 |
| Ambiguous name | Disambiguation | 4, 9, 14, 19 |
| Approximate name | Auto-retry with glob | 5, 10, 15, 20 |

## Metrics

Record per test case:
- **Tool calls**: How many tool invocations
- **Rounds**: How many LLM round-trips (a round may have multiple parallel tool calls)
- **Quality**: Did it find the right answer? (pass/fail + notes)

Aggregate per language and overall:
- Call reduction ratio
- Round reduction ratio
