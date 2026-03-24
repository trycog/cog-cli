const debugTools = new Set([
  "cog_debug_launch",
  "cog_debug_breakpoint",
  "cog_debug_run",
  "cog_debug_inspect",
  "cog_debug_stop",
  "cog_debug_stacktrace",
  "cog_debug_sessions",
  "cog_debug_threads",
  "cog_debug_attach",
  "cog_debug_set_variable",
  "cog_debug_watchpoint",
  "cog_debug_exception_info",
  "cog_debug_restart",
  "cog_debug_memory",
  "cog_debug_disassemble",
  "cog_debug_scopes",
  "cog_debug_capabilities",
  "cog_debug_completions",
  "cog_debug_modules",
  "cog_debug_loaded_sources",
  "cog_debug_source",
  "cog_debug_set_expression",
  "cog_debug_restart_frame",
  "cog_debug_registers",
  "cog_debug_instruction_breakpoint",
  "cog_debug_step_in_targets",
  "cog_debug_breakpoint_locations",
  "cog_debug_cancel",
  "cog_debug_terminate_threads",
  "cog_debug_goto_targets",
  "cog_debug_find_symbol",
  "cog_debug_write_register",
  "cog_debug_variable_location",
  "cog_debug_poll_events",
  "cog_debug_load_core",
  "cog_debug_dap_request",
])

const coreDebugTools = new Set([
  "cog_debug_launch",
  "cog_debug_breakpoint",
  "cog_debug_run",
  "cog_debug_inspect",
  "cog_debug_stop",
  "cog_debug_stacktrace",
  "cog_debug_sessions",
])

const specialistDebugTools = new Set([
  "cog_debug_memory",
  "cog_debug_disassemble",
  "cog_debug_registers",
  "cog_debug_instruction_breakpoint",
  "cog_debug_find_symbol",
  "cog_debug_write_register",
  "cog_debug_variable_location",
  "cog_debug_load_core",
  "cog_debug_dap_request",
])

const codeIntelTools = new Set(["cog_code_explore", "cog_code_query"])
const evidenceTools = new Set([
  "cog_debug_inspect",
  "cog_debug_stacktrace",
  "cog_debug_exception_info",
  "cog_debug_scopes",
  "cog_debug_threads",
  "cog_debug_loaded_sources",
  "cog_debug_capabilities",
  "cog_debug_poll_events",
])

const sessionState = new Map()

