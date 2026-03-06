# Cog

Code intelligence, persistent memory, and interactive debugging.

**Truth hierarchy:** Current code > User statements > Cog knowledge.

## Code Intelligence

When you need a symbol definition, references, call sites, or type information:
use `cog_code_explore` or `cog_code_query`. Do NOT use Grep or Glob for symbol lookups.

- `cog_code_explore` — find symbols by name, return full definition bodies and file TOC
- `cog_code_query` — `find` (locate definitions), `refs` (find references), `symbols` (list file symbols)
- Include synonyms with `|`: `banner|header|splash`
- Glob patterns: `*init*`, `get*`, `Handle?`

Only fall back to Grep for string literals, log messages, or non-symbol text patterns.

## Debugging

Wrong output, unexpected state, or unclear crash: use the `cog-debug` sub-agent.
State your hypothesis before launching.

<cog:mem>
## Memory

`cog_mem_*` tools are MCP tools — call them directly, never via the Skill tool.

Before modifying unfamiliar code, use `cog_mem_recall` or the `cog-mem` sub-agent
to check for relevant context. Skip if nothing useful returns.

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
