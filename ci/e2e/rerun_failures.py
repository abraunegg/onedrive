#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def _normalise_case_id(value: str) -> str:
    text = value.strip()
    if text.lower().startswith("tc"):
        text = text[2:]
    if text.isdigit() and len(text) <= 4:
        text = text.zfill(4)
    return text


def _extract_failed_plan(results: dict) -> tuple[list[str], dict[str, list[str]]]:
    failed_cases: list[str] = []
    scenario_filters: dict[str, list[str]] = {}

    for case in results.get("cases", []):
        if case.get("status") == "pass":
            continue

        case_id = _normalise_case_id(str(case.get("id", "")))
        if not case_id or case_id == "0000":
            continue

        failed_cases.append(case_id)
        details = case.get("details") or {}

        failed_scenario_ids = details.get("failed_scenario_ids")
        if isinstance(failed_scenario_ids, list):
            filtered = [str(value).strip() for value in failed_scenario_ids if str(value).strip()]
            if filtered:
                scenario_filters[case_id] = filtered

    return sorted(set(failed_cases)), dict(sorted(scenario_filters.items()))


def main() -> int:
    parser = argparse.ArgumentParser(description="Automatically rerun failed E2E cases with debug enabled")
    parser.add_argument("--results", required=True, help="Path to the primary run results.json")
    parser.add_argument("--run-script", default="ci/e2e/run.py", help="Path to the E2E run.py entrypoint")
    parser.add_argument("--output-subdir", default="debug-rerun", help="Output subdirectory under ci/e2e/out for rerun artifacts")
    parser.add_argument("--run-label", default="debug-rerun", help="Logical label for the rerun")
    parser.add_argument("--skip-suite-cleanup", action="store_true", help="Skip suite cleanup during the debug rerun")
    parser.add_argument("--plan-file", default="ci/e2e/out/debug_rerun_plan.json", help="Where to write the rerun plan JSON")
    args = parser.parse_args()

    results_path = Path(args.results)
    if not results_path.is_file():
        raise RuntimeError(f"Results file not found: {results_path}")

    results = json.loads(results_path.read_text(encoding="utf-8"))
    failed_cases, scenario_filters = _extract_failed_plan(results)

    plan = {
        "source_results": str(results_path),
        "failed_case_ids": failed_cases,
        "scenario_filters": scenario_filters,
        "output_subdir": args.output_subdir,
        "run_label": args.run_label,
        "skip_suite_cleanup": args.skip_suite_cleanup,
    }

    plan_file = Path(args.plan_file)
    plan_file.parent.mkdir(parents=True, exist_ok=True)
    plan_file.write_text(json.dumps(plan, indent=2, sort_keys=False) + "\n", encoding="utf-8")

    if not failed_cases:
        print("No failed E2E cases detected; skipping debug rerun")
        return 0

    command = [sys.executable, args.run_script, "--debug", "--output-subdir", args.output_subdir, "--run-label", args.run_label]
    if args.skip_suite_cleanup:
        command.append("--skip-suite-cleanup")
    command.extend(["--case-id", ",".join(failed_cases)])

    for case_id, scenario_ids in scenario_filters.items():
        command.extend(["--scenario", f"{case_id}:{','.join(scenario_ids)}"])

    print("Debug rerun plan written to:", plan_file)
    print("Executing:", " ".join(command))

    env = os.environ.copy()
    completed = subprocess.run(command, env=env, check=False)
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main())
