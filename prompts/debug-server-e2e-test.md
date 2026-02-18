# Cog Debug Server — End-to-End Test Prompt

## How the Debug CLI Works

Each debug tool is a subcommand of `cog debug/send`. An agent calls
`cog debug/send launch /tmp/test --stop-on-entry --language c` via Bash and gets clean JSON back.
No JSON arguments, no coprocess, no protocol management.

```
AI Agent --Bash--> cog debug/send <tool> [args] [--flags] --Unix socket--> debug daemon (auto-started)
```

### Using the CLI

Each `debug/send <tool>` command uses proper CLI flags and positional arguments. The daemon is
auto-started on first use — no setup required.

```bash
# Launch a program under the debugger
cog debug/send launch /tmp/debug_test --stop-on-entry --language c
# → {"session_id":"session-1","status":"stopped",...}

# Set a breakpoint
cog debug/send breakpoint_set /tmp/debug_test.c:4 --session session-1
# → {"breakpoints":[{"id":1,"verified":true,"line":4,...}]}

# Continue execution
cog debug/send run continue --session session-1
# → {"stop_reason":"breakpoint","location":{...},"locals":[...]}

# Inspect a variable
cog debug/send inspect a --session session-1
# → {"result":"10","type":"int",...}

# Stop the session
cog debug/send stop --session session-1
```

The daemon maintains state (sessions, breakpoints) across calls. On error, the command exits
with code 1 and prints the error to stderr.

### Debug tools (38 total)

#### Core Tools (5)

##### `debug/send launch` — Start a debug session
```json
{"program": "/path/to/executable", "args": ["arg1", "arg2"], "stop_on_entry": true, "language": "c"}
```
Optional: `env` (object), `cwd` (string)
Returns: `{"session_id": "session-1", "status": "stopped"}`

##### `debug/send stop` — End a debug session
```json
{"session_id": "session-1"}
```
Optional: `terminate_only` (boolean), `detach` (boolean)

##### `debug/send attach` — Attach to a running process
```json
{"pid": 12345, "language": "c"}
```
Returns: `{"session_id": "session-1", "status": "stopped"}`

##### `debug/send restart` — Restart the debug session
```json
{"session_id": "session-1"}
```
Returns: `{"restarted": true}`

##### `debug/send sessions` — List all active debug sessions
```json
{}
```
Returns: array of `{"id": "session-1", "status": "stopped", "driver_type": "native"}`

#### Breakpoint Tools (5)

Each breakpoint action has its own tool (no `action` field needed):

##### `debug/send breakpoint_set` — Set a line breakpoint
```json
{"session_id": "session-1", "file": "/path/to/source.c", "line": 10}
```
Optional: `condition`, `hit_condition`, `log_message`

##### `debug/send breakpoint_set_function` — Set a function breakpoint
```json
{"session_id": "session-1", "function": "add"}
```
Optional: `condition`

##### `debug/send breakpoint_set_exception` — Set exception breakpoints
```json
{"session_id": "session-1", "filters": ["uncaught", "raised"]}
```

##### `debug/send breakpoint_remove` — Remove a breakpoint by ID
```json
{"session_id": "session-1", "id": 1}
```

##### `debug/send breakpoint_list` — List all breakpoints
```json
{"session_id": "session-1"}
```

#### Execution Control (1)

##### `debug/send run` — Control execution
```json
{"session_id": "session-1", "action": "continue"}
```
Actions: `continue`, `step_into`, `step_over`, `step_out`, `restart`, `pause`, `goto`,
`reverse_continue`, `step_back`

Optional: `granularity` (`"statement"`, `"line"`, `"instruction"`), `file` + `line` (for goto),
`target_id` (for targeted step-in), `thread_id`

Returns: `{"stop_reason": "breakpoint|step|entry|...", "location": {...}, "locals": [...], "stack_trace": [...]}`

#### Inspection Tools (3)

##### `debug/send inspect` — Evaluate expressions and inspect variables
```json
// Basic expression
{"session_id": "session-1", "expression": "a + b"}

// With evaluation context
{"session_id": "session-1", "expression": "x", "context": "watch", "frame_id": 0}

// By variable reference (for expanding children)
{"session_id": "session-1", "variable_ref": 1001}

// By scope
{"session_id": "session-1", "scope": "locals"}
```
Contexts: `watch`, `repl`, `hover`, `clipboard`
Scopes: `locals`, `globals`, `arguments`

##### `debug/send set_variable` — Set the value of a variable
```json
{"session_id": "session-1", "variable": "x", "value": "42", "frame_id": 0}
```

##### `debug/send set_expression` — Evaluate and assign a complex expression
```json
{"session_id": "session-1", "expression": "result", "value": "999", "frame_id": 0}
```

#### Thread and Stack Tools (3)

##### `debug/send threads` — List threads
```json
{"session_id": "session-1"}
```
Returns: `{"threads": [{"id": 1, "name": "main"}]}`

##### `debug/send stacktrace` — Get stack trace for a thread
```json
{"session_id": "session-1", "thread_id": 1, "start_frame": 0, "levels": 20}
```
Returns: `{"stack_trace": [{"id": 0, "name": "add", "source": "debug_test.c", "line": 4, "column": 0}, ...]}`

