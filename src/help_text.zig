// Styled help text for each command — matches the CLI design language.
// All output goes to stderr via printCommandHelp().

const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Setup ───────────────────────────────────────────────────────────────

pub const init =
    bold ++ "  cog init" ++ reset ++ "\n" ++ "\n" ++ "  Interactive setup for the current directory. Optionally configures\n" ++ "  memory, then sets up system prompts, MCP server, and hooks\n" ++ "  for your selected AI coding agents.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog init " ++ dim ++ "[options]" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n" ++ "    " ++ bold ++ "--host" ++ reset ++ " HOST             " ++ dim ++ "Server hostname (default: trycog.ai)" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Credential approval" ++ reset ++ "\n" ++ "    Selecting a self-hosted memory origin requires explicit interactive approval\n" ++ "    before Cog reads COG_API_KEY or makes an authenticated request. Approval is\n" ++ "    saved in the global approved-origin store for later runs.\n" ++ "    " ++ dim ++ "Non-interactive setup cannot add an approval and fails closed." ++ reset ++ "\n" ++ "\n";

pub const mcp =
    bold ++ "  cog mcp" ++ reset ++ " — MCP server over stdio\n" ++ "\n" ++ bold ++ "  Usage: " ++ reset ++ "cog mcp [options]\n" ++ "\n" ++ dim ++ "  Starts a local Model Context Protocol server on stdio.\n" ++ dim ++ "  This command is intended to be launched by MCP clients.\n" ++ "\n" ++ cyan ++ bold ++ "  Transport" ++ reset ++ "\n" ++ "    Messages are newline-delimited JSON objects.\n" ++ "    The maximum inbound frame size is " ++ bold ++ "4 MiB (4,194,304 bytes)" ++ reset ++ ";\n" ++ "    oversized frames are rejected as invalid requests.\n" ++ "\n" ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n" ++ "    " ++ bold ++ "--help, -h" ++ reset ++ "            " ++ dim ++ "Show this help message\n" ++ reset ++ "    " ++ bold ++ "--debug-tools=TIER" ++ reset ++ "    " ++ dim ++ "Limit exposed debug tools (core, extended, all)\n" ++ "                              core: 7 essential tools (launch, breakpoint, run, inspect, stacktrace, stop, sessions)\n" ++ "                              extended: core + threads, attach, set_variable, watchpoint, exception_info, restart\n" ++ "                              all: all 36 debug tools (default)" ++ reset ++ "\n" ++ "\n";

pub const doctor =
    bold ++ "  cog doctor" ++ reset ++ "\n" ++ "\n" ++ "  Run diagnostics on your Cog installation. Checks config,\n" ++ "  memory backend, code index, extensions, and agent integration.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog doctor " ++ dim ++ "[options]" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n" ++ "    " ++ bold ++ "--approve-host" ++ reset ++ " ORIGIN " ++ dim ++ "Approve one HTTPS origin as a credential destination" ++ reset ++ "\n" ++ "    " ++ bold ++ "--help, -h" ++ reset ++ "            " ++ dim ++ "Show this help message" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Checks" ++ reset ++ "\n" ++ "    " ++ bold ++ "Config" ++ reset ++ "                " ++ dim ++ ".cog/ directory and settings.json validity" ++ reset ++ "\n" ++ "    " ++ bold ++ "Memory" ++ reset ++ "                " ++ dim ++ "Brain type, connectivity, engram/synapse counts" ++ reset ++ "\n" ++ "    " ++ bold ++ "Code Intelligence" ++ reset ++ "     " ++ dim ++ "SCIP index availability, file count, size" ++ reset ++ "\n" ++ "    " ++ bold ++ "Extensions" ++ reset ++ "            " ++ dim ++ "Installed language extensions" ++ reset ++ "\n" ++ "    " ++ bold ++ "Agent Integration" ++ reset ++ "      " ++ dim ++ "Configured agents and installed assets" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Credential approval" ++ reset ++ "\n" ++ "    Cog sends " ++ bold ++ "COG_API_KEY" ++ reset ++ " only to the official https://trycog.ai:443\n" ++ "    origin, or to an exact HTTPS origin you approved yourself.\n" ++ "    Approvals are stored globally in " ++ dim ++ "~/.config/cog/approved-origins.json" ++ reset ++ "\n" ++ "    (mode 0600). Repository settings can select a self-hosted brain but\n" ++ "    can never authorize sending credentials to it.\n" ++ "\n" ++ "    " ++ dim ++ "Requires an interactive terminal and an explicit confirmation." ++ reset ++ "\n" ++ "    " ++ dim ++ "Give one exact origin: scheme, host, and optional port only." ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n" ++ "    cog doctor                                  " ++ dim ++ "Run all checks" ++ reset ++ "\n" ++ "    cog doctor --approve-host https://memory.example:8443\n" ++ "                                                " ++ dim ++ "Approve a self-hosted origin" ++ reset ++ "\n" ++ "\n" ++ dim ++ "  Exit code 0 if all checks pass, 1 if any failures." ++ reset ++ "\n" ++ "\n";

