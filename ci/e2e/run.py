#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import traceback
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import ensure_directory, write_text_file
from testcases.tc0001_basic_resync import TestCase0001BasicResync
from testcases.tc0002_sync_list_validation import TestCase0002SyncListValidation


def build_test_suite() -> list:
    """
    Return the ordered list of E2E test cases to execute.

    Add future test cases here in the required execution order.
    """
    return [
        TestCase0001BasicResync(),
        TestCase0002SyncListValidation(),
    ]


def result_to_actions_case(result: TestResult) -> dict:
    """
    Convert the internal TestResult into the JSON structure expected by the
    GitHub Actions workflow summary/reporting logic.
    """
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


def main() -> int:
    context = E2EContext.from_environment()
    ensure_directory(context.out_dir)
    ensure_directory(context.logs_dir)
    ensure_directory(context.state_dir)
    ensure_directory(context.work_root)

    context.log(
        f"Initialising E2E framework for target='{context.e2e_target}', "
        f"run_id='{context.run_id}'"
    )

    cases = []
    failed = False

    for testcase in build_test_suite():
        context.log(f"Starting test case {testcase.case_id}: {testcase.name}")

        try:
            result = testcase.run(context)

            if result.case_id != testcase.case_id:
                raise RuntimeError(
                    f"Test case returned mismatched case_id: "
                    f"expected '{testcase.case_id}', got '{result.case_id}'"
                )

            cases.append(result_to_actions_case(result))

            if result.status != "pass":
                failed = True
                context.log(
                    f"Test case {testcase.case_id} FAILED: {result.reason or 'no reason provided'}"
                )
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
                details={
                    "exception_type": type(exc).__name__,
                },
            )
            cases.append(result_to_actions_case(failure_result))

    results = {
        "target": context.e2e_target,
        "run_id": context.run_id,
        "cases": cases,
    }

    results_file = context.out_dir / "results.json"
    results_json = json.dumps(results, indent=2, sort_keys=False)
    write_text_file(results_file, results_json)

    context.log(f"Wrote results to {results_file}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())