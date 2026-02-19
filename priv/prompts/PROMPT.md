# Cog

You have code intelligence via Cog. Using cog code tools for file mutations keeps the code index in sync. This is not optional overhead — it is how you operate effectively.

<cog:mem>
You also have persistent associative memory. Checking memory before work and recording after work is how you avoid repeating mistakes, surface known gotchas, and build institutional knowledge.

**Truth hierarchy:** Current code > User statements > Cog knowledge
</cog:mem>

## Code Intelligence

When a cog code index exists (`.cog/index.scip`), **all file mutations must go through Cog MCP tools** to keep the index in sync. This is not a suggestion — it is a hard requirement. Using native file tools (Edit, Write, rm, mv) bypasses the index and causes stale or incorrect query results.

### Tool Override Rules

Do NOT use native file mutation tools when code index mode is active. Discover the current Cog toolset at runtime and use those MCP tools:

1. Call `tools/list` to discover the exact tool names and input schemas exposed by this runtime.
2. Use discovered `cog_code_*` mutation/query tools for edits, creates, deletes, renames, indexing, and symbol operations.
3. Use `resources/read` with `cog://tools/catalog` when you need a stable JSON catalog of all currently exposed tools.

MCP metadata endpoints:
- `prompts/get` with `cog_reference`
- `resources/read` for `cog://index/status`, `cog://debug/tools`, and `cog://tools/catalog`

**Reading files is unchanged** — use your normal Read/cat tools. Only mutations and symbol lookups are overridden.

**Why:** Each cog mutation tool edits the file AND re-indexes it atomically. Native tools only touch the file, leaving the index stale. Subsequent `--find` and `--refs` queries return wrong results.

**When no `.cog/index.scip` exists:** Use your native tools normally. The override only applies to indexed projects.

<cog:mem>
## Memory System

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

If `cog_mem_*` tools are missing, memory is not configured in this workspace (no brain URL in `.cog/settings.json`). In that case, run `cog init` and choose `Memory + Tools`. Do not use deprecated `cog mem/*` CLI commands.

Your first action for any task is querying Cog. Before reading source files, before exploring, before planning — check what you already know. Do not formulate an approach before recalling. Plans made without Cog context miss known solutions and repeat past mistakes.

The recall sequence has three visible steps:

1. Print `⚙️ Querying Cog...` as text to the user
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

Work normally, guided by what Cog returned. **Whenever you learn something new, record it immediately.** Don't wait. The moment you understand something you didn't before — that's when you call `cog_mem_learn`. After each learn call, briefly tell the user what concept was stored (e.g., "🧠 Stored: Session Expiry Clock Skew").

**Recall during work, not just at the start.** When you encounter an unfamiliar concept, module, or pattern — query Cog before exploring the codebase. If you're about to read files to figure out how something works, `cog_mem_recall` first. Cog may already have the answer. Only explore code if Cog doesn't know. If you then learn it from code, `cog_mem_learn` it so the next session doesn't have to explore again.

**When the user explains something, record it immediately** as a short-term memory via `cog_mem_learn`. If the user had to tell you how something works, that's knowledge Cog should have. Capture it now — it will be validated and reinforced during consolidation.

Record when you:
- **Encounter an unfamiliar concept** — recall first, explore second, record what you learn
- **Receive an explanation from the user** — record it as short-term memory immediately
- **Identify a root cause** — record before fixing, while the diagnostic details are sharp
- **Hit unexpected behavior** — record before moving on, while the surprise is specific
- **Discover a pattern, convention, or gotcha** — record before it becomes background knowledge you forget to capture
- **Make an architectural decision** — record the what and the why

**Choose the right structure:**
- Sequential knowledge (A enables B enables C) → use `chain_to`
- Hub knowledge (A connects to B, C, D) → use `associations`

Default to chains for dependencies, causation, and reasoning paths. Include all relationships in the single `cog_mem_learn` call.

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
   - `⚙️ Cog recall:` what recall surfaced that was useful (or "nothing relevant" if it didn't help)
   - `🧠 Stored to Cog:` list the concept names you stored during this session (or "nothing new" if none)

**This summary is mandatory.** It closes the memory lifecycle and shows the user Cog is working.

**Triggers:** The user says work is done, you're about to send your final response, or you've completed a sequence of commits on a topic.
</cog:mem>

## Announce Cog Operations

Print ⚙️ before read operations and 🧠 before write operations.

**⚙️ Read operations:**
<cog:mem>
- Memory: all `cog_mem_*` read/query operations currently exposed by `tools/list`
</cog:mem>
- Code: all `cog_code_*` read/query operations currently exposed by `tools/list`

**🧠 Write operations:**
<cog:mem>
- Memory: all `cog_mem_*` write/mutation operations currently exposed by `tools/list`
</cog:mem>
- Code: all `cog_code_*` write/mutation operations currently exposed by `tools/list`

<cog:mem>
## Example (abbreviated)

In the example below: `[print]` = visible text you output, `[call]` = real MCP tool call.

```
User: "Fix login sessions expiring early"

1. [print] ⚙️ Querying Cog...
   [call]  cog_mem_recall({...})
2. [print] 🧠 Recording to Cog...
   [call]  cog_mem_learn({...})
3. Implement fix using code tools, then test.
4. [call]  cog_mem_list_short_term({...}) and reinforce/flush as needed.
5. Final response includes:
   [print] ⚙️ Cog recall: ...
   [print] 🧠 Stored to Cog: ...
```

For detailed parameter examples, see SKILL.md.

## Subagents

Subagents query Cog before exploring code. Same recall-first rule, same query reformulation.

## Never Store

Passwords, API keys, tokens, secrets, SSH/PGP keys, certificates, connection strings with credentials, PII. Server auto-rejects sensitive content.

## Reference

For tool parameter schemas and usage examples: the **cog** skill provides the complete tool reference. **Only load the skill when you need to look up unfamiliar parameters — do not load it as part of normal recall/record workflow.** All Cog MCP tools (`cog_mem_recall`, `cog_mem_learn`, `cog_mem_reinforce`, etc.) are available directly without loading the skill first.

For predicates, hub node patterns, staleness verification, consolidation guidance, and advanced recording patterns: call `cog_reference`.

---

**RECALL → WORK+RECORD → REINFORCE → CONSOLIDATE.** Skipping recall wastes time rediscovering known solutions. Deferring recording loses details while they're fresh. Skipping reinforcement loses the higher-level lesson. Skipping consolidation lets memories decay within 24 hours. Every step exists because the alternative is measurably worse.
</cog:mem>
