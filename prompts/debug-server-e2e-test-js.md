# Cog Debug Server — End-to-End Test Prompt (JavaScript / CDP)

## How the MCP Debug Tools Work

You have direct access to Cog MCP debug tools in this environment.

`cog debug/send` has been removed. Use MCP `debug_*` tools via your tool-calling interface.
Do not shell out to `cog debug/send` or invent custom transport wrappers.

```text
AI Agent --MCP tools/call--> debug_* tool in Cog MCP runtime
```

### Using MCP tools

- Discover tool names and schemas with `tools/list`.
- Use `tools/call` with `{ "name": "debug_<tool>", "arguments": { ... } }`.
- Parse JSON from the returned `content[0].text` payload.

```json
{"name":"debug_launch","arguments":{"program":"/tmp/debug_test.js","stop_on_entry":true}}
```

```json
{"name":"debug_breakpoint","arguments":{"session_id":"session-1","action":"set","file":"/tmp/debug_test.js","line":4}}
```

```json
{"name":"debug_run","arguments":{"session_id":"session-1","action":"continue"}}
```

```json
{"name":"debug_inspect","arguments":{"session_id":"session-1","expression":"a"}}
```

```json
{"name":"debug_stop","arguments":{"session_id":"session-1"}}
```

### Canonical MCP tool patterns (Do Not Guess)

Use these as the source of truth for call shape. Do not invent CLI flags.

- `debug_launch`: launch target program
- `debug_attach`: attach to PID
- `debug_sessions`: list active sessions
- `debug_restart`: restart a session
- `debug_stop`: stop/detach/terminate session
- `debug_breakpoint`: breakpoint lifecycle (`action`: `set`, `remove`, `list`, `set_function`, `set_exception`)
- `debug_run`: execution control (`action`: `continue`, `step_into`, `step_over`, `step_out`, `pause`, `restart`, `goto`, `reverse_continue`, `step_back`)
- `debug_inspect`: evaluate expression, list scope, or inspect variable reference
- `debug_set_variable`, `debug_set_expression`
- `debug_threads`, `debug_stacktrace`, `debug_scopes`
- `debug_memory`, `debug_disassemble`, `debug_registers`, `debug_write_register`
- `debug_instruction_breakpoint`, `debug_watchpoint`, `debug_breakpoint_locations`
- `debug_goto_targets`, `debug_step_in_targets`, `debug_restart_frame`
- `debug_capabilities`, `debug_modules`, `debug_loaded_sources`, `debug_source`, `debug_completions`, `debug_exception_info`
- `debug_poll_events`, `debug_cancel`, `debug_terminate_threads`
- `debug_find_symbol`, `debug_variable_location` (native engine only)
- `debug_load_core`, `debug_dap_request` (specialized workflows)

Execution rules:
- Store and reuse `session_id` and breakpoint IDs from actual responses.
- If a step fails, include the raw error output and mark that scenario step as failed.
- Continue to the next scenario unless the current one cannot proceed safely.

### Debug tools (36 total)

Cog exposes 36 debug MCP tools. Prefer runtime discovery (`tools/list`) for exact schemas.

#### Core lifecycle
- `debug_launch`, `debug_attach`, `debug_sessions`, `debug_restart`, `debug_stop`

#### Breakpoints and execution
- `debug_breakpoint`, `debug_instruction_breakpoint`, `debug_breakpoint_locations`, `debug_watchpoint`
- `debug_run`, `debug_goto_targets`, `debug_step_in_targets`, `debug_restart_frame`

#### Inspection and state mutation
- `debug_inspect`, `debug_set_variable`, `debug_set_expression`
- `debug_threads`, `debug_stacktrace`, `debug_scopes`

#### Memory and low-level
- `debug_memory`, `debug_disassemble`, `debug_registers`, `debug_write_register`
- `debug_find_symbol`, `debug_variable_location`

#### Introspection and metadata
- `debug_capabilities`, `debug_modules`, `debug_loaded_sources`, `debug_source`, `debug_completions`, `debug_exception_info`

#### Events and control
- `debug_poll_events`, `debug_cancel`, `debug_terminate_threads`

#### Specialized
- `debug_load_core`, `debug_dap_request`

Use the scenarios below to validate common and advanced flows across these tools.

---

## Test Programs

### Setup

Before running any scenarios, copy all JavaScript test fixtures to `/tmp/`:

