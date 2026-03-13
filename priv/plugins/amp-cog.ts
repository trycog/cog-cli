// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now
import type { PluginAPI } from '@ampcode/plugin'
import { existsSync, readFileSync } from 'node:fs'

const weakRelationPattern = /"relation"\s*:\s*"related_to"/i
const shortDefinitionPattern = /"definition"\s*:\s*"[^"]{0,31}"/i

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

const shellSearchPattern = /(^|\W)(git\s+grep|rg|grep|find)(\W|$)/i

export default function registerCogPlugin(amp: PluginAPI) {
  amp.on('tool.call', (event) => {
    if (!hasCogWorkspaceConfig()) return

    const toolName = getToolName(event)
    if (toolName === 'grep' || toolName === 'glob' || toolName === 'search_file_content') {
      throw new Error('Cog policy: use Cog code intelligence tools before raw file search when the Cog MCP server is configured.')
    }

    if (toolName === 'run_shell_command' || toolName === 'Bash') {
      const text = eventText(event)
      if (shellSearchPattern.test(text)) {
        throw new Error('Cog policy: use Cog code intelligence tools before shell search commands like grep, rg, find, or git grep when the Cog MCP server is configured.')
      }
    }

    if (toolName.startsWith('cog_mem_') || toolName.includes('mem_')) {
      const text = eventText(event)
      if (weakRelationPattern.test(text)) {
        process.stderr.write('Cog memory quality: prefer a stronger predicate than related_to when the relationship is directional or structural.\n')
      }
      if (shortDefinitionPattern.test(text)) {
        process.stderr.write('Cog memory quality: include rationale or constraints when the memory is durable.\n')
      }
    }
  })
}
