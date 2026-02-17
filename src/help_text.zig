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
    ++ "  Interactive setup for the current directory. Verifies your API\n"
    ++ "  key, lets you select or create a brain, writes .cog/settings.json,\n"
    ++ "  and installs the agent skill.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog init " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--host" ++ reset ++ " HOST             " ++ dim ++ "Server hostname (default: trycog.ai)" ++ reset ++ "\n"
    ++ "\n"
;

pub const update_cmd =
    bold ++ "  cog update" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Fetch the latest system prompt and agent skill. Updates\n"
    ++ "  CLAUDE.md/AGENTS.md and the installed SKILL.md.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog update " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--host" ++ reset ++ " HOST             " ++ dim ++ "Server hostname (default: trycog.ai)" ++ reset ++ "\n"
    ++ "\n"
;

// ── Read ────────────────────────────────────────────────────────────────

pub const recall =
    bold ++ "  cog mem/recall" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Search memory using spreading activation. Returns seed matches\n"
    ++ "  and connected concepts discovered through the knowledge graph.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/recall <query> " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--limit" ++ reset ++ " N                " ++ dim ++ "Max seed results (default: 5)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--predicate-filter" ++ reset ++ " P     " ++ dim ++ "Only include these predicates (repeatable)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--exclude-predicate" ++ reset ++ " P    " ++ dim ++ "Exclude these predicates (repeatable)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--created-after" ++ reset ++ " DATE     " ++ dim ++ "Filter by creation date (ISO 8601)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--created-before" ++ reset ++ " DATE    " ++ dim ++ "Filter by creation date (ISO 8601)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--no-strengthen" ++ reset ++ "           " ++ dim ++ "Don't strengthen retrieved synapses" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog mem/recall \"authentication session lifecycle\"\n"
    ++ "    cog mem/recall \"token refresh\" --limit 3 --no-strengthen\n"
    ++ "\n"
;

pub const get =
    bold ++ "  cog mem/get" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Retrieve a specific engram by its UUID. Returns the term,\n"
    ++ "  definition, memory type, and metadata.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/get <engram-id>\n"
    ++ "\n"
;

pub const connections =
    bold ++ "  cog mem/connections" ++ reset ++ "\n"
    ++ "\n"
    ++ "  List all synaptic connections from a specific engram. Shows\n"
    ++ "  connected concepts and their relationship types.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/connections <engram-id> " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--direction" ++ reset ++ " DIR          " ++ dim ++ "incoming, outgoing, or both (default: both)" ++ reset ++ "\n"
    ++ "\n"
;

pub const trace =
    bold ++ "  cog mem/trace" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Find the shortest reasoning path between two concepts in the\n"
    ++ "  knowledge graph. Returns the chain of engrams and synapses\n"
    ++ "  connecting them.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/trace <from-id> <to-id>\n"
    ++ "\n"
;

pub const bulk_recall =
    bold ++ "  cog mem/bulk-recall" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Search with multiple independent queries in one call. More\n"
    ++ "  efficient than separate recall calls.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/bulk-recall <query1> <query2> ... " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--limit" ++ reset ++ " N                " ++ dim ++ "Max seeds per query (default: 3)" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog mem/bulk-recall \"auth tokens\" \"session management\"\n"
    ++ "    cog mem/bulk-recall \"API design\" \"error handling\" --limit 5\n"
    ++ "\n"
;

pub const list_short_term =
    bold ++ "  cog mem/list-short-term" ++ reset ++ "\n"
    ++ "\n"
    ++ "  List short-term memories pending consolidation. Short-term\n"
    ++ "  memories decay within 24 hours unless reinforced.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/list-short-term " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--limit" ++ reset ++ " N                " ++ dim ++ "Max results (default: 20)" ++ reset ++ "\n"
    ++ "\n"
;

pub const stale =
    bold ++ "  cog mem/stale" ++ reset ++ "\n"
    ++ "\n"
    ++ "  List synapses approaching or exceeding staleness thresholds.\n"
    ++ "  Stale synapses may represent outdated knowledge.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/stale " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--level" ++ reset ++ " LEVEL            " ++ dim ++ "warning (3+ mo), critical (6+), deprecated (12+), all" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--limit" ++ reset ++ " N                " ++ dim ++ "Max results (default: 20)" ++ reset ++ "\n"
    ++ "\n"
