# Python — Debug Benchmark

5 test cases with purpose-built Python programs containing specific bugs.

Run each prompt in a fresh Claude Code session from `bench/debug/python/`.

---

## Test 1: Logic Error — Interval Merge Scheduler

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 01-logic-error/ is a meeting room scheduler that merges overlapping time intervals to determine the minimum number of rooms needed. When you run `python3 01-logic-error/main.py`, it should output "Rooms needed: 3" but instead outputs "Rooms needed: 6".

Diagnose the root cause using the debugger, fix the source code, and verify your fix by running the program again.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-1-debug.json in this format: {"test": 1, "name": "Logic error: interval scheduler", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 01-logic-error/ is a meeting room scheduler that merges overlapping time intervals to determine the minimum number of rooms needed. When you run `python3 01-logic-error/main.py`, it should output "Rooms needed: 3" but instead outputs "Rooms needed: 6".

Diagnose the root cause, fix the source code, and verify your fix by running the program again.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-1-traditional.json in this format: {"test": 1, "name": "Logic error: interval scheduler", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 2: State Mutation — Shopping Cart with Discounts

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 02-state-mutation/ is an e-commerce order calculator with tiered discounts and shipping. When you run `python3 02-state-mutation/main.py`, the order total is wrong — it doesn't match expected_output.txt.

Diagnose the root cause using the debugger, fix the source code, and verify your fix by running the program again. The expected output is in 02-state-mutation/expected_output.txt.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-2-debug.json in this format: {"test": 2, "name": "State mutation: shopping cart", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 02-state-mutation/ is an e-commerce order calculator with tiered discounts and shipping. When you run `python3 02-state-mutation/main.py`, the order total is wrong — it doesn't match expected_output.txt.

Diagnose the root cause, fix the source code, and verify your fix by running the program again. The expected output is in 02-state-mutation/expected_output.txt.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-2-traditional.json in this format: {"test": 2, "name": "State mutation: shopping cart", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 3: Crash — Layered Config Loader

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 03-crash/ loads configuration from defaults, environment overlays, and user overrides via recursive dict merging. When you run `python3 03-crash/main.py`, it should output "Config loaded: 12 settings applied" but instead crashes with an AttributeError.

Use exception breakpoints to catch the crash, inspect the state, and trace back to the root cause. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-3-debug.json in this format: {"test": 3, "name": "Crash: config loader", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 03-crash/ loads configuration from defaults, environment overlays, and user overrides via recursive dict merging. When you run `python3 03-crash/main.py`, it should output "Config loaded: 12 settings applied" but instead crashes with an AttributeError.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-3-traditional.json in this format: {"test": 3, "name": "Crash: config loader", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 4: Concurrency — Pipeline Deadlock

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 04-concurrency/ implements a 3-stage threaded data pipeline with bounded queues. Stage 2 sends feedback to Stage 1. When you run `python3 04-concurrency/main.py`, it should output "Processed 200 items" but instead hangs.

Use the debugger to pause the hung program, inspect all thread states, and identify the source of the hang. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-4-debug.json in this format: {"test": 4, "name": "Concurrency: pipeline deadlock", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 04-concurrency/ implements a 3-stage threaded data pipeline with bounded queues. Stage 2 sends feedback to Stage 1. When you run `python3 04-concurrency/main.py`, it should output "Processed 200 items" but instead hangs.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-4-traditional.json in this format: {"test": 4, "name": "Concurrency: pipeline deadlock", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 5: Silent Wrong Output — Statistics Library

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 05-silent-wrong/ computes a Pearson correlation matrix for a multi-variable dataset. When you run `python3 05-silent-wrong/main.py`, the correlation matrix values are incorrect — they don't match expected_output.txt.

Use the debugger to inspect intermediate values in the correlation computation. Fix the source code and verify against expected_output.txt.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-5-debug.json in this format: {"test": 5, "name": "Silent wrong: correlation matrix", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 05-silent-wrong/ computes a Pearson correlation matrix for a multi-variable dataset. When you run `python3 05-silent-wrong/main.py`, the correlation matrix values are incorrect — they don't match expected_output.txt.

Diagnose the root cause, fix the source code, and verify against expected_output.txt.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/python-5-traditional.json in this format: {"test": 5, "name": "Silent wrong: correlation matrix", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```
