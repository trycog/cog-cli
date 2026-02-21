# Rust — Debug Benchmark

5 test cases with purpose-built Rust programs containing specific bugs.

Run each prompt in a fresh Claude Code session from `bench/debug/rust/`.

---

## Test 16: Logic Error — Priority Queue / Dijkstra's

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 01-logic-error/ implements Dijkstra's shortest path algorithm using a custom binary heap priority queue and a graph construction module. When you run `cd 01-logic-error && cargo run 2>/dev/null`, it should output "Shortest A->E: cost 7, path A -> B -> D -> E" but instead finds a suboptimal path with cost 10.

Use the debugger to trace which edges are explored during the search and inspect the graph structure. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-16-debug.json in this format: {"test": 16, "name": "Logic error: Dijkstra priority queue", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 01-logic-error/ implements Dijkstra's shortest path algorithm using a custom binary heap priority queue and a graph construction module. When you run `cd 01-logic-error && cargo run 2>/dev/null`, it should output "Shortest A->E: cost 7, path A -> B -> D -> E" but instead finds a suboptimal path with cost 10.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-16-traditional.json in this format: {"test": 16, "name": "Logic error: Dijkstra priority queue", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```

---

## Test 17: State Mutation — LRU Cache

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 02-state-mutation/ is an LRU cache with HashMap + doubly linked list. When you run `cd 02-state-mutation && cargo run 2>/dev/null`, it should report all lookups correct but instead shows incorrect lookups and a lower hit rate due to linked list corruption.

Use the debugger to inspect the cache's internal data structure state. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-17-debug.json in this format: {"test": 17, "name": "State mutation: LRU cache", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 02-state-mutation/ is an LRU cache with HashMap + doubly linked list. When you run `cd 02-state-mutation && cargo run 2>/dev/null`, it should report all lookups correct but instead shows incorrect lookups and a lower hit rate due to linked list corruption.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-17-traditional.json in this format: {"test": 17, "name": "State mutation: LRU cache", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```

---

## Test 18: Crash — Multi-Format Parser

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 03-crash/ detects file format (JSON/config/CSV) and parses accordingly. When you run `cd 03-crash && cargo run 2>/dev/null`, it should output "Parsed config: 5 values loaded" but instead panics unexpectedly.

Use exception breakpoints to catch the panic, inspect the backtrace, and trace back to the root cause. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-18-debug.json in this format: {"test": 18, "name": "Crash: multi-format parser", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 03-crash/ detects file format (JSON/config/CSV) and parses accordingly. When you run `cd 03-crash && cargo run 2>/dev/null`, it should output "Parsed config: 5 values loaded" but instead panics unexpectedly.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-18-traditional.json in this format: {"test": 18, "name": "Crash: multi-format parser", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```

---

## Test 19: Concurrency — Channel Pipeline Deadlock

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 04-concurrency/ is a 3-stage pipeline with bounded mpsc channels. Stage 2 sends feedback to Stage 1. When you run `cd 04-concurrency && cargo run 2>/dev/null`, it should output "Processed 500 records" but instead hangs.

Use the debugger to pause the hung program, inspect all thread stacks, and identify the source of the hang. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-19-debug.json in this format: {"test": 19, "name": "Concurrency: channel pipeline deadlock", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 04-concurrency/ is a 3-stage pipeline with bounded mpsc channels. Stage 2 sends feedback to Stage 1. When you run `cd 04-concurrency && cargo run 2>/dev/null`, it should output "Processed 500 records" but instead hangs.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-19-traditional.json in this format: {"test": 19, "name": "Concurrency: channel pipeline deadlock", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```

---

## Test 20: Silent Wrong Output — Binary Codec

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 05-silent-wrong/ implements a variable-length integer codec (varint) with separate encoder and decoder modules. When you run `cd 05-silent-wrong && cargo run 2>/dev/null`, single-byte values (0-127) roundtrip correctly but multi-byte values decode to wrong values.

Use the debugger to inspect the encoded bytes and trace the decode process to find the mismatch between encoder and decoder. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-20-debug.json in this format: {"test": 20, "name": "Silent wrong: binary codec", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 05-silent-wrong/ implements a variable-length integer codec (varint) with separate encoder and decoder modules. When you run `cd 05-silent-wrong && cargo run 2>/dev/null`, single-byte values (0-127) roundtrip correctly but multi-byte values decode to wrong values.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/rust-20-traditional.json in this format: {"test": 20, "name": "Silent wrong: binary codec", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../../collect.sh
```
