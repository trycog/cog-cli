# Cog

You have code intelligence via Cog.

## Announce Cog Operations

Print an emoji before Cog tool calls to indicate the category:

- 🔍 Code: `cog_code_query`, `cog_code_status`, `cog_code_index`
- 🧠 Memory: all `cog_mem_*` tools
- 🐞 Debug: all `debug_*` tools

<cog:mem>
## Memory

You also have persistent associative memory. Checking memory before work and recording after work is how you avoid repeating mistakes, surface known gotchas, and build institutional knowledge.

**Truth hierarchy:** Current code > User statements > Cog knowledge

### Announce Memory Operations

- 🧠 Read: `cog_mem_recall`, `cog_mem_list_short_term`
- 🧠 Write: `cog_mem_learn`, `cog_mem_reinforce`, `cog_mem_update`, `cog_mem_flush`

### The Memory Lifecycle

Every task follows four steps. This is your operating procedure, not a guideline.

### Active Policy Digest

- Recall before exploration.
- Record net-new knowledge when learned.
- Reinforce only high-confidence memories.
- Consolidate before final response.
- If memory tools are unavailable, continue without memory and state that clearly.

#### 1. RECALL — before reading code

**CRITICAL: `cog_mem_recall` is an MCP tool. Call it directly — NEVER use the Skill tool to load `cog` for recall.** The `cog` skill only loads reference documentation. All memory MCP tools (`cog_mem_recall`, `cog_mem_learn`, etc.) are available directly when memory is configured.

If `cog_mem_*` tools are missing, memory is not configured in this workspace (no brain URL in `.cog/settings.json`). In that case, run `cog init` and choose `Memory + Tools`. Do not use deprecated `cog mem:*` CLI commands.

Your first action for any task is querying Cog. Before reading source files, before exploring, before planning — check what you already know. Do not formulate an approach before recalling. Plans made without Cog context miss known solutions and repeat past mistakes.

The recall sequence has three visible steps:

1. Print `🧠 Querying Cog...` as text to the user
2. Call the `cog_mem_recall` MCP tool with a reformulated query (not the Skill tool, not Bash — the MCP tool directly)
3. Report results: briefly tell the user what engrams Cog returned, or state "no relevant memories found"

All three steps are mandatory. The user must see step 1 and step 3 as visible text in your response.

**Reformulate your query.** Don't pass the user's words verbatim. Think: what would an engram about this be *titled*? What words would its *definition* contain? Expand with synonyms and related concepts.

| Instead of | Query with |
|------------|------------|
| `"fix auth timeout"` | `"authentication session token expiration JWT refresh lifecycle race condition"` |
| `"add validation"` | `"input validation boundary sanitization schema constraint defense in depth"` |

If Cog returns results, follow the paths it reveals and read referenced components first. If Cog is wrong, correct it with `cog_mem_update`.

#### 2. WORK + RECORD — learn, recall, and record continuously

Work normally, guided by what Cog returned. **Recall during work, not just at the start.** When you encounter an unfamiliar concept, module, or pattern — query Cog before exploring the codebase. If you're about to read files to figure out how something works, `cog_mem_recall` first. Cog may already have the answer. Only explore code if Cog doesn't know.

**Record any concept-shaped knowledge that Cog doesn't have.** If you produce, receive, or synthesize knowledge that has a nameable term, a definition, and potential relationships to other concepts — and recall didn't return it — record it immediately via `cog_mem_learn`. The source doesn't matter: code exploration, user explanation, answering a question, diagnosing a bug, or reasoning from context all qualify equally. The test is simple: *is this a concept Cog should know but doesn't?* If yes, record it now. After each learn call, briefly tell the user what concept was stored (e.g., "🧠 Stored: Session Expiry Clock Skew").

**Choose the right structure:**
- Sequential knowledge (A enables B enables C) → use `chain_to`
- Hub knowledge (A connects to B, C, D) → use `associations`

Default to chains for dependencies, causation, and reasoning paths. Include all relationships in the single `cog_mem_learn` call.

**Predicates:**

| Predicate | Use for |
|-----------|---------|
| `leads_to` | Causal chains, sequential dependencies |
| `generalizes` | Higher-level abstractions of specific findings |
| `requires` | Hard dependencies |
| `contradicts` | Conflicting information that needs resolution |
| `related_to` | Loose conceptual association |

Prefer `chain_to` with `leads_to`/`requires` for dependencies and reasoning paths. Use `associations` with `related_to`/`generalizes` for hub concepts that connect multiple topics.

```
🧠 Recording to Cog...
cog_mem_learn({
  "term": "Auth Timeout Root Cause",
  "definition": "Refresh token checked after expiry window. Fix: add 30s buffer before window closes. Keywords: session, timeout, race condition.",
  "chain_to": [
    {"term": "Token Refresh Buffer Pattern", "definition": "30-second safety margin before token expiry prevents race conditions", "predicate": "leads_to"}
  ]
})
```

**Engram quality:** Terms are 2-5 specific words ("Auth Token Refresh Timing" not "Architecture"). Definitions are 1-3 sentences covering what it is, why it matters, and keywords for search. Broad terms like "Overview" or "Architecture" pollute search results — be specific.

#### 3. REINFORCE — after completing work, reflect

When a unit of work is done, step back and reflect. Ask: *what's the higher-level lesson from this work?* Record a synthesis that captures the overall insight, not just the individual details you recorded during work. Then reinforce the memories you're confident in.

