# Cog

Code intelligence, persistent memory, and interactive debugging via Cog.

## Announce Cog Operations

Print an emoji before Cog tool calls to indicate the category:

- 🔍 Code: all `cog_code_*` tools
- 🧠 Memory: all `cog_mem_*` tools
- 🐞 Debug: all `cog_debug_*` tools

<cog:code>
## Code Intelligence

Prefer `cog_code_query` over Grep/Glob for symbol lookups — the index resolves definitions, references, and file symbols in milliseconds. Fall back to Grep/Glob only for string literals, comments, or non-symbol content.

### Query Modes

| Mode | Use for | Required |
|------|---------|----------|
| `find` | Locate where a symbol is defined | `name` |
| `refs` | Find all references to a symbol | `name` |
| `symbols` | List all symbols in a specific file | `file` |

Start with `find` — don't guess filenames. `name` supports globs (`*init*`, `get*`, case-insensitive). Use `kind` to filter by type (function, class, method, variable). Use `file` to scope results to a specific file.

### Exploration Sequence

Default: `find` → `symbols` → `refs` → `Read` (with `offset`/`limit`, 20-30 lines around the symbol). Skip steps when prior context makes them unnecessary.

### Batch Exploration

`cog_code_explore` combines find + read in one call:

```json
cog_code_explore({ queries: [{ name: "init", kind: "function" }, { name: "Settings" }], context_lines: 15 })
```

### Subagents

- **Inline:** ≤3 symbols via `find` or `cog_code_explore`
- **Subagent:** 4+ symbols or broad searches — query the index, return a summary

Subagents should use `cog_code_query`/`cog_code_explore` for symbol lookups, not Grep/Glob.
</cog:code>

<cog:mem>
## Memory

Persistent associative memory. **Truth hierarchy:** Current code > User statements > Cog knowledge

`cog_mem_*` tools are MCP tools — call them directly, never via the Skill tool.

Subagents do not perform memory operations — only the primary agent owns the lifecycle.

### Lifecycle

| Phase | When | Action |
|-------|------|--------|
| **Recall** | Before exploring unfamiliar code | `cog_mem_recall` with reformulated query. Report results to user. |
| **Record** | When you learn something Cog doesn't know | `cog_mem_learn` — term (2-5 specific words), definition (1-3 sentences + keywords) |
| **Reinforce** | After completing a unit of work | Synthesize a higher-level lesson via `cog_mem_learn`, then validate short-term memories |
| **Consolidate** | Before final response | `cog_mem_list_short_term` → `cog_mem_reinforce` or `cog_mem_flush` each entry |

### Short-Term Memory Model

All new memories are created as **short-term**. Short-term memories decay and are garbage-collected within 24 hours. To preserve what you learned:

- **Reinforce** — after a unit of work, synthesize a higher-level insight via `cog_mem_learn` (with `associations` linking back to specific memories). Then `cog_mem_reinforce` memories validated by the work.
- **Consolidate** — before your final response, `cog_mem_list_short_term` to review all pending memories. `cog_mem_reinforce` if validated, `cog_mem_flush` if wrong or no longer relevant. Unreinforced memories will be lost.

### Recall

Reformulate queries — expand with synonyms and related concepts:

| Instead of | Query with |
|------------|------------|
| `"fix auth timeout"` | `"authentication session token expiration JWT refresh lifecycle race condition"` |

Follow paths Cog reveals. Correct wrong memories with `cog_mem_update`.

### Record

- Sequential knowledge (A → B → C) → `chain_to`
- Hub knowledge (A connects to B, C, D) → `associations`

| Predicate | Use for |
|-----------|---------|
| `leads_to` | Causal chains, sequential dependencies |
| `generalizes` | Higher-level abstractions |
| `requires` | Hard dependencies |
| `contradicts` | Conflicting information |
| `related_to` | Loose conceptual association |

