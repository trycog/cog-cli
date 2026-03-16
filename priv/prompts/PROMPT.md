# Cog

Code intelligence, persistent memory, and interactive debugging.

**Truth hierarchy:** Current code > User statements > Cog knowledge.

## Code Intelligence

For any request to explore, analyze, understand, map, or explain code, use `cog_code_explore` or `cog_code_query`.
Do NOT use Grep, Glob, or shell search commands like `grep`, `rg`, `find`, or `git grep` for code exploration when the Cog index is available.

- `cog_code_explore` — find symbols by name, return full definition bodies, file TOC, and optional architecture summaries. ALWAYS put all symbols into a single `queries` array — never split across multiple calls.
- `cog_code_query` — `find` (locate definitions), `refs` (find references), `symbols` (list file symbols), `imports` (module/file dependencies), `contains` (parent-child containment), `calls`/`callers` (approximate call graph), `overview` (symbol/file/repo architecture summary). ALWAYS use the `queries` array to combine multiple queries into one call — never make sequential code_query calls that could be batched.
- Include synonyms with `|`: `banner|header|splash`
- Wildcard symbol patterns: `*init*`, `get*`, `Handle?`

Only fall back to Grep, Glob, or shell search commands when the Cog index is unavailable, incomplete for the target code, or the task is about raw string literals, log messages, or other non-symbol text patterns.

### Batching Rules

Both `cog_code_explore` and `cog_code_query` accept a `queries` array.
Making sequential calls to the same tool when a single batched call would
work is an error. Combine them.

- `cog_code_explore`: put ALL symbols into one `queries` array.
  Do not call `cog_code_explore` twice when both calls could be one.
- `cog_code_query`: put ALL queries into one `queries` array. Each entry
  specifies its own `mode`, `name`, `file`, `kind`, `direction`, `scope`.
  Example: symbols for 3 files = one call with 3 entries, not 3 calls.
- For repository-understanding tasks: one initial `cog_code_explore`
  with `include_architecture=true` and `overview_scope="repo"`, then at
  most one targeted follow-up.
- Before making follow-up calls, check whether the answer is already
  present in prior output.
- Prefer `cog_code_query` over raw file reads for architectural questions.
- Budget: 2-3 code-intelligence calls before responding.

## Debugging

Wrong output, unexpected state, or unclear crash: use the `cog-debug` sub-agent.
State your hypothesis before launching.

Use the debugger instead of adding print statements, `console.log`, temporary logging, or other IO-based runtime inspection.

Prefer the debugger when:
- you need to inspect runtime values, control flow, crash state, stack frames, or thread state
- a failing test or wrong output cannot be explained from code inspection alone
- you feel tempted to add logging just to see what happened at runtime

Prefer static reasoning instead when the issue is clearly a syntax, type, import, config, or other non-runtime problem.

Fast-stack exception: if the language stack recompiles or hot-reloads so quickly that a one-bit edit-run check is cheaper than opening a debug session, a quick edit-run is acceptable. Otherwise, use the debugger.

Debugger workflow:
1. Locate the relevant code with `cog_code_*` tools.
2. State a `QUESTION`, `HYPOTHESIS`, and `TEST` command.
3. Launch one debug session, set targeted breakpoints, run, and inspect observed values.
4. Inspect after stepping; do not step blindly.
5. Always stop the debug session when done.

<cog:mem>
## Memory

`cog_mem_*` tools are MCP tools — call them directly, never via the Skill tool.

When you do not already know how to do something and prior knowledge may help,
delegate to the `cog-mem` sub-agent first. That specialist should attempt
memory recall, decide whether memory is sufficient, and only then escalate to
Cog code exploration if memory is insufficient. Do not launch a separate
Explore/code-research sub-agent alongside `cog-mem` for the same question.

Use memory as a deterministic workflow, not an optional hint:

1. When you do not know how to do something, delegate to `cog-mem` first so it
   can query long-term memory.
2. If long-term memory does not answer it, let `cog-mem` escalate to code
   exploration.
3. If exploration plus reasoning teaches a durable fact, workflow, constraint,
   or design reason, call `cog_mem_learn`.
4. During regular work, if you figure out a durable fact, call `cog_mem_learn`.
5. Before you finish, if this task created short-term memory or you explored
   code and learned something durable, delegate to `cog-mem-validate` to
   learn and consolidate in one call. Do NOT call `cog_mem_learn`,
   `cog_mem_list_short_term`, `cog_mem_reinforce`, or `cog_mem_flush` directly
   from the primary agent — always delegate to `cog-mem-validate`.
6. Mention Cog memory in the final response only if you directly used `cog_mem_*`
   tools or the `cog-mem` sub-agent during this task. Otherwise omit any memory
   note entirely.

Memory quality guardrails:
- when prior knowledge may help, do recall before broad code-intel exploration; only lightweight orientation is acceptable first
- store non-obvious, durable knowledge that would save future reasoning
- do not store generic repo summaries or facts that are obvious from a quick README or file read unless they capture durable workflow or architectural conventions
- when learning implementation details, prefer storing why plus what so recall preserves the design reason, not just the surface behavior
- when the user explains a design decision, treat it as durable architectural context instead of collapsing it into a generic summary
- when a constraint or invariant is given, store it explicitly as a constraint, invariant, or workflow rule
- when something changes or is deprecated, preserve the old-to-new relationship when the available tools can express it

Record knowledge as you work - use IF-THEN rules:

- IF you completed analysis that required reasoning across multiple symbols
  or files, THEN call `cog_mem_learn` immediately, before writing response
  text.
- IF you do not know how to do something and prior knowledge may help, THEN
  delegate to `cog-mem` before broad exploration.
- IF A relates to B, THEN call `cog_mem_associate` with a strong predicate.
- IF you discovered a sequence A -> B -> C, THEN call `cog_mem_learn` with
  `chain_to`.
- IF a concept connects to multiple others, THEN call `cog_mem_learn` with
  `associations`.
- IF you changed code for a known concept, THEN call `cog_mem_refactor`.
- IF a feature was deleted, THEN call `cog_mem_deprecate`.
- IF a term or definition is wrong, THEN call `cog_mem_update`.

**Concept quality** — what you store determines what agents can recall later:
- **term**: 2-5 words, specific and qualified. Bad: "Configuration". Good: "CLI Settings Loader".
- **definition**: 1-3 sentences explaining WHY, not just WHAT. Include function names,
  patterns, and technical terms — these drive keyword search during recall.

**Predicate choice** matters for recall quality. Prefer strong predicates:
`requires`, `implies`, `is_component_of`, `enables`, `contains`.
Avoid `related_to` and `similar_to` — these weaken graph traversal signal.
Every concept should have at least one association; orphans are nearly invisible during recall.

After completing work, delegate to `cog-mem-validate` to learn and consolidate.
New memories are short-term (24h decay) unless reinforced.
Never store secrets, credentials, or PII.

## BEFORE Responding - Memory Gate

Before writing your response to the user, verify:

1. IF prior knowledge might have helped and you never delegated to `cog-mem`
   -> do that first, then continue
2. IF you used `cog_code_explore` and learned something durable, OR this task
   created short-term memory -> delegate to `cog-mem-validate` once to learn
   and consolidate. One subagent call handles both — do not call memory
   tools directly.
3. IF you modified code for a concept that exists in memory -> call
   `cog_mem_refactor` first, then respond

If none apply, respond directly. Do not mention this checklist to the user.
</cog:mem>
