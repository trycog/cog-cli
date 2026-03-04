You are bootstrapping a persistent knowledge graph for a codebase.

Read the file below and extract concepts with rich semantic metadata, then store them in the knowledge graph.

# Extraction Depth

Extract concepts across MULTIPLE DIMENSIONS, not just what code does:

**Behaviors & Mechanisms** — What the code does
- Different functions serving different purposes = separate concepts
- Different code paths handling different cases = separate behaviors
- Distinct configuration options that change behavior = separate concepts

**Architectural Properties** — What the code guarantees
- Concurrency/isolation guarantees
- Delivery guarantees (at-most-once, at-least-once, exactly-once)
- Consistency models (eventual, strong, CRDT-based)
- Scalability properties

**Boundaries & Layering** — Why components are separated
- What concern does each layer handle that others don't?
- Why is this component above/below/beside another?
- What would break if two layers were merged?

**Constraints & Invariants** — Rules that must always hold
- Ordering requirements (X must happen before Y)
- Access control rules (who can reach what)
- Validation boundaries (where untrusted data becomes trusted)
- Assumptions the code makes about its environment

**Tradeoffs & Alternatives** — Why this approach over others
- What was chosen and what was rejected
- What flexibility was sacrificed for what guarantee
- Runtime vs compile-time tradeoffs

## For Each Concept, Capture

1. **term** — Descriptive name (2-5 words). Must be UNIQUE and FILE-SPECIFIC — qualify generic names with the module or subsystem context. Think: would another file produce a concept with this exact same name? If yes, make it more specific.
2. **definition** — What it is, how it works, and WHY it exists (1-3 sentences). Include the problem it solves and any design tradeoffs. Explain WHY, not just WHAT.
3. **category** — One of: core-algorithm, data-structure, api-surface, configuration, optimization, error-handling, state-management, utility, platform-abstraction, testing, design-decision, architecture, security, constraint

### Categories Explained

- **core-algorithm** — Main logic, algorithms, control flow
- **data-structure** — Data structures and their operations
- **api-surface** — Public interfaces, exports, entry points
- **configuration** — Feature flags, settings, constants
- **optimization** — Performance optimizations, caching, memoization
- **error-handling** — Error management, recovery, validation
- **state-management** — State tracking, transitions, lifecycle
- **utility** — Helper functions, shared utilities
- **platform-abstraction** — Browser/environment abstractions
- **testing** — Test utilities, mocks, test helpers
- **design-decision** — Why a particular approach was chosen, tradeoffs, alternatives rejected
- **architecture** — High-level system design, separation of concerns, module boundaries
- **security** — Authentication, authorization, trust boundaries, access control
- **constraint** — Invariants, ordering requirements, guarantees, assumptions, validation rules

## Documentation vs Code

For documentation files (README, CHANGELOG, LICENSE), focus on DESIGN KNOWLEDGE:

**Prioritize:**
- Architectural principles and WHY components are structured this way
- Design constraints and invariants
- Tradeoffs and alternatives
- Boundaries between components and WHY those boundaries exist
- Security model and trust boundaries

**De-prioritize:**
- Setup/installation/deployment instructions
- Command-line invocations and flag lists
- Version-specific configuration values
- Tutorial walkthroughs

## Quality Guidelines

**Capture foundational definitions, not just usage:**
- When code implements a specification/protocol/behaviour, extract what that specification IS
- If a module defines callbacks or contracts, extract the specification as its own concept
- When code provides guarantees, extract those as their own concepts
- When code enforces constraints, extract the rule and WHY it exists

**Include specific API details in definitions:**
- NAME public functions, callbacks, macros in the definition
- Include exact event names when code emits or handles events
- Mention important options or configuration keys
- Prefer concrete details: "returns {status, socket}" over "returns status information"

**Mine for rationale and design decisions:**
- Comments with "because", "instead of", "tradeoff", "workaround", "note:" signal design decisions
- If a comment explains why an alternative was rejected, that's a design-decision concept
- Capture rules and constraints (e.g., "X must always be called before Y")

**Capture boundaries and layering:**
- When a module delegates to another, extract WHY the separation exists
- Architectural boundaries are concepts too — "X handles concern A so that Y doesn't have to"

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
- Prefer fewer, higher-quality memories over many shallow ones
- Process the ENTIRE file, do not skip sections

## File to Process

{file_path}
