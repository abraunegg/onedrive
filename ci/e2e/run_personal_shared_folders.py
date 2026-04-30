#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import write_text_file
from testcases_personal_shared_folders.sfptc0001_clean_sync_pull_down import (
    SharedFolderPersonalTestCase0001CleanSyncPullDown,
)
from testcases_personal_shared_folders.sfptc0002_clean_monitor_pull_down import (
    SharedFolderPersonalTestCase0002CleanMonitorPullDown,
)
from testcases_personal_shared_folders.sfptc0003_sync_list_validation import (
    SharedFolderPersonalTestCase0003SyncListValidation,
)


def build_test_suite() -> list:
    return [
        SharedFolderPersonalTestCase0001CleanSyncPullDown(),
        SharedFolderPersonalTestCase0002CleanMonitorPullDown(),
        SharedFolderPersonalTestCase0003SyncListValidation(),
    ]


def _normalise_case_id(value: str) -> str:
    text = value.strip().lower()
    if not text:
        return ""
    if text.startswith("sfptc"):
        suffix = text[5:]
        if suffix.isdigit() and len(suffix) <= 4:
            return f"sfptc{suffix.zfill(4)}"
        return text
    if text.startswith("sfp"):
        suffix = text[3:]
        if suffix.isdigit() and len(suffix) <= 4:
            return f"sfptc{suffix.zfill(4)}"
        return text
    if text.isdigit() and len(text) <= 4:
        return f"sfptc{text.zfill(4)}"
    return text


def _apply_cli_overrides(args: argparse.Namespace) -> None:
    if args.debug:
        os.environ["E2E_DEBUG"] = "1"
    if args.output_subdir:
        os.environ["E2E_OUTPUT_SUBDIR"] = args.output_subdir
    if args.run_label:
        os.environ["E2E_RUN_LABEL"] = args.run_label

    if args.case_id:
        selected: list[str] = []
        for raw_value in args.case_id:
            for token in raw_value.split(","):
                case_id = _normalise_case_id(token)
                if case_id:
                    selected.append(case_id)
        if selected:
            os.environ["E2E_SELECTED_CASES"] = ",".join(sorted(set(selected)))


def _should_run_case(context: E2EContext, case_id: str) -> bool:
    if not context.selected_case_ids:
        return True
    return _normalise_case_id(case_id) in {_normalise_case_id(value) for value in context.selected_case_ids}


def result_to_actions_case(result: TestResult) -> dict:
    output = {
        "id": result.case_id,
        "name": result.name,
        "status": result.status,
    }
    if result.reason:
        output["reason"] = result.reason
    if result.artifacts:
        output["artifacts"] = result.artifacts
    if result.details:
        output["details"] = result.details
    return output


def _build_metadata(context: E2EContext, selected_case_ids: list[str], executed_case_ids: list[str]) -> dict:
    return {
        "target": context.e2e_target,
        "run_id": context.run_id,
        "run_label": context.run_label,
        "debug_enabled": context.debug_enabled,
        "suite_cleanup_enabled": False,
        "selected_case_ids": selected_case_ids,
        "executed_case_ids": executed_case_ids,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run OneDrive Personal Account Shared Folder E2E test cases")
    parser.add_argument("--case-id", action="append", help="Run only the specified shared-folder case id(s). Supports sfptc0001, sfp0001, or 0001.")
    parser.add_argument("--debug", action="store_true", help="Rerun with debug verbosity enabled")
    parser.add_argument("--output-subdir", help="Write results into ci/e2e/out/<subdir>")
    parser.add_argument("--run-label", help="Logical label for this run")
    args = parser.parse_args()

    _apply_cli_overrides(args)
    context = E2EContext.from_environment()
    context.prepare_runtime()

    if context.e2e_target != "personal-shared-folders":
        raise RuntimeError(
            "run_personal_shared_folders.py must be executed with E2E_TARGET=personal-shared-folders"
        )

    selected_case_ids = sorted(context.selected_case_ids)
    cases_to_run = [testcase for testcase in build_test_suite() if _should_run_case(context, testcase.case_id)]
    executed_case_ids = [testcase.case_id for testcase in cases_to_run]

    context.log(
        f"Initialising Personal Shared Folder E2E framework for target='{context.e2e_target}', "
        f"run_id='{context.run_id}', run_label='{context.run_label}', debug_enabled={context.debug_enabled}"
    )
    context.log("Suite-wide cleanup is intentionally disabled for Personal Shared Folder testing")

    cases = []
    failed = False

    for testcase in cases_to_run:
        context.log(f"Starting test case {testcase.case_id}: {testcase.name}")
        try:
            result = testcase.run(context)
            if result.case_id != testcase.case_id:
                raise RuntimeError(
                    f"Test case returned mismatched case_id: expected '{testcase.case_id}', got '{result.case_id}'"
                )
            cases.append(result_to_actions_case(result))
            if result.status != "pass":
                failed = True
                context.log(f"Test case {testcase.case_id} FAILED: {result.reason or 'no reason provided'}")
            else:
                context.log(f"Test case {testcase.case_id} PASSED")
        except Exception as exc:
            failed = True
            tb = traceback.format_exc()
            context.log(f"Unhandled exception in test case {testcase.case_id}: {exc}")
            context.log(tb)
            error_log = context.logs_dir / f"{testcase.case_id}_exception.log"
            write_text_file(error_log, tb)
            failure_result = TestResult(
                case_id=testcase.case_id,
                name=testcase.name,
                status="fail",
                reason=f"Unhandled exception: {exc}",
                artifacts=[str(error_log)],
                details={"exception_type": type(exc).__name__},
            )
            cases.append(result_to_actions_case(failure_result))

    results = {
        **_build_metadata(context, selected_case_ids, executed_case_ids),
        "cases": cases,
    }
    results_file = context.out_dir / "results.json"
    write_text_file(results_file, json.dumps(results, indent=2, sort_keys=False))
    context.log(f"Wrote results to {results_file}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