```bash
bash prompts/fixtures/js/setup.sh
```

This copies the `.js` source files from `prompts/fixtures/js/` to `/tmp/`. No compilation
is needed — JavaScript programs are executed directly by Node.js. Run the setup script at
the start of every session to ensure clean state.

**Do NOT kill any running processes.** The daemon auto-starts on first `debug_*` tool use.
Killing processes (e.g., `pkill`) can destroy the user's running dashboard or other sessions.

**Do NOT use sleep-based programs in this E2E.** Never launch `/tmp/debug_sleep.js`, never run `/usr/bin/sleep`, and never add waits via sleep commands.

### Programs

| Program | Source | Used by |
|---------|--------|---------|
| A: Basic | `/tmp/debug_test.js` | Scenarios 1-11, 14-18, 20-28, 30-33 |
| B: Crasher | `/tmp/debug_crash.js` | Scenario 19 |
| D: Multi-variable | `/tmp/debug_vars.js` | Scenarios 12-13, 29 |

### Key Line References

**Program A** (`debug_test.js`):
- Line 4: `const result = a + b;` (inside `add()`)
- Line 5: `return result;` (inside `add()`)
- Line 9: `const result = a * b;` (inside `multiply()`)
- Line 14: `const sum = add(x, y);` (inside `compute()`)
- Line 15: `const product = multiply(x, y);` (inside `compute()`)
- Line 16: `const final_ = sum + product;` (inside `compute()`)
- Line 21: `let total = 0;` (inside `loopSum()`)
- Line 23: `total = add(total, i);` (loop body in `loopSum()`)
- Line 29: `if (n <= 1) return 1;` (inside `factorial()`)
- Line 34: `const x = 10;` (inside `main()`)
- Line 36: `const result1 = compute(x, y);` (inside `main()`)
- Line 37: `console.log(\`compute = ${result1}\`);` (inside `main()`)

**Program B** (`debug_crash.js`):
- Line 4: `if (b === 0) throw new Error("Division by zero");` (thrown Error)
- Line 10: `console.log(obj.value);` (TypeError, null dereference)
- Line 14: `process.abort();` (SIGABRT)

**Program D** (`debug_vars.js`):
- Line 20: `const local3 = local1 * local2;` (inside `process()`)
- Line 29: `x = modify(x, 3);` (inside `main()`)

### JavaScript-Specific Notes

- JavaScript uses **CDP (Chrome DevTools Protocol)** transport via `node --inspect`.
- Programs are launched directly as `.js` files — no compilation step.
- Division is **floating-point** by default: `10 / 20 = 0.5`, not `0`.
- **Native-only features are NOT available** via CDP. The following tools will return
  `NOT_SUPPORTED` (error code `-32001`): `debug_memory`, `debug_disassemble`,
  `debug_registers`, `debug_write_register`, `debug_instruction_breakpoint`,
  `debug_find_symbol`, `debug_variable_location`.

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

1. `debug_launch` with `program: "/tmp/debug_test.js"`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"`, `session_id`, `file: "/tmp/debug_test.js"`, `line: 4`
3. `debug_run` with `action: "continue"` — should hit the breakpoint
4. `debug_inspect` with `expression: "a"` — should be 10
5. `debug_inspect` with `expression: "b"` — should be 20
6. `debug_inspect` with `expression: "a + b"` — should be 30
7. `debug_stop` with `session_id`

**Expected values:** `a=10`, `b=20`, `a + b = 30`

### Scenario 2: Step Into and Step Out

Test function call boundary navigation.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 36 (`const result1 = compute(x, y);` in `main()`)
3. `debug_run` with `action: "continue"` to hit line 36
4. `debug_inspect` with `expression: "x"` and `expression: "y"` to confirm `main()` context
5. `debug_run` with `action: "step_into"` — should enter `compute()`, landing at line 14
6. Inspect to confirm `compute()` scope
7. `debug_run` with `action: "step_into"` again — should enter `add()` at line 4
8. `debug_inspect` for `a` and `b` inside `add()` — should be 10 and 20
9. `debug_run` with `action: "step_out"` — should return to `compute()`
10. `debug_inspect` with `expression: "sum"` — should be 30
11. `debug_stop`

**What this tests:** Crossing function boundaries in both directions. Verifies that variable
scopes change correctly when stepping into/out of functions.

