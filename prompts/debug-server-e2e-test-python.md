# Cog Debug Server — End-to-End Test Prompt (Python / DAP)

## CRITICAL EXECUTION RULES

- Run ALL 30 scenarios in a single pass without stopping
- Do NOT pause between scenarios to report results
- Do NOT output verbose step-by-step results during execution
- Accumulate results internally and output ONLY the final summary table
- If a scenario fails, note the failure and continue to the next scenario
- Never stop to ask for confirmation between scenarios
- Context management: You have limited context. Minimize output during execution. Only output the final summary table after all 30 scenarios.

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
{"name":"debug_launch","arguments":{"program":"/tmp/debug_test.py","stop_on_entry":true}}
```

```json
{"name":"debug_breakpoint","arguments":{"session_id":"session-1","action":"set","file":"/tmp/debug_test.py","line":5}}
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

### DAP Backend Notes

Python debugging uses the DAP (Debug Adapter Protocol) transport via `python3 -m debugpy.adapter`.
This means:

- Programs are **not compiled** — they are launched directly as `.py` files.
- **Native-only tools are NOT available** and must return `NOT_SUPPORTED` (-32001):
  `debug_memory`, `debug_disassemble`, `debug_registers`, `debug_write_register`,
  `debug_instruction_breakpoint`, `debug_find_symbol`, `debug_variable_location`.
- Integer division in Python uses `//` (floor division). `10 // 20` = 0, `20 // 10` = 2.

---

## Test Programs

### Setup

Before running any scenarios, reset all test fixtures:

```bash
bash prompts/fixtures/python/setup.sh
```

This copies the Python source files from `prompts/fixtures/python/` to `/tmp/`. Run the
setup script at the start of every session to ensure clean state.

**Do NOT kill any running processes.** The daemon auto-starts on first `debug_*` tool use.
Killing processes (e.g., `pkill`) can destroy the user's running dashboard or other sessions.

**Do NOT use sleep-based programs in this E2E.** Never launch `/tmp/debug_sleep.py`, never run `/usr/bin/sleep`, and never add waits via sleep commands.

### Programs

| Program | Source | Used by |
|---------|--------|---------|
| A: Basic | `/tmp/debug_test.py` | Scenarios 1-11, 14-30 |
| B: Crasher | `/tmp/debug_crash.py` | Scenario 18 |
| C: Multi-variable | `/tmp/debug_vars.py` | Scenarios 12-13 |

### Key Line References

**Program A** (`debug_test.py`):
- Line 5: `result = a + b` (inside `add()`)
- Line 6: `return result` (inside `add()`)
- Line 10: `result = a * b` (inside `multiply()`)
- Line 15: `sum_ = add(x, y)` (inside `compute()`)
- Line 16: `product = multiply(x, y)` (inside `compute()`)
- Line 17: `final = sum_ + product` (inside `compute()`)
- Line 22: `total = 0` (inside `loop_sum()`)
- Line 24: `total = add(total, i)` (loop body in `loop_sum()`)
- Line 29: `if n <= 1:` (inside `factorial()`)
- Line 35: `x = 10` (inside `main()`)
- Line 37: `result1 = compute(x, y)` (inside `main()`)
- Line 38: `print(f"compute = {result1}")` (inside `main()`)

**Program B** (`debug_crash.py`):
- Line 7: `return a // b` (ZeroDivisionError when b=0)
- Line 12: `print(obj.value)` (AttributeError, None dereference)
- Line 16: `os.kill(os.getpid(), signal.SIGABRT)` (SIGABRT)

**Program D** (`debug_vars.py`):
- Line 21: `local3 = local1 * local2` (inside `process()`)
- Line 30: `x = modify(x, 3)` (inside `main()`)

---

## Test Scenarios

Each scenario is independent. Execute each scenario's steps sequentially:

- If all steps pass: record PASS and move to the next scenario immediately
- If a step fails: record the step number, error, and move to the next scenario
- Do NOT output intermediate results — only record the final pass/fail per scenario

---

### Part 1: Core Debugging (Scenarios 1-10)

These test the fundamental debug loop using Program A.

### Scenario 1: Basic Breakpoint + Continue + Inspect

This is the baseline test. Verify the fundamental debug loop works.

