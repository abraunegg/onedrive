from __future__ import annotations

import subprocess

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, write_text_file
from testcases_personal_shared_folders.shared_folder_common import (
    case_sync_root,
    manifest_failure_reason,
    reset_local_sync_root,
    stop_monitor_process,
    validate_expected_manifest,
    wait_for_stdout_marker,
    write_case_config,
    write_common_metadata,
)


class SharedFolderPersonalTestCase0002CleanMonitorPullDown(E2ETestCase):
    case_id = "sfptc0002"
    name = "personal shared folders clean monitor pull down"
    description = "Validate that --monitor --verbose pulls down the preserved Personal Account shared-folder topology without ghost folders"

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name=self.case_id,
            ensure_refresh_token=True,
        )

        sync_root = case_sync_root(self.case_id)
        confdir = layout.work_dir / "conf"
        reset_local_sync_root(sync_root)
        write_case_config(context, confdir, self.case_id)

        stdout_file = layout.log_dir / "stdout.log"
        stderr_file = layout.log_dir / "stderr.log"
        manifest_file = layout.state_dir / "local_typed_manifest.txt"
        expected_manifest_file = layout.state_dir / "expected_typed_manifest.txt"
        missing_manifest_file = layout.state_dir / "missing_expected_entries.txt"
        unexpected_manifest_file = layout.state_dir / "unexpected_extra_entries.txt"
        metadata_file = layout.state_dir / "metadata.txt"

        command = [
            context.onedrive_bin,
            "--monitor",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--confdir",
            str(confdir),
        ]

        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")

        with stdout_file.open("w", encoding="utf-8") as stdout_fp, stderr_file.open("w", encoding="utf-8") as stderr_fp:
            process = subprocess.Popen(
                command,
                cwd=str(context.repo_root),
                stdout=stdout_fp,
                stderr=stderr_fp,
                text=True,
            )
            initial_sync_complete = wait_for_stdout_marker(stdout_file, "Sync with Microsoft OneDrive is complete")
            monitor_returncode = stop_monitor_process(process)

        stdout_text = stdout_file.read_text(encoding="utf-8", errors="replace") if stdout_file.exists() else ""
        validation = validate_expected_manifest(
            sync_root=sync_root,
            stdout_text=stdout_text,
            manifest_file=manifest_file,
            expected_manifest_file=expected_manifest_file,
            missing_manifest_file=missing_manifest_file,
            unexpected_manifest_file=unexpected_manifest_file,
        )

        write_common_metadata(
            metadata_file,
            case_id=self.case_id,
            name=self.name,
            command=command,
            returncode=monitor_returncode,
            sync_root=sync_root,
            config_dir=confdir,
            validation=validation,
            extra_lines=[f"initial_sync_complete={initial_sync_complete}"],
        )

        artifacts = [
            str(stdout_file),
            str(stderr_file),
            str(manifest_file),
            str(expected_manifest_file),
            str(missing_manifest_file),
            str(unexpected_manifest_file),
            str(metadata_file),
        ]
        details = {
            "command": command,
            "monitor_returncode": monitor_returncode,
            "initial_sync_complete": initial_sync_complete,
            "sync_root": str(sync_root),
            "config_dir": str(confdir),
            **validation,
        }

        if not initial_sync_complete:
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor mode did not complete the initial shared-folder sync within the expected time",
                artifacts,
                details,
            )

        if monitor_returncode not in (0, 130, -2):
            return self.fail_result(
                self.case_id,
                self.name,
                f"monitor mode exited with unexpected status {monitor_returncode}",
                artifacts,
                details,
            )

        reason = manifest_failure_reason(validation)
        if reason:
            return self.fail_result(self.case_id, self.name, reason, artifacts, details)

        return self.pass_result(self.case_id, self.name, artifacts, details)
