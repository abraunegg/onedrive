from __future__ import annotations

import os
import time

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, compute_quickxor_hash_file, reset_directory, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0051MonitorModeMtimeOnlyLocalChangeHandling(MonitorModeTestCaseBase):
    case_id = "0051"
    name = "monitor mode mtime-only local change handling"
    description = "Touch an existing local file under --monitor without changing content and validate that no new upload occurs"

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0051",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        verify_initial_root = case_work_dir / "verify-initial-root"
        verify_final_root = case_work_dir / "verify-final-root"
        conf_main = case_work_dir / "conf-main"
        conf_verify_initial = case_work_dir / "conf-verify-initial"
        conf_verify_final = case_work_dir / "conf-verify-final"
        app_log_dir = case_log_dir / "app-logs"

        root_name = f"ZZ_E2E_TC0051_{context.run_id}_{os.getpid()}"
        relative_path = f"{root_name}/mtime-only.txt"
        local_file_path = sync_root / relative_path
        verify_initial_file_path = verify_initial_root / relative_path
        verify_final_file_path = verify_final_root / relative_path

        initial_content = (
            "TC0051 monitor mode mtime-only local change handling\n"
            "This file content must remain unchanged; only the local mtime is updated.\n"
        )

        extra_config_lines = ['force_session_upload = "true"']
        context.prepare_minimal_config_dir(
            conf_main,
            self._build_config_text(sync_root, app_log_dir, extra_config_lines=extra_config_lines),
        )
        context.prepare_minimal_config_dir(
            conf_verify_initial,
            (
                "# tc0051 verify initial\n"
                f'sync_dir = "{verify_initial_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )
        context.prepare_minimal_config_dir(
            conf_verify_final,
            (
                "# tc0051 verify final\n"
                f'sync_dir = "{verify_final_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        write_text_file(local_file_path, initial_content)
        initial_local_hash = compute_quickxor_hash_file(local_file_path)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        verify_initial_stdout = case_log_dir / "verify_initial_stdout.log"
        verify_initial_stderr = case_log_dir / "verify_initial_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_final_stdout = case_log_dir / "verify_final_stdout.log"
        verify_final_stderr = case_log_dir / "verify_final_stderr.log"
        verify_initial_manifest_file = state_dir / "verify_initial_manifest.txt"
        verify_final_manifest_file = state_dir / "verify_final_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(verify_initial_stdout),
            str(verify_initial_stderr),
            str(monitor_stdout),
            str(monitor_stderr),
            str(verify_final_stdout),
            str(verify_final_stderr),
            str(verify_initial_manifest_file),
            str(verify_final_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "relative_path": relative_path,
            "initial_local_hash": initial_local_hash,
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
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        verify_initial_command = [
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
            str(verify_initial_root),
            "--confdir",
            str(conf_verify_initial),
        ]
        context.log(f"Executing Test Case {self.case_id} initial verify: {command_to_string(verify_initial_command)}")
        verify_initial_result = self._run_verify_command(
            context,
            verify_initial_command,
            verify_initial_stdout,
            verify_initial_stderr,
        )
        details["verify_initial_returncode"] = verify_initial_result.returncode

        verify_initial_manifest = build_manifest(verify_initial_root)
        write_manifest(verify_initial_manifest_file, verify_initial_manifest)

        if verify_initial_result.returncode != 0 or not verify_initial_file_path.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "Initial remote verification failed before monitor mtime-only negative validation",
                artifacts,
                details,
            )

        baseline_verified_mtime = int(verify_initial_file_path.stat().st_mtime)
        details["baseline_verified_mtime"] = baseline_verified_mtime
        details["verify_initial_hash"] = compute_quickxor_hash_file(verify_initial_file_path)
        details["verify_initial_content"] = verify_initial_file_path.read_text(encoding="utf-8")

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
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor mode did not complete the initial sync within the expected time",
                    artifacts,
                    details,
                )

            local_mtime_before_touch = int(local_file_path.stat().st_mtime)
            touched_epoch = max(int(time.time()), local_mtime_before_touch, baseline_verified_mtime) + 120
            os.utime(local_file_path, (touched_epoch, touched_epoch))

            local_hash_after_touch = compute_quickxor_hash_file(local_file_path)
            local_mtime_after_touch = int(local_file_path.stat().st_mtime)

            details["local_mtime_before_touch"] = local_mtime_before_touch
            details["local_mtime_after_touch"] = local_mtime_after_touch
            details["touched_epoch"] = touched_epoch
            details["local_hash_after_touch"] = local_hash_after_touch

            if local_hash_after_touch != initial_local_hash:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Local file hash changed after mtime-only touch",
                    artifacts,
                    details,
                )

            # Give monitor mode enough time to observe and reconcile the touched file.
            time.sleep(15)

            monitor_stdout_content = self._read_stdout(monitor_stdout)
            details["monitor_observed_processing"] = f"Processing: {relative_path}" in monitor_stdout_content
            details["monitor_reported_no_change"] = "The file has not changed" in monitor_stdout_content
            details["monitor_reported_upload"] = f"Uploading modified file: {relative_path} ... done" in monitor_stdout_content
            details["monitor_reported_local_change_event"] = f"[M] Local file changed: {relative_path}" in monitor_stdout_content
        finally:
            self._shutdown_monitor_process(process, details)

        verify_final_command = [
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
            str(verify_final_root),
            "--confdir",
            str(conf_verify_final),
        ]
        context.log(f"Executing Test Case {self.case_id} final verify: {command_to_string(verify_final_command)}")
        verify_final_result = self._run_verify_command(
            context,
            verify_final_command,
            verify_final_stdout,
            verify_final_stderr,
        )
        details["verify_final_returncode"] = verify_final_result.returncode

        verify_final_manifest = build_manifest(verify_final_root)
        write_manifest(verify_final_manifest_file, verify_final_manifest)

        details["verify_final_file_exists"] = verify_final_file_path.is_file()
        details["verify_final_hash"] = (
            compute_quickxor_hash_file(verify_final_file_path)
            if verify_final_file_path.is_file()
            else ""
        )
        details["verify_final_content"] = (
            verify_final_file_path.read_text(encoding="utf-8")
            if verify_final_file_path.is_file()
            else ""
        )
        details["final_verified_mtime"] = (
            int(verify_final_file_path.stat().st_mtime)
            if verify_final_file_path.is_file()
            else -1
        )

        self._write_metadata(metadata_file, details)

        if verify_final_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Final remote verification failed with status {verify_final_result.returncode}",
                artifacts,
                details,
            )

        if not verify_final_file_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing mtime-only file: {relative_path}",
                artifacts,
                details,
            )

        if details["verify_final_hash"] != initial_local_hash:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote file hash changed after mtime-only local touch",
                artifacts,
                details,
            )

        if details["verify_final_content"] != initial_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote file content changed after mtime-only local touch",
                artifacts,
                details,
            )

        if details["final_verified_mtime"] != details["baseline_verified_mtime"]:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote mtime changed after mtime-only local touch; expected no new upload",
                artifacts,
                details,
            )

        if details["monitor_reported_upload"]:
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor mode uploaded the file after an mtime-only local touch",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)