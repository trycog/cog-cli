// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now
import type { PluginAPI } from '@ampcode/plugin'
import { existsSync, readFileSync } from 'node:fs'

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
const deepExplorationTools = new Set(['cog_code_explore', 'cog_code_query', 'grep', 'glob', 'search_file_content'])

const sessionState = {
  didRecall: false,
  usedMemory: false,
  pendingLearning: false,
  pendingConsolidation: false,
  forcedContinuation: false,
  memorySubagentActive: false,
}

function hasCogWorkspaceConfig(): boolean {
  if (!existsSync('.amp/settings.json')) return false

  try {
    const parsed = JSON.parse(readFileSync('.amp/settings.json', 'utf8')) as Record<string, unknown>
    const servers = parsed['amp.mcpServers']
    return typeof servers === 'object' && servers !== null && 'cog' in servers
  } catch {
    return false
  }
}

function getToolName(event: unknown): string {
  if (!event || typeof event !== 'object') return ''
  const record = event as Record<string, unknown>
  if (typeof record.tool === 'string') return record.tool
  if (typeof record.toolName === 'string') return record.toolName
  if (typeof record.name === 'string') return record.name
  if (record.tool && typeof record.tool === 'object') {
    const tool = record.tool as Record<string, unknown>
    if (typeof tool.name === 'string') return tool.name
  }
  return ''
}

function eventText(event: unknown): string {
  try {
    return JSON.stringify(event)
  } catch {
    return ''
  }
}

function clearContinuationGuard() {
  sessionState.forcedContinuation = false
}

export default function registerCogPlugin(amp: PluginAPI) {
  amp.on('session.start', () => {
    sessionState.didRecall = false
    sessionState.usedMemory = false
    sessionState.pendingLearning = false
    sessionState.pendingConsolidation = false
    sessionState.forcedContinuation = false
    sessionState.memorySubagentActive = false
  })

  amp.on('tool.call', (event) => {
    if (!hasCogWorkspaceConfig()) return { action: 'allow' }

    const toolName = getToolName(event)
    const text = eventText(event)

    if (deepExplorationTools.has(toolName) && !sessionState.didRecall) {
      amp.logger.log(
        'Cog memory workflow: if this is a prior-knowledge question rather than direct code tracing, use the cog-mem subagent first so it can attempt recall before broader exploration.',
      )
    }

    if (toolName === 'run_shell_command' || toolName === 'Bash') {
      if (shellSearchPattern.test(text)) {
        return {
          action: 'reject-and-continue',
          message:
            'Cog policy: use Cog code intelligence tools before shell search commands like grep, rg, find, or git grep when the Cog MCP server is configured.',
        }
      }
    }

    if ((sessionState.pendingLearning || sessionState.pendingConsolidation) &&
        !memoryWriteTools.has(toolName) && !memoryReviewTools.has(toolName) && !memoryValidationTools.has(toolName)) {
      // Advisory only — don't block normal read/explore work.
      // The agent.end hook handles hard enforcement at end of session.
      amp.logger.log('Cog memory workflow: remember to delegate to cog-mem-validate to store durable knowledge before finishing.')
    }

    if (memoryWriteTools.has(toolName)) {
      if (weakRelationPattern.test(text)) {
        process.stderr.write('Cog memory quality: prefer a stronger predicate than related_to when the relationship is directional or structural.\n')
      }
      if (shortDefinitionPattern.test(text)) {
        process.stderr.write('Cog memory quality: include rationale or constraints when the memory is durable.\n')
      }
    }

    return { action: 'allow' }
  })

  amp.on('tool.result', (event) => {
    if (!hasCogWorkspaceConfig()) return

    const toolName = getToolName(event)

    if (memoryRecallTools.has(toolName)) {
      sessionState.didRecall = true
      sessionState.usedMemory = true
      clearContinuationGuard()
      return
    }

    if (toolName === 'cog_code_explore') {
      sessionState.pendingLearning = true
      clearContinuationGuard()
      return
    }

    if (memoryWriteTools.has(toolName)) {
      sessionState.usedMemory = true
      sessionState.pendingLearning = false
      sessionState.pendingConsolidation = true
      clearContinuationGuard()
      return
    }

    // list_short_term or any validation tool clears the consolidation gate
    if (memoryReviewTools.has(toolName) || memoryValidationTools.has(toolName)) {
      sessionState.usedMemory = true
      sessionState.pendingConsolidation = false
      clearContinuationGuard()
      return
    }
  })

  amp.on('agent.end', async () => {
    if (!hasCogWorkspaceConfig()) return
    if (sessionState.forcedContinuation) return

    if (sessionState.pendingLearning || sessionState.pendingConsolidation) {
      sessionState.forcedContinuation = true
      return {
        action: 'continue',
        userMessage:
          'Before finishing, delegate to the cog-mem-validate sub-agent to learn durable knowledge and consolidate short-term memories. One subagent call handles both — do not call memory tools directly.',
      }
    }
  })
}
