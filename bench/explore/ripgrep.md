# ripgrep (Rust) — Explore Benchmark

5 test cases against BurntSushi/ripgrep 14.1.1.

Run each prompt in a fresh Claude Code session from `bench/explore/ripgrep/`.

---

## Test 16: Architecture Understanding

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does ripgrep's search pipeline work? Walk me through the architecture from parsing CLI args to printing matches — what are the key crates and their responsibilities?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-16-explore.json in this format: {"test": 16, "name": "Architecture: search pipeline", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does ripgrep's search pipeline work? Walk me through the architecture from parsing CLI args to printing matches — what are the key crates and their responsibilities?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-16-traditional.json in this format: {"test": 16, "name": "Architecture: search pipeline", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 17: Implementation Pattern

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does ripgrep handle different output formats (standard, JSON, count-only, files-with-matches)? What's the printer abstraction and how do the different implementations work?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-17-explore.json in this format: {"test": 17, "name": "Pattern: output formats", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does ripgrep handle different output formats (standard, JSON, count-only, files-with-matches)? What's the printer abstraction and how do the different implementations work?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-17-traditional.json in this format: {"test": 17, "name": "Pattern: output formats", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 18: File Filtering

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does ripgrep decide which files to search? Explain the ignore/filtering system — how does it handle .gitignore, --type filters, and --glob patterns? What are the key types and traits?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-18-explore.json in this format: {"test": 18, "name": "File filtering & ignore", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does ripgrep decide which files to search? Explain the ignore/filtering system — how does it handle .gitignore, --type filters, and --glob patterns? What are the key types and traits?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-18-traditional.json in this format: {"test": 18, "name": "File filtering & ignore", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 19: Parallelism

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does ripgrep parallelize search across files? What's the threading model, how is work distributed, and how are results collected and ordered for output?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-19-explore.json in this format: {"test": 19, "name": "Parallelism model", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does ripgrep parallelize search across files? What's the threading model, how is work distributed, and how are results collected and ordered for output?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-19-traditional.json in this format: {"test": 19, "name": "Parallelism model", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 20: Modification Task

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

I want to add a new output format to ripgrep. What's the interface I need to implement, where do the existing printers live, and how does the CLI flag wire up to the printer selection?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-20-explore.json in this format: {"test": 20, "name": "Modification: new output format", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

I want to add a new output format to ripgrep. What's the interface I need to implement, where do the existing printers live, and how does the CLI flag wire up to the printer selection?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/ripgrep-20-traditional.json in this format: {"test": 20, "name": "Modification: new output format", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```