##### `debug/send scopes` — List variable scopes for a stack frame
```json
{"session_id": "session-1", "frame_id": 0}
```
Returns: `{"scopes": [{"name": "Locals", "variablesReference": 1001, "expensive": false}, ...]}`

#### Memory and Low-Level Tools (5)

##### `debug/send memory` — Read or write process memory
```json
// Read
{"session_id": "session-1", "action": "read", "address": "0x1000", "size": 64}

// Read with byte offset
{"session_id": "session-1", "action": "read", "address": "0x1000", "size": 16, "offset": 4}

// Write hex data
{"session_id": "session-1", "action": "write", "address": "0x1000", "data": "deadbeef"}
```

##### `debug/send disassemble` — Disassemble instructions at an address
```json
{"session_id": "session-1", "address": "0x1000", "instruction_count": 10, "resolve_symbols": true}
```
Returns: `{"instructions": [{"address": "0x1000", "instruction": "push rbp", "instructionBytes": "55"}, ...]}`

##### `debug/send registers` — Read CPU register values (native engine only)
```json
{"session_id": "session-1", "thread_id": 1}
```

##### `debug/send write_register` — Write a value to a CPU register (native engine only)
```json
{"session_id": "session-1", "name": "rax", "value": 42, "thread_id": 0}
```

##### `debug/send instruction_breakpoint` — Set instruction-level breakpoints
```json
{"session_id": "session-1", "instruction_reference": "0x100003f00"}
```
Optional: `offset`, `condition`, `hit_condition`

#### Breakpoint Discovery Tools (1)

##### `debug/send breakpoint_locations` — Query valid breakpoint positions
```json
{"session_id": "session-1", "source": "/tmp/debug_test.c", "line": 4, "end_line": 10}
```
Returns: `{"breakpoints": [{"line": 4, "column": 0, "endLine": 4, "endColumn": 0}, ...]}`

#### Navigation Tools (3)

##### `debug/send goto_targets` — Discover valid goto target locations
```json
{"session_id": "session-1", "file": "/tmp/debug_test.c", "line": 16}
```

##### `debug/send step_in_targets` — List step-in targets for a stack frame
```json
{"session_id": "session-1", "frame_id": 0}
```
Returns: `{"targets": [{"id": 1, "label": "add"}, {"id": 2, "label": "multiply"}]}`

##### `debug/send restart_frame` — Restart execution from a specific stack frame
```json
{"session_id": "session-1", "frame_id": 0}
```

#### Data Breakpoint Tools (1)

##### `debug/send watchpoint` — Set a data breakpoint on a variable
```json
{"session_id": "session-1", "variable": "total", "access_type": "write", "frame_id": 0}
```
Access types: `read`, `write`, `readWrite`

#### Session and Capability Tools (2)

##### `debug/send capabilities` — Query debug driver capabilities
```json
{"session_id": "session-1"}
```

##### `debug/send completions` — Get completions for variable names and expressions
```json
{"session_id": "session-1", "text": "res", "column": 3, "frame_id": 0}
```

#### Introspection Tools (3)

##### `debug/send modules` — List loaded modules and shared libraries
```json
{"session_id": "session-1"}
```

##### `debug/send loaded_sources` — List all source files available
```json
{"session_id": "session-1"}
```

##### `debug/send source` — Retrieve source code by source reference
```json
{"session_id": "session-1", "source_reference": 1}
```

#### Exception and Event Tools (2)

##### `debug/send exception_info` — Get detailed exception information
```json
{"session_id": "session-1", "thread_id": 1}
```

##### `debug/send poll_events` — Poll for pending debug events
```json
// Poll all sessions
{}

// Poll specific session
{"session_id": "session-1"}
```

#### Cancellation Tools (2)

##### `debug/send cancel` — Cancel a pending debug request
```json
{"session_id": "session-1", "request_id": 5}
```

##### `debug/send terminate_threads` — Terminate specific threads
```json
{"session_id": "session-1", "thread_ids": [1, 2]}
```

#### Native Engine Only Tools (2)

These tools only work with the native debug engine (not DAP proxy sessions).

##### `debug/send find_symbol` — Search for symbol definitions by name
```json
{"session_id": "session-1", "name": "add"}
```

##### `debug/send variable_location` — Get physical storage location of a variable
```json
{"session_id": "session-1", "name": "x", "frame_id": 0}
```

---

## Test Programs

### Setup

Before running any scenarios, reset and compile all test fixtures:

```bash
bash prompts/fixtures/setup.sh
```

This copies the source files from `prompts/fixtures/` to `/tmp/` and compiles them with
`cc -g -O0`. Run the setup script at the start of every session to ensure clean state.

### Programs

| Program | Source | Binary | Used by |
|---------|--------|--------|---------|
| A: Basic | `/tmp/debug_test.c` | `/tmp/debug_test` | Scenarios 1-11, 14-18, 20-28, 30-33 |
| B: Crasher | `/tmp/debug_crash.c` | `/tmp/debug_crash` | Scenario 19 |
| C: Sleeper | `/tmp/debug_sleep.c` | `/tmp/debug_sleep` | Attach testing |
| D: Multi-variable | `/tmp/debug_vars.c` | `/tmp/debug_vars` | Scenarios 12-13, 29 |

### Key Line References