```
cog_mem_learn({
  "term": "Auth Timeout Root Cause",
  "definition": "Refresh token checked after expiry window. Fix: add 30s buffer. Keywords: session, timeout, race condition.",
  "chain_to": [
    {"term": "Token Refresh Buffer Pattern", "definition": "30s safety margin before token expiry prevents race conditions", "predicate": "leads_to"}
  ]
})
```

### End of Session

End your response with:
- `🧠 Cog recall:` what was useful (or "nothing relevant")
- `🧠 Stored to Cog:` concepts stored (or "nothing new")

### Never Store

Passwords, API keys, tokens, secrets, SSH/PGP keys, certificates, connection strings with credentials, PII.
</cog:mem>

<cog:debug>
## Debugger

Use the debugger to inspect runtime state instead of print/log statements.

### When to Use

- **YES:** Wrong output, wrong return value, crash with unclear stack, state mutation bugs, concurrency issues
- **NO:** Syntax errors, import errors, missing dependencies, config/env issues — read the error message instead

### Core Tools

These 6 tools cover 95% of debugging workflows:

| Tool | Purpose |
|------|---------|
| `cog_debug_launch` | Start debug session (returns session_id) |
| `cog_debug_breakpoint` | Set/remove/list breakpoints (line, function, conditional) |
| `cog_debug_run` | continue, step_over, step_into, step_out |
| `cog_debug_inspect` | Evaluate expressions, list scope variables |
| `cog_debug_stacktrace` | View call stack with frame IDs |
| `cog_debug_stop` | End session (always call when done) |

### Hypothesis-Driven Workflow

You MUST state a hypothesis before using any debug tool.

1. **Observe** — Run the failing test or reproduce the error. Read the traceback and relevant source.
2. **Hypothesize** — State: "I believe [X] because [Y]. I expect [variable] to be [expected] at [location]." Do this BEFORE calling any `cog_debug_*` tool.
3. **Design experiment** — Decide where to set breakpoints and what expressions to evaluate. What would confirm vs refute the hypothesis?
4. **Execute** — `launch` → `breakpoint` → `run` (continue) → `inspect`. Quote the actual values observed.
5. **Interpret** — Compare observed values to your prediction. Either diagnose the root cause or refine the hypothesis and repeat from step 3.
6. **Fix** — `stop` the debugger, apply the minimal source fix, verify with the test.

### Conditional Breakpoints

Use the `condition` parameter when a breakpoint is inside a loop or called multiple times. This pauses only when the condition is true, saving massive context vs hitting the same line repeatedly.

```
cog_debug_breakpoint(session_id, action="set", file="app.py", line=42, condition="user_id is None")
```

### Debug Subagent

For complex debugging (multiple breakpoints, stepping through loops, deep call stacks), delegate to a subagent to keep your main context clean.

- **When to delegate**: Multi-step investigations, high-iteration loops, deep call stacks, or when your context window is getting large
- **When NOT to delegate**: Single breakpoint-and-inspect, quick variable check — use `cog_debug_inspect` directly

Invoke the `cog-debug` agent by name, or use the Task tool:

```
Task(prompt="Debug subagent: Using cog_debug tools, answer: What is the value of X at file.py:42 when test_foo runs? Return only observed values, no diagnosis.", subagent_type="general-purpose")
```

You must formulate your hypothesis and question BEFORE delegating. The subagent answers questions — it does not diagnose bugs.

### Anti-Patterns

- Do NOT `step_over` repeatedly without inspecting — always have a reason for each step
- Do NOT launch a debug session without a hypothesis — aimless stepping wastes tokens
- Do NOT inspect every variable in scope — target specific expressions tied to your hypothesis
- Do NOT use exception breakpoints in Python/pytest — pytest catches all exceptions internally
- Do NOT add print statements when you have the debugger — use `cog_debug_inspect` instead
- Do NOT delegate to a debug subagent without a hypothesis — formulate your question first

### Bailout Rule

If 2 debug sessions have not found the root cause, stop. Summarize what you observed and reason from the evidence. Do NOT launch a 3rd session without a genuinely different hypothesis.

### Cleanup

Always `cog_debug_stop` when done. On session timeout, relaunch and restore breakpoints.
</cog:debug>
