from __future__ import annotations

import os

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0048MonitorModeBurstLocalFileCreates(MonitorModeTestCaseBase):
    case_id = "0048"
    name = "monitor mode burst local file creates"
    description = "Rapidly create multiple local files under --monitor and validate they all upload correctly"

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0048"
        case_log_dir = context.logs_dir / "tc0048"
        state_dir = context.state_dir / "tc0048"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0048_{context.run_id}_{os.getpid()}"
        baseline_relative = f"{root_name}/baseline.txt"
        burst_relatives = [f"{root_name}/burst-{index}.txt" for index in range(1, 6)]
        burst_contents = {relative: f"TC0048 burst file {relative}\n" for relative in burst_relatives}

        baseline_local_path = sync_root / baseline_relative
        verify_paths = {relative: verify_root / relative for relative in burst_relatives}

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(
            conf_verify,
            (
                "# tc0048 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        write_text_file(baseline_local_path, "TC0048 baseline\n")

        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [str(monitor_stdout), str(monitor_stderr), str(verify_stdout), str(verify_stderr), str(verify_manifest_file), str(metadata_file)]
        details = {"root_name": root_name, "baseline_relative": baseline_relative, "burst_relatives": burst_relatives}

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            initial_sync_complete = self._wait_for_initial_sync_complete(monitor_stdout)
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return TestResult.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)

            for relative in burst_relatives:
                write_text_file(sync_root / relative, burst_contents[relative])

            required_patterns = [f"Uploading new file: {relative} ... done" for relative in burst_relatives]
            mutation_processed = self._wait_for_monitor_patterns(monitor_stdout, required_patterns)
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
        for relative in burst_relatives:
            details[f"verify_exists::{relative}"] = verify_paths[relative].is_file()
            details[f"verify_content::{relative}"] = verify_paths[relative].read_text(encoding="utf-8") if verify_paths[relative].is_file() else ""
        self._write_metadata(metadata_file, details)

        if not details.get("mutation_processed", False):
            return TestResult.fail_result(self.case_id, self.name, "Monitor mode did not process the burst local create events before shutdown", artifacts, details)
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        for relative in burst_relatives:
            if not verify_paths[relative].is_file():
                return TestResult.fail_result(self.case_id, self.name, f"Remote verification is missing burst-created file: {relative}", artifacts, details)
            if details[f"verify_content::{relative}"] != burst_contents[relative]:
                return TestResult.fail_result(self.case_id, self.name, f"Burst-created file content did not match for: {relative}", artifacts, details)
        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
