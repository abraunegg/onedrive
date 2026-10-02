from __future__ import annotations

import os
import time

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, compute_quickxor_hash_file, reset_directory, run_command, write_text_file
from framework.xlsx import REVISION_0, create_random_xlsx, validate_xlsx
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0051MonitorModeMtimeOnlyLocalChangeHandling(MonitorModeTestCaseBase):
    case_id = "0051"
    name = "monitor mode mtime-only Microsoft file change handling"
    description = (
        "Touch an existing local XLSX under --monitor without changing workbook content and validate "
        "that no new upload occurs, including after any Microsoft-side workbook enrichment"
    )

    XLSX_PAYLOAD_ROWS = 80

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
        relative_path = f"{root_name}/mtime-only.xlsx"
        local_file_path = sync_root / relative_path
        verify_initial_file_path = verify_initial_root / relative_path
        verify_final_file_path = verify_final_root / relative_path

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

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0051:{os.getpid()}"
        generated = create_random_xlsx(
            local_file_path,
            xlsx_seed,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0051 monitor mtime-only workbook",
        )
        initial_generated_hash = compute_quickxor_hash_file(local_file_path)

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
            "xlsx_seed": xlsx_seed,
            "generated_size": int(generated["size_bytes"]),
            "initial_generated_hash": initial_generated_hash,
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

        settled_validation_error = validate_xlsx(local_file_path, REVISION_0)
        details["settled_validation_error"] = settled_validation_error
        if settled_validation_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seeded XLSX was invalid after initial sync: {settled_validation_error}",
                artifacts,
                details,
            )

        settled_local_hash = compute_quickxor_hash_file(local_file_path)
        settled_local_size = local_file_path.stat().st_size
        details["settled_local_hash"] = settled_local_hash
        details["settled_local_size"] = settled_local_size
        details["microsoft_changed_seed_bytes"] = settled_local_hash != initial_generated_hash

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
        details["verify_initial_manifest"] = verify_initial_manifest

        if verify_initial_result.returncode != 0 or not verify_initial_file_path.is_file():
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "Initial remote verification failed before monitor mtime-only validation",
                artifacts,
                details,
            )

        verify_initial_validation_error = validate_xlsx(verify_initial_file_path, REVISION_0)
        baseline_verified_mtime = int(verify_initial_file_path.stat().st_mtime)
        verify_initial_hash = compute_quickxor_hash_file(verify_initial_file_path)
        details["verify_initial_validation_error"] = verify_initial_validation_error
        details["baseline_verified_mtime"] = baseline_verified_mtime
        details["verify_initial_hash"] = verify_initial_hash

        if verify_initial_validation_error:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Initial remote XLSX validation failed: {verify_initial_validation_error}",
                artifacts,
                details,
            )

        if verify_initial_hash != settled_local_hash:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                "Initial remote XLSX hash did not match the settled post-upload local workbook",
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
        process, initial_sync_complete = self._launch_monitor_process(context, monitor_command, monitor_stdout, monitor_stderr)
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

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            local_hash_before_touch = compute_quickxor_hash_file(local_file_path)
            local_mtime_before_touch = int(local_file_path.stat().st_mtime)
            touched_epoch = max(int(time.time()), local_mtime_before_touch, baseline_verified_mtime) + 120
            os.utime(local_file_path, (touched_epoch, touched_epoch))

            local_hash_after_touch = compute_quickxor_hash_file(local_file_path)
            local_mtime_after_touch = int(local_file_path.stat().st_mtime)

            details["local_hash_before_touch"] = local_hash_before_touch
            details["local_mtime_before_touch"] = local_mtime_before_touch
            details["local_mtime_after_touch"] = local_mtime_after_touch
            details["touched_epoch"] = touched_epoch
            details["local_hash_after_touch"] = local_hash_after_touch

            if local_hash_before_touch != settled_local_hash or local_hash_after_touch != settled_local_hash:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Local XLSX content changed during the mtime-only monitor stimulus",
                    artifacts,
                    details,
                )

            required_patterns = [
                f"Processing: {relative_path}",
                "The file has not changed",
            ]
            mutation_processed, post_mutation_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                required_patterns=required_patterns,
                timeout_seconds=60,
            )
            details["post_mutation_sync_complete"] = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["mutation_processed"] = mutation_processed
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
            details["mutation_required_patterns"] = required_patterns
            details["monitor_observed_processing"] = self._monitor_output_contains(
                post_mutation_log_segment,
                f"Processing: {relative_path}",
            )
            details["monitor_reported_no_change"] = "The file has not changed" in post_mutation_log_segment
            details["monitor_reported_upload"] = self._monitor_output_contains(
                post_mutation_log_segment,
                f"Uploading modified file: {relative_path} ... done",
            )
            details["monitor_reported_local_change_event"] = self._monitor_output_contains(
                post_mutation_log_segment,
                f"[M] Local file changed: {relative_path}",
            )
        finally:
            self._shutdown_monitor_process(process, details)

        post_monitor_validation_error = validate_xlsx(local_file_path, REVISION_0)
        details["post_monitor_validation_error"] = post_monitor_validation_error

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
        details["verify_final_manifest"] = verify_final_manifest
        details["verify_final_file_exists"] = verify_final_file_path.is_file()
        details["verify_final_hash"] = (
            compute_quickxor_hash_file(verify_final_file_path)
            if verify_final_file_path.is_file()
            else ""
        )
        details["final_verified_mtime"] = (
            int(verify_final_file_path.stat().st_mtime)
            if verify_final_file_path.is_file()
            else -1
        )
        details["verify_final_validation_error"] = (
            validate_xlsx(verify_final_file_path, REVISION_0)
            if verify_final_file_path.is_file()
            else "final XLSX file is missing"
        )

        self._write_metadata(metadata_file, details)

        if post_monitor_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Local XLSX became invalid during monitor mtime-only handling: {post_monitor_validation_error}",
                artifacts,
                details,
            )

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
                f"Remote verification is missing mtime-only XLSX: {relative_path}",
                artifacts,
                details,
            )

        if details["verify_final_validation_error"]:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Final remote XLSX validation failed: {details['verify_final_validation_error']}",
                artifacts,
                details,
            )

        if details["verify_final_hash"] != settled_local_hash:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote XLSX content changed after mtime-only local touch",
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
                "Monitor mode uploaded the XLSX after an mtime-only local touch",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
