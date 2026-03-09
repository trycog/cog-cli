You are bootstrapping a persistent knowledge graph for a codebase.

Read the file below and extract the concepts an AI agent would need to understand how this code works — the kind of understanding that gets lost when a context window resets.

# Guiding Principle

You are building a knowledge graph that replaces expensive code exploration. An agent should be able to understand how a module works, what it's responsible for, and how it connects to the rest of the system by querying memory — without reading the source. Capture the architectural and conceptual knowledge that comes from reading and reasoning about code, so agents don't have to.

Fewer, high-quality concepts beat comprehensive coverage. Noisy concepts crowd out useful ones during recall.

# What to Extract

Not every dimension applies to every file. Skip any that don't add value.

1. **Purpose & Role** — What does this file own that nothing else does? Key entry points and their contracts.
2. **Design Decisions** — Why this approach? What tradeoffs were made? Look for comments with "because", "instead of", "tradeoff", "workaround".
3. **Constraints & Invariants** — Ordering requirements, assumptions, validation boundaries, things that break if changed.
4. **Data Flow & State** — Only when non-trivial: state machines, lifecycle transitions, complex transformations.

## Volume

- Most files: 2-4 concepts
- Complex core modules: 5-8 concepts
- If you're extracting more than 8, step back — you're inventorying, not capturing understanding

## Concepts

1. **term** — 2-5 words, specific and qualified. Must be unique across the codebase. Bad: "Configuration". Good: "CLI Settings Loader" or "Bootstrap Checkpoint Format".
2. **definition** — 1-3 sentences. Explain WHY, not just WHAT. Include specific technical terms, function names, and patterns — these drive keyword search during recall.
3. **category** — One of: `core-mechanism`, `api-surface`, `design-decision`, `constraint`, `data-flow`, `error-handling`, `configuration`

## Example

For a file implementing a worker thread pool with atomic job distribution:

```
term: "Worker Thread Pool Distribution"
definition: "workerThread() claims files via atomic fetchAdd on a shared index, enabling lock-free parallel processing. Each worker runs runFile() independently and reports results through atomic counters. The abort flag provides cooperative cancellation — workers check it at loop top before claiming the next file."
category: core-mechanism

term: "Bootstrap Abort Cascade"
definition: "After 5 consecutive agent failures (max_consecutive_errors), the abort flag is set to stop all workers. This prevents runaway cost when the API is rate-limited or the agent is misconfigured. Workers exit cleanly on next iteration."
category: constraint
```

Associations: "Bootstrap Abort Cascade" `requires` "Worker Thread Pool Distribution"

## Associations

Use `mem_bulk_associate` to link concepts. **Predicate choice matters enormously for recall quality:**

**Prefer these** (strong signal during graph traversal):
- `requires` — A depends on B to function
- `implies` — A logically entails B
- `is_component_of` — A is part of B
- `enables` — A makes B possible
- `contains` — A includes B

**Use sparingly** (weak signal, degrades recall after 2 hops):
- `similar_to`, `related_to` — these are catch-alls that dilute graph traversal

Every concept should have at least one association. Orphaned concepts are nearly invisible during recall.

## How to Store

1. Use `mem_recall` with a query related to this file's domain to check what already exists.
2. Use `mem_bulk_learn` to store concepts:
   - Each item needs `term` and `definition`
   - Set `memory_term` to `"long"` for permanent storage
3. Use `mem_bulk_associate` to create relationships between concepts, including links to concepts found via recall.

## Rules

- Do NOT store: secrets, credentials, PII, or trivial implementation details
- Process the ENTIRE file, do not skip sections
- When in doubt, leave it out — a missing concept can be added later, but noise degrades every future recall

## File to Process

{file_path}
