---
name: cog
description: Runtime MCP reference for Cog operations
---

# Cog Tool Reference

Reference for using Cog via MCP. Behavioral policy lives in `PROMPT.md`; this document explains runtime discovery and invocation patterns.

## Runtime Discovery (Source of Truth)

Do not rely on hardcoded tool inventories in docs. Always discover capabilities from the active runtime:

1. Call `tools/list` for canonical tool names, descriptions, and full `inputSchema`.
2. Call `resources/read` for `cog://tools/catalog` when you need a stable JSON snapshot of all exposed tools.
3. Re-discover after setup changes (`cog init`, `cog update`, memory enable/disable, debug changes).

The local MCP server runs over stdio using framed messages (`Content-Length` headers) and supports standard lifecycle methods (`initialize`, `ping`, `shutdown`, `exit`).

## MCP Endpoints

- `tools/list` / `tools/call` — discover and invoke tools.
- `prompts/list` / `prompts/get` — includes `cog_reference`.
- `resources/list` / `resources/read` — structured runtime metadata:
  - `cog://index/status`
  - `cog://debug/tools`
  - `cog://tools/catalog`

## Tool Families

- `cog_code_*` — code intelligence and indexed file mutations.
- `cog_mem_*` — memory operations (only when memory is configured).
- `debug_*` — debugger daemon operations.

Treat these as prefixes, not fixed enumerations. Exact members are runtime-defined and returned by `tools/list`.

## Invocation Pattern

1. Pick a tool from `tools/list`.
2. Build arguments from that tool's `inputSchema`.
3. Call `tools/call` with `{ "name": "<tool>", "arguments": { ... } }`.
4. Parse JSON text payload from result content.

Example:

```json
{"method":"tools/list","jsonrpc":"2.0","id":1}
```

```json
{"method":"tools/call","jsonrpc":"2.0","id":2,"params":{"name":"cog_code_query","arguments":{"mode":"find","name":"processRequest"}}}
```

## Memory Availability

If `cog_mem_*` tools are absent from `tools/list`, memory is not configured for this workspace.

- Configure with `cog init` (Memory + Tools).
- Do not shell out to deprecated `cog mem/*` compatibility commands from an MCP-capable runtime.

## Predicates and Graph Semantics

For relationship predicate guidance and advanced memory modeling patterns, use `prompts/get` with `cog_reference`.

## Constraints

- Sensitive content is rejected (passwords, API keys, tokens, secrets, SSH/PGP keys, certificates, PII).
- Prefer term-based resolution for memory relationships unless UUIDs are explicitly required by schema.
- Re-check schema before calling rarely used tools; argument shapes can evolve.
