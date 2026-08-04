from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_onedrive_config, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0020MonitorModeValidation(MonitorModeTestCaseBase):
    case_id = "0020"
    name = "monitor mode validation"
    description = "Validate that monitor mode uploads local changes without manually re-running --sync"

    def _write_config(self, config_path: Path, app_log_dir: Path) -> None:
        write_onedrive_config(
            config_path,
            "# tc0020 config\n"
            'bypass_data_preservation = "true"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n'
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n',
        )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0020",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        confdir = case_work_dir / "conf-main"
        verify_root = case_work_dir / "verifyroot"
        verify_conf = case_work_dir / "conf-verify"
        root_name = f"ZZ_E2E_TC0020_{context.run_id}_{os.getpid()}"
        app_log_dir = case_log_dir / "app-logs"

        write_text_file(sync_root / root_name / "baseline.txt", "baseline\n")

        context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config", app_log_dir)
        context.bootstrap_config_dir(verify_conf)
        write_onedrive_config(verify_conf / "config", "# tc0020 verify\n" 'bypass_data_preservation = "true"\n')

        stdout_file = case_log_dir / "monitor_stdout.log"
        stderr_file = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [str(stdout_file), str(stderr_file), str(verify_stdout), str(verify_stderr), str(remote_manifest_file), str(metadata_file)]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))

        details: dict[str, object] = {
            "root_name": root_name,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(confdir),
            "conf_verify": str(verify_conf),
            "monitor_interval": 300,
            "monitor_fullscan_frequency": 0,
            "websocket_disabled": True,
        }

        command = [
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
            str(confdir),
        ]
        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")

        process, initial_sync_complete = self._launch_monitor_process(context, command, stdout_file, stderr_file)
        try:
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor mode did not complete the initial sync within the expected time",
                    artifacts,
                    details,
                )

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, stdout_file, details)
            monitor_added_relative = f"{root_name}/monitor-added.txt"
            write_text_file(sync_root / monitor_added_relative, "added while monitor mode was running\n")
            required_patterns = [f"Uploading new file: {monitor_added_relative} ... done"]
            mutation_processed, post_mutation_log_segment = self._wait_for_stdout_growth_patterns(
                stdout_file,
                start_offset=mutation_log_start_offset,
                required_patterns=required_patterns,
                timeout_seconds=180,
            )
            details["post_mutation_sync_complete"] = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["mutation_processed"] = mutation_processed
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
            details["mutation_required_patterns"] = required_patterns
        finally:
            self._shutdown_monitor_process(process, details)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(verify_root),
            "--confdir",
            str(verify_conf),
        ]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        details["verify_returncode"] = verify_result.returncode
        details["verify_created_exists"] = f"{root_name}/monitor-added.txt" in remote_manifest
        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)

        if f"{root_name}/monitor-added.txt" not in remote_manifest:
            return self.fail_result(self.case_id, self.name, "Monitor mode did not upload the file created while the process was running", artifacts, details)

        return self.pass_result(self.case_id, self.name, artifacts, details)
