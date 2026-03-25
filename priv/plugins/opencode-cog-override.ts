const blockedFallbackTools = new Set(["grep"])
const architectureModes = new Set(["overview", "imports", "contains", "calls", "callers"])
const cogCodeTools = new Set(["cog_code_explore", "cog_code_query"])
const sessionState = new Map()
const shellSearchPattern = /(^|\W)(git\s+grep|rg|grep|find)(\W|$)/i

function getState(sessionID) {
  let state = sessionState.get(sessionID)
  if (!state) {
    state = {
      sawRepoExplore: false,
      hasCogTools: false,
      fileArchitectureQueries: [],
    }
    sessionState.set(sessionID, state)
  }
  return state
}

function getArgs(args) {
  return args && typeof args === "object" ? args : {}
}

function getMode(args) {
  return typeof args.mode === "string" ? args.mode : ""
}

function getScope(args) {
  return typeof args.scope === "string" ? args.scope : ""
}

function getFile(args) {
  return typeof args.file === "string" ? args.file : ""
}

function isRepoExplore(tool, args) {
  return (
    tool === "cog_code_explore" &&
    args.include_architecture === true &&
    args.overview_scope === "repo"
  )
}

function isFileArchitectureQuery(tool, args) {
  return (
    tool === "cog_code_query" &&
    architectureModes.has(getMode(args)) &&
    getScope(args) === "file" &&
    getFile(args).length > 0
  )
}

function rememberFileArchitectureQuery(state, args) {
  state.fileArchitectureQueries.push({
    file: getFile(args),
    mode: getMode(args),
    at: Date.now(),
  })
  if (state.fileArchitectureQueries.length > 8) {
    state.fileArchitectureQueries.shift()
  }
}

function hasDifferentPriorFile(state, file) {
  return state.fileArchitectureQueries.some((entry) => entry.file !== file)
}

function eventText(value) {
  try {
    return JSON.stringify(value)
  } catch {
    return ""
  }
}

function isBlockedShellSearch(tool, args) {
  if (tool !== "bash") return false
  return shellSearchPattern.test(eventText(args))
}

export default async () => ({
  "tool.definition": async (input, output) => {
    if (blockedFallbackTools.has(input.toolID)) {
      output.description =
        "Fallback only. Use cog_code_explore and cog_code_query for code exploration."
      return
    }

    if (input.toolID === "cog_code_explore") {
      output.description +=
        " Batch all candidate symbols or files in one call whenever possible. For repository summaries, start with one batched repo explore."
      return
    }

    if (input.toolID === "cog_code_query") {
      output.description +=
        " Targeted follow-up only. Repeated file-scoped architecture queries across multiple files may be rejected; batch with cog_code_explore instead."
    }
  },
  "experimental.chat.system.transform": async (_, output) => {
    output.system.push(
      "Cog batching policy: for repository-understanding tasks, make one initial batched cog_code_explore call with include_architecture=true and overview_scope=repo.",
      "Do not chain repeated file-scoped cog_code_query overview/imports/contains/calls/callers requests across multiple files. If more than one follow-up target is needed, batch it into cog_code_explore.",
      "Prefer cog_code_explore and cog_code_query for structural code exploration. Use shell search (rg, grep, find) only for raw text patterns, log messages, or string literals that the SCIP index does not cover."
    )
  },
  "tool.execute.before": async (input, output) => {
    const state = getState(input.sessionID)

    // Track cog tool access per session.
    if (cogCodeTools.has(input.tool)) {
      state.hasCogTools = true
    }

    // The grep built-in tool is always blocked — cog_code_query is a
    // direct replacement regardless of session state.
    if (blockedFallbackTools.has(input.tool)) {
      throw new Error(
        "Cog override policy: use cog_code_explore or cog_code_query. The grep tool is disabled; use Cog code intelligence instead."
      )
    }

    // Shell search (rg, grep, find, git grep) in bash is NOT hard-blocked.
    // System prompt guidance steers the model to prefer cog tools for
    // structural exploration.  Shell search remains available for raw text
    // patterns, log messages, and string literals that the SCIP index
    // doesn't cover — and for task sessions that lack MCP tool access.

    // Batching enforcement for file-scoped architecture queries
    const args = getArgs(output.args)
    if (!isFileArchitectureQuery(input.tool, args)) return

    if (state.sawRepoExplore && hasDifferentPriorFile(state, getFile(args))) {
      throw new Error(
        "Cog batching policy: repeated file-scoped architecture queries after a repo explore are not allowed. Use the initial batched result, or merge remaining targets into one cog_code_explore call."
      )
    }

    const distinctFiles = new Set(state.fileArchitectureQueries.map((entry) => entry.file))
    if (!state.sawRepoExplore && distinctFiles.size >= 2 && !distinctFiles.has(getFile(args))) {
      throw new Error(
        "Cog batching policy: repeated file-scoped architecture queries across multiple files are not allowed. Batch the remaining targets into one cog_code_explore call."
      )
    }
  },
  "tool.execute.after": async (input) => {
    const args = getArgs(input.args)
    const state = getState(input.sessionID)

    // Confirm cog tool access after successful execution
    if (cogCodeTools.has(input.tool)) {
      state.hasCogTools = true
    }

    if (isRepoExplore(input.tool, args)) {
      state.sawRepoExplore = true
      state.fileArchitectureQueries = []
      return
    }

    if (isFileArchitectureQuery(input.tool, args)) {
      rememberFileArchitectureQuery(state, args)
    }
  },
})