### Scenario 3: Multiple Breakpoints with Continue

Test hitting multiple breakpoints in sequence using continue.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 (inside `add()`)
3. `debug_breakpoint` with `action: "set"` at line 9 (inside `multiply()`)
4. `debug_breakpoint` with `action: "set"` at line 16 (`const final_ = sum + product;` in `compute()`)
5. `debug_breakpoint` with `action: "list"` — verify all 3 are set and verified
6. `debug_run` with `action: "continue"` — should hit line 4
7. `debug_inspect` for `a` and `b`
8. `debug_run` with `action: "continue"` — should hit line 9
9. `debug_inspect` for `a` and `b`
10. `debug_run` with `action: "continue"` — should hit line 16
11. `debug_inspect` for `sum`, `product`, and `sum + product`
12. `debug_stop`

**What this tests:** The debugger correctly arms multiple breakpoints and hits them in execution
order. Each continue resumes and stops at the next breakpoint.

### Scenario 4: Breakpoint in a Loop

Test that a breakpoint inside a loop is hit on each iteration.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 23 (`total = add(total, i);` in `loopSum()`)
3. `debug_run` with `action: "continue"` — should hit line 23 (i=1)
4. `debug_inspect` for `i` and `total`
5. `debug_run` with `action: "continue"` — should hit line 23 again (i=2)
6. `debug_inspect` for `i` and `total`
7. `debug_run` with `action: "continue"` — should hit line 23 again (i=3)
8. `debug_inspect` for `i` and `total`
9. Continue two more times to get through i=4 and i=5
10. Continue — should NOT hit the breakpoint again (loop ended)
11. `debug_stop`

**What this tests:** Breakpoints inside loops fire on every iteration. The breakpoint
re-arming logic works correctly across multiple hits.

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

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 14 (`const sum = add(x, y);` in `compute()`)
3. `debug_run` with `action: "continue"` to hit line 14
4. `debug_run` with `action: "step_over"` — should execute `add()` entirely, stop at line 15
5. `debug_inspect` with `expression: "sum"` — should be 30
6. `debug_run` with `action: "step_over"` — should execute `multiply()`, stop at line 16
7. `debug_inspect` with `expression: "product"` — should be 200
8. `debug_inspect` with `expression: "sum + product"` — should be 230
9. `debug_stop`

**What this tests:** step_over treats function calls as atomic operations, executing them
fully and stopping at the next line in the current function.

### Scenario 6: Breakpoint Removal and List

Test breakpoint lifecycle management.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 — note the returned breakpoint ID
3. `debug_breakpoint` with `action: "set"` at line 9 — note the returned breakpoint ID
4. `debug_breakpoint` with `action: "set"` at line 34 — note the returned breakpoint ID
5. `debug_breakpoint` with `action: "list"` — verify all 3 are present and verified
6. `debug_breakpoint` with `action: "remove"` and the ID from line 4
7. `debug_breakpoint` with `action: "list"` — verify only 2 remain
8. `debug_run` with `action: "continue"` — should hit line 34 (main), NOT line 4 (removed)
9. `debug_run` with `action: "continue"` — should hit line 9 (multiply), confirming line 4 was skipped
10. `debug_stop`

**What this tests:** Breakpoint removal actually disarms the breakpoint. The removed
breakpoint is no longer hit during execution.

### Scenario 7: Recursive Function Debugging

Test debugging through recursive calls.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 29 (`if (n <= 1) return 1;` in `factorial()`)
3. `debug_run` with `action: "continue"` — should hit line 29 with `n=5`
4. `debug_inspect` with `expression: "n"`
5. `debug_run` with `action: "continue"` — should hit line 29 with `n=4`
6. `debug_inspect` with `expression: "n"`
7. `debug_run` with `action: "continue"` — should hit line 29 with `n=3`
8. `debug_inspect` with `expression: "n"`
9. Continue through remaining recursion levels (n=2, n=1)
10. On `n=1`, the base case triggers — continue should exit the recursion
11. `debug_stop`

**What this tests:** Breakpoints fire at each recursion depth. Variable inspection shows
the correct value of `n` at each depth level, confirming the debugger reads the correct
stack frame.

### Scenario 8: Arithmetic Expression Evaluation

