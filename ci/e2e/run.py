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
from framework.utils import ensure_directory, perform_full_account_cleanup, write_text_file
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
from testcases.tc0025_invalid_character_filename_validation import TestCase0025InvalidCharacterFilenameValidation
from testcases.tc0026_reserved_device_name_validation import TestCase0026ReservedDeviceNameValidation
from testcases.tc0027_whitespace_trailing_dot_validation import TestCase0027WhitespaceTrailingDotValidation
from testcases.tc0028_control_character_non_utf8_filename_validation import TestCase0028ControlCharacterNonUtf8FilenameValidation
from testcases.tc0029_local_first_upload_only_timestamp_preservation_validation import TestCase0029LocalFirstUploadOnlyTimestampPreservationValidation
from testcases.tc0030_local_rename_propagation_validation import TestCase0030LocalRenamePropagationValidation
from testcases.tc0031_local_directory_rename_propagation_validation import TestCase0031LocalDirectoryRenamePropagationValidation
from testcases.tc0032_remote_rename_reconciliation import TestCase0032RemoteRenameReconciliation
from testcases.tc0033_remote_directory_rename_reconciliation import TestCase0033RemoteDirectoryRenameReconciliation
from testcases.tc0034_local_move_between_directories_validation import TestCase0034LocalMoveBetweenDirectoriesValidation
from testcases.tc0035_remote_move_between_directories_reconciliation import TestCase0035RemoteMoveBetweenDirectoriesReconciliation
from testcases.tc0036_overwrite_replace_existing_file_content_validation import TestCase0036OverwriteReplaceExistingFileContentValidation
from testcases.tc0037_mtime_only_local_change_handling import TestCase0037MtimeOnlyLocalChangeHandling
from testcases.tc0038_delete_and_recreate_with_same_name_validation import TestCase0038DeleteAndRecreateWithSameNameValidation
from testcases.tc0039_empty_directory_handling_validation import TestCase0039EmptyDirectoryHandling


def build_test_suite() -> list:
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
        TestCase0021ResumableTransfersValidation(),
        #TestCase0022LocalFirstValidation(),
        #TestCase0023BypassDataPreservationValidation(),
        TestCase0024BigDeleteSafeguardValidation(),
        #TestCase0025InvalidCharacterFilenameValidation(),
        #TestCase0026ReservedDeviceNameValidation(),
        #TestCase0027WhitespaceTrailingDotValidation(),
        #TestCase0028ControlCharacterNonUtf8FilenameValidation(),
        #TestCase0029LocalFirstUploadOnlyTimestampPreservationValidation(),
        #TestCase0030LocalRenamePropagationValidation(),
        #TestCase0031LocalDirectoryRenamePropagationValidation(),
        #TestCase0032RemoteRenameReconciliation(),
        #TestCase0033RemoteDirectoryRenameReconciliation(),
        #TestCase0034LocalMoveBetweenDirectoriesValidation(),
        #TestCase0035RemoteMoveBetweenDirectoriesReconciliation(),
        #TestCase0036OverwriteReplaceExistingFileContentValidation(),
        #TestCase0037MtimeOnlyLocalChangeHandling(),
        #TestCase0038DeleteAndRecreateWithSameNameValidation(),
        #TestCase0039EmptyDirectoryHandling(),
    ]


def _normalise_case_id(value: str) -> str:
    text = value.strip()
    if not text:
        return ""
    if text.lower().startswith("tc"):
        text = text[2:]
    if text.isdigit() and len(text) <= 4:
        text = text.zfill(4)
    return text


