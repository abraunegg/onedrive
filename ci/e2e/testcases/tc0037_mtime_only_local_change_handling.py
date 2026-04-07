from __future__ import annotations

import os
import time
from pathlib import Path

from framework.base import E2ETestCase
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


class TestCase0037MtimeOnlyLocalChangeHandling(E2ETestCase):
    case_id = "0037"
    name = "mtime-only local change handling"
    description = (
        "Validate that changing only the local modification timestamp of an existing "
        "file does not cause unintended content upload or remote state change"
    )

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0037 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
        )

        write_onedrive_config(config_path, config_text)
        write_onedrive_config(backup_path, config_text)
        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")
        os.chmod(config_path, 0o600)
        os.chmod(backup_path, 0o600)
        os.chmod(hash_path, 0o600)

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0037"
        case_log_dir = context.logs_dir / "tc0037"
        state_dir = context.state_dir / "tc0037"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        local_root = case_work_dir / "syncroot"
        verify_initial_root = case_work_dir / "verify-initial-root"
        verify_final_root = case_work_dir / "verify-final-root"

        conf_main = case_work_dir / "conf-main"
        conf_verify_initial = case_work_dir / "conf-verify-initial"
        conf_verify_final = case_work_dir / "conf-verify-final"

        reset_directory(local_root)
        reset_directory(verify_initial_root)
        reset_directory(verify_final_root)

        context.prepare_minimal_config_dir(conf_main, "")
        context.prepare_minimal_config_dir(conf_verify_initial, "")
        context.prepare_minimal_config_dir(conf_verify_final, "")

        self._write_config(conf_main, local_root)
        self._write_config(conf_verify_initial, verify_initial_root)
        self._write_config(conf_verify_final, verify_final_root)

        root_name = f"ZZ_E2E_TC0037_{context.run_id}_{os.getpid()}"
        relative_path = f"{root_name}/mtime-only.txt"

        local_file_path = local_root / relative_path
        verify_initial_file_path = verify_initial_root / relative_path
        verify_final_file_path = verify_final_root / relative_path

        initial_content = (
            "TC0037 mtime-only local change handling\n"
            "This file content must remain unchanged.\n"
            "Only the local modification timestamp is altered.\n"
        )

        phase1_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = case_log_dir / "phase1_seed_stderr.log"
        verify_initial_stdout = case_log_dir / "phase2_verify_initial_stdout.log"
        verify_initial_stderr = case_log_dir / "phase2_verify_initial_stderr.log"
        phase3_stdout = case_log_dir / "phase3_touch_sync_stdout.log"
        phase3_stderr = case_log_dir / "phase3_touch_sync_stderr.log"
        verify_final_stdout = case_log_dir / "phase4_verify_final_stdout.log"
        verify_final_stderr = case_log_dir / "phase4_verify_final_stderr.log"
        verify_initial_manifest_file = state_dir / "verify_initial_manifest.txt"
        verify_final_manifest_file = state_dir / "verify_final_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(verify_initial_stdout),
            str(verify_initial_stderr),
            str(phase3_stdout),
            str(phase3_stderr),
            str(verify_final_stdout),
            str(verify_final_stderr),
            str(verify_initial_manifest_file),
            str(verify_final_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "relative_path": relative_path,
            "main_conf_dir": str(conf_main),
            "verify_initial_conf_dir": str(conf_verify_initial),
            "verify_final_conf_dir": str(conf_verify_final),
            "local_root": str(local_root),
            "verify_initial_root": str(verify_initial_root),
            "verify_final_root": str(verify_final_root),
        }

        # Phase 1: seed initial file content
        write_text_file(local_file_path, initial_content)

        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} phase1: {command_to_string(phase1_command)}")
        phase1_result = run_command(phase1_command, cwd=context.repo_root)
        write_text_file(phase1_stdout, phase1_result.stdout)
        write_text_file(phase1_stderr, phase1_result.stderr)
        details["phase1_returncode"] = phase1_result.returncode

        if phase1_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"seed phase failed with status {phase1_result.returncode}",
                artifacts,
                details,
            )

        # Phase 2: establish remote baseline from a fresh verification client
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
            "--confdir",
            str(conf_verify_initial),
        ]
        context.log(f"Executing Test Case {self.case_id} phase2 verify initial: {command_to_string(verify_initial_command)}")
        verify_initial_result = run_command(verify_initial_command, cwd=context.repo_root)
        write_text_file(verify_initial_stdout, verify_initial_result.stdout)
        write_text_file(verify_initial_stderr, verify_initial_result.stderr)
        details["verify_initial_returncode"] = verify_initial_result.returncode

        verify_initial_manifest = build_manifest(verify_initial_root)
        write_manifest(verify_initial_manifest_file, verify_initial_manifest)
        details["verify_initial_manifest"] = verify_initial_manifest
        details["verify_initial_file_exists"] = verify_initial_file_path.is_file()

        baseline_verified_content = (
            verify_initial_file_path.read_text(encoding="utf-8")
            if verify_initial_file_path.is_file()
            else ""
        )
        details["baseline_verified_content"] = baseline_verified_content

        baseline_verified_mtime_ns = (
            verify_initial_file_path.stat().st_mtime_ns
            if verify_initial_file_path.is_file()
            else -1
        )
        details["baseline_verified_mtime_ns"] = baseline_verified_mtime_ns

        if verify_initial_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"initial remote verification failed with status {verify_initial_result.returncode}",
                artifacts,
                details,
            )

        if not verify_initial_file_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"initial remote verification is missing expected file: {relative_path}",
                artifacts,
                details,
            )

        if baseline_verified_content != initial_content:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "initial remote verification content did not match seeded content",
                artifacts,
                details,
            )

        # Phase 3: change only the local mtime and sync again
        local_mtime_before_touch_ns = local_file_path.stat().st_mtime_ns
        details["local_mtime_before_touch_ns"] = local_mtime_before_touch_ns

        time.sleep(2)
        os.utime(local_file_path, None)

        local_mtime_after_touch_ns = local_file_path.stat().st_mtime_ns
        details["local_mtime_after_touch_ns"] = local_mtime_after_touch_ns
        details["local_touch_advanced_mtime"] = local_mtime_after_touch_ns > local_mtime_before_touch_ns

        local_content_after_touch = local_file_path.read_text(encoding="utf-8")
        details["local_content_after_touch"] = local_content_after_touch

        if local_content_after_touch != initial_content:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local file content changed unexpectedly after mtime-only touch",
                artifacts,
                details,
            )

        if local_mtime_after_touch_ns <= local_mtime_before_touch_ns:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local file modification timestamp did not advance after touch operation",
                artifacts,
                details,
            )

        phase3_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} phase3: {command_to_string(phase3_command)}")
        phase3_result = run_command(phase3_command, cwd=context.repo_root)
        write_text_file(phase3_stdout, phase3_result.stdout)
        write_text_file(phase3_stderr, phase3_result.stderr)
        details["phase3_returncode"] = phase3_result.returncode

        phase3_combined_output = phase3_result.stdout + "\n" + phase3_result.stderr
        upload_markers = [
            f"Uploading new file {relative_path}",
            f"Uploading file {relative_path}",
            f"Uploading differences of {relative_path}",
            "Uploading new file",
            "Uploading differences of",
        ]
        matched_upload_markers = [marker for marker in upload_markers if marker in phase3_combined_output]
        details["matched_upload_markers"] = matched_upload_markers

        if phase3_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"mtime-only sync phase failed with status {phase3_result.returncode}",
                artifacts,
                details,
            )

        # Phase 4: verify remote truth again from a fresh client
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
            "--confdir",
            str(conf_verify_final),
        ]
        context.log(f"Executing Test Case {self.case_id} phase4 verify final: {command_to_string(verify_final_command)}")
        verify_final_result = run_command(verify_final_command, cwd=context.repo_root)
        write_text_file(verify_final_stdout, verify_final_result.stdout)
        write_text_file(verify_final_stderr, verify_final_result.stderr)
        details["verify_final_returncode"] = verify_final_result.returncode

        verify_final_manifest = build_manifest(verify_final_root)
        write_manifest(verify_final_manifest_file, verify_final_manifest)
        details["verify_final_manifest"] = verify_final_manifest
        details["verify_final_file_exists"] = verify_final_file_path.is_file()

        final_verified_content = (
            verify_final_file_path.read_text(encoding="utf-8")
            if verify_final_file_path.is_file()
            else ""
        )
        details["final_verified_content"] = final_verified_content

        final_verified_mtime_ns = (
            verify_final_file_path.stat().st_mtime_ns
            if verify_final_file_path.is_file()
            else -1
        )
        details["final_verified_mtime_ns"] = final_verified_mtime_ns

        expected_manifest = [
            root_name,
            relative_path,
        ]
        details["expected_manifest"] = expected_manifest

        self._write_metadata(metadata_file, details)

        if verify_final_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"final remote verification failed with status {verify_final_result.returncode}",
                artifacts,
                details,
            )

        if matched_upload_markers:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"mtime-only local change triggered upload behaviour: {matched_upload_markers}",
                artifacts,
                details,
            )

        if not verify_final_file_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"final remote verification is missing expected file: {relative_path}",
                artifacts,
                details,
            )

        if final_verified_content != initial_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "final verified file content did not match the original content after mtime-only local change",
                artifacts,
                details,
            )

        if verify_final_manifest != expected_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "final remote verification manifest did not match the expected single-file structure after mtime-only local change",
                artifacts,
                details,
            )

        if baseline_verified_mtime_ns != final_verified_mtime_ns:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "remote file modification timestamp changed after an mtime-only local touch",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)