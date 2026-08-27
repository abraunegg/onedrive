from __future__ import annotations

import os
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file


class TestCase0078MonitorModeRenameToInvalidName(MonitorModeTestCaseBase):
    """Rename an already-synced file to a name the Microsoft naming rules reject.

    tc0025 validates that files which are *created* with an invalid name are skipped, and
    tc0044 validates that a rename between two valid names propagates.  Neither covers the
    intersection: a file that is already online being renamed locally into a name that
    cannot exist online.

    In that case the item has not left the sync scope - it is still inside sync_dir, it
    simply cannot be represented online under its new name.  The online copy is therefore
    the only synced copy of data that still exists locally, and it must be preserved.  No
    subsequent scan can restore it if it is removed, because the local name remains invalid.
    """

    case_id = "0078"
    name = "monitor mode rename to invalid name"
    description = (
        "Rename a synced file to a name rejected by the Microsoft naming rules and validate "
        "that the online copy is preserved and no remote delete is attempted"
    )

    EXCLUDED_LOCATION_MARKER = (
        "Item has been moved to a location that is excluded from sync operations"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0078",
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

        root_name = f"ZZ_E2E_TC0078_{context.run_id}_{os.getpid()}"

        # The invalid leaf name uses '<' and '>', which tc0025 already establishes are
        # rejected by the Microsoft naming rules.
        old_relative = f"{root_name}/valid-original-name.txt"
        new_relative = f"{root_name}/renamed <into> an invalid name.txt"

        old_local_path = sync_root / old_relative
        new_local_path = sync_root / new_relative
        old_verify_path = verify_root / old_relative
        new_verify_path = verify_root / new_relative

        file_content = (
            "TC0065 monitor mode rename to invalid name\n"
            "This online copy must survive a local rename into an unrepresentable name.\n"
        )

        context.bootstrap_config_dir(conf_main)
        write_text_file(conf_main / "config", self._build_config_text(sync_root, app_log_dir))

        context.bootstrap_config_dir(conf_verify)
        write_text_file(
            conf_verify / "config",
            (
                "# tc0078 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        reconcile_stdout = case_log_dir / "reconcile_stdout.log"
        reconcile_stderr = case_log_dir / "reconcile_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(monitor_stdout),
            str(monitor_stderr),
            str(reconcile_stdout),
            str(reconcile_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(verify_manifest_file),
            str(metadata_file),
        ]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))

        details: dict[str, object] = {
            "root_name": root_name,
            "old_relative": old_relative,
            "new_relative": new_relative,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(conf_main),
            "conf_verify": str(conf_verify),
        }

        # Seed: place the file under a valid name and push it online.
        write_text_file(old_local_path, file_content)

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

        # A --sync pass reports scanned paths with a './' prefix, whereas monitor mode
        # event handling reports them without one.  Accept either form here.
        seed_upload_markers = [
            f"Uploading new file: {old_relative}",
            f"Uploading new file: ./{old_relative}",
        ]
        if not any(marker in seed_result.stdout for marker in seed_upload_markers):
            details["seed_upload_marker_present"] = False
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seed phase did not upload the file to be renamed: {old_relative}",
                artifacts,
                details,
            )
        details["seed_upload_marker_present"] = True

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

        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
        )
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

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(
                process, monitor_stdout, details
            )

            context.log(
                f"Test Case {self.case_id}: renaming local file into an invalid name while "
                f"monitor is running: {old_relative} -> {new_relative}"
            )
            old_local_path.rename(new_local_path)
            details["old_local_exists_after_rename"] = old_local_path.exists()
            details["new_local_exists_after_rename"] = new_local_path.is_file()

            # The naming rejection itself is correct and expected behaviour; it is the
            # anchor that tells us the client has finished processing the rename event.
            naming_skip_marker = (
                f"Skipping item - invalid name (Microsoft Naming Convention): {new_relative}"
            )
            mutation_processed, post_mutation_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                required_patterns=[naming_skip_marker],
                timeout_seconds=180,
            )
            details["mutation_processed"] = mutation_processed
            details["naming_skip_marker"] = naming_skip_marker
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)

            remote_delete_marker = f"Deleting item from Microsoft OneDrive: {old_relative}"
            excluded_location_seen = self.EXCLUDED_LOCATION_MARKER in post_mutation_log_segment
            remote_delete_attempted = remote_delete_marker in post_mutation_log_segment
            details["excluded_location_seen"] = excluded_location_seen
            details["remote_delete_attempted"] = remote_delete_attempted
        finally:
            self._shutdown_monitor_process(process, details)

        if not mutation_processed:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "Monitor mode did not report the invalid name for the renamed file",
                artifacts,
                details,
            )

        # An unrepresentable name is not the same thing as leaving the sync scope.  The file
        # is still inside sync_dir, so the online copy must not be treated as removable.
        if excluded_location_seen:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "Rename into an invalid name was classified as a move outside the sync scope",
                artifacts,
                details,
            )

        if remote_delete_attempted:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Client attempted to delete the online copy after a local rename: {old_relative}",
                artifacts,
                details,
            )

        # Handling the rename event correctly is not sufficient on its own.  The database
        # still records the item at its old path, and that path no longer exists locally
        # because the local file now carries the unusable name.  A subsequent scan that
        # reconciles the database against the filesystem will therefore see the old path as
        # a local deletion and remove the online copy anyway, which merely defers the loss
        # by one cycle.  Run a full sync pass with the same configuration so that this
        # reconciliation actually happens before the online state is inspected.
        reconcile_command = [
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
        context.log(f"Executing Test Case {self.case_id} reconcile: {command_to_string(reconcile_command)}")
        reconcile_result = run_command(reconcile_command, cwd=context.repo_root)
        write_text_file(reconcile_stdout, reconcile_result.stdout)
        write_text_file(reconcile_stderr, reconcile_result.stderr)
        details["reconcile_returncode"] = reconcile_result.returncode

        reconcile_delete_attempted = (
            f"Deleting item from Microsoft OneDrive: {old_relative}" in reconcile_result.stdout
        )
        details["reconcile_delete_attempted"] = reconcile_delete_attempted

        if reconcile_delete_attempted:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"A later sync pass removed the online copy as a local deletion: {old_relative}",
                artifacts,
                details,
            )

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
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        details["verify_returncode"] = verify_result.returncode

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)

        details["verify_old_exists"] = old_verify_path.is_file()
        details["verify_new_exists"] = new_verify_path.exists()
        details["verify_old_content"] = (
            old_verify_path.read_text(encoding="utf-8") if old_verify_path.is_file() else ""
        )

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        # The load-bearing assertion.  This currently passes even with the misclassification
        # present, because the delete is issued with a default-constructed Item and the API
        # rejects it.  It is asserted anyway so that correcting that second defect in
        # isolation cannot silently turn this into data loss.
        if not old_verify_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Online copy was removed after a local rename into an invalid name: {old_relative}",
                artifacts,
                details,
            )

        if details["verify_old_content"] != file_content:
            return self.fail_result(
                self.case_id,
                self.name,
                "Preserved online copy content did not match after remote verification",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