def _apply_cli_overrides(args: argparse.Namespace) -> None:
    if args.debug:
        os.environ["E2E_DEBUG"] = "1"
    if args.skip_suite_cleanup:
        os.environ["E2E_SKIP_SUITE_CLEANUP"] = "1"
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

    if args.scenario:
        mapping: dict[str, set[str]] = {}
        for raw_value in args.scenario:
            case_part, separator, scenario_part = raw_value.partition(":")
            if separator != ":":
                raise RuntimeError(f"Invalid --scenario value '{raw_value}'. Expected CASE:SCENARIO[,SCENARIO]")
            case_id = _normalise_case_id(case_part)
            if not case_id:
                raise RuntimeError(f"Invalid case id in --scenario value '{raw_value}'")
            mapping.setdefault(case_id, set())
            for token in scenario_part.split(","):
                scenario_id = token.strip()
                if scenario_id:
                    mapping[case_id].add(scenario_id)
        if mapping:
            os.environ["E2E_SELECTED_SCENARIOS_JSON"] = json.dumps({key: sorted(value) for key, value in mapping.items()}, sort_keys=True)


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
        "skip_suite_cleanup": context.skip_suite_cleanup,
        "selected_case_ids": selected_case_ids,
        "selected_scenarios": {case_id: sorted(values) for case_id, values in sorted(context.selected_scenarios.items())},
        "executed_case_ids": executed_case_ids,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run OneDrive E2E test cases")
    parser.add_argument("--case-id", action="append", help="Run only the specified case id(s). Supports comma-separated values.")
    parser.add_argument("--scenario", action="append", help="Run only the specified scenario(s) for a case. Format: CASE:SCENARIO[,SCENARIO]")
    parser.add_argument("--debug", action="store_true", help="Rerun with debug verbosity enabled")
    parser.add_argument("--skip-suite-cleanup", action="store_true", help="Skip initial full-account cleanup")
    parser.add_argument("--output-subdir", help="Write results into ci/e2e/out/<subdir>")
    parser.add_argument("--run-label", help="Logical label for this run (for metadata/logging)")
    args = parser.parse_args()

    _apply_cli_overrides(args)
    context = E2EContext.from_environment()
    context.prepare_runtime()

    selected_case_ids = sorted(context.selected_case_ids)
    cases_to_run = [testcase for testcase in build_test_suite() if context.should_run_case(testcase.case_id)]
    executed_case_ids = [testcase.case_id for testcase in cases_to_run]

    suite_metadata = _build_metadata(context, selected_case_ids, executed_case_ids)

    if not context.skip_suite_cleanup:
        context.bootstrap_suite_cleanup_config_dir()
        context.log("Starting suite-wide cleanup of local and remote OneDrive content")

        cleanup_ok, cleanup_reason, cleanup_artifacts, cleanup_details = perform_full_account_cleanup(
            onedrive_bin=context.onedrive_bin,
            repo_root=context.repo_root,
            config_dir=context.suite_cleanup_config_dir,
            sync_dir=context.default_sync_dir,
            log_dir=context.suite_cleanup_log_dir,
        )

        if not cleanup_ok:
            context.log(f"Suite cleanup FAILED: {cleanup_reason}")

            results = {
                **suite_metadata,
                "cases": [
                    {
                        "id": "0000",
                        "name": "suite cleanup",
                        "status": "fail",
                        "reason": cleanup_reason,
                        "artifacts": cleanup_artifacts,
                        "details": cleanup_details,
                    }
                ],
            }

            results_file = context.out_dir / "results.json"
            results_json = json.dumps(results, indent=2, sort_keys=False)
            write_text_file(results_file, results_json)
            return 1

        context.log("Suite-wide cleanup completed successfully")
    else:
        context.log("Skipping suite-wide cleanup because E2E_SKIP_SUITE_CLEANUP is enabled")

    context.log(
        f"Initialising E2E framework for target='{context.e2e_target}', "
        f"run_id='{context.run_id}', run_label='{context.run_label}', debug_enabled={context.debug_enabled}"
    )

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
        **suite_metadata,
        "cases": cases,
    }

    results_file = context.out_dir / "results.json"
    results_json = json.dumps(results, indent=2, sort_keys=False)
    write_text_file(results_file, results_json)

    context.log(f"Wrote results to {results_file}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
