const memoryRecallTools = new Set([
  "cog_mem_recall",
  "cog_mem_bulk_recall",
  "cog_mem_connections",
  "cog_mem_trace",
  "cog_mem_get",
])

const memoryWriteTools = new Set([
  "cog_mem_learn",
  "cog_mem_associate",
  "cog_mem_refactor",
  "cog_mem_update",
  "cog_mem_deprecate",
  "cog_mem_bulk_learn",
  "cog_mem_bulk_associate",
])

const memoryConsolidationTools = new Set([
  "cog_mem_list_short_term",
  "cog_mem_reinforce",
  "cog_mem_flush",
  "cog_mem_stale",
  "cog_mem_verify",
])

const orientationTools = new Set(["read", "list"])
const deepExplorationTools = new Set([
  "cog_code_explore",
  "cog_code_query",
  "glob",
  "grep",
])

const debugEvidenceTools = new Set([
  "cog_debug_inspect",
  "cog_debug_stacktrace",
  "cog_debug_scopes",
  "cog_debug_exception_info",
  "cog_debug_loaded_sources",
])

const codeEvidenceTools = new Set(["cog_code_explore", "cog_code_query"])

const sessionState = new Map()

function getState(sessionID) {
  let state = sessionState.get(sessionID)
  if (!state) {
    state = {
      didRecall: false,
      usedMemory: false,
      recallCount: 0,
      needsConsolidation: false,
      consolidationCount: 0,
      learnedCount: 0,
        awaitingUserAnswer: false,
        pendingUserFact: false,
        pendingRationale: false,
        preRecallExplorationCount: 0,
        recentSymbols: [],
        recentFiles: [],
        recentDebugSummary: "",
        lastEvidenceKind: "",
      }
    sessionState.set(sessionID, state)
  }
  return state
}

function getArgs(args) {
  return args && typeof args === "object" ? args : {}
}

function getPrompt(args) {
  return typeof args.prompt === "string" ? args.prompt : ""
}

function getSubagentType(args) {
  return typeof args.subagent_type === "string" ? args.subagent_type : ""
}

function isMemoryTask(args) {
  return getSubagentType(args) === "cog-mem"
}

function looksLikeRecallTask(args) {
  return /recall|memory search|relevant memor|brain/i.test(getPrompt(args))
}

function looksLikeConsolidationTask(args) {
  return /consolidat|short-term|reinforce|flush|validate/i.test(getPrompt(args))
}

function markRecall(state) {
  state.didRecall = true
  state.usedMemory = true
  state.recallCount += 1
}

function markDirty(state) {
  state.needsConsolidation = true
  state.usedMemory = true
}

function pushLimited(list, value, max = 5) {
  if (!value) return
  if (list.includes(value)) return
  list.push(value)
  if (list.length > max) list.shift()
}

function firstString(value) {
  return typeof value === "string" && value.length > 0 ? value : ""
}

function rememberCodeTargets(state, args) {
  if (Array.isArray(args.queries)) {
    for (const query of args.queries) {
      if (query && typeof query === "object" && typeof query.name === "string") {
        pushLimited(state.recentSymbols, query.name, 6)
      }
    }
  }

  if (typeof args.name === "string") pushLimited(state.recentSymbols, args.name, 6)
  if (typeof args.file === "string") pushLimited(state.recentFiles, args.file, 6)
}

function rememberDebugSummary(state, args) {
  const parts = [firstString(args.file), firstString(args.expression), firstString(args.program)].filter(Boolean)
  if (parts.length === 0) return
  state.recentDebugSummary = parts.join(" :: ")
}

function weakRelation(args) {
  return typeof args.relation === "string" && args.relation === "related_to"
}

function looksGenericDefinition(args) {
  if (typeof args.definition !== "string") return false
  const definition = args.definition.trim()
  if (definition.length >= 32) return false
  return !/because|why|constraint|invariant|reason|so that|workflow|architecture/i.test(definition)
}