// ── Code Intelligence ──────────────────────────────────────────────────

pub const code_index =
    bold ++ "  cog code:index" ++ reset ++ "\n" ++ "\n" ++ "  Build a SCIP code index. Expands glob patterns to match files,\n" ++ "  resolves each to a language extension, groups files by indexer,\n" ++ "  and invokes each external indexer once in bulk. The {files}\n" ++ "  placeholder expands inline to one argv entry per matched file.\n" ++ "  Prefix a glob with ! to exclude files matched by earlier include\n" ++ "  patterns. Results are merged into .cog/index.scip.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog code:index " ++ dim ++ "<pattern> [pattern...]" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Glob syntax" ++ reset ++ "\n" ++ "    " ++ bold ++ "*" ++ reset ++ "                    " ++ dim ++ "Any characters except /" ++ reset ++ "\n" ++ "    " ++ bold ++ "**" ++ reset ++ "                   " ++ dim ++ "Any path segments (recursive descent)" ++ reset ++ "\n" ++ "    " ++ bold ++ "?" ++ reset ++ "                    " ++ dim ++ "Any single character except /" ++ reset ++ "\n" ++ "    " ++ bold ++ "!pattern" ++ reset ++ "             " ++ dim ++ "Exclude files matching the pattern" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n" ++ "    cog code:index src/main.ts    " ++ dim ++ "Index a single file" ++ reset ++ "\n" ++ "    cog code:index \"**/*.ts\"       " ++ dim ++ "All .ts files recursively" ++ reset ++ "\n" ++ "    cog code:index \"apps/**/*.js\" \"!apps/**/priv/static/**\"\n" ++ "                            " ++ dim ++ "Match JS, exclude compiled Phoenix assets" ++ reset ++ "\n" ++ "    cog code:index \"*.py\"          " ++ dim ++ ".py files in current dir only" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Built-in extensions" ++ reset ++ "\n" ++ "    scip-go              " ++ dim ++ ".go" ++ reset ++ "\n" ++ "    scip-typescript      " ++ dim ++ ".ts .tsx .js .jsx" ++ reset ++ "\n" ++ "    scip-python          " ++ dim ++ ".py" ++ reset ++ "\n" ++ "    scip-java            " ++ dim ++ ".java" ++ reset ++ "\n" ++ "    rust-analyzer        " ++ dim ++ ".rs" ++ reset ++ "\n" ++ "\n" ++ "  " ++ dim ++ "Installed extensions (~/.config/cog/extensions/) override built-ins." ++ reset ++ "\n" ++ "\n";

pub const code_sync =
    bold ++ "  cog code:sync" ++ reset ++ "\n" ++ "\n" ++ "  Reconcile the SCIP index with the working tree. Compares every\n" ++ "  configured source file against the index provenance manifest and\n" ++ "  reindexes only what drifted — files changed, added, or deleted\n" ++ "  while no watcher was running (edits between sessions, branch\n" ++ "  switches, pulls, merges). Escalates to a full rebuild when most\n" ++ "  of the tree drifted or no manifest exists.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog code:sync\n" ++ "\n" ++ dim ++ "  The MCP server runs the same reconcile automatically at startup\n" ++ "  and when the git HEAD changes; this command is for scripts, git\n" ++ "  hooks, and manual recovery." ++ reset ++ "\n" ++ "\n";

test "code sync help explains reconcile triggers" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, code_sync, "provenance manifest") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_sync, "only what drifted") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_sync, "full rebuild") != null);
}

