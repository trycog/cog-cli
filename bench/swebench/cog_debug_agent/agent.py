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

        # Install debugpy in the container (required by cog MCP debug tools).
        # Try pip first; fall back to uv pip for containers where uv-managed
        # Python lacks pip (e.g. Python 3.9 images that needed uv for swerex).
        if self._container_id:
            try:
                result = self._env.communicate(
                    "python3 -m pip install --index-url https://pypi.org/simple/ -q debugpy 2>&1"
                    " || ((command -v uv >/dev/null 2>&1 || (curl -LsSf https://astral.sh/uv/install.sh | INSTALLER_NO_MODIFY_PATH=1 sh))"
                    " && ~/.local/bin/uv pip install --system debugpy 2>&1)"
                )
                self._log("debugpy install output: %s", result.strip())
            except Exception as e:
                self._log("WARNING: failed to install debugpy: %s", e)

        # Create temp directory for wrapper scripts and MCP config
        self._tmp_dir = tempfile.TemporaryDirectory(prefix="cog_debug_")
        if self._container_id:
            self._create_python3_wrapper()
            self._create_mcp_config()

        # Discover test commands and entry points, then inject into history
        if self._container_id:
            test_info = self._discover_test_info()
            if test_info:
                self._append_history({
                    "role": "user",
                    "content": test_info,
                    "agent": self.name,
                    "message_type": "observation",
                })
                self._log("injected test discovery info (%d chars)", len(test_info))

    def _discover_test_info(self) -> str:
        """Discover available test commands and entry points in the container.

        Returns a string to inject into the conversation history, or empty string.
        """
        parts = []

        # 1. Find test directories and sample test files
        try:
            test_files = self._env.communicate(
                "find /app -path '*/test*' -name 'test_*.py' -type f 2>/dev/null"
                " | head -20"
            ).strip()
            if test_files:
                # Group by directory
                dirs = {}
                for f in test_files.split("\n"):
                    f = f.strip()
                    if not f:
                        continue
                    d = f.rsplit("/", 1)[0] if "/" in f else "."
                    dirs.setdefault(d, []).append(f.rsplit("/", 1)[-1])
                if dirs:
                    lines = ["**Available test files** (use with `python -m pytest <path> -xvs`):"]
                    for d, files in sorted(dirs.items()):
                        lines.append(f"  {d}/: {', '.join(files[:5])}" + (" ..." if len(files) > 5 else ""))
                    parts.append("\n".join(lines))
        except Exception as e:
            self._log("WARNING: test file discovery failed: %s", e)

        # 2. Find console_scripts entry points (e.g. ansible-playbook)
        try:
            entry_points = self._env.communicate(
                "python3 -c \""
                "import importlib.metadata as md;"
                "eps = [ep for ep in md.entry_points().get('console_scripts', []) "
                "if not ep.name.startswith('_')];"
                "[print(f'{ep.name} -> python -m {ep.value.split(\\\":\\\")[0]}') "
                "for ep in eps[:15]]"
                "\" 2>/dev/null"
            ).strip()
            if entry_points:
                parts.append(
                    "**Entry point commands** (for cog_debug test= argument, use the `python -m` form):\n"
                    + entry_points
                )
        except Exception as e:
            self._log("WARNING: entry point discovery failed: %s", e)

        if not parts:
            return ""

        return (
            "[Environment Info] The following test commands and entry points are available "
            "in this repository. Use these with cog_debug:\n\n"
            + "\n\n".join(parts)
        )

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

        # Smart-truncate large observations (e.g., pytest assertion dumps with
        # full base64 certificate data). SWE-agent has max_observation_length but
        # it clips blindly. We extract the useful parts first.
        if step.observation and len(step.observation) > 3000:
            step.observation = self._truncate_observation(step.observation)

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

    def _extract_subagent_output(self, stdout_content: str, mcp_log: str) -> str:
        """Extract meaningful output from subagent, with JSON parsing and MCP log fallback.

        The subagent runs with --output-format json. Try to extract text from
        the JSON response first. If the model produced no text, fall back to
        parsing the MCP log for cog_debug_run results.
        """
        # Try parsing JSON output from claude --output-format json
        text_output = ""
        if stdout_content:
            try:
                result = json.loads(stdout_content)
                # JSON format: {"type":"result","subtype":"success","cost_usd":...,"result":"text",...}
                text_output = result.get("result", "").strip()
            except (json.JSONDecodeError, TypeError, AttributeError):
                # Not JSON — treat as plain text (shouldn't happen with --output-format json)
                text_output = stdout_content.strip()

        if text_output:
            return text_output

        # Fallback: extract result from MCP log
        self._log("subagent produced no text output, falling back to MCP log")
        fallback = self._extract_result_from_mcp_log(mcp_log)
        if fallback:
            return fallback

        return "(subagent returned no output — check cog-mcp.log for details)"

    @staticmethod
    def _extract_result_from_mcp_log(mcp_log: str) -> str:
        """Parse MCP log to extract cog_debug_run results as fallback output.

        When the subagent model produces no text, we can still find what
        happened by reading the MCP server's JSON-RPC responses.
        """
        if not mcp_log:
            return ""
        # Look for cog_debug_run result in the MCP log
        # The log format includes lines like: [timestamp] [DebugServer.callTool] Result: {"stop_reason":"exited","exit_code":0}
        # Also look for JSON-RPC response content
        stop_reason = ""
        exit_code = ""
        for line in mcp_log.split("\n"):
            if "stop_reason" in line:
                # Try to extract JSON from the line
                for segment in re.finditer(r'\{[^{}]*"stop_reason"[^{}]*\}', line):
                    try:
                        data = json.loads(segment.group())
                        stop_reason = data.get("stop_reason", "")
                        exit_code = data.get("exit_code", "")
                        break
                    except (json.JSONDecodeError, TypeError):
                        continue

        if stop_reason == "exited":
            return f"BREAKPOINT NOT HIT — exit_code: {exit_code}"
        elif stop_reason == "breakpoint":
            return "(breakpoint was hit but subagent did not report inspect results)"
        elif stop_reason == "exception":
            return f"Program raised an exception (stop_reason=exception)"
        elif stop_reason:
            return f"Unexpected stop_reason: {stop_reason}"
        return ""

    # Maximum observation size we'll pass to the model (chars).
    # SWE-agent's max_observation_length is a fallback clip; this is smarter.
    _MAX_OBSERVATION = 3000

    @staticmethod
    def _truncate_observation(obs: str) -> str:
        """Smart-truncate a large observation, preserving the most useful parts.

        For pytest output: extract the session header, FAILED/ERROR lines,
        the short test summary, and the final result line. Skip the huge
        assertion introspection dumps (e.g., full base64 certificate data).
        """
        max_len = CogDebugAgent._MAX_OBSERVATION

        # For pytest output, extract meaningful sections
        if "pytest" in obs or "FAILED" in obs or "PASSED" in obs or "test session starts" in obs:
            sections = []

            # 1. Session header (first few lines up to first test result)
            lines = obs.split("\n")
            header = []
            for line in lines[:15]:
                header.append(line)
                if "PASSED" in line or "FAILED" in line or "ERROR" in line or "RERUN" in line:
                    break
            sections.append("\n".join(header))

            # 2. Short test summary / FAILURES section
            # Look for "FAILURES" or "short test summary"
            for marker in ["= FAILURES =", "short test summary", "ERRORS"]:
                idx = obs.find(marker)
                if idx >= 0:
                    # Take up to 800 chars from this section
                    sections.append("...\n" + obs[idx:idx + 800])
                    break

            # 3. AssertionError line (the actual assertion that failed)
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("AssertionError") or stripped.startswith("assert ") or "AssertionError" in stripped:
                    sections.append(f"Assertion: {stripped[:300]}")
                    break
                # Also catch "E   assert" lines from pytest
                if stripped.startswith("E ") and "assert" in stripped:
                    sections.append(f"Assertion: {stripped[:300]}")
                    break

            # 4. Final summary line (e.g., "1 failed, 3 rerun in 0.16s")
            for line in reversed(lines[-10:]):
                if "passed" in line or "failed" in line or "error" in line:
                    sections.append(line.strip())
                    break

            result = "\n\n".join(sections)
            if len(result) < len(obs):
                result += f"\n\n[Observation truncated: {len(obs)} → {len(result)} chars]"
            return result[:max_len]

        # Generic truncation: keep first and last portions
        if len(obs) > max_len:
            half = max_len // 2 - 50
            return (
                obs[:half]
                + f"\n\n[... {len(obs) - max_len} chars truncated ...]\n\n"
                + obs[-half:]
            )

        return obs

    @staticmethod
    def _breakpoint_not_hit_guidance(observation: str, breakpoint_loc: str, test_cmd: str) -> str:
        """Generate actionable recovery guidance when a breakpoint is not hit.

        Parses the exit code from the observation and suggests specific next steps.
        """
        # Extract exit code from observation text
        exit_code = None
        m = re.search(r'exit_code:\s*(\d+)', observation)
        if m:
            exit_code = int(m.group(1))

        bp_file = breakpoint_loc.split(":")[0] if ":" in breakpoint_loc else ""

        guidance = "\n\n**What to try next:**\n"

        if exit_code == 4:
            # pytest "no tests collected"
            guidance += (
                "- exit_code 4 = pytest found no matching tests. "
                "The test name may not exist.\n"
            )
            if bp_file:
                # Suggest discovering tests near the breakpoint file
                test_dir = bp_file.rsplit("/", 1)[0] if "/" in bp_file else "."
                guidance += (
                    f"- Run: `grep -rn 'def test_' /app/test/ | head -20` to find available test functions\n"
                    f"- Or run: `python -m pytest --collect-only {test_dir}/ 2>/dev/null | head -30`\n"
                )
        elif exit_code == 1:
            guidance += (
                "- exit_code 1 = the test/program failed or errored before reaching your breakpoint line.\n"
                "- Try removing the `condition` argument (the condition may never be true in this test).\n"
                "- Try a different test that exercises the target code path.\n"
            )
        elif exit_code == 0:
            guidance += (
                "- exit_code 0 = the program completed successfully but never reached your breakpoint line.\n"
                "- The test may not exercise this code path. Try a different test.\n"
                "- Check that the breakpoint line number is correct (view the file first).\n"
            )
        else:
            guidance += (
                f"- exit_code {exit_code} = unexpected exit. Check the test command is valid.\n"
            )

        return guidance

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

    def _parse_test_command(self, test_cmd: str) -> dict:
        """Parse a test command string into launch args for cog_debug_launch.

        The DAP protocol requires `program` to be the script path (not the
        interpreter) and `module` for `-m` invocations.  This method strips
        the interpreter prefix and extracts module/script accordingly.

        For console_scripts entry points (e.g. ansible-playbook, pytest), auto-resolves
        to the module form by inspecting the wrapper script in the container.

        Handles patterns like:
        - "cd /app && python3 test_file.py"          → program=test_file.py
        - "python -m pytest tests/test_foo.py -xvs"  → module=pytest, args=[...]
        - "python3 -c 'code'"                        → inline_code=... (written to container later)
        - "pytest ... 2>/dev/null || python3 -c ..."  → module=pytest, args=[...]
        - "ansible-playbook pb.yml --tags test_tag"   → module=ansible.cli.playbook, args=[...]
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

        # Not a python interpreter — try to resolve as a console_scripts entry point.
        # Entry points like "ansible-playbook" are wrapper scripts generated by pip.
        # debugpy can't run them directly (run_path fails on the wrapper).
        # Resolve to module form: ansible-playbook → python -m ansible.cli.playbook
        program = tokens[0]
        if not program.endswith(".py") and self._container_id:
            module = self._resolve_entry_point(program)
            if module:
                self._log("resolved entry point %s → module %s", program, module)
                return {"module": module, "args": tokens[1:], "cwd": cwd}

        return {"program": tokens[0], "args": tokens[1:], "cwd": cwd}

    def _resolve_entry_point(self, command: str) -> str | None:
        """Resolve a console_scripts entry point to its Python module.

        Reads the wrapper script generated by pip/setuptools and extracts
        the module import. Returns the module name or None.
        """
        try:
            # Read the wrapper script to find the import
            script_content = self._env.communicate(
                f"cat $(which {shlex.quote(command)} 2>/dev/null) 2>/dev/null | head -20"
            ).strip()
            if not script_content:
                return None

            # pip-generated wrapper scripts have patterns like:
            #   from ansible.cli.playbook import main
            #   from pytest import console_main
            for line in script_content.split("\n"):
                line = line.strip()
                m = re.match(r'from\s+([\w.]+)\s+import\s+', line)
                if m:
                    module = m.group(1)
                    # Skip stdlib imports (sys, os, re, etc.)
                    if module.split(".")[0] not in ("sys", "os", "re", "importlib", "pkg_resources"):
                        return module

            return None
        except Exception as e:
            self._log("WARNING: entry point resolution failed for %s: %s", command, e)
            return None

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

        # Build launch JSON for the subagent (exact args to pass to cog_debug_launch).
        # Always include language="python" so cog uses the DAP/debugpy driver
        # even for entry-point scripts like ansible-playbook that lack a .py extension.
        if "module" in launch_args:
            launch_json = json.dumps({
                "module": launch_args["module"],
                "args": launch_args["args"],
                "cwd": launch_args["cwd"],
                "language": "python",
            }, indent=2)
        else:
            launch_json = json.dumps({
                "program": launch_args["program"],
                "args": launch_args["args"],
                "cwd": launch_args["cwd"],
                "language": "python",
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
- CRITICAL: You MUST end with a text response. NEVER end with only tool calls.

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
   - "exited" → you MUST respond with text: "BREAKPOINT NOT HIT — exit_code: <N>"
   - "exception" → you MUST respond with the exception text
   - anything else → you MUST respond with the stop_reason

5. cog_debug_stop with: session_id="session-1"

6. MANDATORY: Write a text response with the results. For breakpoint hits, output the raw expression values. For exits, output "BREAKPOINT NOT HIT — exit_code: <N>". NEVER skip this step."""

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
                        "--output-format", "json",
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
                output = self._extract_subagent_output(stdout_content, new_mcp_log)
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

        # Enrich "BREAKPOINT NOT HIT" with actionable recovery guidance
        if step.observation and "BREAKPOINT NOT HIT" in step.observation:
            step.observation += self._breakpoint_not_hit_guidance(
                step.observation, breakpoint_loc, test_cmd
            )

        # Get state for consistency with normal flow
        try:
            step.state = self.tools.get_state(env=self._env)
        except Exception:
            pass

        return step
