# React (JavaScript) — Explore Benchmark

5 test cases against facebook/react v19.0.0.

Run each prompt in a fresh Claude Code session from `bench/explore/react/`.

---

## Test 1: Architecture Understanding

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does React's reconciliation work? What happens between calling setState and the DOM updating? Walk me through the key functions in the pipeline.

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-1-explore.json in this format: {"test": 1, "name": "Architecture: reconciliation", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does React's reconciliation work? What happens between calling setState and the DOM updating? Walk me through the key functions in the pipeline.

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-1-traditional.json in this format: {"test": 1, "name": "Architecture: reconciliation", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 2: Implementation Pattern

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

I want to add a new built-in hook. What pattern do the existing hooks (useState, useEffect, useCallback) follow? Show me the implementation path from the public API through to the reconciler.

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-2-explore.json in this format: {"test": 2, "name": "Pattern: adding a new hook", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

I want to add a new built-in hook. What pattern do the existing hooks (useState, useEffect, useCallback) follow? Show me the implementation path from the public API through to the reconciler.

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-2-traditional.json in this format: {"test": 2, "name": "Pattern: adding a new hook", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 3: Error Handling

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does React handle error boundaries? What's the mechanism for catching errors during rendering and propagating them to the nearest boundary?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-3-explore.json in this format: {"test": 3, "name": "Error boundaries", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does React handle error boundaries? What's the mechanism for catching errors during rendering and propagating them to the nearest boundary?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-3-traditional.json in this format: {"test": 3, "name": "Error boundaries", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 4: Cross-Cutting Concern

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does the fiber scheduler decide what work to do next? Explain the priority and lane system — what are the key data structures and functions involved?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-4-explore.json in this format: {"test": 4, "name": "Fiber scheduler & lanes", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does the fiber scheduler decide what work to do next? Explain the priority and lane system — what are the key data structures and functions involved?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-4-traditional.json in this format: {"test": 4, "name": "Fiber scheduler & lanes", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 5: Modification Task

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

I need to understand how React's event system works so I can debug a bubbling issue. How do events get from the DOM through React's synthetic event system? What are the key modules and functions?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-5-explore.json in this format: {"test": 5, "name": "Event system debugging", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

I need to understand how React's event system works so I can debug a bubbling issue. How do events get from the DOM through React's synthetic event system? What are the key modules and functions?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/react-5-traditional.json in this format: {"test": 5, "name": "Event system debugging", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```
