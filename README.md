# cog

A native CLI for [Cog](https://trycog.ai) associative memory.

## Install

Requires [Zig 0.15.2+](https://ziglang.org/download/).

```
zig build
```

The binary is at `zig-out/bin/cog`.

## Setup

### 1. Create a `.cog` file

Place a `.cog` file in your project directory (or any parent directory up to `$HOME`):

```
cog://trycog.ai/username/brain
```

### 2. Set your API key

Either export it:

```
export COG_API_KEY=your-key-here
```

Or add it to a `.env` file in your working directory:

```
COG_API_KEY=your-key-here
```

## Usage

```
cog <command> [options]
```

Run `cog` with no arguments to see all commands, or `cog <command> --help` for details on a specific command.

### Read operations

```sh
# Search memory
cog recall "authentication session lifecycle"
cog recall "token refresh" --limit 3 --predicate-filter requires --no-strengthen

# Search multiple queries at once
cog bulk-recall "auth tokens" "session management" --limit 5

# Get a specific engram
cog get <engram-id>

# List connections from an engram
cog connections <engram-id> --direction outgoing

# Trace reasoning path between two concepts
cog trace <from-id> <to-id>

# List short-term memories pending consolidation
cog list-short-term --limit 20

# List stale synapses
cog stale --level warning --limit 10

# Brain overview
cog stats
cog orphans
cog connectivity
cog list-terms --limit 100
```

### Write operations

```sh
# Store a new concept
cog learn --term "Rate Limiting" --definition "Token bucket algorithm for API throttling"

# Store with associations
cog learn --term "Rate Limiting" \
  --definition "Token bucket algorithm for API throttling" \
  --associate "target:API Gateway,predicate:implemented_by"

# Store with reasoning chain
cog learn --term "PostgreSQL" \
  --definition "Primary relational database" \
  --chain "term:Event Sourcing,definition:Append-only event log,predicate:enables" \
  --chain "term:CQRS,definition:Separate read/write models,predicate:implies"

# Store as permanent long-term memory
cog learn --term "Core Architecture" --definition "..." --long-term

# Link two concepts
cog associate --source "Rate Limiting" --target "API Gateway" --predicate requires

# Batch operations
cog bulk-learn --item "term:Concept A,definition:First concept" \
               --item "term:Concept B,definition:Second concept" \
               --memory short

cog bulk-associate --link "source:Concept A,target:Concept B,predicate:requires"

# Update an engram
cog update <engram-id> --term "New Name" --definition "Updated definition"

# Update by term lookup
cog refactor --term "Rate Limiting" --definition "Updated definition"

# Memory lifecycle
cog reinforce <engram-id>   # short-term → long-term
cog flush <engram-id>       # delete short-term memory
cog deprecate --term "Old Concept"

# Synapse management
cog verify <synapse-id>
cog unlink <synapse-id>

# Cross-brain connection
cog meld --target "other-brain" --description "Shared architecture knowledge"
```

## Development

```sh
zig build test   # run tests
zig build run    # build and run (pass args after --)
zig build run -- stats
```
