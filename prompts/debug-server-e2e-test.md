# Cog Debug Server — End-to-End Test Prompt

## How the Debug Server Works

The cog debug server (`cog debug/serve`) is an MCP server that speaks JSON-RPC 2.0 over
stdin/stdout. You interact with it by piping newline-delimited JSON-RPC messages into the process.
TUI dashboard output goes to stderr.

### Launching the server

```bash
COG=/Users/bcardarella/projects/zog/zig-out/bin/cog

{
  echo '<json-rpc message 1>'
  sleep 0.3
  echo '<json-rpc message 2>'
  sleep 0.3
  # ... more messages ...
} | timeout 30 "$COG" debug/serve 2>/dev/null
```

**Key details:**
- Each JSON-RPC message is a single line (no newlines within the JSON)
- Add `sleep` between messages to let the server process each one before receiving the next
- Use `timeout` to ensure the process exits if it hangs
- Redirect stderr with `2>/dev/null` to suppress TUI dashboard output (or `2>/tmp/dashboard.log` to capture it)
- The server exits when stdin reaches EOF (when the subshell's `}` closes)

### Protocol initialization

The first message must always be an MCP `initialize` handshake:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
```

### The 5 debug tools

All tools are invoked via `tools/call` with `name` and `arguments`:

#### 1. `debug_launch` — Start a debug session
```json
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"debug_launch","arguments":{
  "program": "/path/to/executable",
  "args": ["arg1", "arg2"],
  "stop_on_entry": true,
  "language": "c"
}}}
```
Returns: `{"session_id": "session-1", "status": "stopped"}`

#### 2. `debug_breakpoint` — Manage breakpoints
```json
// Set
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"debug_breakpoint","arguments":{
  "session_id": "session-1", "action": "set", "file": "/path/to/source.c", "line": 10
}}}

// Set with condition
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"debug_breakpoint","arguments":{
  "session_id": "session-1", "action": "set", "file": "/path/to/source.c", "line": 10,
  "condition": "i > 5"
}}}

// Remove by ID
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"debug_breakpoint","arguments":{
  "session_id": "session-1", "action": "remove", "id": 1
}}}

// List all
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"debug_breakpoint","arguments":{
  "session_id": "session-1", "action": "list"
}}}
```

#### 3. `debug_run` — Control execution
```json
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"debug_run","arguments":{
  "session_id": "session-1", "action": "continue"
}}}
```
Actions: `continue`, `step_into`, `step_over`, `step_out`, `restart`

Returns: `{"stop_reason": "breakpoint|step|exit|entry", "location": {...}, "locals": [...], "stack_trace": [...]}`

#### 4. `debug_inspect` — Evaluate expressions
```json
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"debug_inspect","arguments":{
  "session_id": "session-1", "expression": "a + b"
}}}
```
Returns: `{"result": "30", "type": "int"}`

#### 5. `debug_stop` — End a session
```json
{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"debug_stop","arguments":{
  "session_id": "session-1"
}}}
```

---

## Test Program

Write this to `/tmp/debug_test.c` and compile with `cc -g -O0 -o /tmp/debug_test /tmp/debug_test.c`:

```c
#include <stdio.h>

int add(int a, int b) {
    int result = a + b;    // line 4
    return result;         // line 5
}

int multiply(int a, int b) {
    int result = a * b;    // line 9
    return result;         // line 10
}

int compute(int x, int y) {
    int sum = add(x, y);          // line 14
    int product = multiply(x, y); // line 15
    int final = sum + product;    // line 16
    return final;                 // line 17
}

int loop_sum(int n) {
    int total = 0;                // line 21
    for (int i = 1; i <= n; i++) {
        total = add(total, i);    // line 23
    }
    return total;                 // line 25
}

int factorial(int n) {
    if (n <= 1) return 1;         // line 29
    return n * factorial(n - 1);  // line 30
}

