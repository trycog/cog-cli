// Cog runtime enforcement extension for the Pi coding agent.
// Deployed by `cog init` to .pi/extensions/cog.ts
//
// Hooks into Pi's extension lifecycle to enforce Cog-first code
// exploration and memory workflow conventions.

import type { ExtensionContext } from '@mariozechner/pi-coding-agent'

const weakRelationPattern = /"relation"\s*:\s*"related_to"/i
const shortDefinitionPattern = /"definition"\s*:\s*"[^"]{0,31}"/i
const shellSearchPattern = /(^|\W)(git\s+grep|rg|grep|find)(\W|$)/i

const memoryRecallTools = new Set(['cog_mem_recall'])
const memoryWriteTools = new Set([
  'cog_mem_learn',
  'cog_mem_associate',
  'cog_mem_refactor',
  'cog_mem_update',
  'cog_mem_deprecate',
])
const memoryReviewTools = new Set(['cog_mem_list_short_term'])
const memoryValidationTools = new Set(['cog_mem_reinforce', 'cog_mem_verify', 'cog_mem_flush'])
const deepExplorationTools = new Set(['cog_code_explore', 'cog_code_query', 'grep', 'find', 'ls'])

const sessionState = {
  didRecall: false,
  usedMemory: false,
  pendingLearning: false,
  pendingConsolidation: false,
}

function getToolName(event: unknown): string {
  if (!event || typeof event !== 'object') return ''
  const record = event as Record<string, unknown>
  if (typeof record.tool === 'string') return record.tool
  if (typeof record.toolName === 'string') return record.toolName
  if (typeof record.name === 'string') return record.name
  return ''
}

function eventText(event: unknown): string {
  try {
    return JSON.stringify(event)
  } catch {
    return ''
  }
}

export default function activate(ctx: ExtensionContext) {
  ctx.on('session_start', () => {
    sessionState.didRecall = false
    sessionState.usedMemory = false
    sessionState.pendingLearning = false
    sessionState.pendingConsolidation = false
  })

  ctx.on('tool_call', (event) => {
    const toolName = getToolName(event)
    const text = eventText(event)

    // Advisory: recall before deep exploration
    if (deepExplorationTools.has(toolName) && !sessionState.didRecall) {
      process.stderr.write(
        'Cog memory workflow: use cog_mem_recall before broad code exploration so recalled knowledge can inform your search.\n',
      )
    }

    // Block shell search commands when Cog code intelligence is available
    if (toolName === 'bash') {
      if (shellSearchPattern.test(text)) {
        return {
          block: true,
          reason:
            'Cog policy: use Cog code intelligence tools (cog_code_explore, cog_code_query) before shell search commands like grep, rg, find, or git grep.',
        }
      }
    }

    // Advisory: consolidate before finishing
    if (
      (sessionState.pendingLearning || sessionState.pendingConsolidation) &&
      !memoryWriteTools.has(toolName) &&
      !memoryReviewTools.has(toolName) &&
      !memoryValidationTools.has(toolName)
    ) {
      process.stderr.write(
        'Cog memory workflow: remember to store durable knowledge via cog_mem_learn and consolidate short-term memories before finishing.\n',
      )
    }

    // Memory write quality advisories
    if (memoryWriteTools.has(toolName)) {
      if (weakRelationPattern.test(text)) {
        process.stderr.write(
          'Cog memory quality: prefer a stronger predicate than related_to when the relationship is directional or structural.\n',
        )
      }
      if (shortDefinitionPattern.test(text)) {
        process.stderr.write(
          'Cog memory quality: include rationale or constraints when the memory is durable.\n',
        )
      }
    }
  })

  ctx.on('tool_result', (event) => {
    const toolName = getToolName(event)

    if (memoryRecallTools.has(toolName)) {
      sessionState.didRecall = true
      sessionState.usedMemory = true
      return
    }

    if (toolName === 'cog_code_explore') {
      sessionState.pendingLearning = true
      return
    }

    if (memoryWriteTools.has(toolName)) {
      sessionState.usedMemory = true
      sessionState.pendingLearning = false
      sessionState.pendingConsolidation = true
      return
    }

    if (memoryReviewTools.has(toolName) || memoryValidationTools.has(toolName)) {
      sessionState.usedMemory = true
      sessionState.pendingConsolidation = false
      return
    }
  })
}
