#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


DATABASE_ARTIFACT_SUFFIXES = ("", "-wal", "-shm", "-journal")


def _normalise_case_id(value: str) -> str:
    text = value.strip()
    if text.lower().startswith("tc"):
        text = text[2:]
    if text.isdigit() and len(text) <= 4:
        text = text.zfill(4)
    return text


def _safe_relative_path(path: Path, base: Path) -> Path:
    try:
        return path.relative_to(base)
    except ValueError:
        return Path(path.name)


def _database_capture_roots(output_subdir: str) -> tuple[Path, Path]:
    repo_root = Path.cwd()
    target = os.environ.get("E2E_TARGET", "").strip() or "unknown-target"
    runner_temp = os.environ.get("RUNNER_TEMP", "/tmp").strip() or "/tmp"

    work_root = Path(runner_temp) / f"onedrive-e2e-{target}"
    out_dir = repo_root / "ci" / "e2e" / "out"

    if output_subdir.strip():
        safe_subdir = output_subdir.strip().replace("/", "_")
        work_root = work_root / safe_subdir
        out_dir = out_dir / output_subdir.strip()

    return work_root, out_dir


def _capture_debug_rerun_databases(output_subdir: str) -> list[dict[str, str]]:
    """
    Copy per-test/per-scenario OneDrive item databases from the debug rerun
    working area into ci/e2e/out so GitHub artifact upload preserves them.

    This is intentionally done in rerun_failures.py rather than individual
    testcases so every failed debug rerun can capture DB state consistently,
    regardless of account type or testcase implementation.
    """
    work_root, out_dir = _database_capture_roots(output_subdir)
    capture_root = out_dir / "database-captures"
    manifest_file = capture_root / "database-captures.json"
    captured: list[dict[str, str]] = []

    if not work_root.exists():
        print(f"Database capture skipped; debug work root not found: {work_root}")
        return captured

    capture_root.mkdir(parents=True, exist_ok=True)

    for db_path in sorted(work_root.rglob("items.sqlite3")):
        if not db_path.is_file():
            continue

        rel_db_path = _safe_relative_path(db_path, work_root)
        dest_dir = capture_root / rel_db_path.parent
        dest_dir.mkdir(parents=True, exist_ok=True)

        related_files: list[str] = []
        for suffix in DATABASE_ARTIFACT_SUFFIXES:
            source = Path(str(db_path) + suffix)
            if not source.is_file():
                continue

            destination = dest_dir / source.name
            shutil.copy2(source, destination)
            related_files.append(str(destination))

        if related_files:
            captured.append(
                {
                    "source_database": str(db_path),
                    "relative_database": str(rel_db_path),
                    "captured_files": related_files,
                }
            )

    manifest_file.write_text(json.dumps(captured, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(f"Captured {len(captured)} debug rerun database(s) into: {capture_root}")
    print(f"Database capture manifest written to: {manifest_file}")
    return captured


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
    _capture_debug_rerun_databases(args.output_subdir)
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main())
