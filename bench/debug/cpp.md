# C++ — Debug Benchmark

5 test cases with purpose-built C++ programs containing specific bugs.

Run each prompt in a fresh Claude Code session from `bench/debug/cpp/`.

---

## Test 11: Logic Error — Binary Search Tree

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 01-logic-error/ is a binary search tree with insert, delete, and in-order traversal. When you run `make -C 01-logic-error && ./01-logic-error/program`, it should output "Traversal: 2 5 8 12 13 15 20" but instead outputs "Traversal: 2 5 8 12 15 20" — the value 13 is lost after deleting a node.

Set breakpoints in the delete operation, inspect the tree structure (node pointers and values), and find where the relinking goes wrong. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-11-debug.json in this format: {"test": 11, "name": "Logic error: BST delete", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 01-logic-error/ is a binary search tree with insert, delete, and in-order traversal. When you run `make -C 01-logic-error && ./01-logic-error/program`, it should output "Traversal: 2 5 8 12 13 15 20" but instead outputs "Traversal: 2 5 8 12 15 20" — the value 13 is lost after deleting a node.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-11-traditional.json in this format: {"test": 11, "name": "Logic error: BST delete", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 12: State Mutation — Ring Buffer

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 02-state-mutation/ is a circular buffer used as a message queue. When you run `make -C 02-state-mutation && ./02-state-mutation/program`, it should receive all 1000 messages correctly but instead reports corrupted messages due to a wrap-around bug.

Use watchpoints on the read/write pointers to catch the state corruption at the buffer capacity boundary. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-12-debug.json in this format: {"test": 12, "name": "State mutation: ring buffer", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 02-state-mutation/ is a circular buffer used as a message queue. When you run `make -C 02-state-mutation && ./02-state-mutation/program`, it should receive all 1000 messages correctly but instead reports corrupted messages due to a wrap-around bug.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-12-traditional.json in this format: {"test": 12, "name": "State mutation: ring buffer", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 13: Crash — Expression Parser

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 03-crash/ is a recursive descent expression parser and evaluator. When you run `make -C 03-crash && ./03-crash/program`, it should output "-(3+4)*2 = -14" but instead crashes with a segfault. The crash involves a use-after-free in the AST.

Use the debugger to catch the crash (exception breakpoint on SIGSEGV), inspect the backtrace and pointer values. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-13-debug.json in this format: {"test": 13, "name": "Crash: expression parser", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 03-crash/ is a recursive descent expression parser and evaluator. When you run `make -C 03-crash && ./03-crash/program`, it should output "-(3+4)*2 = -14" but instead crashes with a segfault. The crash involves a use-after-free in the AST.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-13-traditional.json in this format: {"test": 13, "name": "Crash: expression parser", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 14: Concurrency — Thread Pool Deadlock

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 04-concurrency/ is a work-stealing thread pool. When you run `make -C 04-concurrency && ./04-concurrency/program`, it should output "Completed 500 tasks" but instead hangs after processing some tasks due to a deadlock in the work-stealing logic.

Use the debugger to pause the hung program, inspect all thread stacks, and identify the lock ordering inconsistency. Fix the source code and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-14-debug.json in this format: {"test": 14, "name": "Concurrency: thread pool deadlock", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 04-concurrency/ is a work-stealing thread pool. When you run `make -C 04-concurrency && ./04-concurrency/program`, it should output "Completed 500 tasks" but instead hangs after processing some tasks due to a deadlock in the work-stealing logic.

Diagnose the root cause, fix the source code, and verify your fix.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-14-traditional.json in this format: {"test": 14, "name": "Concurrency: thread pool deadlock", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 15: Silent Wrong Output — Image Convolution

### Debug variant
```
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

The program in 05-silent-wrong/ applies Sobel edge detection convolution to image data. When you run `make -C 05-silent-wrong && ./05-silent-wrong/program`, the Sobel checksum is wrong — the kernel isn't centered on the target pixel correctly.

Set breakpoints in the convolution loop and inspect the kernel coordinate mapping vs pixel coordinates. Fix the source code and verify against expected_output.txt.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-15-debug.json in this format: {"test": 15, "name": "Silent wrong: image convolution", "variant": "debug", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

The program in 05-silent-wrong/ applies Sobel edge detection convolution to image data. When you run `make -C 05-silent-wrong && ./05-silent-wrong/program`, the Sobel checksum is wrong — the kernel isn't centered on the target pixel correctly.

Diagnose the root cause, fix the source code, and verify against expected_output.txt.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to .bench/cpp-15-traditional.json in this format: {"test": 15, "name": "Silent wrong: image convolution", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```