Test the expression evaluator with various operators.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. Inspect these expressions and verify results:
   - `debug_inspect` with `expression: "a"` — should be 10
   - `debug_inspect` with `expression: "b"` — should be 20
   - `debug_inspect` with `expression: "a + b"` — should be 30
   - `debug_inspect` with `expression: "a - b"` — should be -10
   - `debug_inspect` with `expression: "a * b"` — should be 200
   - `debug_inspect` with `expression: "a / b"` — should be 0.5 (JavaScript uses float division)
   - `debug_inspect` with `expression: "b / a"` — should be 2
   - `debug_inspect` with `expression: "Math.floor(a / b)"` — should be 0 (integer division via Math.floor)
5. `debug_stop`

**What this tests:** All four arithmetic operators in the expression evaluator. JavaScript
float division behavior (`10 / 20 = 0.5`), and `Math.floor()` for integer truncation.

### Scenario 9: Restart

Test restarting a debug session without re-launching.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 34 (`const x = 10;` in `main()`)
3. `debug_run` with `action: "continue"` to hit line 34
4. `debug_run` with `action: "continue"` to let the program run to completion
5. `debug_restart` — should restart the session
6. The response should indicate `stop_reason: "entry"`
7. `debug_run` with `action: "continue"` — should hit line 34 again
8. `debug_inspect` with `expression: "x"` to confirm fresh execution
9. `debug_stop`

**What this tests:** The restart action kills the process, re-spawns it, and re-arms all
breakpoints. The session ID remains the same.

### Scenario 10: Error Handling

Test the server's response to invalid inputs.

1. `debug_launch` with `program: "/tmp/debug_test.js"`
2. `debug_run` with an invalid `session_id: "nonexistent"` — should return an error
3. `debug_breakpoint` with `action: "set"`, `session_id`, but missing `file` — should return an error
4. `debug_run` with `action: "invalid_action"` — should return an error
5. `debug_stop` with the valid session ID

**What this tests:** The server returns proper error responses with appropriate
error codes instead of crashing.

---

### Part 2: Threads, Stacks, and Scopes (Scenarios 11-13)

### Scenario 11: Thread Listing and Stack Traces

Test thread enumeration and stack trace retrieval with pagination.

Uses Program A.

1. `debug_launch` with `/tmp/debug_test.js`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_threads` — should return at least one thread (the main thread)
5. Verify the thread has an `id` and `name` field
6. `debug_stacktrace` with default parameters — should show `add` -> `compute` -> `main`
7. `debug_stacktrace` with `start_frame: 1, levels: 1` — should return only the `compute` frame
8. `debug_stacktrace` with `levels: 2` — should return only 2 frames (`add` and `compute`)
9. `debug_stop`

**What this tests:** Thread listing works. Stack trace returns correct call chain. Pagination
parameters (`start_frame`, `levels`) correctly limit the returned frames.

### Scenario 12: Scopes

Test variable scope enumeration for a stack frame.

Uses Program D (`/tmp/debug_vars.js`).

1. `debug_launch` with `/tmp/debug_vars.js`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 20 (`const local3 = local1 * local2;` inside `process()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_scopes` with `frame_id: 0` — should return scope objects
5. Each scope should have `name`, `variablesReference` (integer), and `expensive` (boolean)
6. Use the `variablesReference` from the "Local" scope to call `debug_inspect` with `variable_ref` — should return `local1` and `local2` variables
7. `debug_stop`

**What this tests:** Scope hierarchy is exposed correctly. Variable references can be used
to drill into scope contents.

### Scenario 13: Set Variable and Set Expression

Test modifying variable values during debugging.

Uses Program D (`/tmp/debug_vars.js`).

1. `debug_launch` with `/tmp/debug_vars.js`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 29 (`x = modify(x, 3);` in `main()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_inspect` with `expression: "x"` — should be 5
5. `debug_set_variable` with `variable: "x"`, `value: "42"`
6. `debug_inspect` with `expression: "x"` — should now be 42
7. `debug_run` with `action: "step_over"` — `x` should become 45 (42 + 3)
8. `debug_inspect` with `expression: "x"` — should be 45
9. `debug_set_expression` with `expression: "y"`, `value: "99"`
10. `debug_inspect` with `expression: "y"` — should be 99
11. `debug_stop`

**What this tests:** Variable modification works and persists through execution. Both
`debug_set_variable` and `debug_set_expression` can alter program state.

---

### Part 3: Native-Only Tools — NOT_SUPPORTED Verification (Scenarios 14-16)

These tools are only available with the native debug engine. When using the CDP/DAP
transport (as JavaScript does via `node --inspect`), they must return `NOT_SUPPORTED`
(error code `-32001`). Each scenario verifies the correct error response.

### Scenario 14: Memory and Disassembly — NOT_SUPPORTED

Verify that `debug_memory` and `debug_disassemble` return NOT_SUPPORTED via CDP.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_memory` with `action: "read"`, `address: "0x1000"`, `size: 32`
   — should return error code `-32001` (NOT_SUPPORTED)
