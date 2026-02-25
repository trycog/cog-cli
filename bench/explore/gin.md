# Gin (Go) — Explore Benchmark

5 test cases against gin-gonic/gin v1.10.0.

Run each prompt in a fresh Claude Code session from `bench/explore/gin/`.

---

## Test 6: Architecture Understanding

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does a request flow through Gin from the HTTP listener to the response? Walk me through the key structs and methods in the pipeline.

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-6-explore.json in this format: {"test": 6, "name": "Architecture: request flow", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does a request flow through Gin from the HTTP listener to the response? Walk me through the key structs and methods in the pipeline.

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-6-traditional.json in this format: {"test": 6, "name": "Architecture: request flow", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 7: Implementation Pattern

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

I want to write custom middleware for authentication. Show me how the middleware chain is structured — how do handlers get registered, how does Next() work, and how does abort short-circuit the chain?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-7-explore.json in this format: {"test": 7, "name": "Pattern: custom middleware", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

I want to write custom middleware for authentication. Show me how the middleware chain is structured — how do handlers get registered, how does Next() work, and how does abort short-circuit the chain?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-7-traditional.json in this format: {"test": 7, "name": "Pattern: custom middleware", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 8: Routing Internals

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does Gin's router match URL paths to handlers? What data structure does it use for route lookup, and how are path parameters like :id extracted?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-8-explore.json in this format: {"test": 8, "name": "Routing internals", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does Gin's router match URL paths to handlers? What data structure does it use for route lookup, and how are path parameters like :id extracted?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-8-traditional.json in this format: {"test": 8, "name": "Routing internals", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 9: Data Binding

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does Gin handle JSON request body binding and validation? Walk me through what happens when I call c.ShouldBindJSON() — what are the key interfaces and implementations?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-9-explore.json in this format: {"test": 9, "name": "JSON binding & validation", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does Gin handle JSON request body binding and validation? Walk me through what happens when I call c.ShouldBindJSON() — what are the key interfaces and implementations?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-9-traditional.json in this format: {"test": 9, "name": "JSON binding & validation", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 10: Error Handling

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does Gin handle panics during request processing? What's the recovery mechanism, and how can I customize error responses? Show me the relevant middleware and error types.

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-10-explore.json in this format: {"test": 10, "name": "Panic recovery", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does Gin handle panics during request processing? What's the recovery mechanism, and how can I customize error responses? Show me the relevant middleware and error types.

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/gin-10-traditional.json in this format: {"test": 10, "name": "Panic recovery", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```