function getState(sessionID) {
  let state = sessionState.get(sessionID)
  if (!state) {
    state = {
      sawCodeIntel: false,
      activeDebugSession: false,
      inspectionRequired: false,
      launchCount: 0,
      sawEvidence: false,
      sawDebugTask: false,
      sawQuestion: false,
      sawHypothesis: false,
      sawTest: false,
      lastHypothesis: "",
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

function getAction(args) {
  return typeof args.action === "string" ? args.action : ""
}

function isDebugTask(args) {
  return getSubagentType(args) === "cog-debug"
}

function parseDebugPrompt(prompt) {
  const question = /(^|\n)\s*QUESTION\s*:/i.test(prompt)
  const hypothesisMatch = prompt.match(/(^|\n)\s*HYPOTHESIS\s*:\s*(.+)/i)
  const test = /(^|\n)\s*TEST\s*:/i.test(prompt)
  return {
    hasQuestion: question,
    hasHypothesis: Boolean(hypothesisMatch),
    hypothesis: hypothesisMatch ? hypothesisMatch[2].trim() : "",
    hasTest: test,
  }
}

export default async () => ({
  "tool.definition": async (input, output) => {
    if (input.toolID === "task") {
      output.description +=
        " Use the cog-debug subagent for runtime bugs, especially when you would otherwise add print statements or temporary logging. Format debug delegations with QUESTION, HYPOTHESIS, and TEST sections."
      return
    }

    if (input.toolID === "cog_debug_launch") {
      output.description +=
        " Start only after you have a clear QUESTION, HYPOTHESIS, and TEST. Prefer one active debug session at a time and stop it when finished."
      return
    }

    if (input.toolID === "cog_debug_run") {
      output.description +=
        " After a breakpoint hit or stepping action, inspect values before continuing again. Prefer targeted evidence over blind stepping."
      return
    }

    if (specialistDebugTools.has(input.toolID)) {
      output.description +=
        " Specialist escape hatch. Prefer the core debug workflow first; use this only when launch, breakpoint, run, inspect, stacktrace, and related core tools cannot answer the question."
      return
    }

    if (coreDebugTools.has(input.toolID)) {
      output.description +=
        " Core debugger workflow tool. Prefer this tier before extended or specialist debugging operations."
    }
  },
  "experimental.chat.system.transform": async (input, output) => {
    if (!input.sessionID) return

    const state = getState(input.sessionID)
    output.system.push(
      "Cog debug workflow: use the debugger instead of print statements or temporary logging when the question is about runtime behavior.",
      "Fast-stack exception: if recompiles or hot reloads are extremely cheap and the question is a one-bit check, a quick edit-run may be cheaper than a debug session.",
      "Preferred sequence: locate code with cog_code_*, state QUESTION/HYPOTHESIS/TEST, launch one debug session, set targeted breakpoints, run, inspect evidence, report findings, and stop the session.",
    )

    if (!state.sawDebugTask) {
      output.system.push(
        "When delegating to cog-debug, structure the prompt with QUESTION:, HYPOTHESIS:, and TEST: sections.",
      )
    }

    if (state.inspectionRequired) {
      output.system.push(
        "A debug run or step produced new runtime state. Inspect values before continuing again.",
      )
    }

    if (state.activeDebugSession) {
      output.system.push(
        "A debug session is still active. Stop it before you finish your task.",
      )
    }

    if (state.launchCount >= 2) {
      output.system.push(
        "You have already launched multiple debug sessions. Do not launch another unless the hypothesis has materially changed.",
      )
    }
  },
  "tool.execute.before": async (input, output) => {
    const state = getState(input.sessionID)
    const args = getArgs(output.args)

    if (input.tool === "task" && isDebugTask(args)) {
      const parsed = parseDebugPrompt(getPrompt(args))
      if (!parsed.hasQuestion || !parsed.hasHypothesis || !parsed.hasTest) {
        throw new Error(
          "Cog debug workflow: cog-debug tasks must include QUESTION:, HYPOTHESIS:, and TEST: sections so the subagent can run a deterministic experiment.",
        )
      }
      return
    }

    if (!debugTools.has(input.tool)) return

    if (input.tool === "cog_debug_launch" && state.activeDebugSession) {
      throw new Error(
        "Cog debug workflow: only one active debug session at a time. Stop the current session before launching another.",
      )
    }

    if (input.tool === "cog_debug_launch" && state.launchCount >= 2 && !state.lastHypothesis) {
      throw new Error(
        "Cog debug workflow: multiple launches already occurred. Re-state a materially different hypothesis via cog-debug before launching again.",
      )
    }

    if (input.tool === "cog_debug_run") {
      const action = getAction(args)
      if (state.inspectionRequired && action !== "pause" && action !== "restart") {
        throw new Error(
          "Cog debug workflow: inspect the current stopped state before continuing or stepping again.",
        )
      }
    }

    if (specialistDebugTools.has(input.tool) && !state.sawEvidence) {
      throw new Error(
        "Cog debug workflow: use the core debugger workflow first. Specialist debug tools are for cases where breakpoints, run control, inspect, and stacktrace did not answer the question.",
      )
    }
  },
  "tool.execute.after": async (input) => {
    const state = getState(input.sessionID)
    const args = getArgs(input.args)

    if (codeIntelTools.has(input.tool)) {
      state.sawCodeIntel = true
      return
    }

    if (input.tool === "task" && isDebugTask(args)) {
      const parsed = parseDebugPrompt(getPrompt(args))
      state.sawDebugTask = true
      state.sawQuestion = parsed.hasQuestion
      state.sawHypothesis = parsed.hasHypothesis
      state.sawTest = parsed.hasTest
      if (parsed.hypothesis) {
        state.lastHypothesis = parsed.hypothesis
      }
      return
    }

    if (!debugTools.has(input.tool)) return

    if (input.tool === "cog_debug_launch" || input.tool === "cog_debug_attach") {
      // Only mark session active if the launch succeeded.
      // A successful launch returns a message containing "session" and the session ID.
      // Failed launches return MCP errors (isError) or empty/error output.
      const output = typeof input.output === "string" ? input.output : ""
      const succeeded = !input.isError && output.length > 0 && output.includes("session")
      if (succeeded) {
        state.activeDebugSession = true
        state.launchCount += 1
      }
      state.inspectionRequired = false
      return
    }

    if (evidenceTools.has(input.tool)) {
      state.sawEvidence = true
      state.inspectionRequired = false
      return
    }

    if (input.tool === "cog_debug_run") {
      const action = getAction(args)
      if (action === "step_over_inspect") {
        state.sawEvidence = true
        state.inspectionRequired = false
      } else if (action !== "pause") {
        state.inspectionRequired = true
      }
      return
    }

    if (input.tool === "cog_debug_stop") {
      state.activeDebugSession = false
      state.inspectionRequired = false
    }
  },
})
