from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.xlsx import REVISION_0, create_random_xlsx, validate_xlsx
from framework.utils import command_to_string, reset_directory, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0045MonitorModeLocalDirectoryCreatePropagation(MonitorModeTestCaseBase):
    case_id = "0045"
    name = "monitor mode local directory create propagation"
    description = "Create a new local directory and real XLSX child under --monitor and validate the remote state"

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0045",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0045_{context.run_id}_{os.getpid()}"
        baseline_relative = f"{root_name}/baseline.txt"
        created_dir_relative = f"{root_name}/created-directory"
        created_file_relative = f"{created_dir_relative}/inside.xlsx"

        baseline_local_path = sync_root / baseline_relative
        created_dir_local_path = sync_root / created_dir_relative
        created_file_local_path = sync_root / created_file_relative
        created_dir_verify_path = verify_root / created_dir_relative
        created_file_verify_path = verify_root / created_file_relative

        baseline_content = "TC0045 baseline\n"
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0045:{os.getpid()}"

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(
            conf_verify,
            (
                "# tc0045 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        write_text_file(baseline_local_path, baseline_content)

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(monitor_stdout),
            str(monitor_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details = {
            "root_name": root_name,
            "baseline_relative": baseline_relative,
            "created_dir_relative": created_dir_relative,
            "created_file_relative": created_file_relative,
            "xlsx_seed": xlsx_seed,
            "payload_rows": self.XLSX_PAYLOAD_ROWS,
        }

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")

        process, initial_sync_complete = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            created_dir_local_path.mkdir(parents=True, exist_ok=True)
            generated = create_random_xlsx(
                created_file_local_path,
                xlsx_seed,
                revision=REVISION_0,
                payload_rows=self.XLSX_PAYLOAD_ROWS,
                title="TC0045 monitor local directory create workbook",
            )
            details["generated_size"] = int(generated["size_bytes"])
            details["created_local_validation_error"] = validate_xlsx(created_file_local_path, REVISION_0)

            required_patterns = [
                f"Uploading new file: {created_file_relative} ... done",
            ]
            mutation_processed, post_mutation_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                required_patterns=required_patterns,
                timeout_seconds=180,
            )
            post_mutation_sync_complete = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["post_mutation_sync_complete"] = post_mutation_sync_complete
            details["mutation_processed"] = mutation_processed
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
            details["mutation_required_patterns"] = required_patterns
        finally:
            self._shutdown_monitor_process(process, details)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(verify_root),
            "--confdir",
            str(conf_verify),
        ]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_created_dir_exists"] = created_dir_verify_path.is_dir()
        details["verify_created_file_exists"] = created_file_verify_path.is_file()
        verify_validation_error = (
            validate_xlsx(created_file_verify_path, REVISION_0)
            if created_file_verify_path.is_file()
            else "Verification XLSX is missing"
        )
        details["verify_validation_error"] = verify_validation_error
        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if not created_dir_verify_path.is_dir():
            return self.fail_result(self.case_id, self.name, f"Remote verification is missing created directory: {created_dir_relative}", artifacts, details)
        if not created_file_verify_path.is_file():
            return self.fail_result(self.case_id, self.name, f"Remote verification is missing created file: {created_file_relative}", artifacts, details)
        if verify_validation_error:
            return self.fail_result(self.case_id, self.name, f"Remote verification returned an invalid or stale XLSX workbook: {verify_validation_error}", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
