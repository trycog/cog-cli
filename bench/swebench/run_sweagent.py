#!/usr/bin/env python3
"""Wrapper to run SWE-agent with platform fixes and CogDebugAgent support.

This script applies two monkey-patches and then delegates to sweagent run-batch:

1. Fixes /bin/sh -> /bin/bash for SWE-bench Pro Docker images that ship dash as
   /bin/sh, which cannot execute under amd64 emulation on Apple Silicon.

2. When COG_DEBUG_AGENT=1 is set, patches the agent factory to use CogDebugAgent
   instead of DefaultAgent, enabling the cog_debug tool interception.

Usage:
    # Baseline (shell fix only):
    python3 bench/swebench/run_sweagent.py run-batch --config configs/baseline.yaml [...]

    # Debugger-subagent (shell fix + CogDebugAgent):
    COG_DEBUG_AGENT=1 COG_BIN=/path/to/cog python3 bench/swebench/run_sweagent.py run-batch --config configs/debugger-subagent.yaml [...]
"""

import os
import sys

# Ensure the bench/swebench directory is on the Python path so cog_debug_agent is importable
script_dir = os.path.dirname(os.path.abspath(__file__))
if script_dir not in sys.path:
    sys.path.insert(0, script_dir)

# ── Patch 1: Faster swe-rex install for containers without swerex-remote ───
#
# SWE-bench Pro images don't have swerex-remote pre-installed. The default
# fallback installs pipx then runs swe-rex through pipx, which is slow
# (especially under amd64 emulation on Apple Silicon). Replace with a direct
# pip install.

from swerex.deployment import docker as _docker_module
from swerex.deployment.docker import REMOTE_EXECUTABLE_NAME, PACKAGE_NAME

_original_get_swerex_start_cmd = _docker_module.DockerDeployment._get_swerex_start_cmd

def _patched_get_swerex_start_cmd(self, token):
    rex_args = f"--auth-token {token}"
    if self._config.python_standalone_dir:
        # Standalone Python path — use original logic
        return _original_get_swerex_start_cmd(self, token)
    # Try swerex-remote directly, fall back to pip install + run.
    # SWE-bench Pro images have pip configured to use a local PyPI mirror
    # (127.0.0.1:9876) that doesn't exist outside the evaluation harness,
    # so we must override the index URL to use real PyPI.
    cmd = (
        f"{REMOTE_EXECUTABLE_NAME} {rex_args} || "
        f"(python3 -m pip install --index-url https://pypi.org/simple/ -q {PACKAGE_NAME} "
        f"&& {REMOTE_EXECUTABLE_NAME} {rex_args})"
    )
    return ["/bin/bash", "-c", cmd]

_docker_module.DockerDeployment._get_swerex_start_cmd = _patched_get_swerex_start_cmd

# ── Patch 2: CogDebugAgent factory ────────────────────────────────────────

from sweagent.agent import agents as _agents_module
from sweagent.agent.agents import get_agent_from_config as _original_factory

from cog_debug_agent import CogDebugAgent


def patched_get_agent_from_config(config):
    """Extended agent factory that uses CogDebugAgent when COG_DEBUG_AGENT=1."""
    if getattr(config, "type", None) == "default":
        cog_bin = os.environ.get("COG_BIN", "cog")

        if os.environ.get("COG_DEBUG_AGENT") == "1":
            agent = CogDebugAgent.from_config(config)
            agent._cog_bin = cog_bin
            return agent

    return _original_factory(config)


_agents_module.get_agent_from_config = patched_get_agent_from_config

try:
    from sweagent.run import run_batch as _run_batch_module
    _run_batch_module.get_agent_from_config = patched_get_agent_from_config
except (ImportError, AttributeError):
    pass

try:
    from sweagent.run import run_single as _run_single_module
    _run_single_module.get_agent_from_config = patched_get_agent_from_config
except (ImportError, AttributeError):
    pass


if __name__ == "__main__":
    from sweagent.run.run import main
    main()
