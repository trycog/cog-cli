---
name: setup-cog
description: Install and configure Cog — persistent memory, SCIP code intelligence, and an interactive debugger for AI coding agents, delivered as a local MCP server. Use when the user wants to install Cog, set up cog-cli, add agent memory, speed up code exploration, or enable agent debugging in a project.
license: MIT
compatibility: Requires a POSIX shell; macOS (Homebrew) or Linux. Windows support is limited.
metadata:
  author: trycog
---

# Set Up Cog

Cog gives this agent three capabilities through one native MCP server: persistent memory that carries across sessions, structured code intelligence that answers symbol and architecture questions in one tool call instead of many rounds of grep, and an interactive debugger with breakpoints and variable inspection.

## Steps

1. **Check whether Cog is already installed:**

   ```sh
   cog --version
   ```

   If it prints a version, skip to step 3.

2. **Install the binary.**

   macOS:

   ```sh
   brew install trycog/tap/cog
   ```

   Linux:

   ```sh
   curl -fsSL https://trycog.ai/cli/install | bash
   ```

3. **Initialize the project.** `cog init` is interactive (memory backend, agent selection, tool permissions), so ask the user to run it in their terminal rather than running it yourself:

   ```sh
   cog init
   ```

   It configures the MCP server, writes the Cog prompt for each selected agent, and installs the Cog specialist skills into this project.

4. **Verify the installation:**

   ```sh
   cog doctor
   ```

   All checks should pass; the report also says whether the code index is in sync and whether a newer Cog version is available.

5. **Build the code index** if `cog doctor` reports it missing:

   ```sh
   cog code:index "**/*.<ext>"
   ```

   Replace `<ext>` with the project's main source extensions, or set patterns under `code.index` in `.cog/settings.json`.

## After setup

Restart the coding agent so it picks up the MCP server and the installed skills. Keeping assets current later is one command: `cog doctor` reports drift, and re-running `cog init` refreshes generated files.

## Common issues

- **Agent cannot see cog tools**: the MCP server entry lives in the agent's project config (for example `.mcp.json` or `.cursor/mcp.json`); restart the agent after `cog init`.
- **Index answers look stale**: run `cog code:sync` — Cog also reconciles automatically at MCP startup and on git branch changes.
- **Hosted memory**: a hosted brain on trycog.ai needs `COG_API_KEY` exported; self-hosted origins require explicit approval during `cog init` or via `cog doctor --approve-host`.
