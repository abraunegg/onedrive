from __future__ import annotations

import os
import shutil
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file


class TestCase0078MonitorModeRenameToInvalidName(MonitorModeTestCaseBase):
    """Preserve online data when an already-synced item is renamed to an invalid name.

    tc0025 validates that items which are *created* with an invalid name are skipped, and
    tc0044/tc0046 validate renames between valid names. Neither covers the intersection:
    an item that is already online being renamed locally into a name that cannot exist
    online.

    In that case the item has not left the sync scope - it is still inside sync_dir, it
    simply cannot be represented online under its new name. The existing online copy must
    therefore be preserved, and stale database tracking must be detached so a later scan
    cannot reinterpret the old path as a local deletion.
    """

    case_id = "0078"
    name = "monitor mode rename to invalid name"
    description = (
        "Rename synced file and directory items to names rejected by the Microsoft naming "
        "rules and validate that their online copies are preserved without remote deletion"
    )

    EXCLUDED_LOCATION_MARKER = (
        "Item has been moved to a location that is excluded from sync operations"
    )
    PRESERVED_ONLINE_PREFIX = (
        "Skipping move - the new name cannot be used on Microsoft OneDrive. "
        "The existing online copy has been preserved: "
    )
    REMOTE_DELETE_PREFIX = "Deleting item from Microsoft OneDrive: "

    def _contains_remote_delete_for_root(self, output: str, root_name: str) -> bool:
        return self._monitor_output_contains(
            output,
            f"{self.REMOTE_DELETE_PREFIX}{root_name}",
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

        # '<' and '>' are already established by tc0025 as invalid Microsoft names.
        old_file_relative = f"{root_name}/valid-original-name.txt"
        new_file_relative = f"{root_name}/renamed <into> an invalid name.txt"
        old_dir_relative = f"{root_name}/valid-original-directory"
        new_dir_relative = f"{root_name}/renamed <into> an invalid directory"
        old_dir_file_relative = f"{old_dir_relative}/child-a.txt"
        old_nested_dir_relative = f"{old_dir_relative}/nested"
        old_nested_file_relative = f"{old_nested_dir_relative}/child-b.txt"

        old_file_local_path = sync_root / old_file_relative
        new_file_local_path = sync_root / new_file_relative
        old_dir_local_path = sync_root / old_dir_relative
        new_dir_local_path = sync_root / new_dir_relative

        file_content = (
            "TC0078 monitor mode rename to invalid name\n"
            "This online copy must survive a local rename into an unrepresentable name.\n"
        )
        dir_file_content = (
            "TC0078 invalid directory rename child A\n"
            "This file must remain online beneath the original directory name.\n"
        )
        nested_file_content = (
            "TC0078 invalid directory rename child B\n"
            "This nested file must remain online beneath the original directory name.\n"
        )

        expected_remote_manifest = [
            root_name,
            old_dir_relative,
            old_dir_file_relative,
            old_nested_dir_relative,
            old_nested_file_relative,
            old_file_relative,
        ]
        expected_remote_content = {
            old_file_relative: file_content,
            old_dir_file_relative: dir_file_content,
            old_nested_file_relative: nested_file_content,
        }

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
        seed_verify_stdout = case_log_dir / "seed_verify_stdout.log"
        seed_verify_stderr = case_log_dir / "seed_verify_stderr.log"
        monitor_stdout = case_log_dir / "monitor_stdout.log"
        monitor_stderr = case_log_dir / "monitor_stderr.log"
        reconcile_stdout = case_log_dir / "reconcile_stdout.log"
        reconcile_stderr = case_log_dir / "reconcile_stderr.log"
        convergence_stdout = case_log_dir / "convergence_stdout.log"
        convergence_stderr = case_log_dir / "convergence_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        seed_verify_manifest_file = state_dir / "seed_verify_manifest.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(seed_verify_stdout),
            str(seed_verify_stderr),
            str(monitor_stdout),
            str(monitor_stderr),
            str(reconcile_stdout),
            str(reconcile_stderr),
            str(convergence_stdout),
            str(convergence_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(seed_verify_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))

        details: dict[str, object] = {
            "root_name": root_name,
            "old_file_relative": old_file_relative,
            "new_file_relative": new_file_relative,
            "old_dir_relative": old_dir_relative,
            "new_dir_relative": new_dir_relative,
            "expected_remote_manifest": expected_remote_manifest,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(conf_main),
            "conf_verify": str(conf_verify),
        }

        # Seed both a file and a nested directory tree under valid names.
        write_text_file(old_file_local_path, file_content)
        write_text_file(sync_root / old_dir_file_relative, dir_file_content)
        write_text_file(sync_root / old_nested_file_relative, nested_file_content)

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

        # Keep the upload marker as a useful diagnostic, but independently prove the
        # complete seed state online before inducing the destructive regression path.
        seed_upload_marker = f"Uploading new file: {old_file_relative}"
        seed_upload_marker_present = self._monitor_output_contains(
            seed_result.stdout,
            seed_upload_marker,
        )
        details["seed_upload_marker_present"] = seed_upload_marker_present
        if not seed_upload_marker_present:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seed phase did not report uploading the file to be renamed: {old_file_relative}",
                artifacts,
                details,
            )

        seed_verify_command = [
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
        context.log(
            f"Executing Test Case {self.case_id} seed verify: "
            f"{command_to_string(seed_verify_command)}"
        )
        seed_verify_result = run_command(seed_verify_command, cwd=context.repo_root)
        write_text_file(seed_verify_stdout, seed_verify_result.stdout)
        write_text_file(seed_verify_stderr, seed_verify_result.stderr)
        details["seed_verify_returncode"] = seed_verify_result.returncode

        seed_verify_manifest = build_manifest(verify_root)
        write_manifest(seed_verify_manifest_file, seed_verify_manifest)
        details["seed_verify_manifest"] = seed_verify_manifest

        if seed_verify_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seed remote verification failed with status {seed_verify_result.returncode}",
                artifacts,
                details,
            )

        if seed_verify_manifest != expected_remote_manifest:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "Seed remote verification manifest did not match the complete expected tree",
                artifacts,
                details,
            )

        for relative_path, expected_content in expected_remote_content.items():
            verify_path = verify_root / relative_path
            if not verify_path.is_file() or verify_path.read_text(encoding="utf-8") != expected_content:
                details["seed_content_mismatch"] = relative_path
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"Seed remote verification content did not match: {relative_path}",
                    artifacts,
                    details,
                )

        # Final verification must be a fresh independent download rather than reusing
        # files downloaded by the seed precondition check.
        shutil.rmtree(verify_root, ignore_errors=True)
        verify_root.mkdir(parents=True, exist_ok=True)

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

            # Scenario A: synced file -> invalid file name.
            file_log_start_offset = self._prepare_monitor_for_local_mutation(
                process,
                monitor_stdout,
                details,
            )
            context.log(
                f"Test Case {self.case_id}: renaming local file into an invalid name while "
                f"monitor is running: {old_file_relative} -> {new_file_relative}"
            )
            old_file_local_path.rename(new_file_local_path)
            details["old_file_exists_after_rename"] = old_file_local_path.exists()
            details["new_file_exists_after_rename"] = new_file_local_path.is_file()

            file_naming_marker = (
                "Skipping item - invalid name (Microsoft Naming Convention): "
                f"{new_file_relative}"
            )
            file_preserved_marker = f"{self.PRESERVED_ONLINE_PREFIX}{old_file_relative}"
            file_processed, file_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=file_log_start_offset,
                required_patterns=[file_naming_marker, file_preserved_marker],
                timeout_seconds=180,
            )
            details["file_mutation_processed"] = file_processed
            details["file_naming_marker"] = file_naming_marker
            details["file_preserved_marker"] = file_preserved_marker

            if file_processed:
                details["file_output_quiet_after_terminal_marker"] = self._wait_for_monitor_stdout_quiet(
                    process,
                    monitor_stdout,
                    quiet_seconds=3.0,
                    timeout_seconds=30,
                )
                file_log_segment = self._read_monitor_output_from_offsets(
                    monitor_stdout,
                    file_log_start_offset,
                )

            details["file_post_mutation_log_segment_length"] = len(file_log_segment)
            details["file_excluded_location_seen"] = (
                self.EXCLUDED_LOCATION_MARKER in file_log_segment
            )
            details["file_remote_delete_attempted"] = self._contains_remote_delete_for_root(
                file_log_segment,
                root_name,
            )

            if not file_processed:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor mode did not complete safe processing of the invalid file rename",
                    artifacts,
                    details,
                )

            if details["file_excluded_location_seen"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Invalid file rename was classified as a move outside the sync scope",
                    artifacts,
                    details,
                )

            if details["file_remote_delete_attempted"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Client attempted remote deletion while processing the invalid file rename",
                    artifacts,
                    details,
                )

            # Scenario B: synced nested directory -> invalid directory name. This directly
            # exercises directory database detachment and descendant cascade behaviour.
            dir_log_start_offset = self._prepare_monitor_for_local_mutation(
                process,
                monitor_stdout,
                details,
            )
            context.log(
                f"Test Case {self.case_id}: renaming local directory into an invalid name while "
                f"monitor is running: {old_dir_relative} -> {new_dir_relative}"
            )
            old_dir_local_path.rename(new_dir_local_path)
            details["old_dir_exists_after_rename"] = old_dir_local_path.exists()
            details["new_dir_exists_after_rename"] = new_dir_local_path.is_dir()

            dir_naming_marker = (
                "Skipping item - invalid name (Microsoft Naming Convention): "
                f"{new_dir_relative}"
            )
            dir_preserved_marker = f"{self.PRESERVED_ONLINE_PREFIX}{old_dir_relative}"
            dir_processed, dir_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=dir_log_start_offset,
                required_patterns=[dir_naming_marker, dir_preserved_marker],
                timeout_seconds=180,
            )
            details["directory_mutation_processed"] = dir_processed
            details["directory_naming_marker"] = dir_naming_marker
            details["directory_preserved_marker"] = dir_preserved_marker

            if dir_processed:
                details["directory_output_quiet_after_terminal_marker"] = self._wait_for_monitor_stdout_quiet(
                    process,
                    monitor_stdout,
                    quiet_seconds=3.0,
                    timeout_seconds=30,
                )
                dir_log_segment = self._read_monitor_output_from_offsets(
                    monitor_stdout,
                    dir_log_start_offset,
                )

            details["directory_post_mutation_log_segment_length"] = len(dir_log_segment)
            details["directory_excluded_location_seen"] = (
                self.EXCLUDED_LOCATION_MARKER in dir_log_segment
            )
            details["directory_remote_delete_attempted"] = self._contains_remote_delete_for_root(
                dir_log_segment,
                root_name,
            )

            if not dir_processed:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Monitor mode did not complete safe processing of the invalid directory rename",
                    artifacts,
                    details,
                )

            if details["directory_excluded_location_seen"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Invalid directory rename was classified as a move outside the sync scope",
                    artifacts,
                    details,
                )

            if details["directory_remote_delete_attempted"]:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Client attempted remote deletion while processing the invalid directory rename",
                    artifacts,
                    details,
                )
        finally:
            self._shutdown_monitor_process(process, details)

        # A successful monitor event is not sufficient: stale DB state can defer deletion
        # until the next scan. Reconcile with the same configuration and require success.
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
        context.log(
            f"Executing Test Case {self.case_id} reconcile: {command_to_string(reconcile_command)}"
        )
        reconcile_result = run_command(reconcile_command, cwd=context.repo_root)
        write_text_file(reconcile_stdout, reconcile_result.stdout)
        write_text_file(reconcile_stderr, reconcile_result.stderr)
        details["reconcile_returncode"] = reconcile_result.returncode
        details["reconcile_delete_attempted"] = self._contains_remote_delete_for_root(
            reconcile_result.stdout,
            root_name,
        )

        if reconcile_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Reconciliation phase failed with status {reconcile_result.returncode}",
                artifacts,
                details,
            )

        if details["reconcile_delete_attempted"]:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "A later sync pass attempted to remove preserved online data as a local deletion",
                artifacts,
                details,
            )

        # Run one more same-DB reconciliation to prove the detached state has converged and
        # does not produce a repeated delete/error cycle.
        context.log(
            f"Executing Test Case {self.case_id} convergence: {command_to_string(reconcile_command)}"
        )
        convergence_result = run_command(reconcile_command, cwd=context.repo_root)
        write_text_file(convergence_stdout, convergence_result.stdout)
        write_text_file(convergence_stderr, convergence_result.stderr)
        details["convergence_returncode"] = convergence_result.returncode
        details["convergence_delete_attempted"] = self._contains_remote_delete_for_root(
            convergence_result.stdout,
            root_name,
        )

        if convergence_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Convergence phase failed with status {convergence_result.returncode}",
                artifacts,
                details,
            )

        if details["convergence_delete_attempted"]:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "A converged sync pass attempted to remove preserved online data",
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
        details["verify_manifest"] = verify_manifest

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if verify_manifest != expected_remote_manifest:
            return self.fail_result(
                self.case_id,
                self.name,
                "Final remote manifest changed after invalid file/directory renames",
                artifacts,
                details,
            )

        for relative_path, expected_content in expected_remote_content.items():
            verify_path = verify_root / relative_path
            if not verify_path.is_file():
                details["missing_verified_file"] = relative_path
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"Preserved online file is missing after final verification: {relative_path}",
                    artifacts,
                    details,
                )

            actual_content = verify_path.read_text(encoding="utf-8")
            if actual_content != expected_content:
                details["content_mismatch"] = relative_path
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"Preserved online file content changed: {relative_path}",
                    artifacts,
                    details,
                )

        self._write_metadata(metadata_file, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
