You are bootstrapping a persistent knowledge graph for a codebase.

You are looking at a **subsystem** — a cluster of related source files that work together. Read all the files listed below and extract the architectural knowledge an AI agent would need to understand how this subsystem works — the kind of understanding that gets lost when a context window resets.

# Guiding Principle

The codebase already has a code intelligence index that can look up any symbol definition, reference, or call graph. Memory does NOT need to duplicate what the index provides. Instead, capture knowledge that cannot be derived from reading the code:

- **Why** something was built this way, not **what** it does
- Design decisions and their tradeoffs
- Constraints and invariants that break if violated
- How data flows across file boundaries within this subsystem
- Workflow rules and ordering requirements

Fewer, high-quality concepts beat comprehensive coverage. Noisy concepts crowd out useful ones during recall.

# What to Extract

Think at the **subsystem level**, not the file level. These files were grouped together because they share dependencies and work as a unit. Ask yourself:

1. **Subsystem Responsibility** — What does this group of files own that nothing else in the codebase does? What is the boundary?
2. **Design Decisions** — Why this approach? What tradeoffs were made? Look for comments with "because", "instead of", "tradeoff", "workaround".
3. **Constraints & Invariants** — Ordering requirements, assumptions, validation boundaries, concurrency rules, things that break if changed.
4. **Cross-File Patterns** — How do these files collaborate? What data flows between them? What are the key integration points?

Skip any dimension that doesn't add value. Not every subsystem has interesting constraints or design decisions.

## Volume

- Target: **2-5 concepts** for the entire subsystem
- If you're extracting more than 5, step back — you're inventorying, not capturing understanding
- One concept that captures a cross-cutting design decision is worth more than five that describe individual files

## Anti-Patterns — Do NOT Do These

- Do NOT create one concept per file
- Do NOT describe what individual functions or methods do — the code index handles that
- Do NOT mirror the file structure (e.g., "Config Module", "Utils Module")
- Do NOT store function signatures, parameter lists, or return types
- Do NOT create concepts that could be answered by a simple code search

## Concepts

1. **term** — 2-5 words, specific and qualified. Must be unique across the codebase. Bad: "Configuration". Good: "Settings Resolution Chain" or "Bootstrap Cooperative Cancellation".
2. **definition** — 1-3 sentences. Explain WHY, not just WHAT. Include specific technical terms and patterns — these drive keyword search during recall.
3. **category** — One of: `design-decision`, `constraint`, `data-flow`, `architecture`, `error-handling`, `configuration`

## Example

For a subsystem of 5 files implementing the bootstrap pipeline (worker pool, file processing, checkpointing, TUI progress):

```
term: "Bootstrap Cooperative Cancellation"
definition: "Workers check an atomic abort flag at loop top before claiming the next file. After 5 consecutive agent failures, the abort flag cascades to all workers. This prevents runaway cost when the API is down. The reaper process handles orphaned children on SIGKILL."
category: constraint

term: "Bootstrap Checkpoint Resume"
definition: "Progress is saved per-file to a JSON checkpoint after each successful extraction. On restart, already-processed files are skipped. The checkpoint is auto-cleared when the brain is empty (detected via cog_stats API call) to prevent stale state after a brain reset."
category: design-decision
```

Note: these concepts describe cross-cutting design patterns, not individual functions.

## Associations

Use `cog_mem_associate` with an `items` array to link concepts in a single batch call. **Predicate choice matters enormously for recall quality:**

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

1. Use `cog_mem_recall` with a query related to this subsystem's domain to check what already exists.
2. Use `cog_mem_learn` with an `items` array to store all concepts in a single batch call:
   - Each item needs `term` and `definition`
   - Set `memory_term` to `"long"` for permanent storage
3. Use `cog_mem_associate` with an `items` array to create relationships in a single batch call, including links to concepts found via recall.

## Rules

- Do NOT store: secrets, credentials, PII, or trivial implementation details
- When in doubt, leave it out — a missing concept can be added later, but noise degrades every future recall

## Subsystem: {subsystem_label}

### Files

{file_paths}

### Cross-File Dependencies

{cross_file_context}
