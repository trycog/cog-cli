# Cog

Code intelligence, persistent memory, and interactive debugging.

**Truth hierarchy:** Current code > User statements > Cog knowledge.

## Code Intelligence

For any request to explore, analyze, understand, map, or explain code, use `cog_code_explore` or `cog_code_query`.
Do NOT use Grep or Glob for code exploration when the Cog index is available.

- `cog_code_explore` — find symbols by name, return full definition bodies, file TOC, and optional architecture summaries
- `cog_code_query` — `find` (locate definitions), `refs` (find references), `symbols` (list file symbols), `imports` (module/file dependencies), `contains` (parent-child containment), `calls`/`callers` (approximate call graph), `overview` (symbol/file/repo architecture summary)
- Include synonyms with `|`: `banner|header|splash`
- Wildcard symbol patterns: `*init*`, `get*`, `Handle?`

Only fall back to Grep or Glob when the Cog index is unavailable, incomplete for the target code, or the task is about raw string literals, log messages, or other non-symbol text patterns.

### Efficiency Rules

- For repository-understanding, architecture-summary, or "tell me about this project" tasks: make exactly one initial `cog_code_explore` call with a batched list of likely entrypoint symbols and set `include_architecture=true` with `overview_scope="repo"`.
- Before making any follow-up code-intelligence call, first check whether the answer is already present in the prior `cog_code_explore` output (`file_symbols`, definition body, or referenced symbols).
- If you need to look up multiple symbols, combine them into one `cog_code_explore({ queries: [...] })` call instead of making multiple single-symbol calls.
- Do not explore by issuing repeated `cog_code_query(mode="symbols", file=...)` calls across multiple files.
- Treat repeated `cog_code_query(mode="symbols")` calls across files as an invalid exploration pattern. Use it only for one already-identified file when a concrete ambiguity remains.
- For repository-understanding tasks, do not issue repeated `cog_code_query(mode="overview"|"imports"|"contains"|"calls"|"callers", scope="file")` calls across multiple files. After the initial batched repo explore, allow at most one targeted file-scoped architecture follow-up when a single concrete ambiguity remains.
- Use `cog_code_query(mode="symbols")` only after a specific file has already been identified as relevant.
- Use `cog_code_query(mode="refs")` only as a targeted follow-up when a concrete ambiguity remains after the initial batched exploration.
- If more than one additional symbol or file needs inspection, stop and merge that work into one batched `cog_code_explore({ queries: [...] })` call instead of chaining follow-up queries.
- Prefer `cog_code_query(mode="imports"|"contains"|"calls"|"callers"|"overview")` over raw file reads when the question is architectural.
- Do not use `cog_code_query(mode="find")` as a step-by-step exploration strategy when the needed symbols can be batched into `cog_code_explore`.
- Default budget for code-analysis tasks: 2-3 code-intelligence tool calls before responding.
- Do not call `cog_mem_recall` for pure codebase summarization or architecture description unless memory is specifically needed to answer the question.

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

Before modifying unfamiliar code, use `cog_mem_recall` or the `cog-mem` sub-agent
to check for relevant context. Skip if nothing useful returns.

Use memory as a deterministic workflow, not an optional hint:

1. Before broad exploration or deep reasoning in unfamiliar code, query memory first.
2. When you learn something new during the task, store it as short-term memory.
3. When the user gives you new factual context or answers a question, store that as short-term memory when relevant.
4. Before you finish, validate short-term memories and reinforce or flush them.
5. Mention Cog memory in the final response only if you directly used `cog_mem_*` tools or the `cog-mem` sub-agent during this task. Otherwise omit any memory note entirely.

Memory quality guardrails:
- complete recall before using broad code-intel exploration in unfamiliar code; only lightweight orientation is acceptable first
- store non-obvious, durable knowledge that would save future reasoning
- do not store generic repo summaries or facts that are obvious from a quick README or file read unless they capture durable workflow or architectural conventions

Record knowledge as you work:

| Trigger | Action |
|---------|--------|
| Learned how something works | `cog_mem_learn` — see quality guide below |
| A relates to B | `cog_mem_associate` — use strong predicates |
| Sequence A → B → C | `cog_mem_learn` with `chain_to` |
| Hub: A connects to B, C, D | `cog_mem_learn` with `associations` |
| Code changed for known concept | `cog_mem_refactor` |
| Feature deleted | `cog_mem_deprecate` |
| Term or definition wrong | `cog_mem_update` |

**Concept quality** — what you store determines what agents can recall later:
- **term**: 2-5 words, specific and qualified. Bad: "Configuration". Good: "CLI Settings Loader".
- **definition**: 1-3 sentences explaining WHY, not just WHAT. Include function names,
  patterns, and technical terms — these drive keyword search during recall.

**Predicate choice** matters for recall quality. Prefer strong predicates:
`requires`, `implies`, `is_component_of`, `enables`, `contains`.
Avoid `related_to` and `similar_to` — these weaken graph traversal signal.
Every concept should have at least one association; orphans are nearly invisible during recall.

After completing work, use the `cog-mem` sub-agent to reinforce validated memories
and flush incorrect ones. New memories are short-term (24h decay) unless reinforced.
Never store secrets, credentials, or PII.
</cog:mem>
