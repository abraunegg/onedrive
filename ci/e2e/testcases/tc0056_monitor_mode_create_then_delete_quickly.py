from __future__ import annotations

import os
import time

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0056MonitorModeCreateThenDeleteQuickly(MonitorModeTestCaseBase):
    case_id = "0056"
    name = "monitor mode create then delete quickly"
    description = "Create and delete a local file quickly under --monitor and validate stability and final remote state"

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0056",
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

        root_name = f"ZZ_E2E_TC0056_{context.run_id}_{os.getpid()}"
        anchor_relative = f"{root_name}/anchor.txt"
        transient_relative = f"{root_name}/transient.txt"

        anchor_local = sync_root / anchor_relative
        transient_local = sync_root / transient_relative
        anchor_verify = verify_root / anchor_relative
        transient_verify = verify_root / transient_relative

        transient_content = (
            "TC0056 monitor mode create then delete quickly\n"
            "This file should not remain remotely after the rapid local delete.\n"
        )

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(
            conf_verify,
            (
                "# tc0056 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )
        write_text_file(anchor_local, "TC0056 anchor\n")

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
            "anchor_relative": anchor_relative,
            "transient_relative": transient_relative,
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
        early_failure: str | None = None
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

            write_text_file(transient_local, transient_content)
            time.sleep(0.2)
            if transient_local.exists():
                transient_local.unlink()
            details["transient_exists_after_local_delete"] = transient_local.exists()

            time.sleep(12)
            if process.poll() is not None:
                early_failure = f"Monitor process exited before shutdown with status {process.returncode} after transient create/delete workflow"

            stdout_content = self._read_stdout(monitor_stdout)
            details["monitor_observed_new_file"] = f"[M] New local file added: {transient_relative}" in stdout_content
            details["monitor_observed_delete"] = f"[M] Local item deleted: {transient_relative}" in stdout_content
            details["monitor_observed_upload"] = f"Uploading new file: {transient_relative} ... done" in stdout_content
            details["monitor_observed_remote_delete"] = f"Deleting item from Microsoft OneDrive: {transient_relative}" in stdout_content
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
        details["verify_anchor_exists"] = anchor_verify.is_file()
        details["verify_transient_exists"] = transient_verify.exists()
        self._write_metadata(metadata_file, details)

        if early_failure is not None:
            return self.fail_result(self.case_id, self.name, early_failure, artifacts, details)
        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )
        if not anchor_verify.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing retained anchor file: {anchor_relative}",
                artifacts,
                details,
            )
        if transient_verify.exists():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification still contains transient file after rapid create/delete: {transient_relative}",
                artifacts,
                details,
            )
        return self.pass_result(self.case_id, self.name, artifacts, details)
