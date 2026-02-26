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

# ── Patch 1: Fix /bin/sh -> /bin/bash for Apple Silicon emulation ──────────
#
# SWE-bench Pro Docker images use dash as /bin/sh. Dash cannot execute under
# QEMU/Rosetta amd64 emulation on Apple Silicon Macs. /bin/bash works fine.
# SWE-ReX hardcodes "/bin/sh" in _get_swerex_start_cmd() with no config option.

import platform
if platform.machine() == "arm64":
    from swerex.deployment import docker as _docker_module

    _original_get_swerex_start_cmd = _docker_module.DockerDeployment._get_swerex_start_cmd

    def _patched_get_swerex_start_cmd(self, token):
        result = _original_get_swerex_start_cmd(self, token)
        # Replace /bin/sh with /bin/bash in the command list
        if result and result[0] == "/bin/sh":
            result = ["/bin/bash"] + result[1:]
        return result

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
