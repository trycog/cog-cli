# Cog Debug Benchmark

Measures whether cog's interactive debugger (`cog_debug_*` MCP tools) reduces time, turns, and token cost for diagnosing and fixing runtime bugs compared to traditional debugging (reading code, adding print statements, analyzing output).

## Structure

- **20 test programs** across 4 languages (5 per language), each with a specific bug
- **2 variants** per test: `debug` (uses `cog_debug_*` tools) vs `traditional` (standard tools only)
- **Verification**: after Claude fixes the code, the program is run and stdout compared to `expected_output.txt`
- **Reset**: `git checkout` restores broken source between runs

## Languages

| Language | Engine | Tests |
|----------|--------|-------|
| Python | DAP (debugpy) | 1-5 |
| JavaScript | DAP (Node.js) | 6-10 |
| C++ | DWARF (native) | 11-15 |
| Rust | DWARF (native) | 16-20 |

## Bug Categories

Each language has one test per category:

| # | Category | Debugger Advantage |
|---|----------|--------------------|
| 1 | Logic error | Step through algorithm, inspect state at decision points |
| 2 | State mutation | Watchpoints catch unexpected modifications |
| 3 | Crash diagnosis | Exception breakpoints, stack inspection at crash site |
| 4 | Concurrency | Pause hung program, inspect all thread states |
| 5 | Silent wrong output | Inspect intermediate values in computation |

## Quick Start

```bash
# Setup: verify deps, compile programs, configure Claude settings
bash bench/debug/setup.sh

# Run all benchmarks
bash bench/debug/run.sh

# Run specific language/variant
bash bench/debug/run.sh python debug
bash bench/debug/run.sh 'python javascript' 'debug traditional'

# View results
open bench/debug/dashboard.html
```

## Directory Layout

```
bench/debug/
├── README.md
├── setup.sh              # verify deps, configure .mcp.json/.claude/
├── run.sh                # orchestrator (reset → run → verify → record)
├── collect.sh            # aggregate results into dashboard
├── dashboard.html        # D3.js visualization
│
├── python/               # Python test programs
│   ├── 01-logic-error/   # Interval merge scheduler
│   ├── 02-state-mutation/ # Shopping cart with discounts
│   ├── 03-crash/         # Layered config loader
│   ├── 04-concurrency/   # Pipeline deadlock
│   └── 05-silent-wrong/  # Statistics library
│
├── javascript/           # JavaScript test programs
│   ├── 01-logic-error/   # Expression evaluator
│   ├── 02-state-mutation/ # Event middleware
│   ├── 03-crash/         # Async resource pool
│   ├── 04-concurrency/   # Async iterator race
│   └── 05-silent-wrong/  # Data pivot
│
├── cpp/                  # C++ test programs
│   ├── 01-logic-error/   # Binary search tree
│   ├── 02-state-mutation/ # Ring buffer
│   ├── 03-crash/         # Expression parser
│   ├── 04-concurrency/   # Thread pool deadlock
│   └── 05-silent-wrong/  # Image convolution
│
├── rust/                 # Rust test programs
│   ├── 01-logic-error/   # Dijkstra priority queue
│   ├── 02-state-mutation/ # LRU cache
│   ├── 03-crash/         # Multi-format parser
│   ├── 04-concurrency/   # Channel pipeline deadlock
│   └── 05-silent-wrong/  # Binary codec (varint)
│
├── python.md             # 5 prompts (debug + traditional)
├── javascript.md
├── cpp.md
├── rust.md
│
└── .bench/               # result JSON files
```

## Metrics

Each test result records:
- `calls`: number of tool invocations
- `rounds`: number of LLM round-trips
- `cost_usd`: total API cost
- `duration_ms`: wall clock time
- `input_tokens` / `output_tokens`: token usage
- `verified`: whether the fix actually produced correct output

## Reset Mechanism

Source files are committed to git in their broken state. Before each test run:
```bash
git checkout -- bench/debug/{lang}/{test}/
```

This restores the original broken source deterministically.