5. Verify the error response contains `code: -32001`
6. `debug_disassemble` with `address: "0x1000"`, `instruction_count: 5`
   — should return error code `-32001` (NOT_SUPPORTED)
7. Verify the error response contains `code: -32001`
8. `debug_stop`

**What this tests:** Native-only memory and disassembly tools correctly report NOT_SUPPORTED
when used against a CDP/DAP session.

### Scenario 15: Instruction Breakpoints — NOT_SUPPORTED

Verify that `debug_instruction_breakpoint` returns NOT_SUPPORTED via CDP.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_instruction_breakpoint` with `instruction_reference: "0x1000"`
   — should return error code `-32001` (NOT_SUPPORTED)
3. Verify the error response contains `code: -32001`
4. `debug_stop`

**What this tests:** Instruction-level breakpoints (which require memory addresses) are
correctly rejected via CDP.

### Scenario 16: CPU Registers and Native Introspection — NOT_SUPPORTED

Verify that `debug_registers`, `debug_variable_location`, `debug_find_symbol`, and
`debug_write_register` return NOT_SUPPORTED via CDP.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_registers` — should return error code `-32001` (NOT_SUPPORTED)
5. `debug_variable_location` with `name: "a"` — should return error code `-32001` (NOT_SUPPORTED)
6. `debug_find_symbol` with `name: "add"` — should return error code `-32001` (NOT_SUPPORTED)
7. `debug_write_register` with `name: "rax"`, `value: 0` — should return error code `-32001` (NOT_SUPPORTED)
8. Verify all four error responses contain `code: -32001`
9. `debug_stop`

**What this tests:** All native-engine-only tools correctly return NOT_SUPPORTED when used
against a JavaScript/CDP session. This confirms the transport layer properly gates
hardware-level features.

---

### Part 4: Advanced Breakpoints (Scenarios 17-19)

### Scenario 17: Function Breakpoints

Test setting breakpoints by function name instead of file:line.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set_function"`, `function: "multiply"`
3. `debug_run` with `action: "continue"` — should hit when `multiply()` is called
4. `debug_inspect` for `a` and `b` — should be 10 and 20
5. Verify the stop location references the `multiply` function
6. `debug_breakpoint` with `action: "list"` — the function breakpoint should be listed
7. `debug_stop`

**What this tests:** Function breakpoints resolve the function name and fire when
execution enters the function.

### Scenario 18: Breakpoint Locations

Test querying valid breakpoint positions in a source file.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint_locations` with `source: "/tmp/debug_test.js"`, `line: 3`, `end_line: 6`
   — should return valid breakpoint positions within `add()` (lines 4 and 5 at minimum)
3. `debug_breakpoint_locations` with `source: "/tmp/debug_test.js"`, `line: 12`
   — query a single line, may return line 14 as the nearest valid position
4. Verify each result has `line` and optionally `endLine`, `column`, `endColumn`
5. `debug_stop`

**What this tests:** The debugger can report which source locations are valid breakpoint
targets. This is critical for IDEs that need to snap breakpoints to valid positions.

### Scenario 19: Exception Breakpoints and Exception Info

Test exception breakpoint configuration and exception information retrieval.

Uses Program B (`/tmp/debug_crash.js`).

1. `debug_launch` with `/tmp/debug_crash.js`, `args: ["null"]`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set_exception"`, `filters: ["uncaught"]`
3. `debug_run` with `action: "continue"` — should stop on the TypeError at line 10 (null dereference)
4. The stop reason should indicate an exception
5. `debug_exception_info` — should return exception details
6. Verify the response has `exceptionId` (required), `breakMode` (required), and optionally `description` and `details`
7. The exception should be a `TypeError` related to reading property of null
8. `debug_stop`

