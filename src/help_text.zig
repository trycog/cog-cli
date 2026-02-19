// Styled help text for each command — matches the CLI design language.
// All output goes to stderr via printCommandHelp().

const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Setup ───────────────────────────────────────────────────────────────

pub const init =
    bold ++ "  cog init" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Interactive setup for the current directory. Optionally configures\n"
    ++ "  memory, then sets up system prompts, MCP server, and hooks\n"
    ++ "  for your selected AI coding agents.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog init " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--host" ++ reset ++ " HOST             " ++ dim ++ "Server hostname (default: trycog.ai)" ++ reset ++ "\n"
    ++ "\n"
;

// ── Code Intelligence ──────────────────────────────────────────────────

pub const code_index =
    bold ++ "  cog code/index" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Build a SCIP code index. Expands a glob pattern to match files,\n"
    ++ "  resolves each to a language extension, invokes the indexer\n"
    ++ "  per-file, and merges results into .cog/index.scip.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog code/index " ++ dim ++ "[pattern]" ++ reset ++ "\n"
    ++ "\n"
    ++ "  " ++ dim ++ "pattern" ++ reset ++ " defaults to " ++ bold ++ "**/*" ++ reset ++ " (all files, recursive).\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Glob syntax" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "*" ++ reset ++ "                    " ++ dim ++ "Any characters except /" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "**" ++ reset ++ "                   " ++ dim ++ "Any path segments (recursive descent)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "?" ++ reset ++ "                    " ++ dim ++ "Any single character except /" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog code/index                " ++ dim ++ "Index everything (default **/*)" ++ reset ++ "\n"
    ++ "    cog code/index src/main.ts    " ++ dim ++ "Index a single file" ++ reset ++ "\n"
    ++ "    cog code/index \"**/*.ts\"       " ++ dim ++ "All .ts files recursively" ++ reset ++ "\n"
    ++ "    cog code/index \"src/**/*.go\"   " ++ dim ++ "All .go files under src/" ++ reset ++ "\n"
    ++ "    cog code/index \"*.py\"          " ++ dim ++ ".py files in current dir only" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Built-in extensions" ++ reset ++ "\n"
    ++ "    scip-go              " ++ dim ++ ".go" ++ reset ++ "\n"
    ++ "    scip-typescript      " ++ dim ++ ".ts .tsx .js .jsx" ++ reset ++ "\n"
    ++ "    scip-python          " ++ dim ++ ".py" ++ reset ++ "\n"
    ++ "    scip-java            " ++ dim ++ ".java" ++ reset ++ "\n"
    ++ "    rust-analyzer        " ++ dim ++ ".rs" ++ reset ++ "\n"
    ++ "\n"
    ++ "  " ++ dim ++ "Installed extensions (~/.config/cog/extensions/) override built-ins." ++ reset ++ "\n"
    ++ "\n"
;

pub const code_query =
    bold ++ "  cog code/query" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Unified code query command. Specify exactly one query mode.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog code/query --find <name> " ++ dim ++ "[--kind KIND] [--limit N]" ++ reset ++ "\n"
    ++ "    cog code/query --refs <name> " ++ dim ++ "[--kind KIND] [--limit N]" ++ reset ++ "\n"
    ++ "    cog code/query --symbols <file> " ++ dim ++ "[--kind KIND]" ++ reset ++ "\n"
    ++ "    cog code/query --structure\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Modes" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--find" ++ reset ++ " NAME            " ++ dim ++ "Find symbol definitions by name (ranked by relevance)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--refs" ++ reset ++ " NAME            " ++ dim ++ "Find all references to a symbol" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--symbols" ++ reset ++ " FILE         " ++ dim ++ "List symbols defined in a file" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--structure" ++ reset ++ "             " ++ dim ++ "Project structure overview" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--kind" ++ reset ++ " KIND             " ++ dim ++ "Filter by symbol kind (function, struct, method, type, etc.)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--limit" ++ reset ++ " N               " ++ dim ++ "Max results for --find/--refs (default: 1 for find, 100 for refs)" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog code/query --find Server --kind struct\n"
    ++ "    cog code/query --find Component --limit 10\n"
    ++ "    cog code/query --refs Config --limit 20\n"
    ++ "    cog code/query --symbols src/main.zig\n"
    ++ "    cog code/query --structure\n"
    ++ "\n"
;

pub const code_create =
    bold ++ "  cog code/create" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Create a new file and add it to the SCIP index.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog code/create <file> " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--content" ++ reset ++ " TEXT          " ++ dim ++ "Initial file content" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog code/create src/new.zig --content \"const std = @import(\\\"std\\\");\"\n"
    ++ "\n"
    ++ dim ++ "  Uses .cog/settings.json creator config if present, otherwise\n"
    ++ "  built-in file creation." ++ reset ++ "\n"
    ++ "\n"
;

pub const code_delete =
    bold ++ "  cog code/delete" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Delete a file and remove it from the SCIP index.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog code/delete <file>\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog code/delete src/old.zig\n"
    ++ "\n"
    ++ dim ++ "  Uses .cog/settings.json deleter config if present, otherwise\n"
    ++ "  built-in file deletion." ++ reset ++ "\n"
    ++ "\n"