**Program A** (`debug_test.c`):
- Line 4: `int result = a + b;` (inside `add()`)
- Line 5: `return result;` (inside `add()`)
- Line 9: `int result = a * b;` (inside `multiply()`)
- Line 14: `int sum = add(x, y);` (inside `compute()`)
- Line 15: `int product = multiply(x, y);` (inside `compute()`)
- Line 16: `int final = sum + product;` (inside `compute()`)
- Line 21: `int total = 0;` (inside `loop_sum()`)
- Line 23: `total = add(total, i);` (loop body in `loop_sum()`)
- Line 29: `if (n <= 1) return 1;` (inside `factorial()`)
- Line 34: `int x = 10;` (inside `main()`)
- Line 36: `int result1 = compute(x, y);` (inside `main()`)
- Line 37: `printf("compute = %d\n", result1);` (inside `main()`)

**Program B** (`debug_crash.c`):
- Line 6: `return a / b;` (divide by zero)
- Line 11: `printf("%d\n", *p);` (null deref, SIGSEGV)
- Line 15: `abort();` (SIGABRT)

**Program D** (`debug_vars.c`):
- Line 19: `int local3 = local1 * local2;` (inside `process()`)
- Line 31: `modify(&x, 3);` (inside `main()`)

---

## Test Scenarios

Each scenario is independent. For each debug command, report:

1. **What you're doing** — state the action and why
2. **The raw response** — show the full response from the tool
3. **Interpretation** — explain what the response means
4. **Current debugger state** — summarize active sessions, breakpoints, execution position

---

### Part 1: Core Debugging (Scenarios 1-10)

These test the fundamental debug loop using Program A.

### Scenario 1: Basic Breakpoint + Continue + Inspect

This is the baseline test. Verify the fundamental debug loop works.

1. `debug/send launch` with `program: "/tmp/debug_test"`, `stop_on_entry: true`
2. `debug/send breakpoint_set` with `session_id`, `file: "/tmp/debug_test.c"`, `line: 4`
3. `debug/send run` with `action: "continue"` — should hit the breakpoint
4. `debug/send inspect` with `expression: "a"` — should be 10
5. `debug/send inspect` with `expression: "b"` — should be 20
6. `debug/send inspect` with `expression: "a + b"` — should be 30
7. `debug/send stop` with `session_id`

**Expected values:** `a=10`, `b=20`, `a + b = 30`

### Scenario 2: Step Into and Step Out

Test function call boundary navigation.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 36 (`int result1 = compute(x, y);` in `main()`)
3. `debug/send run` with `action: "continue"` to hit line 36
4. `debug/send inspect` with `expression: "x"` and `expression: "y"` to confirm `main()` context
5. `debug/send run` with `action: "step_into"` — should enter `compute()`, landing at line 14
6. Inspect to confirm `compute()` scope
7. `debug/send run` with `action: "step_into"` again — should enter `add()` at line 4
8. `debug/send inspect` for `a` and `b` inside `add()` — should be 10 and 20
9. `debug/send run` with `action: "step_out"` — should return to `compute()`
10. `debug/send inspect` with `expression: "sum"` — should be 30
11. `debug/send stop`

**What this tests:** Crossing function boundaries in both directions. Verifies that variable
scopes change correctly when stepping into/out of functions.

### Scenario 3: Multiple Breakpoints with Continue