**What this tests:** Exception breakpoints cause the debugger to stop on uncaught exceptions.
Exception info retrieves structured details about the TypeError.

---

### Part 5: Navigation (Scenarios 20-22)

### Scenario 20: Goto Targets and Goto Execution

Test discovering and jumping to goto targets.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 14 (`const sum = add(x, y);` in `compute()`)
3. `debug_run` with `action: "continue"` to hit line 14
4. `debug_goto_targets` with `file: "/tmp/debug_test.js"`, `line: 16`
5. If targets are returned, `debug_run` with `action: "goto"`, `file: "/tmp/debug_test.js"`, `line: 16`
   — should jump to line 16, skipping `add()` and `multiply()` calls
6. `debug_inspect` for `sum` and `product` — may be undefined (skipped assignments)
7. `debug_stop`

**What this tests:** Goto targets can be discovered for a source location. The goto action
repositions execution to a different line within the same function.

**Note:** Goto may not be fully supported via CDP. If `debug_goto_targets` returns an error
or empty result, document the response and mark as expected limitation.

### Scenario 21: Step-In Targets

Test listing available step-in targets when a line has multiple function calls.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 36 (`const result1 = compute(x, y);` in `main()`)
3. `debug_run` with `action: "continue"` to hit line 36
4. `debug_step_in_targets` with `frame_id: 0` — should list `compute` as a target
5. Record the target IDs returned
6. `debug_breakpoint` with `action: "set"` at line 14 and continue to hit it
7. `debug_step_in_targets` with `frame_id: 0` — should list `add` as a target
8. `debug_stop`

**What this tests:** Step-in targets enumerate the callable functions at the current execution
point.

### Scenario 22: Stepping Granularity

Test line-level stepping. Instruction-level granularity is not available via CDP.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit line 4
4. Record the current line number from the stop location
5. `debug_run` with `action: "step_over"`, `granularity: "line"` — advance to next source line
6. Verify the location changed to a different line number (should be line 5)
7. `debug_run` with `action: "step_over"`, `granularity: "line"` — advance again
8. Verify line changed again (should return to `compute()`)
9. `debug_stop`

**What this tests:** Line-level granularity stepping moves to the next source line. Note
that instruction-level granularity (`granularity: "instruction"`) is not available via CDP
since JavaScript is interpreted, not compiled to machine code.

---

### Part 6: Session Management (Scenarios 23-25)

### Scenario 23: Session Listing and Multiple Sessions

Test the session management tools.

Uses Program A.

1. `debug_sessions` — should return an empty array
2. `debug_launch` with `/tmp/debug_test.js`, `stop_on_entry: true` — note session_id ("session-1")
3. `debug_sessions` — should return one session
4. `debug_launch` with `/tmp/debug_test.js` again — should create "session-2"
5. `debug_sessions` — should return two sessions
6. `debug_stop` for "session-1"
7. `debug_sessions` — should return only "session-2"
8. `debug_stop` for "session-2"
9. `debug_sessions` — should return empty array

**What this tests:** `debug_sessions` accurately reflects the current set of active sessions.
Multiple debug sessions can coexist. Stopping a session removes it from the list.

### Scenario 24: Capabilities Query

Test querying debug engine capabilities.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_capabilities` — should return a JSON object with boolean capability flags
3. Verify key capabilities are present as camelCase fields:
   - `supportsConfigurationDoneRequest`
   - `supportsStepInTargetsRequest`
   - `supportsBreakpointLocationsRequest`
   - `supportsValueFormattingOptions`
4. Note which capabilities are `true` vs `false` — CDP may not support all DAP capabilities
5. `debug_stop`

**What this tests:** The capabilities response uses correct DAP-spec camelCase field names
and returns boolean values. CDP-backed sessions may report fewer supported capabilities
than native sessions.

### Scenario 25: Restart (Tool) and Stop Variants

Test the `debug_restart` tool and `debug_stop` options.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 34
3. `debug_run` with `action: "continue"` to hit line 34
4. `debug_restart` — should return `{"restarted": true}`
5. `debug_run` with `action: "continue"` — should hit line 34 again
6. `debug_stop` with `detach: true` — should attempt to detach
7. Verify the session was ended
8. `debug_launch` a new session
9. `debug_stop` with `terminate_only: true` — verify the response
10. `debug_sessions` — session should be gone

**What this tests:** `debug_restart` restarts the session. Stop variants (`detach`,
`terminate_only`) exercise the different shutdown paths.

---

### Part 7: Introspection (Scenarios 26-28)

### Scenario 26: Modules and Loaded Sources

Test module and source file enumeration.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_modules` — should return loaded modules/libraries
3. The main script (`debug_test.js`) should appear in the modules list
4. Verify each module has identifying fields (name, path, or id)
5. `debug_loaded_sources` — should return source files
6. `/tmp/debug_test.js` should appear in the sources list
7. `debug_stop`