1. `debug_launch` with `program: "/tmp/debug_test.py"`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"`, `session_id`, `file: "/tmp/debug_test.py"`, `line: 5`
3. `debug_run` with `action: "continue"` — should hit the breakpoint
4. `debug_inspect` with `expression: "a"` — should be 10
5. `debug_inspect` with `expression: "b"` — should be 20
6. `debug_inspect` with `expression: "a + b"` — should be 30
7. `debug_stop` with `session_id`

**Expected values:** `a=10`, `b=20`, `a + b = 30`

### Scenario 2: Step Into and Step Out

Test function call boundary navigation.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 37 (`result1 = compute(x, y)` in `main()`)
3. `debug_run` with `action: "continue"` to hit line 37
4. `debug_inspect` with `expression: "x"` and `expression: "y"` to confirm `main()` context
5. `debug_run` with `action: "step_into"` — should enter `compute()`, landing at line 15
6. Inspect to confirm `compute()` scope
7. `debug_run` with `action: "step_into"` again — should enter `add()` at line 5
8. `debug_inspect` for `a` and `b` inside `add()` — should be 10 and 20
9. `debug_run` with `action: "step_out"` — should return to `compute()`
10. `debug_inspect` with `expression: "sum_"` — should be 30
11. `debug_stop`

**What this tests:** Crossing function boundaries in both directions. Verifies that variable
scopes change correctly when stepping into/out of functions.

### Scenario 3: Multiple Breakpoints with Continue

Test hitting multiple breakpoints in sequence using continue.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 5 (inside `add()`)
3. `debug_breakpoint` with `action: "set"` at line 10 (inside `multiply()`)
4. `debug_breakpoint` with `action: "set"` at line 17 (`final = sum_ + product` in `compute()`)
5. `debug_breakpoint` with `action: "list"` — verify all 3 are set and verified
6. `debug_run` with `action: "continue"` — should hit line 5
7. `debug_inspect` for `a` and `b`
8. `debug_run` with `action: "continue"` — should hit line 10
9. `debug_inspect` for `a` and `b`
10. `debug_run` with `action: "continue"` — should hit line 17
11. `debug_inspect` for `sum_`, `product`, and `sum_ + product`
12. `debug_stop`

**What this tests:** The debugger correctly arms multiple breakpoints and hits them in execution
order. Each continue resumes and stops at the next breakpoint.

### Scenario 4: Breakpoint in a Loop

Test that a breakpoint inside a loop is hit on each iteration.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 24 (`total = add(total, i)` in `loop_sum()`)
3. `debug_run` with `action: "continue"` — should hit line 24 (i=1)
4. `debug_inspect` for `i` and `total`
5. `debug_run` with `action: "continue"` — should hit line 24 again (i=2)
6. `debug_inspect` for `i` and `total`
7. `debug_run` with `action: "continue"` — should hit line 24 again (i=3)
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
2. `debug_breakpoint` with `action: "set"` at line 15 (`sum_ = add(x, y)` in `compute()`)
3. `debug_run` with `action: "continue"` to hit line 15
4. `debug_run` with `action: "step_over"` — should execute `add()` entirely, stop at line 16
5. `debug_inspect` with `expression: "sum_"` — should be 30
6. `debug_run` with `action: "step_over"` — should execute `multiply()`, stop at line 17
7. `debug_inspect` with `expression: "product"` — should be 200
8. `debug_inspect` with `expression: "sum_ + product"` — should be 230
9. `debug_stop`

**What this tests:** step_over treats function calls as atomic operations, executing them
fully and stopping at the next line in the current function.

### Scenario 6: Breakpoint Removal and List

Test breakpoint lifecycle management.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 5 — note the returned breakpoint ID
3. `debug_breakpoint` with `action: "set"` at line 10 — note the returned breakpoint ID
4. `debug_breakpoint` with `action: "set"` at line 35 — note the returned breakpoint ID
5. `debug_breakpoint` with `action: "list"` — verify all 3 are present and verified
6. `debug_breakpoint` with `action: "remove"` and the ID from line 5
7. `debug_breakpoint` with `action: "list"` — verify only 2 remain
8. `debug_run` with `action: "continue"` — should hit line 35 (main), NOT line 5 (removed)
9. `debug_run` with `action: "continue"` — should hit line 10 (multiply), confirming line 5 was skipped
10. `debug_stop`

