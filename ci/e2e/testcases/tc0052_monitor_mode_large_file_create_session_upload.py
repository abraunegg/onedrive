from __future__ import annotations

import os

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, compute_quickxor_hash_file, reset_directory, write_text_file
from framework.xlsx import REVISION_0, create_random_xlsx_pair, validate_xlsx_pair, large_xlsx_relative
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0052MonitorModeLargeFileCreateSessionUpload(MonitorModeTestCaseBase):
    case_id = "0052"
    name = "monitor mode large file create session upload"
    description = "Create large and realistic XLSX files under --monitor and validate simple/session upload behaviour and remote integrity"

    XLSX_PAYLOAD_ROWS = 32

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0052",
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

        root_name = f"ZZ_E2E_TC0052_{context.run_id}_{os.getpid()}"
        anchor_relative = f"{root_name}/anchor.txt"
        large_relative = f"{root_name}/large-session-upload.bin"
        xlsx_relative = f"{root_name}/real-session-upload.xlsx"
        anchor_local = sync_root / anchor_relative
        large_local = sync_root / large_relative
        xlsx_local = sync_root / xlsx_relative
        large_verify = verify_root / large_relative
        xlsx_verify = verify_root / xlsx_relative
        large_size_bytes = 6 * 1024 * 1024
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0052:{os.getpid()}"

        # The 6 MiB sentinel already crosses the application's automatic session-upload
        # threshold. Do not force all files through session upload: the XLSX pair deliberately
        # exercises the normal <4 MiB simple-upload and >4 MiB session-upload paths together.
        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(conf_verify, ("# tc0052 verify\n" f'sync_dir = "{verify_root}"\n' 'bypass_data_preservation = "true"\n'))
        write_text_file(anchor_local, "TC0052 anchor\n")

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"
        artifacts = [str(monitor_stdout), str(monitor_stderr), str(verify_stdout), str(verify_stderr), str(verify_manifest_file), str(metadata_file)]
        details = {
            "root_name": root_name,
            "anchor_relative": anchor_relative,
            "large_relative": large_relative,
            "large_size_bytes": large_size_bytes,
            "xlsx_relative": xlsx_relative,
            "xlsx_large_relative": large_xlsx_relative(xlsx_relative),
            "xlsx_seed": xlsx_seed,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
        }

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process, initial_sync_complete = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            self._write_file_with_exact_size(large_local, large_size_bytes, "TC0052 monitor mode large file create session upload\n")
            generated_xlsx = create_random_xlsx_pair(
                xlsx_local,
                xlsx_seed,
                revision=REVISION_0,
                payload_rows=self.XLSX_PAYLOAD_ROWS,
                title="TC0052 monitor session upload workbook",
            )
            details["local_large_hash"] = compute_quickxor_hash_file(large_local)
            details["local_large_size"] = large_local.stat().st_size
            details["generated_xlsx_size"] = int(generated_xlsx["size_bytes"])
            details["generated_large_xlsx_size"] = int(generated_xlsx["large_size_bytes"])
            details["created_xlsx_validation_error"] = validate_xlsx_pair(xlsx_local, REVISION_0)
            if details["created_xlsx_validation_error"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, f"Generated XLSX pair is invalid before monitor processing: {details['created_xlsx_validation_error']}", artifacts, details)

            required_patterns = [
                f"Uploading new file: {large_relative} ... done",
                f"Uploading new file: {xlsx_relative} ... done",
                f"Uploading new file: {large_xlsx_relative(xlsx_relative)} ... done",
            ]
            mutation_processed, post_mutation_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                required_patterns=required_patterns,
                timeout_seconds=240,
            )
            post_mutation_sync_complete = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["post_mutation_sync_complete"] = post_mutation_sync_complete
            details["mutation_processed"] = mutation_processed
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
            details["mutation_required_patterns"] = required_patterns
        finally:
            self._shutdown_monitor_process(process, details)

        details["post_monitor_xlsx_validation_error"] = (
            validate_xlsx_pair(xlsx_local, REVISION_0)
            if xlsx_local.is_file()
            else "Local XLSX is missing after monitor processing"
        )

        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(verify_root), "--confdir", str(conf_verify)]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_large_exists"] = large_verify.is_file()
        details["verify_large_size"] = large_verify.stat().st_size if large_verify.is_file() else -1
        details["verify_large_hash"] = compute_quickxor_hash_file(large_verify) if large_verify.is_file() else ""
        details["verify_xlsx_validation_error"] = (
            validate_xlsx_pair(xlsx_verify, REVISION_0)
            if xlsx_verify.is_file()
            else "Verification XLSX is missing"
        )
        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if not large_verify.is_file():
            return self.fail_result(self.case_id, self.name, f"Remote verification is missing large uploaded file: {large_relative}", artifacts, details)
        if details["verify_large_size"] != details["local_large_size"] or details["verify_large_hash"] != details["local_large_hash"]:
            return self.fail_result(self.case_id, self.name, "Large file session upload did not preserve expected size/hash after remote verification", artifacts, details)
        if details["post_monitor_xlsx_validation_error"]:
            return self.fail_result(self.case_id, self.name, f"Monitor processing did not leave a valid XLSX pair locally: {details['post_monitor_xlsx_validation_error']}", artifacts, details)
        if details["verify_xlsx_validation_error"]:
            return self.fail_result(self.case_id, self.name, f"Remote verification is missing or contains an invalid XLSX pair: {details['verify_xlsx_validation_error']}", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