// ── Debug ─────────────────────────────────────────────────────────────

pub const debug_serve =
    bold ++ "  cog debug:serve" ++ reset ++ "\n" ++ "\n" ++ "  Start the optional debug daemon used by the status, kill, and\n" ++ "  dashboard CLI utilities. MCP debug tools run in the MCP process.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog debug:serve\n" ++ "\n" ++ cyan ++ bold ++ "  Transport" ++ reset ++ "\n" ++ "    Unix domain socket in Cog's private runtime directory.\n" ++ "    Start this command explicitly when using daemon CLI utilities.\n" ++ "\n";

test "debug serve help describes the optional private daemon" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, debug_serve, "private runtime directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug_serve, "MCP debug tools run in the MCP process") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug_serve, "debug:send") == null);
    try std.testing.expect(std.mem.indexOf(u8, debug_serve, "Auto-started") == null);
}

test "dashboard help matches implemented controls" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, debug_dashboard, "Scroll the active pane down") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug_dashboard, "Select the previous or next session") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug_dashboard, "Switch focused session") == null);
}

pub const debug_dashboard =
    bold ++ "  cog debug:dashboard" ++ reset ++ "\n" ++ "\n" ++ "  Live debug session dashboard. Runs in a separate terminal and\n" ++ "  shows real-time state from running debug servers.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog debug:dashboard\n" ++ "\n" ++ cyan ++ bold ++ "  Key Bindings" ++ reset ++ "\n" ++ "    " ++ bold ++ "q" ++ reset ++ " / " ++ bold ++ "Ctrl+C" ++ reset ++ "            " ++ dim ++ "Quit" ++ reset ++ "\n" ++ "    " ++ bold ++ "Tab" ++ reset ++ "                   " ++ dim ++ "Cycle the active pane" ++ reset ++ "\n" ++ "    " ++ bold ++ "j" ++ reset ++ " / " ++ bold ++ "Down" ++ reset ++ "              " ++ dim ++ "Scroll the active pane down" ++ reset ++ "\n" ++ "    " ++ bold ++ "k" ++ reset ++ " / " ++ bold ++ "Up" ++ reset ++ "                " ++ dim ++ "Scroll the active pane up" ++ reset ++ "\n" ++ "    " ++ bold ++ "[" ++ reset ++ " / " ++ bold ++ "]" ++ reset ++ "                 " ++ dim ++ "Select the previous or next session" ++ reset ++ "\n" ++ "\n" ++ dim ++ "  Communicates with the debug daemon via a Unix domain socket.\n" ++ "  Multiple servers can push events to the same dashboard." ++ reset ++ "\n" ++ "\n";

pub const debug_sign =
    bold ++ "  cog debug:sign" ++ reset ++ "\n" ++ "\n" ++ "  Code-sign the cog binary with macOS debug entitlements.\n" ++ "  Required for the debug server to attach to processes via\n" ++ "  task_for_pid. No-op on Linux.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog debug:sign\n" ++ "\n" ++ dim ++ "  Called automatically by Homebrew on install and upgrade.\n" ++ "  Run manually after building from source." ++ reset ++ "\n" ++ "\n";

pub const debug_status =
    bold ++ "  cog debug:status" ++ reset ++ "\n" ++ "\n" ++ "  Check the status of the debug daemon. Reports whether the\n" ++ "  daemon is running and lists active sessions.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog debug:status\n" ++ "\n";

pub const debug_kill =
    bold ++ "  cog debug:kill" ++ reset ++ "\n" ++ "\n" ++ "  Stop the debug daemon. Sends SIGTERM to the daemon process\n" ++ "  and cleans up the socket and PID files.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog debug:kill\n" ++ "\n";

// ── Memory ────────────────────────────────────────────────────────────

