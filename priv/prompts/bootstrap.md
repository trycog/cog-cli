You are bootstrapping a persistent knowledge graph for a codebase.

Read the file below and extract concepts that capture understanding — not an inventory of every function and code path.

# Guiding Principle

**Fewer, high-quality concepts that capture understanding — not an inventory.**

You are building a knowledge graph that replaces expensive code exploration. An agent should be able to understand how a module works, what it's responsible for, and how it connects to the rest of the system by querying memory — without reading the source. Capture the architectural and conceptual knowledge that comes from reading and reasoning about code, so agents don't have to.

# Extraction Dimensions (use only what applies)

Not every dimension applies to every file. Skip any that don't add value.

1. **Purpose & Role** — Why does this file exist? What responsibility does it own that nothing else does?
2. **Key Design Decisions** — Why this approach over alternatives? What tradeoffs were made? Look for comments with "because", "instead of", "tradeoff", "workaround".
3. **Constraints & Gotchas** — Ordering requirements, invariants, assumptions, validation boundaries, things that would break if changed.
4. **Public API Summary** — Key entry points and their contracts. Not every function — just the ones a caller needs to know about.
5. **Data Flow & State** — Only when non-trivial: state machines, lifecycle transitions, complex data transformations.
6. **Error Handling Strategy** — Only when deliberate: retry policies, recovery mechanisms, error propagation patterns.

## Volume Guidance

- A small utility file: 2-3 concepts
- A typical module: 4-6 concepts
- A complex core module: 8-10 concepts
- If you're extracting more than 10, you're probably inventorying — step back and focus on what matters

## For Each Concept, Capture

1. **term** — Descriptive name (2-5 words). Must be UNIQUE and FILE-SPECIFIC — qualify generic names with the module or subsystem context.
2. **definition** — What it is, how it works, and WHY it exists (1-3 sentences). Explain WHY, not just WHAT.
3. **category** — One of: `core-mechanism`, `api-surface`, `design-decision`, `constraint`, `data-flow`, `error-handling`, `configuration`

### Categories

- **core-mechanism** — Main logic, algorithms, data structures, control flow, utilities, optimizations, platform abstractions
- **api-surface** — Public interfaces, exports, entry points
- **design-decision** — Why a particular approach was chosen, tradeoffs, alternatives rejected, architectural boundaries
- **constraint** — Invariants, ordering requirements, guarantees, assumptions, validation rules, security boundaries
- **data-flow** — State tracking, transitions, lifecycle, data transformations
- **error-handling** — Error management, recovery, validation
- **configuration** — Feature flags, settings, constants

## Documentation and Markdown Files

For documentation files (.md, README, CHANGELOG, LICENSE, etc.), focus on DESIGN KNOWLEDGE:

**Prioritize:**
- Architectural principles and WHY components are structured this way
- Design constraints and invariants
- Tradeoffs and alternatives considered
- Domain concepts, terminology, and glossary definitions
- Security model and trust boundaries

**De-prioritize:**
- Setup/installation/deployment instructions
- Command-line invocations and flag lists
- Version-specific configuration values
- Tutorial walkthroughs
- Boilerplate legal text

## How to Store

1. First, use `cog_mem_recall` with a query related to this file's domain to check what already exists and avoid duplicates.
2. Use `cog_mem_bulk_learn` to store all concepts from this file in one call:
   - Each item needs `term` and `definition`
   - Set `memory_term` to `"long"` for permanent storage
3. Use `cog_mem_bulk_associate` to create relationships between concepts:
   - Valid predicates: `implies`, `requires`, `is_component_of`, `contains`, `similar_to`, `contrasts_with`, `enables`, `derived_from`, `related_to`, `leads_to`
   - If concept A calls/uses B → A `requires` B
   - If concept A is part of B → A `is_component_of` B
   - If concept A and B do similar things → A `similar_to` B
   - If A and B do the same thing differently → A `contrasts_with` B
   - Also link to concepts from `cog_mem_recall` results when relevant

## Rules

- Do NOT store: secrets, credentials, PII, or trivial implementation details
- Process the ENTIRE file, do not skip sections
- When in doubt, leave it out — a missing concept can be added later, but noisy ones pollute the graph

## File to Process

{file_path}