Test hitting multiple breakpoints in sequence using continue.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`)
3. `debug/send breakpoint_set` at line 9 (inside `multiply()`)
4. `debug/send breakpoint_set` at line 16 (`int final = sum + product;` in `compute()`)
5. `debug/send breakpoint_list` — verify all 3 are set and verified
6. `debug/send run` with `action: "continue"` — should hit line 4
7. `debug/send inspect` for `a` and `b`
8. `debug/send run` with `action: "continue"` — should hit line 9
9. `debug/send inspect` for `a` and `b`
10. `debug/send run` with `action: "continue"` — should hit line 16
11. `debug/send inspect` for `sum`, `product`, and `sum + product`
12. `debug/send stop`

**What this tests:** The debugger correctly arms multiple breakpoints and hits them in execution
order. Each continue resumes and stops at the next breakpoint.

### Scenario 4: Breakpoint in a Loop

Test that a breakpoint inside a loop is hit on each iteration.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 23 (`total = add(total, i);` in `loop_sum()`)
3. `debug/send run` with `action: "continue"` — should hit line 23 (i=1)
4. `debug/send inspect` for `i` and `total`
5. `debug/send run` with `action: "continue"` — should hit line 23 again (i=2)
6. `debug/send inspect` for `i` and `total`
7. `debug/send run` with `action: "continue"` — should hit line 23 again (i=3)
8. `debug/send inspect` for `i` and `total`
9. Continue two more times to get through i=4 and i=5
10. Continue — should NOT hit the breakpoint again (loop ended)
11. `debug/send stop`

**What this tests:** Breakpoints inside loops fire on every iteration. The breakpoint
re-arming logic (step past INT3, re-insert trap) works correctly across multiple hits.

**Expected values per iteration:**
| Hit | i | total (before add) |
|-----|---|-------------------|
| 1   | 1 | 0                 |
| 2   | 2 | 1                 |
| 3   | 3 | 3                 |
| 4   | 4 | 6                 |
| 5   | 5 | 10                |

### Scenario 5: Step Over

Test that step_over executes a function call without entering it.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 14 (`int sum = add(x, y);` in `compute()`)
3. `debug/send run` with `action: "continue"` to hit line 14
4. `debug/send run` with `action: "step_over"` — should execute `add()` entirely, stop at line 15
5. `debug/send inspect` with `expression: "sum"` — should be 30
6. `debug/send run` with `action: "step_over"` — should execute `multiply()`, stop at line 16
7. `debug/send inspect` with `expression: "product"` — should be 200
8. `debug/send inspect` with `expression: "sum + product"` — should be 230
9. `debug/send stop`

**What this tests:** step_over treats function calls as atomic operations, executing them
fully and stopping at the next line in the current function.

### Scenario 6: Breakpoint Removal and List

Test breakpoint lifecycle management.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 — note the returned breakpoint ID
3. `debug/send breakpoint_set` at line 9 — note the returned breakpoint ID
4. `debug/send breakpoint_set` at line 34 — note the returned breakpoint ID
5. `debug/send breakpoint_list` — verify all 3 are present and verified
6. `debug/send breakpoint_remove` with the ID from line 4
7. `debug/send breakpoint_list` — verify only 2 remain
8. `debug/send run` with `action: "continue"` — should hit line 34 (main), NOT line 4 (removed)
9. `debug/send run` with `action: "continue"` — should hit line 9 (multiply), confirming line 4 was skipped
10. `debug/send stop`

**What this tests:** Breakpoint removal actually disarms the trap instruction. The removed
breakpoint is no longer hit during execution.

### Scenario 7: Recursive Function Debugging

Test debugging through recursive calls.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 29 (`if (n <= 1) return 1;` in `factorial()`)
3. `debug/send run` with `action: "continue"` — should hit line 29 with `n=5`
4. `debug/send inspect` with `expression: "n"`
5. `debug/send run` with `action: "continue"` — should hit line 29 with `n=4`
6. `debug/send inspect` with `expression: "n"`
7. `debug/send run` with `action: "continue"` — should hit line 29 with `n=3`
8. `debug/send inspect` with `expression: "n"`
9. Continue through remaining recursion levels (n=2, n=1)
10. On `n=1`, the base case triggers — continue should exit the recursion
11. `debug/send stop`

**What this tests:** Breakpoints fire at each recursion depth. Variable inspection shows
the correct value of `n` at each depth level, confirming the debugger reads the correct
stack frame.

### Scenario 8: Arithmetic Expression Evaluation

Test the expression evaluator with various operators.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`)
3. `debug/send run` with `action: "continue"` to hit the breakpoint
4. Inspect these expressions and verify results:
   - `debug/send inspect` with `expression: "a"` — should be 10
   - `debug/send inspect` with `expression: "b"` — should be 20
   - `debug/send inspect` with `expression: "a + b"` — should be 30
   - `debug/send inspect` with `expression: "a - b"` — should be -10
   - `debug/send inspect` with `expression: "a * b"` — should be 200
   - `debug/send inspect` with `expression: "a / b"` — should be 0 (integer division)
   - `debug/send inspect` with `expression: "b / a"` — should be 2
5. `debug/send stop`

**What this tests:** All four arithmetic operators in the expression evaluator. Integer
division truncation behavior.

### Scenario 9: Restart

Test restarting a debug session without re-launching.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 34 (`int x = 10;` in `main()`)
3. `debug/send run` with `action: "continue"` to hit line 34
4. `debug/send run` with `action: "continue"` to let the program run to completion
5. `debug/send restart` — should restart the session
6. The response should indicate `stop_reason: "entry"`
7. `debug/send run` with `action: "continue"` — should hit line 34 again
8. `debug/send inspect` with `expression: "x"` to confirm fresh execution
9. `debug/send stop`

**What this tests:** The restart action kills the process, re-spawns it, and re-arms all
breakpoints. The session ID remains the same.

### Scenario 10: Error Handling

Test the server's response to invalid inputs.

1. `debug/send launch` with `program: "/tmp/debug_test"`
2. `debug/send run` with an invalid `session_id: "nonexistent"` — should return an error
3. `debug/send breakpoint_set` with `session_id` but missing `file` — should return an error
4. `debug/send run` with `action: "invalid_action"` — should return an error
5. `debug/send stop` with the valid session ID

**What this tests:** The server returns proper error responses with appropriate
error codes instead of crashing.

---

### Part 2: Threads, Stacks, and Scopes (Scenarios 11-13)

### Scenario 11: Thread Listing and Stack Traces

Test thread enumeration and stack trace retrieval with pagination.

Uses Program A.

1. `debug/send launch` with `/tmp/debug_test`, `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`)
3. `debug/send run` with `action: "continue"` to hit the breakpoint
4. `debug/send threads` — should return at least one thread (the main thread)
5. Verify the thread has an `id` and `name` field
6. `debug/send stacktrace` with default parameters — should show `add` -> `compute` -> `main`
7. `debug/send stacktrace` with `start_frame: 1, levels: 1` — should return only the `compute` frame
8. `debug/send stacktrace` with `levels: 2` — should return only 2 frames (`add` and `compute`)
9. `debug/send stop`

**What this tests:** Thread listing works. Stack trace returns correct call chain. Pagination
parameters (`start_frame`, `levels`) correctly limit the returned frames.