;

pub const stats =
    bold ++ "  cog mem/stats" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Get brain statistics including total engram and synapse counts.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/stats\n"
    ++ "\n"
;

pub const orphans =
    bold ++ "  cog mem/orphans" ++ reset ++ "\n"
    ++ "\n"
    ++ "  List engrams with no connections. Orphaned concepts don't\n"
    ++ "  surface during spreading activation recall.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/orphans " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--limit" ++ reset ++ " N                " ++ dim ++ "Max results (default: 50)" ++ reset ++ "\n"
    ++ "\n"
;

pub const connectivity =
    bold ++ "  cog mem/connectivity" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Analyze graph connectivity. Returns main cluster size,\n"
    ++ "  disconnected clusters, and isolated engrams.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/connectivity\n"
    ++ "\n"
;

pub const list_terms =
    bold ++ "  cog mem/list-terms" ++ reset ++ "\n"
    ++ "\n"
    ++ "  List all engram terms in the brain.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/list-terms " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--limit" ++ reset ++ " N                " ++ dim ++ "Max results (default: 500)" ++ reset ++ "\n"
    ++ "\n"
;

// ── Write ───────────────────────────────────────────────────────────────

pub const learn =
    bold ++ "  cog mem/learn" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Store a new concept as short-term memory. Short-term memories\n"
    ++ "  decay within 24 hours unless reinforced with cog mem/reinforce.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/learn --term TERM --definition DEF " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--term" ++ reset ++ " TERM             " ++ dim ++ "Concept name (required)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--definition" ++ reset ++ " DEF        " ++ dim ++ "Your understanding (required)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--long-term" ++ reset ++ "              " ++ dim ++ "Store as permanent long-term memory" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--associate" ++ reset ++ " ASSOC        " ++ dim ++ "Link to concept (repeatable)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--chain" ++ reset ++ " CHAIN            " ++ dim ++ "Create reasoning chain (repeatable)" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog mem/learn --term \"Rate Limiting\" --definition \"Token bucket for throttling\"\n"
    ++ "    cog mem/learn --term \"Auth\" --definition \"OAuth2 with PKCE\" --long-term\n"
    ++ "    cog mem/learn --term \"API Gateway\" --definition \"Entry point\" \\\n"
    ++ "      --associate \"target:Rate Limiting,predicate:contains\"\n"
    ++ "\n"
;

pub const associate =
    bold ++ "  cog mem/associate" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Create a typed link between two concepts. Terms are matched\n"
    ++ "  semantically \xe2\x80\x94 exact spelling is not required.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/associate --source TERM --target TERM " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--source" ++ reset ++ " TERM            " ++ dim ++ "Source concept (required)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--target" ++ reset ++ " TERM            " ++ dim ++ "Target concept (required)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--predicate" ++ reset ++ " TYPE         " ++ dim ++ "Relationship type (e.g. requires, enables)" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog mem/associate --source \"Auth\" --target \"JWT\" --predicate requires\n"
    ++ "\n"
;

pub const bulk_learn =
    bold ++ "  cog mem/bulk-learn" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Store multiple concepts in one batch. Deduplicates at >=90%\n"
    ++ "  similarity.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/bulk-learn --item ITEM " ++ dim ++ "[--item ITEM ...] [options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--item" ++ reset ++ " ITEM             " ++ dim ++ "Concept to store (repeatable, required)" ++ reset ++ "\n"
    ++ "                              " ++ dim ++ "Format: term:Name,definition:Description" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--memory" ++ reset ++ " TYPE           " ++ dim ++ "short or long (default: long)" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog mem/bulk-learn --item \"term:Redis,definition:In-memory cache\" \\\n"
    ++ "                       --item \"term:Postgres,definition:Relational DB\"\n"
    ++ "\n"
;

