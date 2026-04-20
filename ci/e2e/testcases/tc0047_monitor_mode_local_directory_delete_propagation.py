from __future__ import annotations

import os
import shutil

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0047MonitorModeLocalDirectoryDeletePropagation(MonitorModeTestCaseBase):
    case_id = "0047"
    name = "monitor mode local directory delete propagation"
    description = "Delete a populated local directory tree under --monitor and validate the remote delete"

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0047",
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

        root_name = f"ZZ_E2E_TC0047_{context.run_id}_{os.getpid()}"
        keep_relative = f"{root_name}/anchor.txt"
        delete_dir_relative = f"{root_name}/delete-directory"
        delete_file1_relative = f"{delete_dir_relative}/file1.txt"
        delete_file2_relative = f"{delete_dir_relative}/nested/file2.txt"

        keep_local_path = sync_root / keep_relative
        delete_dir_local_path = sync_root / delete_dir_relative
        delete_file1_local_path = sync_root / delete_file1_relative
        delete_file2_local_path = sync_root / delete_file2_relative
        keep_verify_path = verify_root / keep_relative
        delete_dir_verify_path = verify_root / delete_dir_relative

        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(
            conf_verify,
            (
                "# tc0047 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        write_text_file(keep_local_path, "TC0047 anchor\n")
        write_text_file(delete_file1_local_path, "TC0047 delete file 1\n")
        write_text_file(delete_file2_local_path, "TC0047 delete file 2\n")

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [str(seed_stdout), str(seed_stderr), str(monitor_stdout), str(monitor_stderr), str(verify_stdout), str(verify_stderr), str(verify_manifest_file), str(metadata_file)]
        details = {"root_name": root_name, "keep_relative": keep_relative, "delete_dir_relative": delete_dir_relative, "delete_file1_relative": delete_file1_relative, "delete_file2_relative": delete_file2_relative}

        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Seed phase failed with status {seed_result.returncode}", artifacts, details)

        monitor_command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose", "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")
        process = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
        try:
            initial_sync_complete = self._wait_for_initial_sync_complete(monitor_stdout)
            details["initial_sync_complete"] = initial_sync_complete
            if not initial_sync_complete:
                self._write_metadata(metadata_file, details)
                return self.fail_result(self.case_id, self.name, "Monitor mode did not complete the initial sync within the expected time", artifacts, details)

            shutil.rmtree(delete_dir_local_path)
            groups = [
                [f"Deleting item from Microsoft OneDrive: {delete_file1_relative}"],
                [f"Deleting item from Microsoft OneDrive: {delete_file2_relative}"],
                [f"Deleting item from Microsoft OneDrive: {delete_dir_relative}"],
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
        details["verify_keep_exists"] = keep_verify_path.is_file()
        details["verify_deleted_dir_exists"] = delete_dir_verify_path.exists()
        self._write_metadata(metadata_file, details)

        if not details.get("mutation_processed", False):
            return self.fail_result(self.case_id, self.name, "Monitor mode did not process the local directory delete event before shutdown", artifacts, details)
        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if not keep_verify_path.is_file():
            return self.fail_result(self.case_id, self.name, f"Remote verification is missing retained anchor file: {keep_relative}", artifacts, details)
        if delete_dir_verify_path.exists():
            return self.fail_result(self.case_id, self.name, f"Remote verification still contains deleted directory tree: {delete_dir_relative}", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
