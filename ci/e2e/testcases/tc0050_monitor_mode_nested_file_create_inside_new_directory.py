from __future__ import annotations

import os

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, write_text_file
from framework.xlsx import REVISION_0, create_random_xlsx, validate_xlsx
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0050MonitorModeNestedFileCreateInsideNewDirectory(MonitorModeTestCaseBase):
    XLSX_PAYLOAD_ROWS = 32
    case_id = "0050"
    name = "monitor mode nested file create inside new directory"
    description = "Create a nested directory tree and deep file under --monitor and validate the remote state"

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0050",
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

        root_name = f"ZZ_E2E_TC0050_{context.run_id}_{os.getpid()}"
        anchor_relative = f"{root_name}/anchor.txt"
        deep_dir_relative = f"{root_name}/new-root/child/grandchild"
        deep_file_relative = f"{deep_dir_relative}/deep-file.txt"
        deep_xlsx_relative = f"{deep_dir_relative}/deep-file.xlsx"

        anchor_local = sync_root / anchor_relative
        deep_dir_local = sync_root / deep_dir_relative
        deep_file_local = sync_root / deep_file_relative
        deep_xlsx_local = sync_root / deep_xlsx_relative
        deep_file_verify = verify_root / deep_file_relative
        deep_xlsx_verify = verify_root / deep_xlsx_relative

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0050:{os.getpid()}"
        deep_file_content = (
            "TC0050 monitor mode nested file create inside new directory\n"
            "This file was created at a nested path while --monitor was active.\n"
        )

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(conf_verify, ("# tc0050 verify\n" f'sync_dir = "{verify_root}"\n' 'bypass_data_preservation = "true"\n'))
        write_text_file(anchor_local, "TC0050 anchor\n")

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"
        artifacts = [str(monitor_stdout), str(monitor_stderr), str(verify_stdout), str(verify_stderr), str(verify_manifest_file), str(metadata_file)]
        details = {"root_name": root_name, "anchor_relative": anchor_relative, "deep_dir_relative": deep_dir_relative, "deep_file_relative": deep_file_relative, "deep_xlsx_relative": deep_xlsx_relative, "xlsx_seed": xlsx_seed, "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS}

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process, initial_sync_complete = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)
            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            deep_dir_local.mkdir(parents=True, exist_ok=True)
            write_text_file(deep_file_local, deep_file_content)
            generated_xlsx = create_random_xlsx(
                deep_xlsx_local,
                xlsx_seed,
                revision=REVISION_0,
                payload_rows=self.XLSX_PAYLOAD_ROWS,
                title="TC0050 nested monitor create workbook",
            )
            details["generated_xlsx_size"] = int(generated_xlsx["size_bytes"])
            details["created_xlsx_validation_error"] = validate_xlsx(deep_xlsx_local, REVISION_0)
            required_patterns = [
                f"Uploading new file: {deep_file_relative} ... done",
                f"Uploading new file: {deep_xlsx_relative} ... done",
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

        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(verify_root), "--confdir", str(conf_verify)]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_deep_file_exists"] = deep_file_verify.is_file()
        details["verify_deep_file_content"] = deep_file_verify.read_text(encoding="utf-8") if deep_file_verify.is_file() else ""
        details["verify_deep_xlsx_exists"] = deep_xlsx_verify.is_file()
        details["verify_deep_xlsx_validation_error"] = (
            validate_xlsx(deep_xlsx_verify, REVISION_0)
            if deep_xlsx_verify.is_file()
            else "Verification XLSX is missing"
        )
        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if not deep_file_verify.is_file() or details["verify_deep_file_content"] != deep_file_content:
            return self.fail_result(self.case_id, self.name, f"Remote verification is missing deep nested file state: {deep_file_relative}", artifacts, details)
        if details["verify_deep_xlsx_validation_error"]:
            return self.fail_result(self.case_id, self.name, f"Remote verification is missing or contains an invalid nested XLSX: {deep_xlsx_relative}", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