**What this tests:** Module enumeration exposes loaded scripts and Node.js internals.

### Scenario 27: Completions

Test expression completion suggestions.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_completions` with `text: "res"`, `column: 3` — should return completions matching "res"
5. `debug_completions` with `text: "a"`, `column: 1` — should return completions starting with "a"
6. Verify the response has a `targets` array
7. `debug_stop`

**What this tests:** The completion engine suggests variable names and expressions that match
partial input.

### Scenario 28: Advanced Inspect (Contexts, Scopes, and Frames)

Test inspect with different evaluation contexts, frame IDs, and scope filtering.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 (inside `add()`, called from `compute()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_inspect` with `expression: "a"`, `context: "watch"` — watch context
5. `debug_inspect` with `expression: "a"`, `context: "hover"` — hover context
6. `debug_inspect` with `expression: "a + b"`, `context: "repl"` — REPL context
7. `debug_inspect` with `scope: "locals"` — all local variables
8. `debug_inspect` with `scope: "arguments"` — function arguments
9. `debug_inspect` with `expression: "x"`, `frame_id: 2` — inspect in `main()` frame
   - `frame_id: 0` = `add()`, `frame_id: 1` = `compute()`, `frame_id: 2` = `main()`
   - `x` should be 10
10. `debug_stop`

**What this tests:** Different evaluation contexts, scope-based variable listing, and
frame-relative inspection all work correctly.

---

### Part 8: Watchpoints and Events (Scenarios 29-30)

### Scenario 29: Watchpoints (Data Breakpoints)

Test setting a data breakpoint on a variable.

Uses Program D (`/tmp/debug_vars.js`).

1. `debug_launch` with `/tmp/debug_vars.js`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 29 (`x = modify(x, 3);` in `main()`)
3. `debug_run` with `action: "continue"` to hit line 29
4. `debug_watchpoint` with `variable: "x"`, `access_type: "write"`
5. Verify the response — it may return a watchpoint confirmation or an error
6. If successful: `debug_run` with `action: "continue"` — should trigger watchpoint when `x` is written
7. `debug_inspect` with `expression: "x"` — should show modified value (8 = 5 + 3)
8. `debug_stop`

**What this tests:** Data breakpoints (watchpoints) fire when a watched variable is written.

**Note:** Watchpoint support via CDP may be limited or unavailable. If the debugger returns
an error indicating watchpoints are not supported, document the error and mark as expected.

### Scenario 30: Event Polling

Test the event polling mechanism.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_poll_events` with no session_id — should return any pending events
3. `debug_breakpoint` with `action: "set"` at line 37 (`console.log(\`compute = ${result1}\`);`)
4. `debug_run` with `action: "continue"` to hit line 37
5. `debug_run` with `action: "step_over"` — `console.log` should execute
6. `debug_poll_events` with `session_id` — should return pending events
7. Look for output events containing `"compute = 230"`
8. `debug_poll_events` again — should return empty (events already drained)
9. `debug_stop`

**What this tests:** Events accumulate during execution and are drained by polling.

---

### Part 9: Error Paths and Edge Cases (Scenarios 31-33)

### Scenario 31: Cancel and Terminate Threads