### Scenario 12: Scopes

Test variable scope enumeration for a stack frame.

Uses Program D (`/tmp/debug_vars`).

1. `debug/send launch` with `/tmp/debug_vars`, `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 19 (`int local3 = local1 * local2;` inside `process()`)
3. `debug/send run` with `action: "continue"` to hit the breakpoint
4. `debug/send scopes` with `frame_id: 0` — should return scope objects
5. Each scope should have `name`, `variablesReference` (integer), and `expensive` (boolean)
6. Use the `variablesReference` from the "Locals" scope to call `debug/send inspect` with `variable_ref` — should return `local1` and `local2` variables
7. `debug/send stop`

**What this tests:** Scope hierarchy is exposed correctly. Variable references can be used
to drill into scope contents.

### Scenario 13: Set Variable and Set Expression

Test modifying variable values during debugging.

Uses Program D (`/tmp/debug_vars`).

1. `debug/send launch` with `/tmp/debug_vars`, `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 31 (`modify(&x, 3);` in `main()`)
3. `debug/send run` with `action: "continue"` to hit the breakpoint
4. `debug/send inspect` with `expression: "x"` — should be 5
5. `debug/send set_variable` with `variable: "x"`, `value: "42"`
6. `debug/send inspect` with `expression: "x"` — should now be 42
7. `debug/send run` with `action: "step_over"` — `x` should become 45 (42 + 3)
8. `debug/send inspect` with `expression: "x"` — should be 45
9. `debug/send set_expression` with `expression: "y"`, `value: "99"`
10. `debug/send inspect` with `expression: "y"` — should be 99
11. `debug/send stop`

**What this tests:** Variable modification works and persists through execution. Both
`debug/send set_variable` and `debug/send set_expression` can alter program state.

---

### Part 3: Memory and Low-Level (Scenarios 14-16)

### Scenario 14: Memory Read and Disassembly

Test reading memory and disassembling instructions at the current PC.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`)
3. `debug/send run` with `action: "continue"` to hit the breakpoint
4. Get the current PC from the stop state's `location` (or from `debug/send registers`)
5. `debug/send memory` with `action: "read"`, PC address, `size: 32` — should return hex bytes
6. Verify the response has `data` (hex string), `address`, and `size` fields
7. `debug/send disassemble` with the PC address, `instruction_count: 5` — should return disassembled instructions
8. Verify each instruction has `address`, `instruction` (mnemonic), and optionally `instructionBytes`
9. `debug/send memory` with `action: "read"`, `address: "0x0"`, `size: 1` — should fail (invalid address)
10. `debug/send stop`

**What this tests:** Memory reads at valid addresses return hex data. Disassembly produces
instruction mnemonics. Invalid memory addresses produce errors rather than crashes.

### Scenario 15: Instruction Breakpoints

Test setting breakpoints by memory address rather than source line.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`)
3. `debug/send run` with `action: "continue"` to hit line 4
4. `debug/send disassemble` at the current PC to get instruction addresses
5. `debug/send breakpoint_remove` for the source breakpoint
6. `debug/send run` with `action: "continue"` to proceed past `add()`
7. `debug/send instruction_breakpoint` with an address from step 4
8. `debug/send run` with `action: "continue"` — should hit the instruction breakpoint on next `add()` call
9. Verify the stop reason indicates an instruction breakpoint
10. `debug/send stop`

**What this tests:** Instruction-level breakpoints can be set by address and fire correctly.
This exercises a different breakpoint path than source-line breakpoints.

### Scenario 16: CPU Registers (Native Engine Only)

Test reading and writing CPU registers.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`)
3. `debug/send run` with `action: "continue"` to hit the breakpoint
4. `debug/send registers` — should return register name/value pairs
5. Verify key registers are present (e.g., `rip`/`pc`, `rsp`/`sp`, `rbp`/`fp`)
6. Note the value of `rip` — it should match the address in the stop location
7. `debug/send variable_location` with `name: "a"` — should indicate register or stack location
8. `debug/send find_symbol` with `name: "add"` — should return symbol information
9. `debug/send stop`

**What this tests:** Register reads return valid data. Variable location tracking works.
Symbol lookup resolves function names to addresses.

**Note:** If the session uses a DAP proxy backend, these tools will return `NOT_SUPPORTED`
errors (error code -32001). That is also valid behavior to verify.

---

### Part 4: Advanced Breakpoints (Scenarios 17-19)

### Scenario 17: Function Breakpoints

Test setting breakpoints by function name instead of file:line.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set_function` with `function: "multiply"`
3. `debug/send run` with `action: "continue"` — should hit when `multiply()` is called
4. `debug/send inspect` for `a` and `b` — should be 10 and 20
5. Verify the stop location references the `multiply` function
6. `debug/send breakpoint_list` — the function breakpoint should be listed
7. `debug/send stop`

**What this tests:** Function breakpoints resolve the function name to an address and fire
when execution enters the function.

### Scenario 18: Breakpoint Locations