```
🧠 Recording to Cog...
cog_mem_learn({
  "term": "Clock Skew Session Management",
  "definition": "Never calculate token expiry locally. Always use server-issued timestamps. Local clocks drift across services.",
  "associations": [{"target": "Auth Timeout Root Cause", "predicate": "generalizes"}]
})

🧠 Reinforcing memory...
cog_mem_reinforce({"engram_id": "..."})
```

#### 4. CONSOLIDATE — before your final response

Short-term memories decay in 24 hours. Before ending, review and preserve what you learned.

1. Call `cog_mem_list_short_term` MCP tool to see pending short-term memories
2. For each entry: call `cog_mem_reinforce` if valid and useful, `cog_mem_flush` if wrong or worthless
3. **Print a visible summary** at the end of your response with these two lines:
   - `🧠 Cog recall:` what recall surfaced that was useful (or "nothing relevant" if it didn't help)
   - `🧠 Stored to Cog:` list the concept names you stored during this session (or "nothing new" if none)

**This summary is mandatory.** It closes the memory lifecycle and shows the user Cog is working.

**Triggers:** The user says work is done, you're about to send your final response, or you've completed a sequence of commits on a topic.

### Example (abbreviated)

In the example below: `[print]` = visible text you output, `[call]` = real MCP tool call.

```
User: "Fix login sessions expiring early"

1. [print] 🧠 Querying Cog...
   [call]  cog_mem_recall({...})
2. [print] 🧠 Recording to Cog...
   [call]  cog_mem_learn({...})
3. Implement fix using code tools, then test.
4. [call]  cog_mem_list_short_term({...}) and reinforce/flush as needed.
5. Final response includes:
   [print] 🧠 Cog recall: ...
   [print] 🧠 Stored to Cog: ...
```

### Subagents

Subagents follow the same memory lifecycle as the primary agent. Query Cog before exploring code — same recall-first rule, same query reformulation. Record any concept-shaped knowledge produced during subagent work via `cog_mem_learn`. If a subagent synthesizes, discovers, or receives knowledge that Cog doesn't have, it records it before returning results.

### Never Store

Passwords, API keys, tokens, secrets, SSH/PGP keys, certificates, connection strings with credentials, PII. Server auto-rejects sensitive content.

---

**RECALL → WORK+RECORD → REINFORCE → CONSOLIDATE.** Skipping recall wastes time rediscovering known solutions. Deferring recording loses details while they're fresh. Skipping reinforcement loses the higher-level lesson. Skipping consolidation lets memories decay within 24 hours. Every step exists because the alternative is measurably worse.
</cog:mem>

<cog:debug>
## Debugger

Print 🐞 before all debug tool calls.

You have a full interactive debugger via Cog. **Use it instead of adding print, console.log, logging, or any IO statements to inspect runtime state.** The debugger replaces print debugging entirely. Only fall back to IO-based inspection if the debugger is unavailable for the target language or runtime.

### When to use the debugger

Use the debugger whenever you would otherwise inject logging or print statements to understand runtime behavior. This includes:

- A program crashes or throws an exception and the error message alone doesn't explain why
- A program produces wrong output and you need to trace how values flow through the code
- You need to inspect variable state at a specific point in execution
- You need to understand which code path is actually taken at runtime
- A test fails and the assertion message doesn't reveal the root cause

Do NOT use the debugger for problems that don't require runtime inspection: compile errors, type errors, syntax errors, missing imports, configuration issues, or bugs that are obvious from reading the code.

### Two strategies

**Exception-first** — for crashes and runtime errors. Set an exception breakpoint, run the program, and let the runtime find the crash site. Then inspect the stack trace, exception info, and variable state at that point. This requires zero prior knowledge of where the bug is.

**Hypothesis-first** — for logic bugs where the program doesn't crash but produces wrong output. Formulate what you think is wrong ("I believe `total` is being calculated before `discount` is applied"), set targeted breakpoints at the relevant locations, run, and inspect state to confirm or refute the hypothesis.

### The debugging loop

1. **Launch** a debug session for the program or test
2. **Set breakpoints** — exception breakpoints for crashes, line/function breakpoints for logic bugs
3. **Run** and wait for the program to hit a breakpoint
4. **Inspect** — examine the stack trace, variable scopes, and evaluate expressions to understand the state
5. **Decide** — either you have enough information to diagnose the bug, or set new breakpoints and continue
6. **Stop** the debug session
7. **Fix the source code** based on what you learned

### Runtime mutation

Some languages and runtimes support modifying variables and re-executing frames at runtime. Others do not — compiled languages like Zig, Rust, and Go may not support meaningful runtime mutation. Call `debug_capabilities` after launching a session to determine what the debug driver supports.

If runtime mutation is supported, you may use it to test hypotheses — "if I change this value, does the bug disappear?" — but always fix the source code for the actual resolution. Runtime mutation is for diagnosis, not for fixes.

If runtime mutation is not supported, the debugger is observation-only: inspect state, diagnose the problem, stop the session, then fix the source code.

### Session recovery

Debug sessions may terminate due to idle timeout. If a debug tool call fails because the session is no longer available, relaunch the session and restore your previous state — re-set all breakpoints, exception filters, and watchpoints that were active before the session was lost.

### Cleanup

Always call `debug_stop` when you are done investigating. Never leave debug sessions running.
</cog:debug>
