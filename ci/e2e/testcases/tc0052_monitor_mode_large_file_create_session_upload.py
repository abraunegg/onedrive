from __future__ import annotations

import os

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, compute_quickxor_hash_file, reset_directory, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0052MonitorModeLargeFileCreateSessionUpload(MonitorModeTestCaseBase):
    case_id = "0052"
    name = "monitor mode large file create session upload"
    description = "Create a large file under --monitor and validate session upload behaviour and remote integrity"

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
        anchor_local = sync_root / anchor_relative
        large_local = sync_root / large_relative
        large_verify = verify_root / large_relative
        large_size_bytes = 6 * 1024 * 1024

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir, extra_config_lines=['force_session_upload = "true"']))
        context.prepare_minimal_config_dir(conf_verify, ("# tc0052 verify\n" f'sync_dir = "{verify_root}"\n' 'bypass_data_preservation = "true"\n'))
        write_text_file(anchor_local, "TC0052 anchor\n")

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"
        artifacts = [str(monitor_stdout), str(monitor_stderr), str(verify_stdout), str(verify_stderr), str(verify_manifest_file), str(metadata_file)]
        details = {"root_name": root_name, "anchor_relative": anchor_relative, "large_relative": large_relative, "large_size_bytes": large_size_bytes}

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            initial_sync_complete = self._wait_for_initial_sync_complete(monitor_stdout)
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)

            self._write_file_with_exact_size(large_local, large_size_bytes, "TC0052 monitor mode large file create session upload\n")
            details["local_large_hash"] = compute_quickxor_hash_file(large_local)
            details["local_large_size"] = large_local.stat().st_size
            required_patterns = [f"Uploading new file: {large_relative} ... done"]
            mutation_processed = self._wait_for_monitor_patterns(monitor_stdout, required_patterns, timeout_seconds=240)
            details["mutation_processed"] = mutation_processed
            details["mutation_required_patterns"] = required_patterns
        finally:
            self._shutdown_monitor_process(process, details)

        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(verify_root), "--confdir", str(conf_verify)]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_large_exists"] = large_verify.is_file()
        details["verify_large_size"] = large_verify.stat().st_size if large_verify.is_file() else -1
        details["verify_large_hash"] = compute_quickxor_hash_file(large_verify) if large_verify.is_file() else ""
        self._write_metadata(metadata_file, details)

        if not details.get("mutation_processed", False):
            return self.fail_result(self.case_id, self.name, "Monitor mode did not process the large file create event before shutdown", artifacts, details)
        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if not large_verify.is_file():
            return self.fail_result(self.case_id, self.name, f"Remote verification is missing large uploaded file: {large_relative}", artifacts, details)
        if details["verify_large_size"] != details["local_large_size"] or details["verify_large_hash"] != details["local_large_hash"]:
            return self.fail_result(self.case_id, self.name, "Large file session upload did not preserve expected size/hash after remote verification", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
