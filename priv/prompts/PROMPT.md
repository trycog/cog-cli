# Cog

Code intelligence, persistent memory, and interactive debugging.

**Truth hierarchy:** Current code > User statements > Cog knowledge.

## Code Intelligence

For any request to explore, analyze, understand, map, or explain code, use `cog_code_explore` or `cog_code_query`.
<cog:code-query>
For repository exploration, invoke or apply the installed `cog-code-query` specialist so code-index work stays out of the primary context.
</cog:code-query>
Do NOT use Grep, Glob, or shell search commands like `grep`, `rg`, `find`, or `git grep` for code exploration when the Cog index is available.
Only fall back to Grep, Glob, or shell search commands when the Cog index is unavailable, incomplete for the target code, or the task is about raw string literals, log messages, or other non-symbol text patterns.

Both tools take a `queries` array — batch every lookup into one call; sequential calls that could be combined are an error. Before your first code-intelligence call in a session, load the installed `cog-explore` skill for the full batching workflow.

<cog:debug>
## Debugging

**Always route runtime debugging through the installed `cog-debug` specialist** — do NOT call `cog_debug_*` tools directly. Invoke it with QUESTION (what you want to understand), HYPOTHESIS (your theory), and TEST (the command to run). Use it whenever runtime values, control flow, or crash state cannot be explained from code inspection alone; prefer static reasoning for syntax, type, import, or config problems. Do NOT fall back to shell debuggers (lldb, gdb, dlv).
</cog:debug>

<cog:observe>
## Observability

**Always route system observability through the installed `cog-observe` specialist** — do NOT call `cog_observe_*` tools directly. Invoke it with QUESTION, HYPOTHESIS, and TARGET (process or command) when syscalls, GPU, network, or resource costs need investigation. Do NOT fall back to shell profiling tools (strace, perf, dtrace, tcpdump).
</cog:observe>

<cog:mem>
## Memory

`cog_mem_*` tools are MCP tools — call them directly, never via the Skill tool.

<cog:memory-specialist>
When you do not already know how to do something and prior knowledge may help, route retrieval through the installed `cog-mem` specialist first: it recalls from long-term memory, decides sufficiency, and only then escalates to Cog code exploration. Do not launch a separate exploration specialist alongside it for the same question.
</cog:memory-specialist>

Memory is a deterministic workflow, not an optional hint: recall before broad exploration, record durable facts as you work, and consolidate before finishing. Before recording, associating, or maintaining memories, load the installed `cog-remember` skill for the recording rules and quality guardrails.
<cog:validate>
Before you finish, if this task created short-term memory or you explored code and learned something durable, route validation through `cog-mem-validate` to learn and consolidate in one call — do NOT call `cog_mem_learn`, `cog_mem_list_short_term`, `cog_mem_reinforce`, or `cog_mem_flush` directly.
</cog:validate>
Mention Cog memory in the final response only if you directly used `cog_mem_*` tools or an installed memory specialist during this task.

## BEFORE Responding - Memory Gate

Before writing your response to the user, verify:

<cog:memory-specialist>
1. IF prior knowledge might have helped and you never used `cog-mem` -> do that first, then continue
</cog:memory-specialist>
<cog:validate>
2. IF you used `cog_code_explore` and learned something durable, OR this task created short-term memory -> use `cog-mem-validate` once to learn and consolidate
</cog:validate>
3. IF you modified code for a concept that exists in memory -> call `cog_mem_refactor` first, then respond

If none apply, respond directly. Do not mention this checklist to the user.
</cog:mem>
