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
from testcases.tc0003_dry_run_validation import TestCase0003DryRunValidation
from testcases.tc0004_single_directory_sync import TestCase0004SingleDirectorySync
from testcases.tc0005_force_sync_override import TestCase0005ForceSyncOverride
from testcases.tc0006_download_only import TestCase0006DownloadOnly
from testcases.tc0007_download_only_cleanup_local_files import TestCase0007DownloadOnlyCleanupLocalFiles
from testcases.tc0008_upload_only import TestCase0008UploadOnly
from testcases.tc0009_upload_only_no_remote_delete import TestCase0009UploadOnlyNoRemoteDelete
from testcases.tc0010_upload_only_remove_source_files import TestCase0010UploadOnlyRemoveSourceFiles
from testcases.tc0011_skip_file_validation import TestCase0011SkipFileValidation
from testcases.tc0012_skip_dir_validation import TestCase0012SkipDirValidation
from testcases.tc0013_skip_dotfiles_validation import TestCase0013SkipDotfilesValidation
from testcases.tc0014_skip_size_validation import TestCase0014SkipSizeValidation
from testcases.tc0015_skip_symlinks_validation import TestCase0015SkipSymlinksValidation
from testcases.tc0016_check_nosync_validation import TestCase0016CheckNosyncValidation
from testcases.tc0017_check_nomount_validation import TestCase0017CheckNomountValidation
from testcases.tc0018_recycle_bin_validation import TestCase0018RecycleBinValidation
from testcases.tc0019_logging_and_running_config import TestCase0019LoggingAndRunningConfig
from testcases.tc0020_monitor_mode_validation import TestCase0020MonitorModeValidation
from testcases.tc0021_resumable_transfers_validation import TestCase0021ResumableTransfersValidation
from testcases.tc0022_local_first_validation import TestCase0022LocalFirstValidation
from testcases.tc0023_bypass_data_preservation_validation import TestCase0023BypassDataPreservationValidation
from testcases.tc0024_big_delete_safeguard_validation import TestCase0024BigDeleteSafeguardValidation


def build_test_suite() -> list:
    """
    Return the ordered list of E2E test cases to execute.

    Add future test cases here in the required execution order.
    """
    return [
        #TestCase0001BasicResync(),
        #TestCase0002SyncListValidation(),
        #TestCase0003DryRunValidation(),
        #TestCase0004SingleDirectorySync(),
        #TestCase0005ForceSyncOverride(),
        #TestCase0006DownloadOnly(),
        #TestCase0007DownloadOnlyCleanupLocalFiles(),
        #TestCase0008UploadOnly(),
        #TestCase0009UploadOnlyNoRemoteDelete(),
        #TestCase0010UploadOnlyRemoveSourceFiles(),
        #TestCase0011SkipFileValidation(),
        #TestCase0012SkipDirValidation(),
        #TestCase0013SkipDotfilesValidation(),
        #TestCase0014SkipSizeValidation(),
        #TestCase0015SkipSymlinksValidation(),
        #TestCase0016CheckNosyncValidation(),
        #TestCase0017CheckNomountValidation(),
        #TestCase0018RecycleBinValidation(),
        #TestCase0019LoggingAndRunningConfig(),
        #TestCase0020MonitorModeValidation(),
        #TestCase0021ResumableTransfersValidation(),
        #TestCase0022LocalFirstValidation(),
        #TestCase0023BypassDataPreservationValidation(),
        TestCase0024BigDeleteSafeguardValidation(),
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