pub const mem_bootstrap =
    bold ++ "  cog mem:bootstrap" ++ reset ++ "\n" ++ "\n" ++ "  Populate the Cog knowledge graph from your codebase. Groups files\n" ++ "  into subsystem clusters using the SCIP dependency graph, then\n" ++ "  invokes your agent once per subsystem to extract architectural\n" ++ "  knowledge — design decisions, constraints, and cross-file patterns.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog mem:bootstrap " ++ dim ++ "[options]" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n" ++ "    " ++ bold ++ "--concurrency" ++ reset ++ " N       " ++ dim ++ "Parallel agent processes (default: 1)" ++ reset ++ "\n" ++ "    " ++ bold ++ "--timeout" ++ reset ++ " N           " ++ dim ++ "Minutes per subsystem before killing (default: 10)" ++ reset ++ "\n" ++ "    " ++ bold ++ "--clean" ++ reset ++ "                " ++ dim ++ "Reset checkpoint and start fresh" ++ reset ++ "\n" ++ "    " ++ bold ++ "--debug" ++ reset ++ "                " ++ dim ++ "Show agent stderr output" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Model override" ++ reset ++ "\n" ++ "    Set " ++ dim ++ "memory.bootstrap.model" ++ reset ++ " in .cog/settings.json to pass " ++ dim ++ "--model" ++ reset ++ "\n" ++ "    to the agent CLI (e.g. use a faster model for bulk extraction).\n" ++ "\n" ++ cyan ++ bold ++ "  Resumability" ++ reset ++ "\n" ++ "    Progress is saved to " ++ dim ++ ".cog/bootstrap-checkpoint.json" ++ reset ++ ".\n" ++ "    Re-run the command to resume from where it left off.\n" ++ "    Use " ++ dim ++ "--clean" ++ reset ++ " to discard the checkpoint and start over.\n" ++ "\n" ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n" ++ "    cog mem:bootstrap                  " ++ dim ++ "Bootstrap with defaults" ++ reset ++ "\n" ++ "    cog mem:bootstrap --concurrency 4  " ++ dim ++ "4 subsystems processed in parallel" ++ reset ++ "\n" ++ "    cog mem:bootstrap --clean           " ++ dim ++ "Start fresh" ++ reset ++ "\n" ++ "\n" ++ dim ++ "  Requires: an AI agent CLI and a SCIP index.\n" ++ "  Run " ++ reset ++ bold ++ "cog code:index" ++ reset ++ dim ++ " first." ++ reset ++ "\n" ++ "\n";

pub const mem_upgrade =
    bold ++ "  cog mem:upgrade" ++ reset ++ "\n" ++ "\n" ++ "  Migrate a local SQLite brain to hosted memory on trycog.ai.\n" ++ "  If memory is already hosted, reports the current brain URL.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog mem:upgrade " ++ dim ++ "[options]" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n" ++ "    " ++ bold ++ "--host" ++ reset ++ " HOST             " ++ dim ++ "Server hostname (default: trycog.ai)" ++ reset ++ "\n" ++ "    " ++ bold ++ "--clean" ++ reset ++ "                " ++ dim ++ "Clear migration checkpoint and start fresh" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Requirements" ++ reset ++ "\n" ++ "    COG_API_KEY must be set in your environment or .env file.\n" ++ "    The current brain must be local (file: scheme in settings).\n" ++ "\n" ++ cyan ++ bold ++ "  Resumability" ++ reset ++ "\n" ++ "    Progress is saved to " ++ dim ++ ".cog/upgrade-checkpoint.json" ++ reset ++ ".\n" ++ "    Re-run the command to resume from where it left off.\n" ++ "    Use " ++ dim ++ "--clean" ++ reset ++ " to discard the checkpoint and start over.\n" ++ "\n" ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n" ++ "    cog mem:upgrade                     " ++ dim ++ "Migrate to trycog.ai" ++ reset ++ "\n" ++ "    cog mem:upgrade --host custom.host   " ++ dim ++ "Migrate to a custom host" ++ reset ++ "\n" ++ "    cog mem:upgrade --clean              " ++ dim ++ "Clear checkpoint and restart" ++ reset ++ "\n" ++ "\n";

// ── Observe ──────────────────────────────────────────────────────────

pub const observe_status =
    bold ++ "  cog observe:status" ++ reset ++ "\n" ++ "\n" ++ "  Placeholder CLI command. Observation CLI operations are under\n" ++ "  development and this command currently reports that status only.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog observe:status\n" ++ "\n";

pub const observe_sessions =
    bold ++ "  cog observe:sessions" ++ reset ++ "\n" ++ "\n" ++ "  Placeholder CLI command. It does not currently list stored\n" ++ "  observation sessions; use the opt-in MCP tools where applicable.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog observe:sessions\n" ++ "\n";