Test querying valid breakpoint positions in a source file.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_locations` with `source: "/tmp/debug_test.c"`, `line: 3`, `end_line: 6`
   — should return valid breakpoint positions within `add()` (lines 4 and 5 at minimum)
3. `debug/send breakpoint_locations` with `source: "/tmp/debug_test.c"`, `line: 12`
   — query a single line, may return line 14 as the nearest valid position
4. Verify each result has `line` and optionally `endLine`, `column`, `endColumn`
5. `debug/send stop`

**What this tests:** The debugger can report which source locations are valid breakpoint
targets. This is critical for IDEs that need to snap breakpoints to valid positions.

### Scenario 19: Exception Breakpoints and Exception Info

Test exception/signal breakpoint configuration and exception information retrieval.

Uses Program B (`/tmp/debug_crash`).

1. `debug/send launch` with `/tmp/debug_crash`, `args: ["null"]`, `stop_on_entry: true`
2. `debug/send breakpoint_set_exception` with `filters: ["uncaught"]`
3. `debug/send run` with `action: "continue"` — should crash with SIGSEGV at line 11
4. The stop reason should indicate an exception or signal
5. `debug/send exception_info` — should return exception details
6. Verify the response has `exceptionId` (required), `breakMode` (required), and optionally `description` and `details`
7. `debug/send stop`

**What this tests:** Exception breakpoints cause the debugger to stop on signals/exceptions.
Exception info retrieves structured details about what went wrong.

---

### Part 5: Navigation (Scenarios 20-22)

### Scenario 20: Goto Targets and Goto Execution

Test discovering and jumping to goto targets.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 14 (`int sum = add(x, y);` in `compute()`)
3. `debug/send run` with `action: "continue"` to hit line 14
4. `debug/send goto_targets` with `file: "/tmp/debug_test.c"`, `line: 16`
5. If targets are returned, `debug/send run` with `action: "goto"`, `file: "/tmp/debug_test.c"`, `line: 16`
   — should jump to line 16, skipping `add()` and `multiply()` calls
6. `debug/send inspect` for `sum` and `product` — may be uninitialized/zero
7. `debug/send stop`

**What this tests:** Goto targets can be discovered for a source location. The goto action
repositions execution to a different line within the same function.

### Scenario 21: Step-In Targets

Test listing available step-in targets when a line has multiple function calls.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 36 (`int result1 = compute(x, y);` in `main()`)
3. `debug/send run` with `action: "continue"` to hit line 36
4. `debug/send step_in_targets` with `frame_id: 0` — should list `compute` as a target
5. Record the target IDs returned
6. `debug/send breakpoint_set` at line 14 and continue to hit it
7. `debug/send step_in_targets` with `frame_id: 0` — should list `add` as a target
8. `debug/send stop`

**What this tests:** Step-in targets enumerate the callable functions at the current execution
point.

### Scenario 22: Stepping Granularity

Test instruction-level stepping vs line-level stepping.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`)
3. `debug/send run` with `action: "continue"` to hit line 4
4. Record the current PC address from the stop location
5. `debug/send run` with `action: "step_over"`, `granularity: "instruction"` — advance by one instruction
6. Record the new PC — should have advanced by a small number of bytes
7. `debug/send run` with `action: "step_over"`, `granularity: "instruction"` two more times
8. `debug/send run` with `action: "step_over"`, `granularity: "line"` — advance to next source line
9. Verify the location changed to a different line number
10. `debug/send stop`

**What this tests:** Instruction-level granularity moves by individual machine instructions.
Line granularity (the default) moves to the next source line.

---

### Part 6: Session Management (Scenarios 23-25)

### Scenario 23: Session Listing and Multiple Sessions

Test the session management tools.

Uses Program A.

1. `debug/send sessions` — should return an empty array
2. `debug/send launch` with `/tmp/debug_test`, `stop_on_entry: true` — note session_id ("session-1")
3. `debug/send sessions` — should return one session
4. `debug/send launch` with `/tmp/debug_test` again — should create "session-2"
5. `debug/send sessions` — should return two sessions
6. `debug/send stop` for "session-1"
7. `debug/send sessions` — should return only "session-2"
8. `debug/send stop` for "session-2"
9. `debug/send sessions` — should return empty array

**What this tests:** `debug/send sessions` accurately reflects the current set of active sessions.
Multiple debug sessions can coexist. Stopping a session removes it from the list.

### Scenario 24: Capabilities Query

Test querying debug engine capabilities.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send capabilities` — should return a JSON object with boolean capability flags
3. Verify key capabilities are present as camelCase fields:
   - `supportsConfigurationDoneRequest`
   - `supportsReadMemoryRequest`
   - `supportsDisassembleRequest`
   - `supportsStepInTargetsRequest`
   - `supportsBreakpointLocationsRequest`
   - `supportsValueFormattingOptions`
4. All capability values should be booleans
5. `debug/send stop`

**What this tests:** The capabilities response uses correct DAP-spec camelCase field names
and returns boolean values.

### Scenario 25: Restart (Tool) and Stop Variants

Test the `debug/send restart` tool and `debug/send stop` options.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 34
3. `debug/send run` with `action: "continue"` to hit line 34
4. `debug/send restart` — should return `{"restarted": true}`
5. `debug/send run` with `action: "continue"` — should hit line 34 again
6. `debug/send stop` with `detach: true` — should attempt to detach
7. Verify the session was ended
8. `debug/send launch` a new session
9. `debug/send stop` with `terminate_only: true` — verify the response
10. `debug/send sessions` — session should be gone

**What this tests:** `debug/send restart` restarts the session. Stop variants (`detach`,
`terminate_only`) exercise the different shutdown paths.

---

### Part 7: Introspection (Scenarios 26-28)

### Scenario 26: Modules and Loaded Sources

Test module and source file enumeration.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send modules` — should return loaded modules/libraries
3. The main executable (`debug_test`) should appear in the modules list
4. Verify each module has identifying fields (name, path, or id)
5. `debug/send loaded_sources` — should return source files
6. `/tmp/debug_test.c` should appear in the sources list
7. `debug/send stop`

