# Rules

- *NEVER* attempt to use any historically destructive git commands
- *ALWAYS* make small and frequent commits
- This project is using Zig 0.15 and you must respect the avalable API for that
- All tests must pass, do not ignore failing tests that you believe are unreleated to your work. Only fix those failing tests after you've completed and validated your work. The last step of any job you do should be to ensure all tests pass.
- *NEVER* attempt to launch the Zig documentation, it is a web app that you cannot access. Instead you *MUST* search the documentation on the ziglang website

<cog>
# Cog

Code intelligence, persistent memory, and interactive debugging via Cog.

Announce operations with an emoji prefix:

- 🔍 Code: cog-code-query sub-agent
- 🧠 Memory: all `cog_mem_*` tools and cog-mem sub-agent
- 🐞 Debug: cog-debug sub-agent

`cog_mem_*` tools are MCP tools — call them directly, never via the Skill tool.
**Truth hierarchy:** Current code > User statements > Cog knowledge.

## Step 1 — Recall (before starting work)

Before modifying code or exploring an unfamiliar module, invoke the `cog-mem`
sub-agent to recall concepts related to the files, modules, or task at hand.
Use recalled context to inform your approach. If nothing relevant is returned,
proceed normally.

## Step 2 — Work (trigger → action)

While working, execute the matching action when you hit a trigger:

| Trigger | Action |
|---------|--------|
| Need a symbol definition, call site, or type | 🔍 `cog-code-query` sub-agent (prefer over Grep/Glob). Include synonyms via `|` alternation — e.g. if the user says "banner", query `banner|header|splash|logo`. |
| Wrong output, unexpected state, unclear crash | 🐞 `cog-debug` sub-agent — state your hypothesis first |
| Discovered how something works (pattern, API, architecture) | 🧠 `cog_mem_learn` (term: 2-5 words, def: 1-3 sentences) |
| Discovered A relates to B (depends on, leads to, contains) | 🧠 `cog_mem_associate` — link the two concepts |
| Discovered a sequence A → B → C | 🧠 `cog_mem_learn` with `chain_to` |
| Discovered a hub: A connects to B, C, D | 🧠 `cog_mem_learn` with `associations` |
| Code/behavior changed for a known concept | 🧠 `cog_mem_refactor` — update the definition |
| A feature or concept was deleted | 🧠 `cog_mem_deprecate` — mark it gone |
| A concept's term or definition needs a correction | 🧠 `cog_mem_update` — edit by UUID |

## Step 3 — Consolidate (after completing work)

After the user's task is done:

1. Invoke the `cog-mem` sub-agent for **consolidation** — it will reinforce
   validated short-term memories and flush incorrect ones.
2. End your final response with:
   - `🧠 Cog recall:` what was useful (or "nothing relevant")
   - `🧠 Stored to Cog:` concepts stored (or "nothing new")

All new memories are **short-term** and decay within 24 hours unless reinforced
during consolidation. Never store secrets, credentials, PII, or keys.
</cog>