Test cancellation and thread termination tools.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_cancel` with `request_id: 999` — should return `{"cancelled": true}`
3. `debug_cancel` with `progress_id: "nonexistent"` — should return `{"cancelled": true}`
4. `debug_terminate_threads` with `thread_ids: [1]` — should return `{"terminated": true}`
5. `debug_stop`

**What this tests:** Cancel and terminate tools handle both valid and invalid targets gracefully.

### Scenario 32: Restart Frame

Test restarting execution from a specific stack frame.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 4 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit line 4
4. `debug_stacktrace` — should show `add` at frame 0, `compute` at frame 1
5. `debug_restart_frame` with `frame_id: 0` — should return `{"restarted": true}`
   (or an error if the engine doesn't support frame restart)
6. If successful, execution should restart at the beginning of `add()`
7. `debug_stop`

**What this tests:** Frame restart repositions execution to the start of a specific function.

### Scenario 33: Extended Error Handling and Error Codes

Test error differentiation and edge cases.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_memory` with `action: "read"`, `address: "not_hex"` — should return error
   (either INVALID_PARAMS `-32602` or NOT_SUPPORTED `-32001`)
3. `debug_memory` with `action: "write"`, `address: "0x1000"`, `data: "GG"` — should return error
   (either INVALID_PARAMS `-32602` or NOT_SUPPORTED `-32001`)
4. `debug_breakpoint` with `action: "set"` and missing `file` — should return INVALID_PARAMS
5. `debug_stacktrace` with invalid `session_id` — should return error
6. `debug_instruction_breakpoint` with missing `instruction_reference` — should return error
   (either INVALID_PARAMS `-32602` or NOT_SUPPORTED `-32001`)
7. `debug_source` with `source_reference: 99999` — should return error
8. `debug_registers` — should return NOT_SUPPORTED (`-32001`)
9. `debug_stop`

**What this tests:** Different error types return different error codes:
- `-32602` (INVALID_PARAMS) for malformed/missing parameters
- `-32601` (METHOD_NOT_FOUND) for unknown MCP tools
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
| 14 | Memory + disassembly (NOT_SUPPORTED) | ? | |
| 15 | Instruction breakpoints (NOT_SUPPORTED) | ? | |
| 16 | CPU registers / native tools (NOT_SUPPORTED) | ? | |
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
| `debug_launch` | 1-33 (all) |
| `debug_breakpoint` (set) | 1, 3-9, 11-13, 17-19, 28-30, 32 |
| `debug_breakpoint` (remove) | 6 |
| `debug_breakpoint` (list) | 3, 6, 17 |
| `debug_breakpoint` (set_function) | 17 |
| `debug_breakpoint` (set_exception) | 19 |
| `debug_run` (continue) | 1-9, 17, 19-20, 29-30 |
| `debug_run` (step_into) | 2, 21 |
| `debug_run` (step_over) | 5, 13, 22, 30 |
| `debug_run` (step_out) | 2 |
| `debug_run` (restart) | 9 |
| `debug_run` (goto) | 20 |
| `debug_run` (granularity) | 22 |
| `debug_inspect` | 1-8, 12-13, 20, 28-29 |
| `debug_inspect` (context) | 28 |
| `debug_inspect` (variable_ref) | 12 |
| `debug_inspect` (scope) | 28 |
| `debug_inspect` (frame_id) | 28 |
| `debug_stop` | 1-33 (all) |
| `debug_stop` (detach) | 25 |
| `debug_stop` (terminate_only) | 25 |
| `debug_threads` | 11 |
| `debug_stacktrace` | 11, 32 |
| `debug_scopes` | 12 |
| `debug_set_variable` | 13 |
| `debug_set_expression` | 13 |
| `debug_memory` (read) | 14, 33 |
| `debug_memory` (write) | 33 |
| `debug_disassemble` | 14 |
| `debug_instruction_breakpoint` | 15, 33 |
| `debug_breakpoint_locations` | 18 |
| `debug_goto_targets` | 20 |
| `debug_step_in_targets` | 21 |
| `debug_capabilities` | 24 |
| `debug_modules` | 26 |
| `debug_loaded_sources` | 26 |
| `debug_source` | 33 |
| `debug_completions` | 27 |
| `debug_exception_info` | 19 |
| `debug_registers` | 16, 33 |
| `debug_write_register` | 16 |
| `debug_find_symbol` | 16 |
| `debug_variable_location` | 16 |
| `debug_sessions` | 23, 25 |
| `debug_restart` | 25 |
| `debug_restart_frame` | 32 |
| `debug_watchpoint` | 29 |
| `debug_poll_events` | 30 |
| `debug_cancel` | 31 |
| `debug_terminate_threads` | 31 |

For any failures, include the raw response and describe what went wrong vs what
was expected. If a scenario cannot complete (e.g., due to a prior step failing), note which
step failed and skip the rest of that scenario.
