# Writing a Language Extension

Cog extensions add language support for two capabilities: **code intelligence** (indexing, go-to-definition, find references) and **debugging** (breakpoints, stepping, variable inspection). An extension can provide one or both.

A language extension is a git repository with a manifest, a build command, and a binary that produces a SCIP index. Optionally, the manifest declares a debugger configuration.

## How Indexing Works

Cog uses two indexing layers that work together:

### Tree-sitter (built-in, syntactic)

Cog ships with tree-sitter grammars compiled into the binary for 9 languages. These provide fast, zero-dependency, per-file indexing with no external tools. Tree-sitter parsing runs in-process and produces SCIP documents directly.

The tree-sitter layer is **syntactic** — it identifies definitions and references by matching AST patterns (function declarations, class definitions, import statements). It works per-file with no cross-file resolution.

| Language | Extensions |
|----------|-----------|
| Go | `.go` |
| TypeScript | `.ts` |
| TSX | `.tsx` |
| JavaScript | `.js` |
| Python | `.py` |
| Java | `.java` |
| Rust | `.rs` |
| C | `.c` |
| C++ | `.cpp` |

### SCIP extensions (external, semantic)

For languages tree-sitter doesn't cover — or when richer cross-file analysis is needed — Cog invokes an external indexer that produces a [SCIP](https://github.com/sourcegraph/scip) (Source Code Intelligence Protocol) index. **This is what extensions provide.**

SCIP extensions are **semantic** — they understand the language's type system, module resolution, and cross-file dependencies. They can resolve imports, track type hierarchies, and produce accurate cross-reference data that syntactic parsing alone cannot.

### Why both layers exist

Tree-sitter gives every supported language instant, zero-config indexing on the first `cog code:index`. No external tools to install, no build step, no configuration. This is the baseline.

SCIP extensions add depth. A tree-sitter grammar can identify that `foo()` is a function call, but it can't tell you which `foo` — the one in `utils.zig` or the one in `math.zig`. A SCIP extension with access to the compiler's symbol table resolves that unambiguously.

For the 9 built-in languages, Cog also ships built-in SCIP extension definitions (e.g., `scip-go`, `scip-python`). When these external tools are installed, Cog invokes them after tree-sitter for the same file set, and their richer results are merged into the index.

### Indexing flow

When you run `cog code:index`:

1. Expands the glob pattern to a list of files
2. For each file, tries the **tree-sitter** indexer first (built-in, per-file, fast)
3. Collects files that tree-sitter doesn't handle
4. For each unique language needing external indexing, invokes the **SCIP extension** binary with the project path and a temp output path
5. Reads the SCIP protobuf output and merges all documents into `.cog/index.scip`

Both layers produce the same SCIP format internally — tree-sitter results are converted to SCIP documents before merging. Installed extensions take priority over built-in SCIP definitions when they handle the same file types.

## Repository Layout

```
your-extension/
├── cog-extension.json       # Manifest (required)
├── bin/
│   └── <name>               # Compiled binary (produced by build)
└── ... source code, build files, etc.
```

The binary must be at `bin/<name>` where `<name>` matches the `name` field in the manifest.

## Manifest

Create `cog-extension.json` in the repository root:

```json
{
  "name": "cog-zig",
  "extensions": [".zig", ".zon"],
  "args": ["{file}", "--output", "{output}"],
  "build": "zig build -Doptimize=ReleaseFast && mkdir -p bin && cp zig-out/bin/cog-zig bin/cog-zig",
  "debugger": {
    "type": "native",
    "boundary_markers": ["std.start", "__zig_return_address"]
  }
}
```

### Core fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Extension name. Must match the binary filename in `bin/`. |
| `extensions` | string[] | File extensions this extension handles. Include the leading dot. |
| `args` | string[] | Arguments passed to the binary. Use `{file}` and `{output}` placeholders. |
| `build` | string | Shell command to build the binary. Runs via `/bin/sh -c` in the repo directory. |

### Placeholders

| Placeholder | Replaced With |
|-------------|---------------|
| `{file}` | Project root path (e.g., `/Users/me/project`) |
| `{output}` | Temp file path for SCIP output (e.g., `/tmp/cog-index-12345.scip`) |

Cog invokes your binary as:

```
bin/<name> <args with placeholders substituted>
```

For example, with the manifest above:

```
bin/cog-zig /Users/me/project --output /tmp/cog-index-12345.scip
```

## SCIP Output