pub const observe_query =
    bold ++ "  cog observe:query" ++ reset ++ "\n" ++ "\n" ++ "  Placeholder CLI command. It does not currently execute SQL or\n" ++ "  read an observation session database.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog observe:query\n" ++ "\n";

pub const observe_export =
    bold ++ "  cog observe:export" ++ reset ++ "\n" ++ "\n" ++ "  Placeholder CLI command. Observation export is not implemented.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog observe:export\n" ++ "\n";

pub const observe_prune =
    bold ++ "  cog observe:prune" ++ reset ++ "\n" ++ "\n" ++ "  Delete finalized observation session databases older than\n" ++ "  observe.retention_days (default: 30). Capturing, stopped, error,\n" ++ "  and unexpired finalized sessions are always preserved.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog observe:prune\n" ++ "\n";

// ── Extensions ────────────────────────────────────────────────────────

pub const ext_install =
    bold ++ "  cog ext:install" ++ reset ++ "\n" ++ "\n" ++ "  Install a language extension from a GitHub release tarball. Cog\n" ++ "  stages and validates the release before atomically promoting it.\n" ++ "  Downloaded shell build commands are blocked unless explicitly\n" ++ "  trusted for this invocation.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog ext:install <github-url> " ++ dim ++ "[--version=X.Y.Z] [--trust-build]" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n" ++ "    " ++ bold ++ "--version" ++ reset ++ "=VERSION    " ++ dim ++ "Install an exact released version" ++ reset ++ "\n" ++ "    " ++ bold ++ "--trust-build" ++ reset ++ "        " ++ dim ++ "Allow the downloaded manifest build shell command" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Manifest" ++ reset ++ dim ++ "  (cog-extension.json in repo root)" ++ reset ++ "\n" ++ "    " ++ bold ++ "name" ++ reset ++ "         " ++ dim ++ "Extension name (also the binary name)" ++ reset ++ "\n" ++ "    " ++ bold ++ "extensions" ++ reset ++ "   " ++ dim ++ "File extensions this indexer handles" ++ reset ++ "\n" ++ "    " ++ bold ++ "build" ++ reset ++ "        " ++ dim ++ "Shell command to build the indexer" ++ reset ++ "\n" ++ "    " ++ bold ++ "args" ++ reset ++ "         " ++ dim ++ "Args template with {files} and {output}" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n" ++ "    cog ext:install https://github.com/example/scip-zig.git --trust-build\n" ++ "    cog ext:install https://github.com/example/scip-zig --version=0.75.0 --trust-build\n" ++ "\n" ++ dim ++ "  Extensions are installed to ~/.config/cog/extensions/<name>/.\n" ++ "  Tag matching is exact after optional v-prefix normalization, and\n" ++ "  installed extensions override built-in indexers for shared file\n" ++ "  extensions." ++ reset ++ "\n" ++ "\n";

pub const ext_update =
    bold ++ "  cog ext:update" ++ reset ++ "\n" ++ "\n" ++ "  Update installed extensions to the latest stable GitHub release\n" ++ "  available for each extension source repository. Extensions that\n" ++ "  are already current are left unchanged.\n" ++ "\n" ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n" ++ "    cog ext:update " ++ dim ++ "[name] [--trust-build]" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n" ++ "    " ++ bold ++ "--trust-build" ++ reset ++ "        " ++ dim ++ "Allow downloaded manifest build shell commands" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n" ++ "    cog ext:update --trust-build\n" ++ "    cog ext:update cog-zig --trust-build\n" ++ "\n" ++ dim ++ "  Requires extensions installed with release metadata from\n" ++ "  cog ext:install. Legacy installs without metadata are skipped." ++ reset ++ "\n" ++ "\n";

test "observe CLI help is explicit about placeholders" {
    const std = @import("std");
    inline for (.{ observe_status, observe_sessions, observe_query, observe_export }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, text, "Placeholder CLI command") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, observe_export, "not implemented") != null);
}

test "MCP help publishes the inbound transport frame contract" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, mcp, "4 MiB (4,194,304 bytes)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp, "oversized frames are rejected") != null);
}

test "init help publishes self-hosted memory approval policy" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, init, "self-hosted memory origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, init, "interactive approval") != null);
    try std.testing.expect(std.mem.indexOf(u8, init, "Non-interactive setup cannot add an approval") != null);
}