**What this tests:** Breakpoint removal actually disarms the breakpoint. The removed
breakpoint is no longer hit during execution.

### Scenario 7: Recursive Function Debugging

Test debugging through recursive calls.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 29 (`if n <= 1:` in `factorial()`)
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
2. `debug_breakpoint` with `action: "set"` at line 5 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. Inspect these expressions and verify results:
   - `debug_inspect` with `expression: "a"` — should be 10
   - `debug_inspect` with `expression: "b"` — should be 20
   - `debug_inspect` with `expression: "a + b"` — should be 30
   - `debug_inspect` with `expression: "a - b"` — should be -10
   - `debug_inspect` with `expression: "a * b"` — should be 200
   - `debug_inspect` with `expression: "a // b"` — should be 0 (integer floor division)
   - `debug_inspect` with `expression: "b // a"` — should be 2
5. `debug_stop`

**What this tests:** Arithmetic operators in the expression evaluator. Python integer
floor division (`//`) truncation behavior.

### Scenario 9: Restart

Test restarting a debug session without re-launching.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 35 (`x = 10` in `main()`)
3. `debug_run` with `action: "continue"` to hit line 35
4. `debug_run` with `action: "continue"` to let the program run to completion
5. `debug_restart` — should restart the session
6. The response should indicate `stop_reason: "entry"`
7. `debug_run` with `action: "continue"` — should hit line 35 again
8. `debug_inspect` with `expression: "x"` to confirm fresh execution
9. `debug_stop`

**What this tests:** The restart action kills the process, re-spawns it, and re-arms all
breakpoints. The session ID remains the same.

### Scenario 10: Error Handling

Test the server's response to invalid inputs.

1. `debug_launch` with `program: "/tmp/debug_test.py"`, `stop_on_entry: true`
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

1. `debug_launch` with `/tmp/debug_test.py`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 5 (inside `add()`)
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

Uses Program D (`/tmp/debug_vars.py`).

