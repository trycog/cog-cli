# Flask (Python) — Explore Benchmark

5 test cases against pallets/flask 3.1.0.

Run each prompt in a fresh Claude Code session from `bench/explore/flask/`.

---

## Test 11: Architecture Understanding

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does Flask's request context work? What happens when a request comes in — how does the app create the context, make it available to handlers, and clean it up?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-11-explore.json in this format: {"test": 11, "name": "Architecture: request context", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does Flask's request context work? What happens when a request comes in — how does the app create the context, make it available to handlers, and clean it up?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-11-traditional.json in this format: {"test": 11, "name": "Architecture: request context", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 12: Implementation Pattern

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How do Flask blueprints work? I want to use them to organize a large app. Show me how blueprints register routes, how they integrate with the main app, and how URL prefixes are handled.

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-12-explore.json in this format: {"test": 12, "name": "Pattern: blueprints", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How do Flask blueprints work? I want to use them to organize a large app. Show me how blueprints register routes, how they integrate with the main app, and how URL prefixes are handled.

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-12-traditional.json in this format: {"test": 12, "name": "Pattern: blueprints", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 13: URL Routing

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does Flask dispatch an incoming request to the right view function? Walk me through the routing from URL matching through the @app.route decorator to calling the handler.

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-13-explore.json in this format: {"test": 13, "name": "URL routing & dispatch", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does Flask dispatch an incoming request to the right view function? Walk me through the routing from URL matching through the @app.route decorator to calling the handler.

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-13-traditional.json in this format: {"test": 13, "name": "URL routing & dispatch", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 14: Error Handling

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does Flask handle errors and exceptions? I want to add custom error pages for 404 and 500 errors. Show me the error handler registration mechanism and how exceptions flow through the app.

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-14-explore.json in this format: {"test": 14, "name": "Error handling", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does Flask handle errors and exceptions? I want to add custom error pages for 404 and 500 errors. Show me the error handler registration mechanism and how exceptions flow through the app.

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-14-traditional.json in this format: {"test": 14, "name": "Error handling", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

---

## Test 15: Template & Response

### Explore variant
```
Use the cog-code-explore agent to answer this question. Do NOT use Grep, Read, Glob, or any other tools yourself.

How does Flask's response system work? When a view function returns a value, how does Flask turn it into an HTTP response? What are the different return types it handles (string, tuple, Response object)?

After answering, count the total number of tool calls you made (including subagent calls) and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-15-explore.json in this format: {"test": 15, "name": "Response system", "variant": "explore", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```

### Traditional variant
```
You MUST answer using ONLY Grep, Read, and Glob tools. Do NOT use any cog_code_* MCP tools or the cog-code-explore agent.

How does Flask's response system work? When a view function returns a value, how does Flask turn it into an HTTP response? What are the different return types it handles (string, tuple, Response object)?

After answering, count the total number of tool calls you made and the number of LLM rounds (each assistant turn where you invoked tools = 1 round). Write the result as JSON to ../.bench/flask-15-traditional.json in this format: {"test": 15, "name": "Response system", "variant": "traditional", "calls": N, "rounds": N}

Then run this command to update the dashboard: bash ../collect.sh
```
