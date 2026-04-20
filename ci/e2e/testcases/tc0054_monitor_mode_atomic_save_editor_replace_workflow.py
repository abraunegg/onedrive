from __future__ import annotations

import os

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0054MonitorModeAtomicSaveEditorReplaceWorkflow(MonitorModeTestCaseBase):
    case_id = "0054"
    name = "monitor mode atomic-save editor replace workflow"
    description = "Replace an existing file via temp-file save and atomic rename under --monitor and validate the final remote state"

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0054"
        case_log_dir = context.logs_dir / "tc0054"
        state_dir = context.state_dir / "tc0054"
        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0054_{context.run_id}_{os.getpid()}"
        target_relative = f"{root_name}/document.txt"
        temp_relative = f"{root_name}/.document.txt.swp"

        target_local = sync_root / target_relative
        temp_local = sync_root / temp_relative
        target_verify = verify_root / target_relative
        temp_verify = verify_root / temp_relative

        original_content = (
            "TC0054 monitor mode atomic-save editor replace workflow\n"
            "ORIGINAL CONTENT\n"
        )
        updated_content = (
            "TC0054 monitor mode atomic-save editor replace workflow\n"
            "UPDATED CONTENT VIA TEMP FILE REPLACE\n"
        )

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(
            conf_verify,
            (
                "# tc0054 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        write_text_file(target_local, original_content)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(monitor_stdout),
            str(monitor_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(verify_manifest_file),
            str(metadata_file),
        ]
        details = {
            "root_name": root_name,
            "target_relative": target_relative,
            "temp_relative": temp_relative,
        }

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            initial_sync_complete = self._wait_for_initial_sync_complete(monitor_stdout)
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor mode did not complete the initial sync within the expected time",
                    artifacts,
                    details,
                )

            write_text_file(temp_local, updated_content)
            os.replace(temp_local, target_local)
            details["temp_local_exists_after_replace"] = temp_local.exists()
            details["target_local_exists_after_replace"] = target_local.is_file()

            pattern_groups = [
                [f"Uploading modified file: {target_relative} ... done"],
                [f"Uploading new file: {target_relative} ... done"],
            ]
            mutation_processed, matched_group = self._wait_for_any_monitor_pattern_group(
                monitor_stdout,
                pattern_groups,
                timeout_seconds=120,
            )
            details["mutation_processed"] = mutation_processed
            details["matched_pattern_group_index"] = matched_group
            details["pattern_groups"] = pattern_groups
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
        details["verify_target_exists"] = target_verify.is_file()
        details["verify_target_content"] = target_verify.read_text(encoding="utf-8") if target_verify.is_file() else ""
        details["verify_temp_exists"] = temp_verify.exists()
        self._write_metadata(metadata_file, details)

        if not details.get("mutation_processed", False):
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Monitor mode did not process the atomic-save editor replace workflow before shutdown",
                artifacts,
                details,
            )
        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )
        if not target_verify.is_file() or details["verify_target_content"] != updated_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Remote verification did not preserve the updated editor-save content: {target_relative}",
                artifacts,
                details,
            )
        if temp_verify.exists():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains temporary editor-save file: {temp_relative}",
                artifacts,
                details,
            )
        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