1. `debug_launch` with `/tmp/debug_vars.py`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 21 (`local3 = local1 * local2` inside `process()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_scopes` with `frame_id: 0` — should return scope objects
5. Each scope should have `name`, `variablesReference` (integer), and `expensive` (boolean)
6. Use the `variablesReference` from the "Locals" scope to call `debug_inspect` with `variable_ref` — should return `local1` and `local2` variables
7. `debug_stop`

**What this tests:** Scope hierarchy is exposed correctly. Variable references can be used
to drill into scope contents.

### Scenario 13: Set Variable and Set Expression

Test modifying variable values during debugging.

Uses Program D (`/tmp/debug_vars.py`).

1. `debug_launch` with `/tmp/debug_vars.py`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 30 (`x = modify(x, 3)` in `main()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_inspect` with `expression: "x"` — should be 5
5. `debug_set_variable` with `variable: "x"`, `value: "42"`
6. `debug_inspect` with `expression: "x"` — should now be 42
7. `debug_run` with `action: "step_over"` — `x` should become 45 (modify returns 42 + 3)
8. `debug_inspect` with `expression: "x"` — should be 45
9. `debug_set_expression` with `expression: "y"`, `value: "99"`
10. `debug_inspect` with `expression: "y"` — should be 99
11. `debug_stop`

**What this tests:** Variable modification works and persists through execution. Both
`debug_set_variable` and `debug_set_expression` can alter program state.

---

### Part 3: Native-Only Tools — NOT_SUPPORTED Verification (Scenarios 14-16)

These scenarios verify that native-only tools correctly return `NOT_SUPPORTED` (-32001)
when used with the DAP/debugpy backend. Python debugging runs through DAP, which does not
expose memory, registers, or instruction-level features.

### Scenario 14: Memory and Disassembly

Verify that `debug_memory` and `debug_disassemble` return NOT_SUPPORTED via DAP.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 5 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_memory` with `action: "read"`, `address: "0x1000"`, `size: 32`
   — should return error with code `-32001` (NOT_SUPPORTED)
5. Verify the error response contains code `-32001`
6. `debug_disassemble` with `address: "0x1000"`, `instruction_count: 5`
   — should return error with code `-32001` (NOT_SUPPORTED)
7. Verify the error response contains code `-32001`
8. `debug_stop`

**What this tests:** Native-only memory and disassembly tools are correctly rejected
with NOT_SUPPORTED when the backend is DAP/debugpy.

### Scenario 15: Instruction Breakpoints

Verify that `debug_instruction_breakpoint` returns NOT_SUPPORTED via DAP.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_instruction_breakpoint` with `instruction_reference: "0x1000"`
   — should return error with code `-32001` (NOT_SUPPORTED)
3. Verify the error response contains code `-32001`
4. `debug_stop`

**What this tests:** Instruction-level breakpoints are correctly rejected with
NOT_SUPPORTED when the backend is DAP/debugpy.

### Scenario 16: CPU Registers and Native Introspection

Verify that register and native introspection tools return NOT_SUPPORTED via DAP.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 5 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_registers` — should return error with code `-32001` (NOT_SUPPORTED)
5. `debug_variable_location` with `name: "a"` — should return error with code `-32001` (NOT_SUPPORTED)
6. `debug_find_symbol` with `name: "add"` — should return error with code `-32001` (NOT_SUPPORTED)
7. `debug_write_register` with `name: "rax"`, `value: 0` — should return error with code `-32001` (NOT_SUPPORTED)
8. Verify all four responses contain error code `-32001`
9. `debug_stop`

**What this tests:** All native-engine-only tools (`debug_registers`,
`debug_variable_location`, `debug_find_symbol`, `debug_write_register`) are correctly
rejected with NOT_SUPPORTED when the backend is DAP/debugpy.

---

### Part 4: Advanced Breakpoints (Scenarios 17-18)

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

**What this tests:** Function breakpoints resolve the function name and fire
when execution enters the function.

### Scenario 18: Exception Breakpoints and Exception Info

Test exception breakpoint configuration and exception information retrieval.

Uses Program B (`/tmp/debug_crash.py`).

1. `debug_launch` with `/tmp/debug_crash.py`, `args: ["none"]`, `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set_exception"`, `filters: ["raised"]`
3. `debug_run` with `action: "continue"` — should stop on an exception (AttributeError at line 12)
4. The stop reason should indicate an exception
5. `debug_exception_info` — should return exception details
6. Verify the response has `exceptionId` (required), `breakMode` (required), and optionally `description` and `details`
7. `debug_stop`

**What this tests:** Exception breakpoints cause the debugger to stop on raised exceptions.
Exception info retrieves structured details about what went wrong. With the `"none"` argument,
the program calls `dereference_none()` which triggers an `AttributeError`.

---

### Part 5: Navigation (Scenarios 19-21)

### Scenario 19: Goto Targets and Goto Execution

Test discovering and jumping to goto targets.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 15 (`sum_ = add(x, y)` in `compute()`)
3. `debug_run` with `action: "continue"` to hit line 15
4. `debug_goto_targets` with `file: "/tmp/debug_test.py"`, `line: 17`
5. If targets are returned, `debug_run` with `action: "goto"`, `file: "/tmp/debug_test.py"`, `line: 17`
   — should jump to line 17, skipping `add()` and `multiply()` calls
6. `debug_inspect` for `sum_` and `product` — may be uninitialized/zero
7. `debug_stop`

**What this tests:** Goto targets can be discovered for a source location. The goto action
repositions execution to a different line within the same function.

### Scenario 20: Step-In Targets

Test listing available step-in targets when a line has multiple function calls.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 37 (`result1 = compute(x, y)` in `main()`)
3. `debug_run` with `action: "continue"` to hit line 37
4. `debug_step_in_targets` with `frame_id: 0` — should list `compute` as a target
5. Record the target IDs returned
6. `debug_breakpoint` with `action: "set"` at line 15 and continue to hit it
7. `debug_step_in_targets` with `frame_id: 0` — should list `add` as a target
8. `debug_stop`

**What this tests:** Step-in targets enumerate the callable functions at the current execution
point.

### Scenario 21: Stepping Granularity

Test line-level stepping. Instruction-level stepping is not available via DAP/debugpy.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 5 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit line 5
4. Record the current line from the stop location
5. `debug_run` with `action: "step_over"`, `granularity: "line"` — advance to next source line
6. Verify the location changed to a different line number (should be line 6)
7. `debug_run` with `action: "step_over"`, `granularity: "line"` — advance again
8. Verify the line changed again (should return to caller)
9. `debug_stop`

**What this tests:** Line-level granularity stepping moves to the next source line. Instruction-level
granularity is not available via DAP/debugpy.

---

### Part 6: Session Management (Scenarios 22-24)

### Scenario 22: Session Listing and Multiple Sessions

Test the session management tools.

Uses Program A.

1. `debug_sessions` — should return an empty array
2. `debug_launch` with `/tmp/debug_test.py`, `stop_on_entry: true` — note session_id ("session-1")
3. `debug_sessions` — should return one session
4. `debug_launch` with `/tmp/debug_test.py` again — should create "session-2"
5. `debug_sessions` — should return two sessions
6. `debug_stop` for "session-1"
7. `debug_sessions` — should return only "session-2"
8. `debug_stop` for "session-2"
9. `debug_sessions` — should return empty array

**What this tests:** `debug_sessions` accurately reflects the current set of active sessions.
Multiple debug sessions can coexist. Stopping a session removes it from the list.

### Scenario 23: Capabilities Query

Test querying debug engine capabilities.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_capabilities` — should return a JSON object with boolean capability flags
3. Verify key capabilities are present as camelCase fields:
   - `supportsConfigurationDoneRequest`
   - `supportsSetVariable`
   - `supportsStepInTargetsRequest`
   - `supportsBreakpointLocationsRequest`
   - `supportsExceptionInfoRequest`
   - `supportsValueFormattingOptions`
4. All capability values should be booleans
5. `debug_stop`

**What this tests:** The capabilities response uses correct DAP-spec camelCase field names
and returns boolean values. Some capabilities may differ from native (e.g.,
`supportsReadMemoryRequest` and `supportsDisassembleRequest` may be false).

### Scenario 24: Restart (Tool) and Stop Variants

Test the `debug_restart` tool and `debug_stop` options.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 35
3. `debug_run` with `action: "continue"` to hit line 35
4. `debug_restart` — should return `{"restarted": true}`
5. `debug_run` with `action: "continue"` — should hit line 35 again
6. `debug_stop` with `detach: true` — should attempt to detach
7. Verify the session was ended
8. `debug_launch` a new session
9. `debug_stop` with `terminate_only: true` — verify the response
10. `debug_sessions` — session should be gone

**What this tests:** `debug_restart` restarts the session. Stop variants (`detach`,
`terminate_only`) exercise the different shutdown paths.

---

### Part 7: Introspection (Scenarios 25-27)

### Scenario 25: Modules

Test module enumeration after program execution.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 5 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_modules` — should return loaded modules/libraries
5. The main module (`__main__`) should appear in the modules list
6. Verify each module has identifying fields (name, path, or id)
7. `debug_stop`

**What this tests:** Module enumeration exposes loaded Python modules after execution begins.
Note: `debug_loaded_sources` is not supported by debugpy and has been removed from this scenario.

### Scenario 26: Completions

Test expression completion suggestions.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 5 (inside `add()`)
3. `debug_run` with `action: "continue"` to hit the breakpoint
4. `debug_completions` with `text: "res"`, `column: 3` — should return completions matching "res"
5. `debug_completions` with `text: "a"`, `column: 1` — should return completions starting with "a"
6. Verify the response has a `targets` array
7. `debug_stop`

**What this tests:** The completion engine suggests variable names and expressions that match
partial input.

### Scenario 27: Advanced Inspect (Contexts, Scopes, and Frames)

Test inspect with different evaluation contexts, frame IDs, and scope filtering.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_breakpoint` with `action: "set"` at line 5 (inside `add()`, called from `compute()`)
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

### Part 8: Events (Scenario 28)

### Scenario 28: Event Polling

Test the event polling mechanism.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_poll_events` with no session_id — should return any pending events
3. `debug_breakpoint` with `action: "set"` at line 38 (`print(f"compute = {result1}")`)
4. `debug_run` with `action: "continue"` to hit line 38
5. `debug_run` with `action: "step_over"` — `print` should execute
6. `debug_poll_events` with `session_id: "session-1"` — should return pending events
7. Look for output events containing `"compute = 230"`
8. `debug_poll_events` again — should return empty (events already drained)
9. `debug_stop`

**What this tests:** Events accumulate during execution and are drained by polling.

---

### Part 9: Error Paths and Edge Cases (Scenarios 29-30)

### Scenario 29: Cancel and Terminate Threads

Test cancellation and thread termination tools.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_cancel` with `request_id: 999` — should return `{"cancelled": true}`
3. `debug_cancel` with `progress_id: "nonexistent"` — should return `{"cancelled": true}`
4. `debug_terminate_threads` with `thread_ids: [1]` — should return `{"terminated": true}`
5. `debug_stop`

**What this tests:** Cancel and terminate tools handle both valid and invalid targets gracefully.

### Scenario 30: Extended Error Handling and Error Codes

Test error differentiation and edge cases.

Uses Program A.

1. `debug_launch` with `stop_on_entry: true`
2. `debug_memory` with `action: "read"`, `address: "not_hex"` — should return INVALID_PARAMS (-32602) or NOT_SUPPORTED (-32001)
3. `debug_memory` with `action: "write"`, `address: "0x1000"`, `data: "GG"` — should return error (NOT_SUPPORTED or INVALID_PARAMS)
4. `debug_breakpoint` with `action: "set"` and missing `file` — should return INVALID_PARAMS
5. `debug_stacktrace` with invalid `session_id` — should return error
6. `debug_instruction_breakpoint` with missing `instruction_reference` — should return INVALID_PARAMS or NOT_SUPPORTED (-32001)
7. `debug_source` with `source_reference: 99999` — should return error
8. `debug_registers` — should return NOT_SUPPORTED (-32001) via DAP backend
9. `debug_stop`

**What this tests:** Different error types return different error codes:
- `-32602` (INVALID_PARAMS) for malformed/missing parameters
- `-32601` (METHOD_NOT_FOUND) for unknown MCP tools
- `-32001` (NOT_SUPPORTED) for features the engine doesn't support
- `-32603` (INTERNAL_ERROR) for runtime failures

---

## Reporting

After completing all 30 scenarios, output this summary table and nothing else:

| # | Description | Result | Failed Step | Error |
|---|-------------|--------|-------------|-------|
| 1 | Basic breakpoint + inspect | PASS/FAIL | | |
| 2 | Step into / step out | PASS/FAIL | | |
| 3 | Multiple breakpoints + continue | PASS/FAIL | | |
| 4 | Loop breakpoint | PASS/FAIL | | |
| 5 | Step over | PASS/FAIL | | |
| 6 | Breakpoint removal + list | PASS/FAIL | | |
| 7 | Recursive function | PASS/FAIL | | |
| 8 | Expression evaluation | PASS/FAIL | | |
| 9 | Restart | PASS/FAIL | | |
| 10 | Error handling | PASS/FAIL | | |
| 11 | Threads + stack traces | PASS/FAIL | | |
| 12 | Scopes | PASS/FAIL | | |
| 13 | Set variable / set expression | PASS/FAIL | | |
| 14 | Memory + disassembly (NOT_SUPPORTED) | PASS/FAIL | | |
| 15 | Instruction breakpoints (NOT_SUPPORTED) | PASS/FAIL | | |
| 16 | CPU registers + native tools (NOT_SUPPORTED) | PASS/FAIL | | |
| 17 | Function breakpoints | PASS/FAIL | | |
| 18 | Exception breakpoints + info | PASS/FAIL | | |
| 19 | Goto targets + goto | PASS/FAIL | | |
| 20 | Step-in targets | PASS/FAIL | | |
| 21 | Stepping granularity | PASS/FAIL | | |
| 22 | Session listing + multiple sessions | PASS/FAIL | | |
| 23 | Capabilities query | PASS/FAIL | | |
| 24 | Restart tool + stop variants | PASS/FAIL | | |
| 25 | Modules | PASS/FAIL | | |
| 26 | Completions | PASS/FAIL | | |
| 27 | Advanced inspect (contexts/scopes/frames) | PASS/FAIL | | |
| 28 | Event polling | PASS/FAIL | | |
| 29 | Cancel + terminate threads | PASS/FAIL | | |
| 30 | Extended error handling + error codes | PASS/FAIL | | |

For failures, fill in the Failed Step and Error columns. If a scenario cannot complete
(e.g., due to a prior step failing), note which step failed and skip the rest of that scenario.
