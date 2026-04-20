from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0046MonitorModeLocalDirectoryRenamePropagation(MonitorModeTestCaseBase):
    case_id = "0046"
    name = "monitor mode local directory rename propagation"
    description = "Rename a populated local directory while --monitor is active and validate the final remote state"

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0046"
        case_log_dir = context.logs_dir / "tc0046"
        state_dir = context.state_dir / "tc0046"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0046_{context.run_id}_{os.getpid()}"
        old_dir_relative = f"{root_name}/original-dir"
        new_dir_relative = f"{root_name}/renamed-dir"
        old_file_relative = f"{old_dir_relative}/inside.txt"
        new_file_relative = f"{new_dir_relative}/inside.txt"

        old_dir_local_path = sync_root / old_dir_relative
        new_dir_local_path = sync_root / new_dir_relative
        old_file_local_path = sync_root / old_file_relative
        old_dir_verify_path = verify_root / old_dir_relative
        new_dir_verify_path = verify_root / new_dir_relative
        old_file_verify_path = verify_root / old_file_relative
        new_file_verify_path = verify_root / new_file_relative

        file_content = (
            "TC0046 monitor mode local directory rename propagation\n"
            "This file must survive the directory rename unchanged.\n"
        )

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(
            conf_verify,
            (
                "# tc0046 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        write_text_file(old_file_local_path, file_content)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [str(seed_stdout), str(seed_stderr), str(monitor_stdout), str(monitor_stderr), str(verify_stdout), str(verify_stderr), str(verify_manifest_file), str(metadata_file)]
        details = {"root_name": root_name, "old_dir_relative": old_dir_relative, "new_dir_relative": new_dir_relative, "old_file_relative": old_file_relative, "new_file_relative": new_file_relative}

        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(self.case_id, self.name, f"Seed phase failed with status {seed_result.returncode}", artifacts, details)

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            initial_sync_complete = self._wait_for_initial_sync_complete(monitor_stdout)
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return TestResult.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)

            old_dir_local_path.rename(new_dir_local_path)
            groups = [
                [f"[M] Local item moved: {old_dir_relative} -> {new_dir_relative}", f"Moving {old_dir_relative} to {new_dir_relative}"],
                [f"Deleting item from Microsoft OneDrive: {old_file_relative}", f"Uploading new file: {new_file_relative} ... done"],
            ]
            mutation_processed, matched_group = self._wait_for_any_monitor_pattern_group(monitor_stdout, groups)
            details["mutation_processed"] = mutation_processed
            details["matched_pattern_group_index"] = matched_group
            details["mutation_pattern_groups"] = groups
        finally:
            self._shutdown_monitor_process(process, details)

        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(verify_root), "--confdir", str(conf_verify)]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_old_dir_exists"] = old_dir_verify_path.exists()
        details["verify_new_dir_exists"] = new_dir_verify_path.is_dir()
        details["verify_old_file_exists"] = old_file_verify_path.exists()
        details["verify_new_file_exists"] = new_file_verify_path.is_file()
        details["verify_new_file_content"] = new_file_verify_path.read_text(encoding="utf-8") if new_file_verify_path.is_file() else ""
        self._write_metadata(metadata_file, details)

        if not details.get("mutation_processed", False):
            return TestResult.fail_result(self.case_id, self.name, "Monitor mode did not process the local directory rename event before shutdown", artifacts, details)
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if old_dir_verify_path.exists() or old_file_verify_path.exists():
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification still contains old directory path: {old_dir_relative}", artifacts, details)
        if not new_dir_verify_path.is_dir() or not new_file_verify_path.is_file():
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification is missing renamed directory content at: {new_dir_relative}", artifacts, details)
        if details["verify_new_file_content"] != file_content:
            return TestResult.fail_result(self.case_id, self.name, "Renamed directory child file content did not match after remote verification", artifacts, details)
        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