export default async () => ({
  "tool.definition": async (input, output) => {
    if (input.toolID === "cog_mem_recall" || input.toolID === "cog_mem_bulk_recall") {
      output.description +=
        " Use before broad code exploration or deep reasoning in unfamiliar code so memory can reduce direct investigation."
      return
    }

    if (memoryWriteTools.has(input.toolID)) {
      output.description +=
        " Store newly learned or user-provided facts as short-term memory first; validate them before reinforcing to long-term memory. Do not store generic repo summaries or facts that are obvious from a quick README or file read unless they are durable workflow knowledge."
      return
    }

    if (input.toolID === "task") {
      output.description +=
        " Use the cog-mem subagent for recall before unfamiliar exploration and for consolidation before you finish when memory changed during the task."
    }
  },
  "experimental.chat.system.transform": async (input, output) => {
    if (!input.sessionID) return

    const state = getState(input.sessionID)
    output.system.push(
      "Cog memory workflow: recall before broad unfamiliar exploration or deep reasoning, store newly learned facts as short-term memories, validate short-term memories before finishing, and mention memory in the response only when cog_mem tools were actually used.",
    )

    if (!state.didRecall) {
      output.system.push(
        "Before broad code exploration or deep reasoning in unfamiliar code, call cog_mem_recall or delegate to the cog-mem subagent first. A small amount of initial orientation via read/list is acceptable, but complete recall before using cog_code_explore, cog_code_query, glob, or grep.",
      )
    }

    output.system.push(
      "Only store memory when you learn something non-obvious and durable: implementation details, workflow knowledge, user-provided facts, or discoveries that would materially save future reasoning. Avoid generic repo-summary memories.",
    )

    if (state.pendingUserFact) {
      output.system.push(
        "The user recently provided potentially important factual context. If it helps solve the task, store it as short-term memory before moving on.",
      )
    }

    if (state.pendingRationale) {
      output.system.push(
        "Recent context suggests a design reason or invariant. If you write memory, include the rationale or constraint instead of only the surface fact.",
      )
    }

    if (state.recentSymbols.length > 0 || state.recentFiles.length > 0) {
      output.system.push(
        `Recent Cog evidence: symbols=${state.recentSymbols.join(", ") || "none"}; files=${state.recentFiles.join(", ") || "none"}. If you store memory from this work, keep the provenance anchored to that evidence.`,
      )
    }

    if (state.recentDebugSummary) {
      output.system.push(
        `Recent debug evidence: ${state.recentDebugSummary}. If this reveals a durable bug pattern or invariant, preserve the trigger and why it matters.`,
      )
    }

    if (state.needsConsolidation) {
      output.system.push(
        "This session created or updated memory. Before you finish, validate short-term memories and reinforce or flush them, preferably via the cog-mem subagent.",
      )
    }

    if (state.usedMemory) {
      output.system.push(
        "At the end of the task, mention Cog memory only because this session directly used cog_mem tools. If no cog_mem tools or cog-mem subagent were used, omit any memory note entirely.",
      )
    }
  },
  "chat.message": async (input) => {
    const state = getState(input.sessionID)
    if (state.awaitingUserAnswer) {
      state.awaitingUserAnswer = false
      state.pendingUserFact = true
      state.pendingRationale = true
    }
  },
  "tool.execute.before": async (input, output) => {
    const state = getState(input.sessionID)

    if (!state.didRecall && deepExplorationTools.has(input.tool)) {
      throw new Error(
        "Cog memory workflow: complete memory recall before broad exploration. Call cog_mem_recall, cog_mem_bulk_recall, or delegate to the cog-mem subagent before using cog_code_explore, cog_code_query, glob, or grep.",
      )
    }

    if (!state.didRecall && orientationTools.has(input.tool)) {
      if (state.preRecallExplorationCount >= 1) {
        throw new Error(
          "Cog memory workflow: use memory before continuing exploration. One initial orientation step is allowed, but after that call cog_mem_recall, cog_mem_bulk_recall, or delegate to the cog-mem subagent before exploring further.",
        )
      }
    }

    if (input.tool === "task") {
      const args = getArgs(output.args)
      if (!state.didRecall && !isMemoryTask(args)) {
        throw new Error(
          "Cog memory workflow: recall before delegating broader work. Use cog_mem_recall directly or call the cog-mem subagent first.",
        )
      }
    }

    if (memoryWriteTools.has(input.tool)) {
      const args = getArgs(output.args)
      if (looksGenericDefinition(args)) {
        output.metadata = output.metadata || {}
      }
      if (looksGenericDefinition(args) || weakRelation(args) || (state.pendingRationale && !/because|why|constraint|invariant|reason|workflow|architecture/i.test(String(args.definition || "")))) {
        output.system = output.system || []
        output.system.push(
          "Cog memory quality: this write looks thin. Prefer durable wording with rationale, constraints, stronger predicates, and provenance from the recent code/debug evidence.",
        )
      }
    }
  },
  "tool.execute.after": async (input) => {
    const state = getState(input.sessionID)
    const args = getArgs(input.args)

    if (memoryRecallTools.has(input.tool)) {
      markRecall(state)
      state.preRecallExplorationCount = 0
      return
    }

    if (memoryWriteTools.has(input.tool)) {
      state.learnedCount += 1
      state.pendingUserFact = false
      state.pendingRationale = false
      markDirty(state)
      return
    }

    if (memoryConsolidationTools.has(input.tool)) {
      state.needsConsolidation = false
      state.consolidationCount += 1
      state.usedMemory = true
      return
    }

    if (input.tool === "question") {
      state.awaitingUserAnswer = true
      return
    }

    if (!state.didRecall && orientationTools.has(input.tool)) {
      state.preRecallExplorationCount += 1
      return
    }

    if (codeEvidenceTools.has(input.tool)) {
      rememberCodeTargets(state, args)
      state.lastEvidenceKind = "code"
      return
    }

    if (debugEvidenceTools.has(input.tool)) {
      rememberDebugSummary(state, args)
      state.pendingRationale = true
      state.lastEvidenceKind = "debug"
      return
    }

    if (input.tool === "cog_debug_launch") {
      rememberDebugSummary(state, args)
      state.lastEvidenceKind = "debug"
      return
    }

    if (input.tool === "task" && isMemoryTask(args)) {
      markRecall(state)
      state.preRecallExplorationCount = 0
      if (looksLikeConsolidationTask(args) || state.needsConsolidation) {
        state.needsConsolidation = false
        state.consolidationCount += 1
      }
      if (looksLikeRecallTask(args)) {
        state.pendingUserFact = false
      }
      state.usedMemory = true
    }
  },
})
