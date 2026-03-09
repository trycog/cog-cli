# Rules

- *NEVER* attempt to use any historically destructive git commands
- *ALWAYS* make small and frequent commits
- This project is using Zig 0.15 and you must respect the avalable API for that
- All tests must pass, do not ignore failing tests that you believe are unreleated to your work. Only fix those failing tests after you've completed and validated your work. The last step of any job you do should be to ensure all tests pass.
- *NEVER* attempt to launch the Zig documentation, it is a web app that you cannot access. Instead you *MUST* search the documentation on the ziglang website
- All new features must include `debug_log.log()` calls at key decision points and IO boundaries (network calls, file operations, subprocess spawns, config resolution). These are no-ops when `--debug` is not active.

## Release Process

When the user says "release" (or similar), follow this procedure:

### 1. Determine the version

- If the user specifies a version, use it.
- Otherwise, analyze all commits since the last release tag (`git log <last-tag>..HEAD --oneline`) and apply [Semantic Versioning](https://semver.org/):
  - **patch** (0.0.x): bug fixes, build fixes, documentation, dependency updates
  - **minor** (0.x.0): new features, new commands, non-breaking enhancements
  - **major** (x.0.0): breaking changes to CLI interface, config format, or public API

### 2. Update version string

Update the version in the single source of truth:
- `build.zig.zon` — `.version = "X.Y.Z",`

(`build.zig` reads the version from `build.zig.zon` via `@import`)

### 3. Review and update README.md

Ensure the README accurately reflects the current state of the project:
- New commands or features are documented
- Removed or renamed features are cleaned up
- Installation instructions are current
- Examples and usage sections match the actual CLI interface

### 4. Update CHANGELOG.md

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/):
- Add a new `## [X.Y.Z] - YYYY-MM-DD` section below `## [Unreleased]` (or below the header if no Unreleased section exists)
- Categorize changes under: Added, Changed, Deprecated, Removed, Fixed, Security
- Add a link reference at the bottom: `[X.Y.Z]: https://github.com/trycog/cog-cli/releases/tag/vX.Y.Z`
- Each entry should be a concise, user-facing description (not a commit message)

### 5. Commit, tag, and push

```sh
git add build.zig.zon README.md CHANGELOG.md
git commit -m "Release X.Y.Z"
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

The GitHub Actions release workflow handles the rest: building binaries, creating the GitHub Release, and updating the Homebrew tap.

## CLI Design Language

The Cog CLI has a distinctive visual identity. All terminal output follows these conventions.

### Brand

- **Logo**: "COG" spelled with Unicode box-drawing characters (┌ ┐ └ ┘ ─ │) — see `tui.header()`
- **Tagline**: "Memory for AI agents" in dim text below the logo
- **Primary color**: Cyan (`\x1B[36m`) — the brand accent, used for the logo, section headers, interactive glyphs, and structural elements

### Visual Hierarchy (3 levels)

1. **Bold** (`\x1B[1m`) — primary content: command names, selected items, key labels

<cog>
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
</cog>
