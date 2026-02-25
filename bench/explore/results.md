# Explore Benchmark Results

**Date**: YYYY-MM-DD
**Model**: (e.g. claude-sonnet-4-6)
**Cog version**: (e.g. 0.4.0)

## How to record

For each test case, run both variants in fresh Claude Code sessions and note:
- **Calls**: Total tool invocations (count from the session)
- **Rounds**: LLM round-trips (each assistant turn that made tool calls = 1 round)
- **Pass**: Did it find the right answer? (Y/N)
- **Notes**: Anything notable (wrong file, partial answer, extra calls, etc.)

---

## React (JavaScript)

| # | Test | Variant | Calls | Rounds | Pass | Notes |
|---|------|---------|-------|--------|------|-------|
| 1 | Architecture: reconciliation | Explore | | | | |
| 1 | Architecture: reconciliation | Traditional | | | | |
| 2 | Pattern: adding a new hook | Explore | | | | |
| 2 | Pattern: adding a new hook | Traditional | | | | |
| 3 | Error boundaries | Explore | | | | |
| 3 | Error boundaries | Traditional | | | | |
| 4 | Fiber scheduler & lanes | Explore | | | | |
| 4 | Fiber scheduler & lanes | Traditional | | | | |
| 5 | Event system debugging | Explore | | | | |
| 5 | Event system debugging | Traditional | | | | |

## Gin (Go)

| # | Test | Variant | Calls | Rounds | Pass | Notes |
|---|------|---------|-------|--------|------|-------|
| 6 | Architecture: request flow | Explore | | | | |
| 6 | Architecture: request flow | Traditional | | | | |
| 7 | Pattern: custom middleware | Explore | | | | |
| 7 | Pattern: custom middleware | Traditional | | | | |
| 8 | Routing internals | Explore | | | | |
| 8 | Routing internals | Traditional | | | | |
| 9 | JSON binding & validation | Explore | | | | |
| 9 | JSON binding & validation | Traditional | | | | |
| 10 | Panic recovery | Explore | | | | |
| 10 | Panic recovery | Traditional | | | | |

## Flask (Python)

| # | Test | Variant | Calls | Rounds | Pass | Notes |
|---|------|---------|-------|--------|------|-------|
| 11 | Architecture: request context | Explore | | | | |
| 11 | Architecture: request context | Traditional | | | | |
| 12 | Pattern: blueprints | Explore | | | | |
| 12 | Pattern: blueprints | Traditional | | | | |
| 13 | URL routing & dispatch | Explore | | | | |
| 13 | URL routing & dispatch | Traditional | | | | |
| 14 | Error handling | Explore | | | | |
| 14 | Error handling | Traditional | | | | |
| 15 | Response system | Explore | | | | |
| 15 | Response system | Traditional | | | | |

## ripgrep (Rust)

| # | Test | Variant | Calls | Rounds | Pass | Notes |
|---|------|---------|-------|--------|------|-------|
| 16 | Architecture: search pipeline | Explore | | | | |
| 16 | Architecture: search pipeline | Traditional | | | | |
| 17 | Pattern: output formats | Explore | | | | |
| 17 | Pattern: output formats | Traditional | | | | |
| 18 | File filtering & ignore | Explore | | | | |
| 18 | File filtering & ignore | Traditional | | | | |
| 19 | Parallelism model | Explore | | | | |
| 19 | Parallelism model | Traditional | | | | |
| 20 | Modification: new output format | Explore | | | | |
| 20 | Modification: new output format | Traditional | | | | |

---

## Overall Summary

| Metric | Explore | Traditional | Ratio |
|--------|---------|-------------|-------|
| Total tool calls | | | x |
| Total rounds | | | x |
| Pass rate | /20 | /20 | |