Your binary must write a SCIP index in [Protocol Buffer](https://protobuf.dev/) wire format to the `{output}` path. The SCIP protobuf schema is defined at [sourcegraph/scip](https://github.com/sourcegraph/scip/blob/main/scip.proto).

### What Cog reads

**Per document** (one per indexed file):

| Field | Required | Description |
|-------|----------|-------------|
| `relative_path` | yes | Path from project root (e.g., `src/main.zig`) |
| `language` | yes | Language identifier (e.g., `zig`) |
| `occurrences` | yes | Array of symbol occurrences |
| `symbols` | no | Array of symbol information (definitions) |

**Per occurrence:**

| Field | Required | Description |
|-------|----------|-------------|
| `range` | yes | `[start_line, start_char, end_line, end_char]` (0-indexed) |
| `symbol` | yes | Fully qualified SCIP symbol string |
| `symbol_roles` | yes | Bit flags: `0x1` = definition, `0x2` = import, `0x4` = write, `0x8` = read |

**Per symbol information** (for definitions):

| Field | Required | Description |
|-------|----------|-------------|
| `symbol` | yes | Matching SCIP symbol string |
| `kind` | yes | Symbol kind integer (see table below) |
| `display_name` | no | Short name for display in query results |
| `documentation` | no | Doc strings |
| `relationships` | no | Links to parent/related symbols |
| `enclosing_symbol` | no | Parent symbol (for nested definitions) |

### Common symbol kinds

| Code | Kind | Code | Kind |
|------|------|------|------|
| 7 | class | 17 | function |
| 8 | constant | 21 | interface |
| 11 | enum | 26 | method |
| 12 | enum_member | 29 | module |
| 15 | field | 37 | parameter |
| 41 | property | 49 | struct |
| 54 | type | 55 | type_alias |
| 58 | type_parameter | 61 | variable |

The full list of 70+ kinds is in the [SCIP spec](https://github.com/sourcegraph/scip/blob/main/scip.proto).

### Symbol strings

SCIP symbol strings encode the fully qualified name. The format is:

```
scheme manager package-name version descriptor...
```

For example: `scip-ruby gem ruby-core 3.2.0 Kernel#puts().`

See the [SCIP symbol spec](https://github.com/sourcegraph/scip/blob/main/docs/scip-symbol-format.md) for the full format. Cog uses these strings to match definitions with references — consistency within your indexer is more important than exact adherence to the spec format.

## Building

Your build command runs via `/bin/sh -c "<build>"` in the repository directory. It must produce an executable at `bin/<name>`.

Common patterns:

```json
{"build": "go build -o bin/scip-ruby ./cmd/indexer"}
{"build": "cargo build --release && cp target/release/scip-rust bin/scip-rust"}
{"build": "make install"}
{"build": "zig build -Doptimize=ReleaseFast && mkdir -p bin && cp zig-out/bin/cog-zig bin/cog-zig"}
```

## Installation

Users install extensions with:

```sh
cog install https://github.com/you/cog-zig.git
```

This clones the repo to `~/.config/cog/extensions/cog-zig/`, runs the build command, and verifies the binary exists. Once installed, the extension is automatically used for matching file types.

Installed extensions take priority over built-in ones. If your extension handles `.py` files, it overrides the built-in `scip-python`.

## Debugger Support

Extensions can declare a debugger configuration so that `cog debug:*` commands know how to debug programs in that language. The debugger section is optional — an extension can provide indexing only, debugging only, or both.

### How debugging works

Cog's debug system supports two driver types:

1. **DAP (Debug Adapter Protocol)** — For languages with a DAP-compatible debug adapter (most interpreted and managed languages). Cog spawns the adapter as a subprocess, communicates via the DAP wire protocol, and manages the session lifecycle.

2. **Native (DWARF/ptrace/mach)** — For compiled languages that produce DWARF debug info (C, C++, Zig, Rust). Cog's built-in engine reads ELF/Mach-O binaries directly, sets breakpoints via instruction patching, and walks stack frames using DWARF call frame information. No external adapter needed.

Both drivers expose the same interface to the user: launch, breakpoints, stepping, variable inspection, expression evaluation, stack traces. The extension manifest tells Cog which driver to use and how to configure it.

### Debug launch flow

When `cog debug:send launch` is called with a program path:

1. Cog determines the file extension of the target program
2. Looks up the extension (installed first, then built-in) for that file type
3. Reads the `debugger` configuration from the extension manifest
4. If `type` is `"dap"`: spawns the adapter subprocess, connects via the specified transport, sends DAP initialize/launch/configurationDone sequence
5. If `type` is `"native"`: loads DWARF debug info from the binary, spawns the process under ptrace/mach control
6. Creates a debug session and returns the session ID for subsequent commands

### Manifest configuration

Add a `debugger` field to `cog-extension.json`:

```json
{
  "name": "cog-ruby",
  "extensions": [".rb", ".rake"],
  "args": ["{file}", "--output", "{output}"],
  "build": "make install",
  "debugger": {
    "type": "dap",
    "adapter": {
      "command": "rdbg",
      "args": ["--open", "--port", ":{port}"],
      "transport": "tcp"
    },
    "launch_args": "{\"cwd\":\"{cwd}\"}",
    "boundary_markers": ["<internal_frame>"]
  }
}
```

### Debugger fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `debugger.type` | string | yes | `"dap"` or `"native"` |
| `debugger.adapter` | object | for DAP | Adapter process configuration |
| `debugger.adapter.command` | string | for DAP | Executable to launch (must be in `$PATH`) |
| `debugger.adapter.args` | string[] | for DAP | Arguments. `{port}` is replaced with an available port. |
| `debugger.adapter.transport` | string | for DAP | `"tcp"`, `"stdio"`, or `"cdp"` |
| `debugger.launch_args` | string | no | JSON template for DAP launch config. `{program}` and `{cwd}` are replaced. |
| `debugger.boundary_markers` | string[] | no | Stack frame symbol names to filter from traces |

### Choosing a debugger type

**Use `"dap"`** when a DAP-compatible debug adapter exists for your language. Most modern debuggers speak DAP — it's the protocol VS Code uses. Examples:

- **Go**: `dlv dap` (Delve)
- **Python**: `debugpy`
- **Ruby**: `rdbg` (debug.gem)
- **Java**: JDWP agent
- **JavaScript/TypeScript**: Node.js `--inspect` (Chrome DevTools Protocol, use transport `"cdp"`)

**Use `"native"`** when the language compiles to native binaries with DWARF debug info. No adapter needed — Cog reads the debug info directly:

- **Zig**: Compile with debug info (`-Doptimize=Debug` or default)
- **Rust**: Compile with debug info (`cargo build`, not `--release`)
- **C/C++**: Compile with `-g` flag

### Transport types

| Transport | When to use | How it works |
|-----------|-------------|--------------|
| `tcp` | Most DAP adapters | Adapter listens on a TCP port. Cog connects after spawn. Use `{port}` in args. |
| `stdio` | Pipe-based adapters | Cog communicates via the adapter's stdin/stdout using DAP Content-Length framing. |
| `cdp` | Node.js debugging | Chrome DevTools Protocol over WebSocket. Used with `node --inspect`. |

### Boundary markers

Boundary markers filter runtime-internal stack frames from user-facing stack traces. When a frame's function name contains any of these markers, it and everything below it are hidden.

Examples:

| Language | Markers | Purpose |
|----------|---------|---------|
| Go | `_cgo_topofstack`, `crosscall2` | Hide cgo FFI frames |
| Zig | `std.start`, `__zig_return_address` | Hide Zig runtime startup |
| Java | `sun.misc.Unsafe` | Hide JVM internals |

### DAP adapter examples

**Go (Delve):**
```json
"debugger": {
  "type": "dap",
  "adapter": {
    "command": "dlv",
    "args": ["dap", "--listen", ":{port}"],
    "transport": "tcp"
  },
  "launch_args": "{\"mode\":\"debug\",\"program\":\"{program}\"}",
  "boundary_markers": ["_cgo_topofstack", "crosscall2"]
}
```

**Python (debugpy):**
```json
"debugger": {
  "type": "dap",
  "adapter": {
    "command": "python3",
    "args": ["-m", "debugpy", "--listen", ":{port}", "--wait-for-client", "{program}"],
    "transport": "tcp"
  }
}
```

**JavaScript (Node.js):**
```json
"debugger": {
  "type": "dap",
  "adapter": {
    "command": "node",
    "args": ["--inspect=0", "{program}"],
    "transport": "cdp"
  }
}
```

**Native (compiled languages):**
```json
"debugger": {
  "type": "native",
  "boundary_markers": ["std.start", "__zig_return_address"]
}
```

Native debugging requires no adapter configuration. The binary must be compiled with debug info (DWARF). Cog handles process control, breakpoints, and inspection directly.

## Built-in Language Support

### Tree-sitter (in-process, syntactic)

These languages are indexed by the built-in tree-sitter grammars. No external tools needed.

| Language | Extensions |
|----------|-----------|
| Go | `.go` |
| TypeScript | `.ts` |
| TSX | `.tsx` |
| JavaScript | `.js` |
| Python | `.py` |
| Java | `.java` |
| Rust | `.rs` |
| C | `.c` |
| C++ | `.cpp` |

### SCIP extensions (external, semantic)

These are built-in SCIP extension definitions. Cog invokes them as external processes when the tool is installed on the system. Installed extensions override these if they handle the same file types.

| Name | Extensions | Debugger |
|------|------------|----------|
| scip-go | `.go` | DAP via `dlv` |
| scip-typescript | `.ts` `.tsx` `.js` `.jsx` | CDP via `node --inspect` |
| scip-python | `.py` | DAP via `debugpy` |
| scip-java | `.java` | DAP via JDWP |
| rust-analyzer | `.rs` | Native (DWARF) |

## Checklist

### Indexing

- [ ] `cog-extension.json` in the repo root with `name`, `extensions`, `args`, `build`
- [ ] `build` command produces an executable at `bin/<name>`
- [ ] Binary accepts `{file}` and `{output}` arguments
- [ ] Binary writes valid SCIP protobuf to the output path
- [ ] Binary exits 0 on success, non-zero on failure
- [ ] Binary does not write to stdout or stderr (both are ignored by Cog)
- [ ] Paths in SCIP documents are relative to the project root
- [ ] Occurrences include `symbol_roles` with the definition bit (`0x1`) set for definitions

### Debugging (optional)

- [ ] `debugger.type` is `"dap"` or `"native"`
- [ ] For DAP: adapter `command` is installed and in `$PATH`
- [ ] For DAP: adapter `args` include `{port}` placeholder if using `tcp` transport
- [ ] For DAP: `transport` is `"tcp"`, `"stdio"`, or `"cdp"`
- [ ] For native: target binaries are compiled with debug info (DWARF)
- [ ] `boundary_markers` list runtime-internal frame names to filter (if applicable)

## Example: Minimal Indexer in Go

```go
package main

import (
    "os"

    "github.com/sourcegraph/scip/bindings/go/scip"
    "google.golang.org/protobuf/proto"
)

func main() {
    projectRoot := os.Args[1]
    outputPath := os.Args[3] // after "--output"

    index := &scip.Index{
        Metadata: &scip.Metadata{
            Version:              scip.ProtocolVersion_UnspecifiedProtocolVersion,
            ToolInfo:             &scip.ToolInfo{Name: "my-indexer", Version: "0.1.0"},
            ProjectRoot:          "file://" + projectRoot,
            TextDocumentEncoding: scip.TextEncoding_UTF8,
        },
        Documents: []*scip.Document{
            {
                Language:     "mylang",
                RelativePath: "src/example.mylang",
                Occurrences: []*scip.Occurrence{
                    {
                        Range:       []int32{0, 4, 0, 13},  // line 0, cols 4-13
                        Symbol:      "my-indexer . . . myFunction().",
                        SymbolRoles: int32(scip.SymbolRole_Definition),
                    },
                },
                Symbols: []*scip.SymbolInformation{
                    {
                        Symbol:      "my-indexer . . . myFunction().",
                        Kind:        scip.SymbolInformation_Function,
                        DisplayName: "myFunction",
                    },
                },
            },
        },
    }

    data, _ := proto.Marshal(index)
    os.WriteFile(outputPath, data, 0644)
}
```

## Example: cog-zig

The [cog-zig](https://github.com/bcardarella/cog-zig) extension demonstrates a complete implementation with both indexing and debugging:

```json
{
  "name": "cog-zig",
  "extensions": [".zig", ".zon"],
  "args": ["{file}", "--output", "{output}"],
  "build": "zig build -Doptimize=ReleaseFast && mkdir -p bin && cp zig-out/bin/cog-zig bin/cog-zig",
  "debugger": {
    "type": "native",
    "boundary_markers": ["std.start", "__zig_return_address"]
  }
}
```

**Indexing:** The binary uses Zig's built-in AST parser (`std.zig.Ast`) to perform semantic analysis — scope resolution, symbol kind inference, cross-file import tracking — and emits SCIP protobuf. This is equivalent to what a tree-sitter grammar plus a type checker would produce, but implemented using the language's own compiler infrastructure.

**Debugging:** Declared as `"native"` because Zig compiles to native binaries with DWARF debug info. No external adapter needed. The `boundary_markers` filter Zig's runtime startup frames (`std.start`) and return address helpers (`__zig_return_address`) from stack traces.

**Architecture:** A thin wrapper binary (`bin/cog-zig`) auto-discovers the package name from `build.zig.zon` and the root source file (`src/main.zig`, `src/root.zig`, `src/lib.zig`, or `build.zig`), then delegates to the vendored SCIP indexer in-process.