pub const bulk_associate =
    bold ++ "  cog mem/bulk-associate" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Create multiple associations in one batch. Terms are matched\n"
    ++ "  semantically.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/bulk-associate --link LINK " ++ dim ++ "[--link LINK ...]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--link" ++ reset ++ " LINK             " ++ dim ++ "Association to create (repeatable, required)" ++ reset ++ "\n"
    ++ "                              " ++ dim ++ "Format: source:Term,target:Term,predicate:type" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog mem/bulk-associate --link \"source:Redis,target:API,predicate:enables\"\n"
    ++ "\n"
;

pub const update =
    bold ++ "  cog mem/update" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Update an existing engram's term or definition by UUID.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/update <engram-id> " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--term" ++ reset ++ " TERM             " ++ dim ++ "New term" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--definition" ++ reset ++ " DEF        " ++ dim ++ "New definition" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog mem/update 550e8400... --definition \"Updated description\"\n"
    ++ "\n"
;

pub const unlink =
    bold ++ "  cog mem/unlink" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Remove a synapse between two concepts by its UUID.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/unlink <synapse-id>\n"
    ++ "\n"
;

pub const refactor =
    bold ++ "  cog mem/refactor" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Update a concept's definition by term lookup. Finds the engram\n"
    ++ "  semantically, updates the definition, and re-embeds. All\n"
    ++ "  existing synapses are preserved.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/refactor --term TERM --definition DEF\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--term" ++ reset ++ " TERM             " ++ dim ++ "Concept to find (required, semantically matched)" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--definition" ++ reset ++ " DEF        " ++ dim ++ "New definition (required)" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog mem/refactor --term \"Rate Limiting\" --definition \"Updated algorithm\"\n"
    ++ "\n"
;

pub const deprecate =
    bold ++ "  cog mem/deprecate" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Mark a concept as no longer existing. Severs all synapses and\n"
    ++ "  converts to short-term with ~4 hour TTL.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/deprecate --term TERM\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--term" ++ reset ++ " TERM             " ++ dim ++ "Concept to deprecate (required, semantically matched)" ++ reset ++ "\n"
    ++ "\n"
;

pub const reinforce =
    bold ++ "  cog mem/reinforce" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Convert a short-term memory to long-term (memory consolidation).\n"
    ++ "  Connected synapses also convert when both endpoints are long-term.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/reinforce <engram-id>\n"
    ++ "\n"
;

pub const flush =
    bold ++ "  cog mem/flush" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Delete a short-term memory immediately. Only works on\n"
    ++ "  short-term memories.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/flush <engram-id>\n"
    ++ "\n"
;

pub const verify =
    bold ++ "  cog mem/verify" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Confirm a synapse is still accurate. Resets the staleness\n"
    ++ "  timer and increases the confidence score.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/verify <synapse-id>\n"
    ++ "\n"
;

pub const meld =
    bold ++ "  cog mem/meld" ++ reset ++ "\n"
    ++ "\n"
    ++ "  Create a cross-brain connection for knowledge traversal during\n"
    ++ "  recall. Connected brains are queried when the search is\n"
    ++ "  relevant to the meld description.\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog mem/meld --target BRAIN " ++ dim ++ "[options]" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Options" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--target" ++ reset ++ " BRAIN           " ++ dim ++ "Brain reference (required)" ++ reset ++ "\n"
    ++ "                              " ++ dim ++ "Formats: brain, user/brain, user:brain" ++ reset ++ "\n"
    ++ "    " ++ bold ++ "--description" ++ reset ++ " TEXT       " ++ dim ++ "Gates when meld is traversed during recall" ++ reset ++ "\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
    ++ "    cog mem/meld --target \"other-brain\" --description \"Shared architecture\"\n"
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
    ++ "  dispatches debug tool calls from CLI commands (debug/send_*).\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Usage" ++ reset ++ "\n"
    ++ "    cog debug/serve\n"
    ++ "\n"
    ++ cyan ++ bold ++ "  Transport" ++ reset ++ "\n"
    ++ "    Unix domain socket at /tmp/cog-debug-<uid>.sock.\n"
    ++ "    Auto-started by debug/send_* commands when not running.\n"
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
