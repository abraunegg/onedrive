from __future__ import annotations

import os
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_text_file,
)
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx, mutate_xlsx_revision, validate_xlsx


class TestCase0042MonitorModeLocalModifyUpload(MonitorModeTestCaseBase):
    case_id = "0042"
    name = "monitor mode local modify upload"
    description = (
        "Modify an existing real XLSX workbook under --monitor and validate the update propagates"
    )

    XLSX_PAYLOAD_ROWS = 32

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _build_config_text(self, sync_dir: Path, app_log_dir: Path) -> str:
        return (
            "# tc0042 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            'enable_logging = "true"\n'
            f'log_dir = "{app_log_dir}"\n'
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n'
        )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0042",
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

        root_name = f"ZZ_E2E_TC0042_{context.run_id}_{os.getpid()}"
        relative_path = f"{root_name}/modify-me.xlsx"
        local_file_path = sync_root / relative_path
        verify_file_path = verify_root / relative_path
        xlsx_seed = f"{context.run_id}:{context.e2e_target}:TC0042:{os.getpid()}"

        context.bootstrap_config_dir(conf_main)
        write_text_file(conf_main / "config", self._build_config_text(sync_root, app_log_dir))

        context.bootstrap_config_dir(conf_verify)
        write_text_file(
            conf_verify / "config",
            (
                "# tc0042 verify\n"
                f'sync_dir = "{verify_root}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

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
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))

        generated = create_random_xlsx(
            local_file_path,
            xlsx_seed,
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0042 monitor local modification workbook",
        )
        initial_generated_hash = compute_quickxor_hash_file(local_file_path)

        details: dict[str, object] = {
            "root_name": root_name,
            "relative_path": relative_path,
            "sync_root": str(sync_root),
            "verify_root": str(verify_root),
            "conf_main": str(conf_main),
            "conf_verify": str(conf_verify),
            "xlsx_seed": xlsx_seed,
            "payload_rows": self.XLSX_PAYLOAD_ROWS,
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

        settled_hash = compute_quickxor_hash_file(local_file_path)
        details["settled_hash"] = settled_hash
        details["settled_size"] = local_file_path.stat().st_size
        details["microsoft_changed_seed_bytes"] = settled_hash != initial_generated_hash

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

            mutation_log_start_offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)

            context.log(f"Test Case {self.case_id}: modifying local XLSX while monitor is running: {relative_path}")
            mutate_xlsx_revision(local_file_path, REVISION_0, REVISION_1)
            modified_validation_error = validate_xlsx(local_file_path, REVISION_1)
            modified_hash = compute_quickxor_hash_file(local_file_path)
            details["modified_validation_error"] = modified_validation_error
            details["modified_hash"] = modified_hash
            details["local_file_exists_after_modify"] = local_file_path.is_file()

            if modified_validation_error:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"Local XLSX mutation produced an invalid workbook: {modified_validation_error}",
                    artifacts,
                    details,
                )
            if modified_hash == settled_hash:
                self._write_metadata(metadata_file, details)
                return self.fail_result(
                    self.case_id,
                    self.name,
                    "Local XLSX revision mutation did not change file content",
                    artifacts,
                    details,
                )

            required_patterns = [
                f"Uploading modified file: {relative_path} ... done",
            ]
            mutation_processed, post_mutation_log_segment = self._wait_for_stdout_growth_patterns(
                monitor_stdout,
                start_offset=mutation_log_start_offset,
                required_patterns=required_patterns,
                timeout_seconds=180,
            )
            post_mutation_sync_complete = self.SYNC_COMPLETE_PATTERN in post_mutation_log_segment
            details["post_mutation_sync_complete"] = post_mutation_sync_complete
            details["mutation_processed"] = mutation_processed
            details["post_mutation_log_segment_length"] = len(post_mutation_log_segment)
            details["mutation_required_patterns"] = required_patterns
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
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        details["verify_returncode"] = verify_result.returncode

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)

        details["verify_file_exists"] = verify_file_path.is_file()
        verify_validation_error = validate_xlsx(verify_file_path, REVISION_1) if verify_file_path.is_file() else "Verification XLSX is missing"
        verify_hash = compute_quickxor_hash_file(verify_file_path) if verify_file_path.is_file() else ""
        details["verify_validation_error"] = verify_validation_error
        details["verify_hash"] = verify_hash

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if not verify_file_path.is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification is missing modified file: {relative_path}",
                artifacts,
                details,
            )

        if verify_validation_error:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification returned an invalid or stale XLSX workbook: {verify_validation_error}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
