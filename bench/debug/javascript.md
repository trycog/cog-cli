# JavaScript — Debug Benchmark

5 test cases with purpose-built JavaScript programs containing specific bugs.

Run each prompt in a fresh Claude Code session from `bench/debug/javascript/`.

---

## Test 6: Logic Error — Expression Evaluator

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 01-logic-error/ is a math expression parser with operator precedence. When you run `node 01-logic-error/main.js`, it should output "2^3^2 = 512" (right-associative exponentiation: 2^(3^2) = 2^9) but instead outputs "2^3^2 = 64" (left-associative: (2^3)^2 = 64).

Step through the parser's precedence climbing to find where right-associativity is handled incorrectly. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-6-debug.json in this format: {"test": 6, "name": "Logic error: expression evaluator", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 01-logic-error/ is a math expression parser with operator precedence. When you run `node 01-logic-error/main.js`, it should output "2^3^2 = 512" (right-associative exponentiation: 2^(3^2) = 2^9) but instead outputs "2^3^2 = 64" (left-associative: (2^3)^2 = 64).

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-6-traditional.json in this format: {"test": 6, "name": "Logic error: expression evaluator", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 7: State Mutation — Event Middleware

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 02-state-mutation/ is an event system with middleware factories that enrich events before delivery to handlers. The emitter deep-clones events so each handler gets an independent copy. When you run `node 02-state-mutation/main.js`, it should output "OK: Handler B received clean event, no cross-handler leakage" but instead shows Handler B received metadata contaminated by Handler A's middleware.

Use the debugger to inspect the middleware state and how context is shared across middleware instances. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-7-debug.json in this format: {"test": 7, "name": "State mutation: event middleware", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 02-state-mutation/ is an event system with middleware factories that enrich events before delivery to handlers. The emitter deep-clones events so each handler gets an independent copy. When you run `node 02-state-mutation/main.js`, it should output "OK: Handler B received clean event, no cross-handler leakage" but instead shows Handler B received metadata contaminated by Handler A's middleware.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-7-traditional.json in this format: {"test": 7, "name": "State mutation: event middleware", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 8: Crash — Async Resource Pool

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 03-crash/ is an async connection pool with checkout/release lifecycle. When you run `node 03-crash/main.js`, it should complete all 50 operations but instead crashes with a TypeError after ~15 operations due to pool corruption.

Use exception breakpoints to catch the crash, inspect the pool state, and trace back to the root cause. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-8-debug.json in this format: {"test": 8, "name": "Crash: async resource pool", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 03-crash/ is an async connection pool with checkout/release lifecycle. When you run `node 03-crash/main.js`, it should complete all 50 operations but instead crashes with a TypeError after ~15 operations due to pool corruption.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-8-traditional.json in this format: {"test": 8, "name": "Crash: async resource pool", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 9: Concurrency — Parallel Workers with Cache

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 04-concurrency/ uses a WorkScheduler to partition paginated API data across two parallel workers. A shared cache deduplicates API calls. When you run `node 04-concurrency/main.js`, it should output "Processed 100 unique items" but instead outputs "Processed 200 items (100 unique)" — double the expected count.

Use the debugger to trace how work is partitioned and assigned to each worker. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-9-debug.json in this format: {"test": 9, "name": "Concurrency: parallel workers with cache", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 04-concurrency/ uses a WorkScheduler to partition paginated API data across two parallel workers. A shared cache deduplicates API calls. When you run `node 04-concurrency/main.js`, it should output "Processed 100 unique items" but instead outputs "Processed 200 items (100 unique)" — double the expected count.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-9-traditional.json in this format: {"test": 9, "name": "Concurrency: parallel workers with cache", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 10: Silent Wrong Output — Data Pivot

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 05-silent-wrong/ groups and pivots tabular sales data by year using a stats module for summation. When you run `node 05-silent-wrong/main.js`, it should output "Pivot: 2021=$1200 2022=$1500 2023=$1800 2024=$2100" but instead outputs "Pivot: 2021=$1200 2022=$2700 2023=$4500 2024=$6600" — values grow cumulatively instead of being independent per year.

Use the debugger to inspect intermediate values in the summation and aggregation steps. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-10-debug.json in this format: {"test": 10, "name": "Silent wrong: data pivot", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 05-silent-wrong/ groups and pivots tabular sales data by year using a stats module for summation. When you run `node 05-silent-wrong/main.js`, it should output "Pivot: 2021=$1200 2022=$1500 2023=$1800 2024=$2100" but instead outputs "Pivot: 2021=$1200 2022=$2700 2023=$4500 2024=$6600" — values grow cumulatively instead of being independent per year.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/javascript-10-traditional.json in this format: {"test": 10, "name": "Silent wrong: data pivot", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```