int main() {
    int x = 10;                        // line 34
    int y = 20;                        // line 35
    int result1 = compute(x, y);       // line 36
    printf("compute = %d\n", result1); // line 37
    int result2 = loop_sum(5);         // line 38
    printf("loop_sum = %d\n", result2);// line 39
    int result3 = factorial(5);        // line 40
    printf("fact = %d\n", result3);    // line 41
    return 0;                          // line 42
}
```

---

## Test Scenarios

Execute each scenario as a separate debug server session (separate bash pipeline). For each
debug command, report:

1. **What you're doing** — state the action and why
2. **The raw JSON-RPC response** — show the full response
3. **Interpretation** — explain what the response means
4. **Current debugger state** — summarize active sessions, breakpoints, execution position

### Scenario 1: Basic Breakpoint + Continue + Inspect

This is the baseline test. Verify the fundamental debug loop works.

1. Initialize the MCP server
2. Launch `/tmp/debug_test` with `stop_on_entry: true`
3. Set a breakpoint at line 4 (`int result = a + b;` inside `add()`)
4. Continue execution — should hit the breakpoint
5. Inspect individual variables: `a`, `b`, `result`
6. Inspect expression: `a + b`
7. Stop the session

**Expected values:** `a=10`, `b=20`, `a + b = 30`

### Scenario 2: Step Into and Step Out

Test function call boundary navigation.

1. Initialize + launch with `stop_on_entry: true`
2. Set a breakpoint at line 36 (`int result1 = compute(x, y);` in `main()`)
3. Continue to hit the breakpoint at line 36
4. Inspect `x` and `y` to confirm we're in `main()` context
5. **Step into** — should enter `compute()`, landing at line 14
6. Inspect to confirm we're now in `compute()` scope
7. **Step into** again — should enter `add()` from line 14, landing at line 4
8. Inspect `a` and `b` inside `add()` — should be 10 and 20
9. **Step out** — should return from `add()` back to `compute()`
10. Inspect `sum` in `compute()` — should be 30
11. Stop the session

**What this tests:** Crossing function boundaries in both directions. Verifies that variable
scopes change correctly when stepping into/out of functions.

### Scenario 3: Multiple Breakpoints with Continue

Test hitting multiple breakpoints in sequence using continue.

1. Initialize + launch with `stop_on_entry: true`
2. Set breakpoint at line 4 (inside `add()`)
3. Set breakpoint at line 9 (inside `multiply()`)
4. Set breakpoint at line 16 (`int final = sum + product;` in `compute()`)
5. **List breakpoints** — verify all 3 are set and verified
6. Continue — should hit line 4 (first call to `add()` from `compute()`)
7. Inspect `a` and `b` at line 4
8. Continue — should hit line 9 (call to `multiply()` from `compute()`)
9. Inspect `a` and `b` at line 9
10. Continue — should hit line 16 in `compute()`
11. Inspect `sum`, `product`, and `sum + product`
12. Stop the session

**What this tests:** The debugger correctly arms multiple breakpoints and hits them in execution
order. Each continue resumes and stops at the next breakpoint.

### Scenario 4: Breakpoint in a Loop

Test that a breakpoint inside a loop is hit on each iteration.

1. Initialize + launch with `stop_on_entry: true`
2. Set a breakpoint at line 23 (`total = add(total, i);` inside the loop in `loop_sum()`)
3. Continue — should hit line 23 on the first iteration (i=1)
4. Inspect `i` and `total`
5. Continue — should hit line 23 again (i=2)
6. Inspect `i` and `total`
7. Continue — should hit line 23 again (i=3)
8. Inspect `i` and `total`
9. Continue two more times to get through i=4 and i=5
10. Continue — should NOT hit the breakpoint again (loop ended), program should continue
    to next breakpoint or exit
11. Stop the session

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

1. Initialize + launch with `stop_on_entry: true`
2. Set a breakpoint at line 14 (`int sum = add(x, y);` in `compute()`)
3. Continue to hit line 14
4. **Step over** — should execute `add()` entirely and stop at line 15
5. Inspect `sum` — should be 30 (add completed)
6. **Step over** again — should execute `multiply()` entirely and stop at line 16
7. Inspect `product` — should be 200 (multiply completed)
8. Inspect `sum + product` — should be 230
9. Stop the session

**What this tests:** step_over treats function calls as atomic operations, executing them
fully and stopping at the next line in the current function.

### Scenario 6: Breakpoint Removal and List

Test breakpoint lifecycle management.

1. Initialize + launch with `stop_on_entry: true`
2. Set breakpoint at line 4 (in `add()`) — note the returned breakpoint ID
3. Set breakpoint at line 9 (in `multiply()`) — note the returned breakpoint ID
4. Set breakpoint at line 34 (in `main()`) — note the returned breakpoint ID
5. **List breakpoints** — verify all 3 are present and verified
6. **Remove** breakpoint at line 4 (by ID)
7. **List breakpoints** — verify only 2 remain
8. Continue — should hit line 34 (main), NOT line 4 (removed)
9. Continue — should hit line 9 (multiply), confirming line 4 was skipped
10. Stop the session

**What this tests:** Breakpoint removal actually disarms the trap instruction. The removed
breakpoint is no longer hit during execution.

### Scenario 7: Recursive Function Debugging

Test debugging through recursive calls.

1. Initialize + launch with `stop_on_entry: true`
2. Set a breakpoint at line 29 (`if (n <= 1) return 1;` in `factorial()`)
3. Continue — should hit line 29 with `n=5` (first call)
4. Inspect `n`
5. Continue — should hit line 29 again with `n=4` (recursive call)
6. Inspect `n`
7. Continue — should hit line 29 again with `n=3`
8. Inspect `n`
9. Continue through remaining recursion levels (n=2, n=1)
10. On `n=1`, the base case triggers — continue should exit the recursion
11. Stop the session

**What this tests:** Breakpoints fire at each recursion depth. Variable inspection shows
the correct value of `n` at each depth level, confirming the debugger reads the correct
stack frame.

### Scenario 8: Arithmetic Expression Evaluation

Test the expression evaluator with various operators.

1. Initialize + launch with `stop_on_entry: true`
2. Set a breakpoint at line 4 (inside `add()`)
3. Continue to hit the breakpoint
4. Inspect these expressions and verify results:
   - `a` — should be 10
   - `b` — should be 20
   - `a + b` — should be 30
   - `a - b` — should be -10
   - `a * b` — should be 200
   - `a / b` — should be 0 (integer division: 10/20 = 0)
   - `b / a` — should be 2 (integer division: 20/10 = 2)
5. Stop the session

**What this tests:** All four arithmetic operators in the expression evaluator. Integer
division truncation behavior.

### Scenario 9: Restart

Test restarting a debug session without re-launching.

1. Initialize + launch with `stop_on_entry: true`
2. Set a breakpoint at line 34 (`int x = 10;` in `main()`)
3. Continue to hit line 34
4. Continue to let the program run to completion (or set no further breakpoints)
5. **Restart** the session
6. The program should restart and the response should indicate `stop_reason: "entry"`
7. Continue — should hit line 34 again (breakpoints are re-armed after restart)
8. Inspect `x` to confirm fresh execution
9. Stop the session

**What this tests:** The restart action kills the process, re-spawns it, and re-arms all
breakpoints. The session ID remains the same.

### Scenario 10: Error Handling

Test the server's response to invalid inputs.

1. Initialize the MCP server
2. Launch `/tmp/debug_test`
3. Try `debug_run` with an invalid session ID — should return an error
4. Try `debug_breakpoint` with `action: "set"` but missing `file` — should return an error
5. Try `debug_run` with `action: "invalid_action"` — should return an error
6. Try calling a nonexistent tool name — should return an error
7. Stop the session (with the valid session ID)

**What this tests:** The server returns proper JSON-RPC error responses with appropriate
error codes instead of crashing.

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

For any failures, include the raw JSON-RPC response and describe what went wrong vs what
was expected. If a scenario cannot complete (e.g., due to a prior step failing), note which
step failed and skip the rest of that scenario.
