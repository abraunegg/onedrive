from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)
from framework.xlsx import REVISION_0, REVISION_1, REVISION_2, create_random_xlsx, mutate_xlsx_revision, validate_xlsx
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0036OverwriteReplaceExistingFileContentValidation(MonitorModeTestCaseBase):
    case_id = "0036"
    name = "overwrite / replace existing Microsoft file content validation"
    description = (
        "Validate XLSX content replacement across newer and timestamp-preserving older local "
        "mtime cases, including simple and session uploads, while retaining the safeBackup "
        "conflict path when the online item has genuinely changed"
    )

    SESSION_THRESHOLD_BYTES = 4 * 1024 * 1024
    SMALL_XLSX_PAYLOAD_ROWS = 80
    LARGE_XLSX_PAYLOAD_ROWS = 240

    def _write_config(
        self,
        config_dir: Path,
        sync_dir: Path,
        extra_config_lines: list[str] | None = None,
    ) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_lines = [
            "# tc0036 config",
            f'sync_dir = "{sync_dir}"',
        ]
        if extra_config_lines:
            config_lines.extend(extra_config_lines)
        config_text = "\n".join(config_lines) + "\n"

        write_onedrive_config(config_path, config_text)
        write_onedrive_config(backup_path, config_text)
        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")
        os.chmod(config_path, 0o600)
        os.chmod(backup_path, 0o600)
        os.chmod(hash_path, 0o600)

    @staticmethod
    def _rewrite_runtime_config(
        config_dir: Path,
        sync_root: Path,
        *,
        extra_lines: list[str] | None = None,
    ) -> None:
        """Rewrite runtime settings while preserving cloned DB/token/delta state."""
        config_path = config_dir / "config"
        existing_lines = config_path.read_text(encoding="utf-8").splitlines()
        retained_lines: list[str] = []
        managed_extra_keys = {
            "enable_logging",
            "log_dir",
            "monitor_interval",
            "monitor_fullscan_frequency",
            "disable_websocket_support",
            "bypass_data_preservation",
        }

        for raw_line in existing_lines:
            stripped = raw_line.strip()
            if stripped.startswith("sync_dir") and "=" in stripped:
                continue
            if extra_lines and "=" in stripped:
                key = stripped.split("=", 1)[0].strip()
                if key in managed_extra_keys:
                    continue
            retained_lines.append(raw_line)

        retained_lines.append(f'sync_dir = "{sync_root}"')
        if extra_lines:
            retained_lines.extend(extra_lines)

        config_text = "\n".join(retained_lines) + "\n"
        config_path.write_text(config_text, encoding="utf-8")
        os.chmod(config_path, 0o600)

        backup_path = config_dir / ".config.backup"
        backup_path.write_text(config_text, encoding="utf-8")
        os.chmod(backup_path, 0o600)

        hash_path = config_dir / ".config.hash"
        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")
        os.chmod(hash_path, 0o600)

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _run_logged_command(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_path: Path,
        stderr_path: Path,
    ):
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_path, result.stdout)
        write_text_file(stderr_path, result.stderr)
        return result

    def _safe_backup_files_for(self, canonical_path: Path) -> list[Path]:
        return sorted(
            path
            for path in canonical_path.parent.glob(
                f"{canonical_path.stem}-*-safeBackup-????{canonical_path.suffix}"
            )
            if path.is_file()
        )

    def _sync_command(
        self,
        context: E2EContext,
        root_name: str,
        config_dir: Path,
        *,
        upload_only: bool = False,
        download_only: bool = False,
        resync: bool = False,
        debug: bool = False,
    ) -> list[str]:
        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
        ]
        if upload_only:
            command.append("--upload-only")
        if download_only:
            command.append("--download-only")
        command.append("--verbose")
        if debug:
            command.append("--verbose")
        if resync:
            command.extend(["--resync", "--resync-auth"])
        command.extend(
            [
                "--single-directory",
                root_name,
                "--confdir",
                str(config_dir),
            ]
        )
        return command

    def _run_local_replacement_scenario(
        self,
        context: E2EContext,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
        *,
        scenario_id: str,
        scenario_name: str,
        payload_rows: int,
        timestamp_mode: str,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        scenario_work_dir = case_work_dir / scenario_id
        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id

        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        local_root = scenario_work_dir / "syncroot"
        verify_root = scenario_work_dir / "verifyroot"
        conf_main = scenario_work_dir / "conf-main"
        conf_verify = scenario_work_dir / "conf-verify"

        reset_directory(local_root)
        reset_directory(verify_root)
        context.prepare_minimal_config_dir(conf_main, "")
        context.prepare_minimal_config_dir(conf_verify, "")
        self._write_config(conf_main, local_root)
        self._write_config(conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0036_{scenario_id}_{context.run_id}_{os.getpid()}"
        relative_path = f"{root_name}/replace-me.xlsx"
        local_file_path = local_root / relative_path
        verify_file_path = verify_root / relative_path

        phase1_stdout = scenario_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_replace_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_replace_stderr.log"
        phase3_stdout = scenario_log_dir / "phase3_verify_stdout.log"
        phase3_stderr = scenario_log_dir / "phase3_verify_stderr.log"
        verify_manifest_file = scenario_state_dir / "verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts.extend(
            [
                str(phase1_stdout),
                str(phase1_stderr),
                str(phase2_stdout),
                str(phase2_stderr),
                str(phase3_stdout),
                str(phase3_stderr),
                str(verify_manifest_file),
                str(metadata_file),
            ]
        )

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:{scenario_id}:{os.getpid()}"
        generated = create_random_xlsx(
            local_file_path,
            xlsx_seed,
            payload_rows=payload_rows,
            title=f"TC0036 {scenario_id} replacement workbook",
        )
        generated_size = int(generated["size_bytes"])
        expected_session_upload = generated_size > self.SESSION_THRESHOLD_BYTES

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "root_name": root_name,
            "relative_path": relative_path,
            "timestamp_mode": timestamp_mode,
            "payload_rows": payload_rows,
            "generated_size": generated_size,
            "expected_session_upload": expected_session_upload,
            "xlsx_seed": xlsx_seed,
            "main_conf_dir": str(conf_main),
            "verify_conf_dir": str(conf_verify),
            "local_root": str(local_root),
            "verify_root": str(verify_root),
        }

        if payload_rows == self.SMALL_XLSX_PAYLOAD_ROWS and generated_size > self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} small XLSX unexpectedly exceeded the 4 MiB session threshold", details
        if payload_rows == self.LARGE_XLSX_PAYLOAD_ROWS and generated_size <= self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} large XLSX did not exceed the 4 MiB session threshold", details

        phase1_result = self._run_logged_command(
            context,
            f"{scenario_id} phase1 seed",
            self._sync_command(context, root_name, conf_main),
            phase1_stdout,
            phase1_stderr,
        )
        details["phase1_returncode"] = phase1_result.returncode
        if phase1_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} seed phase failed with status {phase1_result.returncode}", details

        baseline_validation_error = validate_xlsx(local_file_path, REVISION_0)
        details["baseline_validation_error"] = baseline_validation_error
        if baseline_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} seeded XLSX was invalid after initial sync: {baseline_validation_error}", details

        baseline_hash = compute_quickxor_hash_file(local_file_path)
        baseline_size = local_file_path.stat().st_size
        baseline_mtime = int(local_file_path.stat().st_mtime)
        details["baseline_hash"] = baseline_hash
        details["baseline_size"] = baseline_size
        details["baseline_mtime"] = baseline_mtime

        if payload_rows == self.SMALL_XLSX_PAYLOAD_ROWS and baseline_size > self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} settled small XLSX unexpectedly exceeded the 4 MiB session threshold", details
        if payload_rows == self.LARGE_XLSX_PAYLOAD_ROWS and baseline_size <= self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} settled large XLSX did not exceed the 4 MiB session threshold", details

        # Reproduce the user workflow as a timestamp-preserving copy-over rather
        # than editing the synced file in place. Build the replacement from the
        # settled Microsoft-returned workbook so any SharePoint enrichment remains
        # part of the XLSX package under test.
        replacement_source = scenario_work_dir / "replacement-source.xlsx"
        shutil.copy2(local_file_path, replacement_source)
        mutate_xlsx_revision(replacement_source, REVISION_0, REVISION_1)
        replacement_hash_before_timestamp = compute_quickxor_hash_file(replacement_source)
        if replacement_hash_before_timestamp == baseline_hash:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} XLSX revision mutation did not change file content", details

        if timestamp_mode == "older":
            replacement_epoch = max(1, baseline_mtime - 3600)
        elif timestamp_mode == "newer":
            replacement_epoch = max(int(time.time()), baseline_mtime) + 120
        else:
            raise ValueError(f"Unsupported timestamp mode: {timestamp_mode}")

        os.utime(replacement_source, (replacement_epoch, replacement_epoch))
        shutil.copy2(replacement_source, local_file_path)
        replacement_mtime = int(local_file_path.stat().st_mtime)
        replacement_hash = compute_quickxor_hash_file(local_file_path)

        details["replacement_epoch"] = replacement_epoch
        details["replacement_mtime"] = replacement_mtime
        replacement_size = local_file_path.stat().st_size
        details["replacement_hash"] = replacement_hash
        details["replacement_size"] = replacement_size
        details["replacement_source"] = str(replacement_source)

        if payload_rows == self.SMALL_XLSX_PAYLOAD_ROWS and replacement_size > self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} small replacement XLSX unexpectedly exceeded the 4 MiB session threshold", details
        if payload_rows == self.LARGE_XLSX_PAYLOAD_ROWS and replacement_size <= self.SESSION_THRESHOLD_BYTES:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} large replacement XLSX did not exceed the 4 MiB session threshold", details

        if replacement_hash != replacement_hash_before_timestamp:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} setting replacement mtime unexpectedly changed XLSX content", details
        if timestamp_mode == "older" and replacement_mtime >= baseline_mtime:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} failed to establish an older local replacement mtime", details
        if timestamp_mode == "newer" and replacement_mtime <= baseline_mtime:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} failed to establish a newer local replacement mtime", details

        phase2_result = self._run_logged_command(
            context,
            f"{scenario_id} phase2 replacement",
            self._sync_command(context, root_name, conf_main, debug=True),
            phase2_stdout,
            phase2_stderr,
        )
        details["phase2_returncode"] = phase2_result.returncode

        phase2_output = phase2_result.stdout + "\n" + phase2_result.stderr
        modified_upload_marker = f"Uploading modified file: {relative_path} ... done"
        conflict_marker = "Skipping uploading this item as a locally modified file"
        guard_marker = "Online eTag matches database eTag; treating as local modification despite older local timestamp"
        local_safe_backups = self._safe_backup_files_for(local_file_path)

        details["phase2_modified_upload_seen"] = modified_upload_marker in phase2_output
        details["phase2_conflict_marker_seen"] = conflict_marker in phase2_output
        details["phase2_guard_marker_seen"] = guard_marker in phase2_output
        details["local_safe_backup_files"] = [str(path.relative_to(local_root)) for path in local_safe_backups]

        if phase2_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} replacement sync failed with status {phase2_result.returncode}", details
        if modified_upload_marker not in phase2_output:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} did not report a successful modified-file upload", details
        if conflict_marker in phase2_output:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} incorrectly entered the newer-online safeBackup conflict path", details
        if local_safe_backups:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} incorrectly created a local safeBackup for the replacement", details
        if timestamp_mode == "older" and guard_marker not in phase2_output:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} did not exercise the unchanged-eTag older-mtime guard", details

        phase3_result = self._run_logged_command(
            context,
            f"{scenario_id} phase3 fresh verification",
            self._sync_command(context, root_name, conf_verify, download_only=True, resync=True),
            phase3_stdout,
            phase3_stderr,
        )
        details["phase3_returncode"] = phase3_result.returncode

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        expected_manifest = [root_name, relative_path]
        verify_validation_error = validate_xlsx(verify_file_path, REVISION_1)

        details["verify_manifest"] = verify_manifest
        details["expected_manifest"] = expected_manifest
        details["verify_validation_error"] = verify_validation_error
        self._write_metadata(metadata_file, details)

        if phase3_result.returncode != 0:
            return False, f"{scenario_id} fresh remote verification failed with status {phase3_result.returncode}", details
        if verify_validation_error:
            return False, f"{scenario_id} remote canonical XLSX did not contain the replacement revision: {verify_validation_error}", details
        if verify_manifest != expected_manifest:
            return False, f"{scenario_id} remote verification found unexpected files, including a possible safeBackup", details

        return True, f"{scenario_id} passed", details

    def _run_remote_change_control_scenario(
        self,
        context: E2EContext,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
        *,
        scenario_id: str,
        scenario_name: str,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        scenario_work_dir = case_work_dir / scenario_id
        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id

        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        subject_root = scenario_work_dir / "subject-root"
        mutator_root = scenario_work_dir / "mutator-root"
        precheck_root = scenario_work_dir / "precheck-root"
        verify_root = scenario_work_dir / "verify-root"
        conf_subject = scenario_work_dir / "conf-subject"
        conf_mutator = scenario_work_dir / "conf-mutator"
        conf_precheck = scenario_work_dir / "conf-precheck"
        conf_verify = scenario_work_dir / "conf-verify"

        for path in [subject_root, precheck_root, verify_root]:
            reset_directory(path)

        context.prepare_minimal_config_dir(conf_subject, "")
        context.prepare_minimal_config_dir(conf_precheck, "")
        context.prepare_minimal_config_dir(conf_verify, "")
        self._write_config(conf_subject, subject_root)
        self._write_config(conf_precheck, precheck_root)
        self._write_config(conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0036_{scenario_id}_{context.run_id}_{os.getpid()}"
        relative_path = f"{root_name}/replace-me.xlsx"
        subject_file = subject_root / relative_path
        mutator_file = mutator_root / relative_path
        precheck_file = precheck_root / relative_path
        verify_file = verify_root / relative_path

        phase_files = {
            "seed": (
                scenario_log_dir / "phase1_subject_seed_stdout.log",
                scenario_log_dir / "phase1_subject_seed_stderr.log",
            ),
            "mutator": (
                scenario_log_dir / "phase2_mutator_monitor_stdout.log",
                scenario_log_dir / "phase2_mutator_monitor_stderr.log",
            ),
            "precheck": (
                scenario_log_dir / "phase3_remote_precheck_stdout.log",
                scenario_log_dir / "phase3_remote_precheck_stderr.log",
            ),
            "subject_conflict": (
                scenario_log_dir / "phase4_subject_conflict_stdout.log",
                scenario_log_dir / "phase4_subject_conflict_stderr.log",
            ),
            "verify": (
                scenario_log_dir / "phase5_verify_stdout.log",
                scenario_log_dir / "phase5_verify_stderr.log",
            ),
        }
        precheck_manifest_file = scenario_state_dir / "precheck_manifest.txt"
        verify_manifest_file = scenario_state_dir / "verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"
        for stdout_path, stderr_path in phase_files.values():
            artifacts.extend([str(stdout_path), str(stderr_path)])
        artifacts.extend(
            [
                str(precheck_manifest_file),
                str(verify_manifest_file),
                str(metadata_file),
            ]
        )

        xlsx_seed = f"{context.run_id}:{context.e2e_target}:{scenario_id}:{os.getpid()}"
        generated = create_random_xlsx(
            subject_file,
            xlsx_seed,
            payload_rows=self.SMALL_XLSX_PAYLOAD_ROWS,
            title=f"TC0036 {scenario_id} remote-change control workbook",
        )
        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "root_name": root_name,
            "relative_path": relative_path,
            "xlsx_seed": xlsx_seed,
            "generated_size": int(generated["size_bytes"]),
            "subject_conf_dir": str(conf_subject),
            "mutator_conf_dir": str(conf_mutator),
            "precheck_conf_dir": str(conf_precheck),
            "verify_conf_dir": str(conf_verify),
        }

        seed_result = self._run_logged_command(
            context,
            f"{scenario_id} phase1 subject seed",
            self._sync_command(context, root_name, conf_subject),
            *phase_files["seed"],
        )
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} subject seed failed with status {seed_result.returncode}", details

        subject_baseline_error = validate_xlsx(subject_file, REVISION_0)
        if subject_baseline_error:
            details["subject_baseline_validation_error"] = subject_baseline_error
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} subject baseline XLSX invalid after seed: {subject_baseline_error}", details

        subject_baseline_mtime = int(subject_file.stat().st_mtime)
        subject_baseline_hash = compute_quickxor_hash_file(subject_file)
        details["subject_baseline_mtime"] = subject_baseline_mtime
        details["subject_baseline_hash"] = subject_baseline_hash

        # Use the established multi-client E2E topology: clone the complete tracked
        # client state and local tree, then let a separate --monitor --upload-only
        # client perform the genuine online modification while the subject stays stale.
        if conf_mutator.exists():
            shutil.rmtree(conf_mutator)
        if mutator_root.exists():
            shutil.rmtree(mutator_root)
        shutil.copytree(conf_subject, conf_mutator)
        shutil.copytree(subject_root, mutator_root)

        mutator_app_log_dir = scenario_log_dir / "app-logs"
        self._rewrite_runtime_config(
            conf_mutator,
            mutator_root,
            extra_lines=[
                'bypass_data_preservation = "true"',
                'enable_logging = "true"',
                f'log_dir = "{mutator_app_log_dir}"',
                'monitor_interval = "300"',
                'monitor_fullscan_frequency = "0"',
                'disable_websocket_support = "true"',
            ],
        )

        mutator_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--upload-only",
            "--verbose",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_mutator),
        ]
        details["mutator_command"] = command_to_string(mutator_command)
        context.log(
            f"Executing Test Case {self.case_id} {scenario_id} phase2 mutator monitor: "
            f"{details['mutator_command']}"
        )

        mutator_process, mutator_initial_sync_complete = self._launch_monitor_process(
            context,
            mutator_command,
            *phase_files["mutator"],
            startup_timeout_seconds=300,
        )
        details["mutator_initial_sync_complete"] = mutator_initial_sync_complete
        mutator_modified = False
        mutator_segment = ""
        try:
            if mutator_initial_sync_complete:
                mutation_offset = self._prepare_monitor_for_local_mutation(
                    mutator_process,
                    phase_files["mutator"][0],
                    details,
                )
                if bool(details.get("monitor_ready_after_initial_sync", False)):
                    mutator_replacement_source = scenario_work_dir / "mutator-replacement-source.xlsx"
                    shutil.copy2(mutator_file, mutator_replacement_source)
                    mutate_xlsx_revision(mutator_replacement_source, REVISION_0, REVISION_2)
                    mutator_epoch = max(
                        int(time.time()),
                        int(mutator_replacement_source.stat().st_mtime),
                        subject_baseline_mtime,
                    ) + 240
                    os.utime(mutator_replacement_source, (mutator_epoch, mutator_epoch))
                    shutil.copy2(mutator_replacement_source, mutator_file)
                    details["mutator_epoch"] = mutator_epoch
                    details["mutator_hash"] = compute_quickxor_hash_file(mutator_file)
                    details["mutator_replacement_source"] = str(mutator_replacement_source)
                    mutator_modified, mutator_segment = self._wait_for_stdout_growth_patterns(
                        phase_files["mutator"][0],
                        start_offset=mutation_offset,
                        required_patterns=[f"Uploading modified file: {relative_path} ... done"],
                        timeout_seconds=180,
                    )
        finally:
            self._shutdown_monitor_process(mutator_process, details)

        details["mutator_modified"] = mutator_modified
        details["mutator_log_segment_length"] = len(mutator_segment)
        if not mutator_initial_sync_complete:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} mutator monitor did not complete its initial sync", details
        if not bool(details.get("monitor_ready_after_initial_sync", False)):
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} mutator monitor was not ready for local modification", details
        if not mutator_modified:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} mutator monitor did not propagate the genuine remote modification", details

        # Confirm the remote object really contains the mutator revision before the
        # stale subject is evaluated. This removes Graph/event timing from the control.
        precheck_result = self._run_logged_command(
            context,
            f"{scenario_id} phase3 remote precheck",
            self._sync_command(context, root_name, conf_precheck, download_only=True, resync=True),
            *phase_files["precheck"],
        )
        details["precheck_returncode"] = precheck_result.returncode
        precheck_manifest = build_manifest(precheck_root)
        write_manifest(precheck_manifest_file, precheck_manifest)
        precheck_validation_error = validate_xlsx(precheck_file, REVISION_2)
        details["precheck_manifest"] = precheck_manifest
        details["precheck_validation_error"] = precheck_validation_error
        if precheck_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} remote precheck failed with status {precheck_result.returncode}", details
        if precheck_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} remote precheck did not contain the mutator revision: {precheck_validation_error}", details

        subject_replacement_source = scenario_work_dir / "subject-replacement-source.xlsx"
        shutil.copy2(subject_file, subject_replacement_source)
        mutate_xlsx_revision(subject_replacement_source, REVISION_0, REVISION_1)
        subject_replacement_epoch = max(1, subject_baseline_mtime - 3600)
        os.utime(subject_replacement_source, (subject_replacement_epoch, subject_replacement_epoch))
        shutil.copy2(subject_replacement_source, subject_file)
        details["subject_replacement_epoch"] = subject_replacement_epoch
        details["subject_replacement_hash"] = compute_quickxor_hash_file(subject_file)
        details["subject_replacement_source"] = str(subject_replacement_source)

        if int(subject_file.stat().st_mtime) >= subject_baseline_mtime:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} failed to establish the older local replacement precondition", details

        subject_conflict_result = self._run_logged_command(
            context,
            f"{scenario_id} phase4 subject conflict",
            self._sync_command(context, root_name, conf_subject, debug=True),
            *phase_files["subject_conflict"],
        )
        details["subject_conflict_returncode"] = subject_conflict_result.returncode

        conflict_output = subject_conflict_result.stdout + "\n" + subject_conflict_result.stderr
        conflict_marker = "Skipping uploading this item as a locally modified file"
        guard_marker = "Online eTag matches database eTag; treating as local modification despite older local timestamp"
        local_safe_backups = self._safe_backup_files_for(subject_file)

        details["conflict_marker_seen"] = conflict_marker in conflict_output
        details["guard_marker_seen"] = guard_marker in conflict_output
        details["local_safe_backup_files"] = [str(path.relative_to(subject_root)) for path in local_safe_backups]

        if subject_conflict_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} subject conflict sync failed with status {subject_conflict_result.returncode}", details
        if guard_marker in conflict_output:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} incorrectly trusted the database eTag after the remote item changed", details
        if len(local_safe_backups) != 1:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} expected exactly one local safeBackup, found {len(local_safe_backups)}", details

        canonical_validation_error = validate_xlsx(subject_file, REVISION_2)
        backup_validation_error = validate_xlsx(local_safe_backups[0], REVISION_1)
        details["canonical_validation_error"] = canonical_validation_error
        details["backup_validation_error"] = backup_validation_error
        if canonical_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} canonical file did not retain the genuine remote revision: {canonical_validation_error}", details
        if backup_validation_error:
            self._write_metadata(metadata_file, details)
            return False, f"{scenario_id} safeBackup did not preserve the local replacement revision: {backup_validation_error}", details

        verify_result = self._run_logged_command(
            context,
            f"{scenario_id} phase5 fresh verification",
            self._sync_command(context, root_name, conf_verify, download_only=True, resync=True),
            *phase_files["verify"],
        )
        details["verify_returncode"] = verify_result.returncode

        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        backup_relative_path = f"{root_name}/{local_safe_backups[0].name}"
        expected_manifest = sorted([root_name, relative_path, backup_relative_path])
        verify_backup_file = verify_root / backup_relative_path
        verify_canonical_error = validate_xlsx(verify_file, REVISION_2)
        verify_backup_error = validate_xlsx(verify_backup_file, REVISION_1)

        details["verify_manifest"] = verify_manifest
        details["expected_manifest"] = expected_manifest
        details["verify_canonical_error"] = verify_canonical_error
        details["verify_backup_error"] = verify_backup_error
        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return False, f"{scenario_id} fresh remote verification failed with status {verify_result.returncode}", details
        if verify_manifest != expected_manifest:
            return False, f"{scenario_id} fresh verification did not contain exactly the canonical file and one safeBackup", details
        if verify_canonical_error:
            return False, f"{scenario_id} remote canonical XLSX does not contain the genuine remote revision: {verify_canonical_error}", details
        if verify_backup_error:
            return False, f"{scenario_id} remote safeBackup does not contain the preserved local revision: {verify_backup_error}", details

        return True, f"{scenario_id} passed", details

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0036",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        artifacts: list[str] = []
        details: dict[str, object] = {}
        failed_scenarios: list[str] = []

        scenarios = [
            {
                "scenario_id": "OR-0001",
                "scenario_name": "small XLSX replacement with newer local mtime using simple upload",
                "payload_rows": self.SMALL_XLSX_PAYLOAD_ROWS,
                "timestamp_mode": "newer",
                "remote_change_control": False,
            },
            {
                "scenario_id": "OR-0002",
                "scenario_name": "small XLSX replacement with preserved older local mtime using simple upload",
                "payload_rows": self.SMALL_XLSX_PAYLOAD_ROWS,
                "timestamp_mode": "older",
                "remote_change_control": False,
            },
            {
                "scenario_id": "OR-0003",
                "scenario_name": "large XLSX replacement with preserved older local mtime using automatic session upload",
                "payload_rows": self.LARGE_XLSX_PAYLOAD_ROWS,
                "timestamp_mode": "older",
                "remote_change_control": False,
            },
            {
                "scenario_id": "OR-0004",
                "scenario_name": "genuine remote XLSX change preserves both revisions through safeBackup handling",
                "payload_rows": self.SMALL_XLSX_PAYLOAD_ROWS,
                "timestamp_mode": "older",
                "remote_change_control": True,
            },
        ]
        scenarios = [
            scenario
            for scenario in scenarios
            if context.should_run_scenario(self.case_id, scenario["scenario_id"])
        ]

        for scenario in scenarios:
            if scenario["remote_change_control"]:
                passed, message, scenario_details = self._run_remote_change_control_scenario(
                    context,
                    case_work_dir,
                    case_log_dir,
                    state_dir,
                    scenario_id=scenario["scenario_id"],
                    scenario_name=scenario["scenario_name"],
                    artifacts=artifacts,
                )
            else:
                passed, message, scenario_details = self._run_local_replacement_scenario(
                    context,
                    case_work_dir,
                    case_log_dir,
                    state_dir,
                    scenario_id=scenario["scenario_id"],
                    scenario_name=scenario["scenario_name"],
                    payload_rows=scenario["payload_rows"],
                    timestamp_mode=scenario["timestamp_mode"],
                    artifacts=artifacts,
                )

            details[scenario["scenario_id"]] = scenario_details
            details[f"{scenario['scenario_id']}_passed"] = passed
            details[f"{scenario['scenario_id']}_message"] = message
            if not passed:
                failed_scenarios.append(scenario["scenario_id"])

        details["executed_scenario_ids"] = [scenario["scenario_id"] for scenario in scenarios]
        details["failed_scenario_ids"] = list(failed_scenarios)

        summary_file = state_dir / "scenario-summary.txt"
        summary_lines: list[str] = []
        for scenario in scenarios:
            scenario_id = scenario["scenario_id"]
            summary_lines.append(
                f"{scenario_id}: passed={details.get(f'{scenario_id}_passed')} "
                f"message={details.get(f'{scenario_id}_message')!r}"
            )
        write_text_file(summary_file, "\n".join(summary_lines) + "\n")
        artifacts.append(str(summary_file))

        metadata_file = state_dir / "metadata.txt"
        self._write_metadata(metadata_file, details)
        artifacts.append(str(metadata_file))

        if failed_scenarios:
            return self.fail_result(
                self.case_id,
                self.name,
                f"{len(failed_scenarios)} of {len(scenarios)} overwrite/replacement scenarios failed: {', '.join(failed_scenarios)}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
