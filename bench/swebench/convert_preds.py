#!/usr/bin/env python3
"""Convert SWE-agent prediction output to our JSONL evaluation format.

SWE-agent produces per-instance .pred files and a merged preds.json (dict keyed by
instance_id). Our evaluate.sh expects predictions/{variant}.jsonl with one JSON
object per line: {"instance_id": "...", "model_name_or_path": "...", "model_patch": "..."}.

Usage:
    python3 bench/swebench/convert_preds.py <variant> <sweagent_output_dir>

    # Example:
    python3 bench/swebench/convert_preds.py baseline trajectories/user/baseline__claude-opus/
    python3 bench/swebench/convert_preds.py debugger-subagent trajectories/user/debugger-subagent__claude-opus/

Output: predictions/{variant}.jsonl
"""

import json
import os
import sys
from pathlib import Path


def find_preds_json(output_dir: Path) -> Path | None:
    """Find preds.json in the SWE-agent output directory."""
    # Direct path
    direct = output_dir / "preds.json"
    if direct.exists():
        return direct
    # Search one level down
    for p in output_dir.rglob("preds.json"):
        return p
    return None


def collect_pred_files(output_dir: Path) -> dict:
    """Collect individual .pred files from SWE-agent output."""
    preds = {}
    for pred_file in output_dir.rglob("*.pred"):
        try:
            with open(pred_file) as f:
                pred = json.load(f)
            iid = pred.get("instance_id", "")
            if iid and pred.get("model_patch"):
                preds[iid] = pred
        except (json.JSONDecodeError, KeyError) as e:
            print(f"  warning: skipping {pred_file}: {e}", file=sys.stderr)
    return preds


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 convert_preds.py <variant> <sweagent_output_dir>", file=sys.stderr)
        sys.exit(1)

    variant = sys.argv[1]
    output_dir = Path(sys.argv[2])

    if not output_dir.exists():
        print(f"ERROR: Output directory not found: {output_dir}", file=sys.stderr)
        sys.exit(1)

    script_dir = Path(__file__).parent
    predictions_dir = script_dir / "predictions"
    predictions_dir.mkdir(exist_ok=True)

    # Try preds.json first, then individual .pred files
    preds = {}
    preds_json = find_preds_json(output_dir)
    if preds_json:
        print(f"Loading {preds_json}...", file=sys.stderr)
        with open(preds_json) as f:
            raw = json.load(f)
        # preds.json is a dict keyed by instance_id
        if isinstance(raw, dict):
            for iid, pred in raw.items():
                if pred.get("model_patch"):
                    preds[iid] = pred
        elif isinstance(raw, list):
            for pred in raw:
                iid = pred.get("instance_id", "")
                if iid and pred.get("model_patch"):
                    preds[iid] = pred
    else:
        print(f"No preds.json found, collecting .pred files...", file=sys.stderr)
        preds = collect_pred_files(output_dir)

    if not preds:
        print(f"WARNING: No predictions found in {output_dir}", file=sys.stderr)
        sys.exit(0)

    # Write JSONL
    jsonl_path = predictions_dir / f"{variant}.jsonl"
    with open(jsonl_path, "w") as f:
        for iid in sorted(preds.keys()):
            pred = preds[iid]
            entry = {
                "instance_id": pred.get("instance_id", iid),
                "model_name_or_path": pred.get("model_name_or_path", f"cog-swebench-{variant}"),
                "model_patch": pred["model_patch"],
            }
            f.write(json.dumps(entry) + "\n")

    print(f"Wrote {len(preds)} predictions to {jsonl_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
