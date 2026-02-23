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

When you need to inspect runtime state to diagnose a bug, use the debugger instead of print/log statements.

### Strategies

**Exception-first** — for crashes. Set exception breakpoint → run → inspect stack trace and variables at crash site.

**Hypothesis-first** — for wrong output. Formulate hypothesis → set targeted breakpoints → run → inspect to confirm or refute.

### Loop

Launch → Set breakpoints → Run → Inspect (stack, scopes, expressions) → Decide (diagnose or continue) → Stop → Fix source

### Notes

- `cog_debug_capabilities` after launch checks mutation support. Mutation is for diagnosis only — always fix source code.
- Session timeout: relaunch and restore breakpoints/watchpoints.
- Always `cog_debug_stop` when done.
</cog:debug>