;

pub const code_rename =
    bold ++ "  cog code/rename" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Rename a file and update the SCIP index.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog code/rename <old-path> --to <new-path>\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--to" ++ reset ++ " PATH              " ++ dim ++ "New file path (required)" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog code/rename src/old.zig --to src/new.zig\n"
    ++ "\n"
    ++ dim ++ "  Uses .cog/settings.json renamer config if present, otherwise\n"
    ++ "  built-in rename." ++ reset ++ "\n"
    ++ "\n"
;

// ── Debug ─────────────────────────────────────────────────────────────

pub const debug_serve =
    bold ++ "  cog debug/serve" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Start the debug daemon. Listens on a Unix domain socket and\n"
    ++ "  dispatches debug tool calls from debug/send.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog debug/serve\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Transport" ++ reset ++ "\n"
    ++ "    Unix domain socket at /tmp/cog-debug-<uid>.sock.\n"
    ++ "    Auto-started by debug/send commands when not running.\n"
    ++ "\n"
;

pub const debug_dashboard =
    bold ++ "  cog debug/dashboard" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Live debug session dashboard. Runs in a separate terminal and\n"
    ++ "  shows real-time state from running debug servers.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog debug/dashboard\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Key Bindings" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "q" ++ reset ++ " / " ++ bold ++ "Ctrl+C" ++ reset ++ "            " ++ dim ++ "Quit" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "Up" ++ reset ++ " / " ++ bold ++ "Down" ++ reset ++ "              " ++ dim ++ "Switch focused session" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "Tab" ++ reset ++ "                   " ++ dim ++ "Cycle focus forward" ++ reset ++ "\n"
    ++ "\n"
    ++ dim ++ "  Communicates with the debug daemon via a Unix domain socket.\n"
    ++ "  Multiple servers can push events to the same dashboard." ++ reset ++ "\n"
    ++ "\n"
;

pub const debug_sign =
    bold ++ "  cog debug/sign" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Code-sign the cog binary with macOS debug entitlements.\n"
    ++ "  Required for the debug server to attach to processes via\n"
    ++ "  task_for_pid. No-op on Linux.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog debug/sign\n"
    ++ "\n"
    ++ dim ++ "  Called automatically by Homebrew on install and upgrade.\n"
    ++ "  Run manually after building from source." ++ reset ++ "\n"
    ++ "\n"
;

pub const debug_status =
    bold ++ "  cog debug/status" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Check the status of the debug daemon. Reports whether the\n"
    ++ "  daemon is running and lists active sessions.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog debug/status\n"
    ++ "\n"
;

pub const debug_kill =
    bold ++ "  cog debug/kill" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Stop the debug daemon. Sends SIGTERM to the daemon process\n"
    ++ "  and cleans up the socket and PID files.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog debug/kill\n"
    ++ "\n"
;

// ── Extensions ────────────────────────────────────────────────────────

pub const install =
    bold ++ "  cog install" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Install a language extension from a git repository. Clones the\n"
    ++ "  repo, reads cog-extension.json, runs the build command, and\n"
    ++ "  verifies the binary.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog install <git-url>\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Manifest" ++ reset ++ dim ++ "  (cog-extension.json in repo root)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "name" ++ reset ++ "         " ++ dim ++ "Extension name (also the binary name)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "extensions" ++ reset ++ "   " ++ dim ++ "File extensions this indexer handles" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "build" ++ reset ++ "        " ++ dim ++ "Shell command to build the indexer" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "args" ++ reset ++ "         " ++ dim ++ "Args template with {file} and {output} placeholders" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog install https://github.com/example/scip-zig.git\n"
    ++ "\n"
    ++ dim ++ "  Extensions are installed to ~/.config/cog/extensions/<name>/.\n"
    ++ "  Installed extensions override built-in indexers for shared file\n"
    ++ "  extensions." ++ reset ++ "\n"
    ++ "\n"
;

pub const code_edit =
    bold ++ "  cog code/edit" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Edit a file using string replacement and re-index. Finds the\n"
    ++ "  exact old text, replaces with new text, then rebuilds the SCIP\n"
    ++ "  index to keep code intelligence current.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog code/edit <file> --old OLD --new NEW\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--old" ++ reset ++ " TEXT             " ++ dim ++ "Exact text to find (must be unique in file)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--new" ++ reset ++ " TEXT             " ++ dim ++ "Replacement text" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog code/edit src/main.zig --old \"fn old()\" --new \"fn new()\"\n"
    ++ "\n"
    ++ dim ++ "  Uses .cog/settings.json editor config if present, otherwise\n"
    ++ "  built-in string replacement." ++ reset ++ "\n"
    ++ "\n"
;

pub const code_status =
    bold ++ "  cog code/status" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Report the status of the SCIP code index. Shows whether an\n"
    ++ "  index exists, document/symbol counts, and indexer info.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog code/status\n"
    ++ "\n"
;