**What this tests:** Module enumeration exposes loaded binaries and shared libraries.

### Scenario 27: Completions

Test expression completion suggestions.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`)
3. `debug/send run` with `action: "continue"` to hit the breakpoint
4. `debug/send completions` with `text: "res"`, `column: 3` — should return completions matching "res"
5. `debug/send completions` with `text: "a"`, `column: 1` — should return completions starting with "a"
6. Verify the response has a `targets` array
7. `debug/send stop`

**What this tests:** The completion engine suggests variable names and expressions that match
partial input.

### Scenario 28: Advanced Inspect (Contexts and Scopes)

Test inspect with different evaluation contexts, frame IDs, and scope filtering.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`, called from `compute()`)
3. `debug/send run` with `action: "continue"` to hit the breakpoint
4. `debug/send inspect` with `expression: "a"`, `context: "watch"` — watch context
5. `debug/send inspect` with `expression: "a"`, `context: "hover"` — hover context
6. `debug/send inspect` with `expression: "a + b"`, `context: "repl"` — REPL context
7. `debug/send inspect` with `scope: "locals"` — all local variables
8. `debug/send inspect` with `scope: "arguments"` — function arguments
9. `debug/send inspect` with `expression: "x"`, `frame_id: 2` — inspect in `main()` frame
   - `frame_id: 0` = `add()`, `frame_id: 1` = `compute()`, `frame_id: 2` = `main()`
   - `x` should be 10
10. `debug/send stop`

**What this tests:** Different evaluation contexts, scope-based variable listing, and
frame-relative inspection all work correctly.

---

### Part 8: Watchpoints and Events (Scenarios 29-30)

### Scenario 29: Watchpoints (Data Breakpoints)

Test setting a data breakpoint on a variable.

Uses Program D (`/tmp/debug_vars`).

1. `debug/send launch` with `/tmp/debug_vars`, `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 31 (`modify(&x, 3);` in `main()`)
3. `debug/send run` with `action: "continue"` to hit line 31
4. `debug/send watchpoint` with `variable: "x"`, `access_type: "write"`
5. Verify the response has `breakpoint` and `description` fields
6. `debug/send run` with `action: "continue"` — should trigger watchpoint when `modify()` writes `x`
7. `debug/send inspect` with `expression: "x"` — should show modified value (8 = 5 + 3)
8. `debug/send stop`

**What this tests:** Data breakpoints (watchpoints) fire when a watched variable is written.

**Note:** Watchpoint support depends on hardware and OS capabilities. If the debugger returns
an error indicating watchpoints are not supported, document the error and mark as expected.

### Scenario 30: Event Polling

Test the event polling mechanism.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send poll_events` with no session_id — should return any pending events
3. `debug/send breakpoint_set` at line 37 (`printf("compute = %d\n", result1);`)
4. `debug/send run` with `action: "continue"` to hit line 37
5. `debug/send run` with `action: "step_over"` — `printf` should execute
6. `debug/send poll_events` with `session_id: "session-1"` — should return pending events
7. Look for output events containing `"compute = 230"`
8. `debug/send poll_events` again — should return empty (events already drained)
9. `debug/send stop`

**What this tests:** Events accumulate during execution and are drained by polling.

---

### Part 9: Error Paths and Edge Cases (Scenarios 31-33)

### Scenario 31: Cancel and Terminate Threads

