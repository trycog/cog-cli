"""CogDebugAgent — intercepts cog_debug tool calls and delegates to a Claude subagent.

This agent subclasses SWE-agent's DefaultAgent. When the model calls the `cog_debug`
tool, instead of executing it in the container (where it would fail), the agent:

1. Extracts breakpoint/inspect/test/condition arguments
2. Builds a subagent prompt
3. Creates a temporary python3 docker-exec wrapper for the current container
4. Spawns `claude -p` with cog MCP config pointing to the container
5. Returns the subagent's output as the tool observation

All other tool calls (bash, str_replace_editor, submit) pass through to the container
via the normal SWE-agent flow.
"""

from __future__ import annotations

import json
import logging
import os
import re
import shlex
import stat
import subprocess
import tempfile
from pathlib import Path

from sweagent.agent.agents import DefaultAgent
from sweagent.types import StepOutput

logger = logging.getLogger(__name__)

class CogDebugAgent(DefaultAgent):
    """DefaultAgent extended with host-side cog_debug interception."""

    # After this many steps without a cog_debug call, inject a one-time reminder
    COG_DEBUG_REMINDER_STEP = 3
    # Max number of verification reminders (one per source edit)
    MAX_VERIFY_REMINDERS = 3

    # Patterns for script filenames that the agent creates
    _SCRIPT_FILENAME_RE = re.compile(
        r'(^test_|^reproduce|^debug_|^check_|^verify_|^script_)',
    )

    def __init__(self, *, cog_bin: str | None = None, **kwargs):
        super().__init__(**kwargs)
        self._cog_bin = cog_bin or os.environ.get("COG_BIN", "cog")
        self._container_id: str | None = None
        self._tmp_dir: tempfile.TemporaryDirectory | None = None
        self._step_count: int = 0
        self._cog_debug_called: bool = False
        self._reminder_sent: bool = False
        self._source_edited: bool = False
        self._verify_reminder_count: int = 0
        # Track created script paths for custom-script-run detection
        self._created_scripts: set[str] = set()

    def setup(self, env, problem_statement, output_dir=Path(".")):
        """Set up the agent, then discover the Docker container for cog MCP."""
        super().setup(env, problem_statement, output_dir)

        # Discover container ID by running hostname inside the container
        try:
            self._container_id = self._env.communicate("cat /proc/1/cpuset 2>/dev/null | grep -oP '[a-f0-9]{64}$' || hostname").strip()
            if not self._container_id:
                self._container_id = self._env.communicate("hostname").strip()
            self._log("container_id=%s", self._container_id)
        except Exception as e:
            self._log("WARNING: could not discover container ID: %s", e)
            self._container_id = None

        # Install debugpy in the container (required by cog MCP debug tools)
        if self._container_id:
            try:
                result = self._env.communicate(
                    "python3 -m pip install --index-url https://pypi.org/simple/ -q debugpy 2>&1"
                )
                self._log("debugpy install output: %s", result.strip())
            except Exception as e:
                self._log("WARNING: failed to install debugpy: %s", e)

        # Create temp directory for wrapper scripts and MCP config
        self._tmp_dir = tempfile.TemporaryDirectory(prefix="cog_debug_")
        if self._container_id:
            self._create_python3_wrapper()
            self._create_mcp_config()

    def _create_python3_wrapper(self):
        """Create a python3 wrapper script that delegates to docker exec."""
        bin_dir = Path(self._tmp_dir.name) / "bin"
        bin_dir.mkdir(exist_ok=True)
        wrapper = bin_dir / "python3"
        wrapper.write_text(
            f'#!/bin/bash\nexec docker exec -i "{self._container_id}" python3 "$@"\n'
        )
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        self._log("python3 wrapper at %s", wrapper)

    def _create_mcp_config(self):
        """Create MCP config for the cog debug subagent."""
        bin_dir = str(Path(self._tmp_dir.name) / "bin")
        system_path = os.environ.get("PATH", "")

        config = {
            "mcpServers": {
                "cog": {
                    "command": self._cog_bin,
                    "args": ["mcp", "--debug-tools=core"],
                    "env": {
                        "PATH": bin_dir + ":" + system_path,
                        "SWEBENCH_CONTAINER": self._container_id,
                    },
                }
            }
        }
        config_path = Path(self._tmp_dir.name) / "mcp_config.json"
        config_path.write_text(json.dumps(config))
        self._log("MCP config at %s", config_path)

    _COG_DEBUG_REMINDER = (
        "\n\n[Reminder] You have `cog_debug` available — it evaluates any Python expression "
        "at a breakpoint in one step. If you need runtime state (variable values, types, API "
        "exploration), cog_debug is faster than writing and running a script."
    )

    _COG_DEBUG_VERIFY_REMINDER = (
        "\n\n[Reminder] You can verify this fix with `cog_debug` using `condition` to target "
        "the changed code path — one call confirms the fix without writing a test script. "
        "Example: cog_debug breakpoint=\"file.py:line\" inspect=\"var, result\" "
        "test=\"python -m pytest tests/... -xvs\" condition=\"your_new_param == 'value'\""
    )

    _PYTHON_C_BLOCKED = (
        "python3 -c is not available. Use cog_debug to evaluate expressions "
        "at a breakpoint in the actual runtime context:\n\n"
        "  cog_debug breakpoint=\"file.py:line\" "
        "inspect=[\"expr1\", \"expr2\"] "
        "test=\"python -m pytest tests/... -xvs\""
    )

    _SCRIPT_CREATE_REDIRECT = (
        "Script creation is not available. Use cog_debug to verify behavior "
        "at a breakpoint instead:\n\n"
        "  cog_debug breakpoint=\"file.py:line\" "
        "inspect=[\"expr1\", \"expr2\"] "
        "test=\"python -m pytest tests/... -xvs\" "
        "condition=\"your_condition\""
    )

    _SCRIPT_RUN_BLOCKED = (
        "Running custom scripts is not available. Use cog_debug to evaluate "
        "expressions at a breakpoint instead:\n\n"
        "  cog_debug breakpoint=\"file.py:line\" "
        "inspect=[\"expr1\", \"expr2\"] "
        "test=\"python -m pytest tests/... -xvs\""
    )

    def handle_action(self, step: StepOutput) -> StepOutput:
        """Intercept cog_debug tool calls; hard-gate unwanted actions."""
        self._step_count += 1

        if self._is_cog_debug_call(step):
            self._cog_debug_called = True
            return self._handle_cog_debug(step)

        # --- Hard gate: python3 -c / python -c ---
        if self._is_python_c_command(step):
            step.observation = self._PYTHON_C_BLOCKED
            try:
                step.state = self.tools.get_state(env=self._env)
            except Exception:
                pass
            self._log("blocked python3 -c at step %d", self._step_count)
            return step

        # --- Hard gate: script creation ---
        script_create_path = self._is_script_create(step)
        if script_create_path:
            step.observation = self._SCRIPT_CREATE_REDIRECT
            try:
                step.state = self.tools.get_state(env=self._env)
            except Exception:
                pass
            self._log("blocked script creation %s at step %d", script_create_path, self._step_count)
            return step

        # --- Hard gate: running custom scripts ---
        if self._is_custom_script_run(step):
            step.observation = self._SCRIPT_RUN_BLOCKED
            try:
                step.state = self.tools.get_state(env=self._env)
            except Exception:
                pass
            self._log("blocked custom script run at step %d", self._step_count)
            return step

        # Detect source edit before processing
        is_source_edit = self._is_source_edit(step)

        step = super().handle_action(step)

        # Exploration reminder: once, after N steps, if cog_debug hasn't been used yet
        if (
            not self._cog_debug_called
            and not self._reminder_sent
            and self._step_count >= self.COG_DEBUG_REMINDER_STEP
        ):
            self._reminder_sent = True
            if step.observation:
                step.observation += self._COG_DEBUG_REMINDER
            self._log("injected exploration reminder at step %d", self._step_count)

        # Verification reminder: after each source edit, up to MAX_VERIFY_REMINDERS
        if is_source_edit and self._verify_reminder_count < self.MAX_VERIFY_REMINDERS:
            self._source_edited = True
            self._verify_reminder_count += 1
            if step.observation:
                step.observation += self._COG_DEBUG_VERIFY_REMINDER
            self._log("injected verification reminder #%d at step %d", self._verify_reminder_count, self._step_count)

        return step

    def _is_source_edit(self, step: StepOutput) -> bool:
        """Check if this step edits project source (not creating a new test file)."""
        if not step.tool_calls:
            return False
        for tc in step.tool_calls:
            fn = tc.get("function", {})
            if fn.get("name") != "str_replace_editor":
                continue
            args = fn.get("arguments", {})
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except (json.JSONDecodeError, TypeError):
                    continue
            # Only str_replace (actual edits), not view or create
            if args.get("command") != "str_replace":
                continue
            # Skip files that look like agent-created test scripts
            path = args.get("path", "")
            basename = path.rsplit("/", 1)[-1] if "/" in path else path
            if basename.startswith("test_") or basename.startswith("reproduce"):
                continue
            return True
        return False

    def _is_script_create(self, step: StepOutput) -> str | None:
        """Check if this step creates a script file. Returns the path or None."""
        if not step.tool_calls:
            return None
        for tc in step.tool_calls:
            fn = tc.get("function", {})
            if fn.get("name") != "str_replace_editor":
                continue
            args = fn.get("arguments", {})
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except (json.JSONDecodeError, TypeError):
                    continue
            if args.get("command") != "create":
                continue
            path = args.get("path", "")
            basename = path.rsplit("/", 1)[-1] if "/" in path else path
            if self._SCRIPT_FILENAME_RE.match(basename):
                return path
        return None

    def _is_python_c_command(self, step: StepOutput) -> bool:
        """Check if this step runs a python3 -c or python -c command."""
        cmd = self._get_bash_command(step)
        if not cmd:
            return False
        return bool(re.search(r'\bpython3?\s+-c\b', cmd))

    def _is_custom_script_run(self, step: StepOutput) -> bool:
        """Check if this step runs a script the agent previously created."""
        cmd = self._get_bash_command(step)
        if not cmd:
            return False
        # Check if the command runs any of the agent's created scripts
        for script_path in self._created_scripts:
            if script_path in cmd:
                return True
        # Also match pattern: python3 /app/test_*.py, python3 /app/reproduce_*.py, etc.
        if re.search(r'\bpython3?\s+\S*(test_|reproduce|debug_|check_|verify_|script_)\S*\.py\b', cmd):
            # Exclude pytest invocations on existing test suites
            if 'pytest' not in cmd and '-m pytest' not in cmd:
                return True
        return False

    def _get_bash_command(self, step: StepOutput) -> str | None:
        """Extract the bash command string from a step, if it's a bash call."""
        if step.tool_calls:
            for tc in step.tool_calls:
                fn = tc.get("function", {})
                if fn.get("name") == "bash":
                    args = fn.get("arguments", {})
                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except (json.JSONDecodeError, TypeError):
                            return None
                    return args.get("command", "")
        # Fallback: check action string for bash commands
        if step.action and not step.action.strip().startswith("cog_debug"):
            return step.action
        return None

    def _is_cog_debug_call(self, step: StepOutput) -> bool:
        """Check if this step is a cog_debug tool call."""
        # Check structured tool_calls first (function calling mode)
        if step.tool_calls:
            for tc in step.tool_calls:
                fn = tc.get("function", {})
                if fn.get("name") == "cog_debug":
                    return True
        # Fallback: check action string
        if step.action and step.action.strip().startswith("cog_debug"):
            return True
        return False

    def _extract_cog_debug_args(self, step: StepOutput) -> dict:
        """Extract cog_debug arguments from the tool call."""
        if step.tool_calls:
            for tc in step.tool_calls:
                fn = tc.get("function", {})
                if fn.get("name") == "cog_debug":
                    args = fn.get("arguments", {})
                    if isinstance(args, str):
                        args = json.loads(args)
                    return args
        # Fallback: can't reliably parse from action string
        return {}

    @staticmethod
    def _read_log_tail(log_path: Path, pos_before: int) -> str:
        """Read new content appended to a log file since pos_before."""
        try:
            if not log_path.exists():
                return ""
            size = log_path.stat().st_size
            if size <= pos_before:
                return ""
            with open(log_path, "r", errors="replace") as f:
                f.seek(pos_before)
                return f.read().strip()
        except Exception:
            return ""

    def _log(self, msg: str, *args):
        """Log to both the Python logger and stderr (print) for visibility."""
        formatted = msg % args if args else msg
        logger.info(formatted)
        print(f"[CogDebugAgent] {formatted}", flush=True)

    @staticmethod
    def _strip_shell_operators(cmd: str) -> str:
        """Strip shell redirections and take only the first command from compound expressions.

        Handles patterns like:
        - "pytest tests/... 2>/dev/null"         → "pytest tests/..."
        - "pytest tests/... || python3 -c ..."   → "pytest tests/..."
        - "cmd1 | cmd2"                          → "cmd1"
        """
        # Remove shell redirections: 2>/dev/null, >/dev/null, 2>&1, &>/dev/null
        cmd = re.sub(r'\s+\d*>(?:&\d+|/dev/null)\s*', ' ', cmd)
        cmd = re.sub(r'\s+&>/dev/null\s*', ' ', cmd)

        # Take only the first command before || or | (but not inside quotes)
        # We use a simple approach: split on unquoted || and |
        # First handle ||
        depth = 0
        for i, ch in enumerate(cmd):
            if ch in ('"', "'"):
                # Simple toggle — doesn't handle escaped quotes but good enough
                depth = 1 - depth
            elif depth == 0 and cmd[i:i+2] == '||':
                cmd = cmd[:i].strip()
                break

        # Then handle single | (pipe)
        depth = 0
        for i, ch in enumerate(cmd):
            if ch in ('"', "'"):
                depth = 1 - depth
            elif depth == 0 and ch == '|' and (i + 1 >= len(cmd) or cmd[i + 1] != '|'):
                cmd = cmd[:i].strip()
                break

        return cmd.strip()

    @staticmethod
    def _parse_test_command(test_cmd: str) -> dict:
        """Parse a test command string into launch args for cog_debug_launch.

        The DAP protocol requires `program` to be the script path (not the
        interpreter) and `module` for `-m` invocations.  This method strips
        the interpreter prefix and extracts module/script accordingly.

        Handles patterns like:
        - "cd /app && python3 test_file.py"          → program=test_file.py
        - "python -m pytest tests/test_foo.py -xvs"  → module=pytest, args=[...]
        - "python3 -c 'code'"                        → inline_code=... (written to container later)
        - "pytest ... 2>/dev/null || python3 -c ..."  → module=pytest, args=[...]
        """
        cwd = "/app"  # default
        cmd = test_cmd.strip()

        # Extract cwd from "cd <dir> &&" prefix
        cd_match = re.match(r'cd\s+(\S+)\s*&&\s*(.*)', cmd)
        if cd_match:
            cwd = cd_match.group(1)
            cmd = cd_match.group(2).strip()

        # Strip shell redirections and compound operators before tokenizing
        cmd = CogDebugAgent._strip_shell_operators(cmd)

        # Split the remaining command into tokens
        try:
            tokens = shlex.split(cmd)
        except ValueError:
            tokens = cmd.split()

        if not tokens:
            return {"program": "python3", "args": [], "cwd": cwd}

        # Filter out any remaining redirect-like tokens that survived
        tokens = [t for t in tokens if not re.match(r'^\d*>[>&]', t)]

        # Check if the first token is a python interpreter
        is_python = tokens[0] in ("python", "python3", "/usr/bin/python", "/usr/bin/python3")

        if is_python and len(tokens) > 1:
            rest = tokens[1:]
            if rest[0] == "-m" and len(rest) > 1:
                # "python -m pytest tests/... -xvs" → module mode
                return {"module": rest[1], "args": rest[2:], "cwd": cwd}
            elif rest[0] == "-c" and len(rest) > 1:
                # "python -c 'code'" → needs to be written to a file inside
                # the container (returned as inline_code for the caller to handle)
                return {"inline_code": rest[1], "args": rest[2:], "cwd": cwd}
            else:
                # "python3 test_file.py arg1 arg2" → script mode
                return {"program": rest[0], "args": rest[1:], "cwd": cwd}

        # Not a python interpreter — use as-is
        return {"program": tokens[0], "args": tokens[1:], "cwd": cwd}

    def _handle_cog_debug(self, step: StepOutput) -> StepOutput:
        """Execute cog_debug by spawning a Claude subagent with cog MCP."""
        args = self._extract_cog_debug_args(step)

        breakpoint_loc = args.get("breakpoint", "")
        inspect_exprs = args.get("inspect", [])
        test_cmd = args.get("test", "")
        condition = args.get("condition", "")

        if not breakpoint_loc or not inspect_exprs or not test_cmd:
            step.observation = (
                "ERROR: cog_debug requires breakpoint, inspect, and test arguments. "
                f"Got: breakpoint={breakpoint_loc!r}, inspect={inspect_exprs!r}, test={test_cmd!r}"
            )
            return step

        # Build subagent prompt with clear instructions for using MCP debug tools
        condition_line = ""
        if condition:
            condition_line = f"\n   condition: \"{condition}\""

        # Pre-parse the test command so the subagent doesn't have to figure it out
        launch_args = self._parse_test_command(test_cmd)

        # Handle inline code: write it to a file inside the container
        if "inline_code" in launch_args:
            container_script = "/tmp/_cog_debug_inline.py"
            try:
                # Escape the code for shell and write inside the container
                escaped = launch_args["inline_code"].replace("'", "'\\''")
                self._env.communicate(
                    f"printf '%s' '{escaped}' > {container_script}"
                )
                launch_args = {
                    "program": container_script,
                    "args": launch_args.get("args", []),
                    "cwd": launch_args["cwd"],
                }
            except Exception as e:
                self._log("failed to write inline code to container: %s", e)
                step.observation = f"[cog_debug error] Failed to write inline code to container: {e}"
                return step

        # Build launch JSON for the subagent (exact args to pass to cog_debug_launch)
        if "module" in launch_args:
            launch_json = json.dumps({
                "module": launch_args["module"],
                "args": launch_args["args"],
                "cwd": launch_args["cwd"],
            }, indent=2)
        else:
            launch_json = json.dumps({
                "program": launch_args["program"],
                "args": launch_args["args"],
                "cwd": launch_args["cwd"],
            }, indent=2)

        # Pre-build the inspect JSON calls so the subagent can copy-paste them
        expr_list = inspect_exprs
        inspect_calls_json = "\n".join(
            f'   - cog_debug_inspect with: session_id="session-1", expression={json.dumps(e)}, frame_id=0'
            for e in expr_list
        )

        subagent_prompt = f"""You are a debugging agent with MCP tools that control a debugger inside a Docker container.

RULES:
- ONLY use the cog_debug MCP tools. No bash, no local commands.
- If any step fails, report the error, call cog_debug_stop, and stop.
- NEVER pass "python3" or "python" as the program argument.
- ALWAYS use frame_id=0 for inspect calls. Do NOT try other frame IDs.
- Do NOT call scope="locals". Only inspect the specific expressions listed below.

Execute these steps IN ORDER:

1. cog_debug_launch with EXACTLY:
```json
{launch_json}
```

2. cog_debug_breakpoint with: session_id="session-1", file and line from "{breakpoint_loc}"{condition_line}

3. cog_debug_run with: session_id="session-1", action="continue", timeout_ms=15000

4. Check stop_reason from the result:
   - "breakpoint" → call ALL of these inspects IN A SINGLE PARALLEL TOOL CALL (do NOT call them one at a time):
{inspect_calls_json}
   - "exited" → report "BREAKPOINT NOT HIT" with the exit_code
   - "exception" → report the exception text
   - anything else → report the stop_reason

5. cog_debug_stop with: session_id="session-1"

Output ONLY the raw expression values. No analysis."""

        if not self._container_id:
            step.observation = "ERROR: No Docker container discovered. Cannot run cog debug subagent."
            return step

        mcp_config_path = str(Path(self._tmp_dir.name) / "mcp_config.json")

        self._log(
            "spawning subagent — breakpoint=%s inspect=%s test=%s launch=%s",
            breakpoint_loc, inspect_exprs, test_cmd, launch_args,
        )

        # Use file-based capture so output survives process kill on timeout
        stdout_path = Path(self._tmp_dir.name) / f"subagent_stdout_{self._step_count}.log"
        stderr_path = Path(self._tmp_dir.name) / f"subagent_stderr_{self._step_count}.log"

        # Record cog log positions before the call so we can read only new content
        mcp_log = Path("/tmp/cog-mcp.log")
        dap_log = Path("/tmp/cog-dap-debug.log")
        mcp_pos_before = mcp_log.stat().st_size if mcp_log.exists() else 0
        dap_pos_before = dap_log.stat().st_size if dap_log.exists() else 0

        try:
            env = {
                k: v for k, v in os.environ.items()
                if k not in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT")
            }
            env["SWEBENCH_CONTAINER"] = self._container_id
            bin_dir = str(Path(self._tmp_dir.name) / "bin")
            env["PATH"] = bin_dir + ":" + env.get("PATH", "")

            with open(stdout_path, "w") as stdout_f, open(stderr_path, "w") as stderr_f:
                proc = subprocess.Popen(
                    [
                        "claude", "-p", subagent_prompt,
                        "--model", "claude-sonnet-4-6",
                        "--dangerously-skip-permissions",
                        "--strict-mcp-config",
                        "--mcp-config", mcp_config_path,
                    ],
                    stdout=stdout_f,
                    stderr=stderr_f,
                    text=True,
                    cwd=self._tmp_dir.name,
                    env=env,
                )

                try:
                    returncode = proc.wait(timeout=90)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                    returncode = None

            # Read captured output from files (survives process kill)
            stdout_content = stdout_path.read_text().strip() if stdout_path.exists() else ""
            stderr_content = stderr_path.read_text().strip() if stderr_path.exists() else ""

            # Read new cog DAP/MCP logs since before the call
            new_mcp_log = self._read_log_tail(mcp_log, mcp_pos_before)
            new_dap_log = self._read_log_tail(dap_log, dap_pos_before)

            if returncode is None:
                # Timeout — dump everything for diagnosis
                self._log("subagent TIMEOUT after 90s")
                self._log("  stdout (%d bytes): %s", len(stdout_content), stdout_content[:1000] or "(empty)")
                self._log("  stderr (%d bytes): %s", len(stderr_content), stderr_content[:1000] or "(empty)")
                if new_mcp_log:
                    self._log("  cog-mcp.log (new): %s", new_mcp_log[:2000])
                if new_dap_log:
                    self._log("  cog-dap-debug.log (new): %s", new_dap_log[:2000])
                step.observation = (
                    f"[cog_debug timeout] Subagent timed out after 90s.\n"
                    f"Partial stdout: {stdout_content[:500]}\n"
                    f"Partial stderr: {stderr_content[:500]}"
                )
            elif returncode == 0:
                output = stdout_content or "(subagent returned no output)"
                if stderr_content:
                    self._log("subagent OK — stderr: %s", stderr_content[:500])
                if new_dap_log:
                    self._log("subagent OK — dap log: %s", new_dap_log[:500])
                step.observation = f"[cog_debug result]\n{output}"
            else:
                self._log("subagent FAILED (rc=%d)", returncode)
                self._log("  stdout: %s", stdout_content[:500] or "(empty)")
                self._log("  stderr: %s", stderr_content[:500] or "(empty)")
                if new_mcp_log:
                    self._log("  cog-mcp.log (new): %s", new_mcp_log[:1000])
                if new_dap_log:
                    self._log("  cog-dap-debug.log (new): %s", new_dap_log[:1000])
                step.observation = (
                    f"[cog_debug error] Subagent exited with code {returncode}.\n"
                    f"stdout: {stdout_content[:500]}\n"
                    f"stderr: {stderr_content[:500]}"
                )

        except FileNotFoundError:
            step.observation = "[cog_debug error] 'claude' CLI not found. Is it installed?"
        except Exception as e:
            self._log("subagent exception: %s: %s", type(e).__name__, e)
            step.observation = f"[cog_debug error] {type(e).__name__}: {e}"

        # Get state for consistency with normal flow
        try:
            step.state = self.tools.get_state(env=self._env)
        except Exception:
            pass

        return step
