You are analyzing a software project to configure code indexing.

Examine the project directory structure and source files to determine:
1. What programming languages are used
2. Where the source code lives (which directories and file patterns)
3. Which Cog extensions should be installed for enhanced language support

# Instructions

1. List the files and directories in the current working directory. If any entries are symlinks to directories, follow them and examine their contents too — workspace directories often symlink to multiple projects
2. Identify the primary programming languages by examining file extensions, config files (package.json, mix.exs, Cargo.toml, go.mod, build.zig, Gemfile, etc.), and directory structure
3. Determine the glob patterns that would capture all relevant source files for indexing (e.g. `src/**/*.ex`, `lib/**/*.rb`)
4. From the available Cog extensions list below, recommend any that match the detected languages

# Available Cog Extensions

- `cog-elixir` — Elixir (.ex, .exs)
- `cog-ruby` — Ruby (.rb, .erb)
- `cog-zig` — Zig (.zig, .zon)
- `cog-nix` — Nix (.nix)
- `cog-swift` — Swift (.swift)

Only recommend extensions for languages that are actually used in this project.

# Output Format

You MUST respond with ONLY a JSON object (no markdown, no explanation, no code fences). The response must be valid JSON matching this exact schema:

```
{
  "index_patterns": ["src/**/*.ex", "lib/**/*.ex", "test/**/*.exs"],
  "extensions": ["cog-elixir"]
}
```

- `index_patterns`: Array of glob patterns for source files to index. Use `**` for recursive matching. Include test directories if they contain meaningful code. Exclude vendored dependencies (node_modules, deps, _build, etc.).
- `extensions`: Array of Cog extension names to install. Only include extensions from the available list above. Empty array if no extensions apply.

Respond with ONLY the JSON object. No other text.