Test cancellation and thread termination tools.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send cancel` with `request_id: 999` — should return `{"cancelled": true}`
3. `debug/send cancel` with `progress_id: "nonexistent"` — should return `{"cancelled": true}`
4. `debug/send terminate_threads` with `thread_ids: [1]` — should return `{"terminated": true}`
5. `debug/send stop`

**What this tests:** Cancel and terminate tools handle both valid and invalid targets gracefully.

### Scenario 32: Restart Frame

Test restarting execution from a specific stack frame.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send breakpoint_set` at line 4 (inside `add()`)
3. `debug/send run` with `action: "continue"` to hit line 4
4. `debug/send stacktrace` — should show `add` at frame 0, `compute` at frame 1
5. `debug/send restart_frame` with `frame_id: 0` — should return `{"restarted": true}`
   (or an error if the engine doesn't support frame restart)
6. If successful, execution should restart at the beginning of `add()`
7. `debug/send stop`

**What this tests:** Frame restart repositions execution to the start of a specific function.

### Scenario 33: Extended Error Handling and Error Codes

Test error differentiation and edge cases.

Uses Program A.

1. `debug/send launch` with `stop_on_entry: true`
2. `debug/send memory` with `action: "read"`, `address: "not_hex"` — should return INVALID_PARAMS (-32602)
3. `debug/send memory` with `action: "write"`, `address: "0x1000"`, `data: "GG"` — should return error
4. `debug/send breakpoint_set` with missing `file` — should return INVALID_PARAMS
5. `debug/send stacktrace` with invalid `session_id` — should return error
6. `debug/send instruction_breakpoint` with missing `instruction_reference` — should return INVALID_PARAMS
7. `debug/send source` with `source_reference: 99999` — should return error
8. `debug/send registers` — if using DAP backend, should return NOT_SUPPORTED (-32001)
9. `debug/send stop`

**What this tests:** Different error types return different error codes:
- `-32602` (INVALID_PARAMS) for malformed/missing parameters
- `-32601` (METHOD_NOT_FOUND) for unknown tools
- `-32001` (NOT_SUPPORTED) for features the engine doesn't support
- `-32603` (INTERNAL_ERROR) for runtime failures

---

## Reporting

After completing all scenarios, provide a summary table:

| Scenario | Description | Result | Notes |
|----------|-------------|--------|-------|
| 1 | Basic breakpoint + inspect | ? | |
| 2 | Step into / step out | ? | |
| 3 | Multiple breakpoints + continue | ? | |
| 4 | Loop breakpoint | ? | |
| 5 | Step over | ? | |
| 6 | Breakpoint removal + list | ? | |
| 7 | Recursive function | ? | |
| 8 | Expression evaluation | ? | |
| 9 | Restart | ? | |
| 10 | Error handling | ? | |
| 11 | Threads + stack traces | ? | |
| 12 | Scopes | ? | |
| 13 | Set variable / set expression | ? | |
| 14 | Memory read + disassembly | ? | |
| 15 | Instruction breakpoints | ? | |
| 16 | CPU registers (native) | ? | |
| 17 | Function breakpoints | ? | |
| 18 | Breakpoint locations | ? | |
| 19 | Exception breakpoints + info | ? | |
| 20 | Goto targets + goto | ? | |
| 21 | Step-in targets | ? | |
| 22 | Stepping granularity | ? | |
| 23 | Session listing + multiple sessions | ? | |
| 24 | Capabilities query | ? | |
| 25 | Restart tool + stop variants | ? | |
| 26 | Modules + loaded sources | ? | |
| 27 | Completions | ? | |
| 28 | Advanced inspect (contexts/scopes/frames) | ? | |
| 29 | Watchpoints | ? | |
| 30 | Event polling | ? | |
| 31 | Cancel + terminate threads | ? | |
| 32 | Restart frame | ? | |
| 33 | Extended error handling + error codes | ? | |

### Tools Coverage Matrix

| Tool | Scenario(s) |
|------|-------------|
| `debug/send launch` | 1-33 (all) |
| `debug/send breakpoint_set` | 1, 3-9, 14-15, 28-30 |
| `debug/send breakpoint_remove` | 6, 15 |
| `debug/send breakpoint_list` | 3, 6, 17 |
| `debug/send breakpoint_set_function` | 17 |
| `debug/send breakpoint_set_exception` | 19 |
| `debug/send run` (continue) | 1-9, 14-15, 17, 19-20, 29-30 |
| `debug/send run` (step_into) | 2, 21 |
| `debug/send run` (step_over) | 5, 13, 22 |
| `debug/send run` (step_out) | 2 |
| `debug/send run` (restart) | 9 |
| `debug/send run` (goto) | 20 |
| `debug/send run` (granularity) | 22 |
| `debug/send inspect` | 1-8, 12-13, 28-29 |
| `debug/send inspect` (context) | 28 |
| `debug/send inspect` (variable_ref) | 12 |
| `debug/send inspect` (scope) | 28 |
| `debug/send inspect` (frame_id) | 28 |
| `debug/send stop` | 1-33 (all) |
| `debug/send stop` (detach) | 25 |
| `debug/send stop` (terminate_only) | 25 |
| `debug/send threads` | 11 |
| `debug/send stacktrace` | 11, 32 |
| `debug/send scopes` | 12 |
| `debug/send set_variable` | 13 |
| `debug/send set_expression` | 13 |
| `debug/send memory` (read) | 14, 33 |
| `debug/send memory` (write) | 33 |
| `debug/send disassemble` | 14, 15 |
| `debug/send instruction_breakpoint` | 15, 33 |
| `debug/send breakpoint_locations` | 18 |
| `debug/send goto_targets` | 20 |
| `debug/send step_in_targets` | 21 |
| `debug/send capabilities` | 24 |
| `debug/send modules` | 26 |
| `debug/send loaded_sources` | 26 |
| `debug/send source` | 33 |
| `debug/send completions` | 27 |
| `debug/send exception_info` | 19 |
| `debug/send registers` | 16, 33 |
| `debug/send write_register` | 16 |
| `debug/send find_symbol` | 16 |
| `debug/send variable_location` | 16 |
| `debug/send sessions` | 23, 25 |
| `debug/send restart` | 25 |
| `debug/send restart_frame` | 32 |
| `debug/send watchpoint` | 29 |
| `debug/send poll_events` | 30 |
| `debug/send cancel` | 31 |
| `debug/send terminate_threads` | 31 |

For any failures, include the raw response and describe what went wrong vs what
was expected. If a scenario cannot complete (e.g., due to a prior step failing), note which
step failed and skip the rest of that scenario.
