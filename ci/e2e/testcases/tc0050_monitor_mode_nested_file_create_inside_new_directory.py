from __future__ import annotations

import os

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0050MonitorModeNestedFileCreateInsideNewDirectory(MonitorModeTestCaseBase):
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

        anchor_local = sync_root / anchor_relative
        deep_dir_local = sync_root / deep_dir_relative
        deep_file_local = sync_root / deep_file_relative
        deep_file_verify = verify_root / deep_file_relative

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
        details = {"root_name": root_name, "anchor_relative": anchor_relative, "deep_dir_relative": deep_dir_relative, "deep_file_relative": deep_file_relative}

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            initial_sync_complete = self._wait_for_initial_sync_complete(monitor_stdout)
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)
            deep_dir_local.mkdir(parents=True, exist_ok=True)
            write_text_file(deep_file_local, deep_file_content)
            required_patterns = [f"Uploading new file: {deep_file_relative} ... done"]
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
        details["verify_deep_file_exists"] = deep_file_verify.is_file()
        details["verify_deep_file_content"] = deep_file_verify.read_text(encoding="utf-8") if deep_file_verify.is_file() else ""
        self._write_metadata(metadata_file, details)

        if not details.get("mutation_processed", False):
            return self.fail_result(self.case_id, self.name, "Monitor mode did not process the nested create event before shutdown", artifacts, details)
        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if not deep_file_verify.is_file() or details["verify_deep_file_content"] != deep_file_content:
            return self.fail_result(self.case_id, self.name, f"Remote verification is missing deep nested file state: {deep_file_relative}", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
