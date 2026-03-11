// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now
import type { PluginAPI } from '@ampcode/plugin'
import { existsSync, readFileSync } from 'node:fs'

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

export default function registerCogPlugin(amp: PluginAPI) {
  amp.on('tool.call', (event) => {
    if (!hasCogWorkspaceConfig()) return

    const toolName = getToolName(event)
    if (toolName === 'grep' || toolName === 'glob' || toolName === 'search_file_content') {
      throw new Error('Cog policy: use Cog code intelligence tools before raw file search when the Cog MCP server is configured.')
    }

    if (toolName === 'run_shell_command' || toolName === 'Bash') {
      const text = eventText(event)
      if (/(^|\W)(rg|grep|find)(\W|$)/.test(text)) {
        throw new Error('Cog policy: use Cog code intelligence tools before raw shell search commands when the Cog MCP server is configured.')
      }
    }
  })
}
