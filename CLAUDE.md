<cog>
# Cog Memory System

You have persistent associative memory via Cog. Checking it before work and recording to it after work is how you avoid repeating mistakes, surface known gotchas, and build institutional knowledge. This is not optional overhead — it is how you operate effectively.

**Truth hierarchy:** Current code > User statements > Cog knowledge

## The Memory Lifecycle

Every task follows four steps. This is your operating procedure, not a guideline.

### 1. RECALL — before reading code

Your first action for any task is querying Cog. Before reading source files, before exploring, before planning — check what you already know. Do not formulate an approach before recalling. Plans made without Cog context miss known solutions and repeat past mistakes. The 2-second query may reveal gotchas, prior solutions, or context that changes your entire approach.

Your first visible action in every response should be a `cog_recall` call. This is not a suggestion — it is the expected output pattern.

**Reformulate your query.** Don't pass the user's words verbatim. Think: what would an engram about this be *titled*? What words would its *definition* contain? Expand with synonyms and related concepts.

| Instead of | Query with |
|------------|------------|
| `"fix auth timeout"` | `"authentication session token expiration JWT refresh lifecycle race condition"` |
| `"add validation"` | `"input validation boundary sanitization schema constraint defense in depth"` |

```
⚙️ Querying Cog...
cog_recall({"query": "authentication session token expiration JWT refresh lifecycle"})
```

If Cog returns results, follow the paths it reveals and read referenced components first. If Cog is wrong, correct it with `cog_update`.

### 2. WORK + RECORD — learn, recall, and record continuously

Work normally, guided by what Cog returned. **Whenever you learn something new, record it immediately.** Don't wait. The moment you understand something you didn't before — that's when you call `cog_learn`.

**Recall during work, not just at the start.** When you encounter an unfamiliar concept, module, or pattern — query Cog before exploring the codebase. If you're about to read files to figure out how something works, `cog_recall` first. Cog may already have the answer. Only explore code if Cog doesn't know. If you then learn it from code, `cog_learn` it so the next session doesn't have to explore again.

**When the user explains something, record it immediately** as a short-term memory via `cog_learn`. If the user had to tell you how something works, that's knowledge Cog should have. Capture it now — it will be validated and reinforced during consolidation.

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

Default to chains for dependencies, causation, and reasoning paths. Include all relationships in the single `cog_learn` call.

```
🧠 Recording to Cog...
cog_learn({
  "term": "Auth Timeout Root Cause",
  "definition": "Refresh token checked after expiry window. Fix: add 30s buffer before window closes. Keywords: session, timeout, race condition.",
  "chain_to": [
    {"term": "Token Refresh Buffer Pattern", "definition": "30-second safety margin before token expiry prevents race conditions", "predicate": "leads_to"}
  ]
})
```

**Engram quality:** Terms are 2-5 specific words ("Auth Token Refresh Timing" not "Architecture"). Definitions are 1-3 sentences covering what it is, why it matters, and keywords for search. Broad terms like "Overview" or "Architecture" pollute search results — be specific.

### 3. REINFORCE — after completing work, reflect

When a unit of work is done, step back and reflect. Ask: *what's the higher-level lesson from this work?* Record a synthesis that captures the overall insight, not just the individual details you recorded during work. Then reinforce the memories you're confident in.

```
🧠 Recording to Cog...
cog_learn({
  "term": "Clock Skew Session Management",
  "definition": "Never calculate token expiry locally. Always use server-issued timestamps. Local clocks drift across services.",
  "associations": [{"target": "Auth Timeout Root Cause", "predicate": "generalizes"}]
})

🧠 Reinforcing memory...
cog_reinforce({"engram_id": "..."})
```

### 4. CONSOLIDATE — before your final response

Short-term memories decay in 24 hours. Before ending, review and preserve what you learned.

```
⚙️ Listing short-term memories...
cog_list_short_term({"limit": 20})
```

For each entry: `cog_reinforce` if valid and useful, `cog_flush` if wrong or worthless.

**Evaluate recall usefulness.** In your summary, state whether Cog recall helped and why. If it surfaced relevant context, name what helped. If it returned nothing useful, say so — honest self-evaluation improves future queries and reinforces the habit of recalling.

**Triggers:** The user says work is done, you're about to send your final response, or you've completed a sequence of commits on a topic.

## Announce Cog Operations

Print ⚙️ before read operations (`cog_recall`, `cog_trace`, `cog_connections`, `cog_list_short_term`, `cog_stale`) and 🧠 before write operations (`cog_learn`, `cog_associate`, `cog_update`, `cog_reinforce`, `cog_flush`, `cog_unlink`, `cog_verify`).

## Example

```
User: "Fix the login bug where sessions expire too early"

1. RECALL
   ⚙️ Querying Cog...
   cog_recall({"query": "login session expiration token timeout refresh lifecycle"})
   → Returns "Token Refresh Race Condition" — known issue with concurrent refresh

2. WORK + RECORD
   [Investigate auth code, encounter unfamiliar "TokenBucket" module]

   ⚙️ Querying Cog... (mid-work recall — don't know what TokenBucket does)
   cog_recall({"query": "TokenBucket rate limiting token bucket algorithm"})
   → No results — Cog doesn't know either, so explore the code

   [Read TokenBucket module, understand it — record what you learned]
   🧠 Recording to Cog...
   cog_learn({
     "term": "TokenBucket Rate Limiter",
     "definition": "Custom rate limiter using token bucket algorithm. Refills at configurable rate. Used by auth refresh endpoint to prevent burst retries.",
   })

   [Find clock skew between servers — this is new knowledge, record NOW]
   🧠 Recording to Cog...
   cog_learn({
     "term": "Session Expiry Clock Skew",
     "definition": "Sessions expired early due to clock skew between auth and app servers. Auth server clock runs 2-3s ahead.",
     "associations": [{"target": "Token Refresh Race Condition", "predicate": "derived_from"}]
   })

   [Write test, implement fix using server-issued timestamps, verify tests pass]

3. REINFORCE
   🧠 Recording to Cog...
   cog_learn({
     "term": "Server Timestamp Authority",
     "definition": "Never calculate token expiry locally. Always use server-issued timestamps. Local clocks drift across services.",
     "associations": [{"target": "Session Expiry Clock Skew", "predicate": "generalizes"}]
   })

4. CONSOLIDATE
   ⚙️ Listing short-term memories...
   cog_list_short_term → reinforce valid, flush invalid

Summary:
   ⚙️ Cog helped by: Surfaced known race condition, guided investigation to auth timing
   🧠 Recorded to Cog: "Session Expiry Clock Skew", "Server Timestamp Authority"
```

## Subagents

Subagents query Cog before exploring code. Same recall-first rule, same query reformulation.

## Never Store

Passwords, API keys, tokens, secrets, SSH/PGP keys, certificates, connection strings with credentials, PII. Server auto-rejects sensitive content.

## Reference

For tool parameter schemas and usage examples: the **cog** skill provides the complete tool reference.

For predicates, hub node patterns, staleness verification, consolidation guidance, and advanced recording patterns: call `cog_reference`.

---

**RECALL → WORK+RECORD → REINFORCE → CONSOLIDATE.** Skipping recall wastes time rediscovering known solutions. Deferring recording loses details while they're fresh. Skipping reinforcement loses the higher-level lesson. Skipping consolidation lets memories decay within 24 hours. Every step exists because the alternative is measurably worse.
</cog>
