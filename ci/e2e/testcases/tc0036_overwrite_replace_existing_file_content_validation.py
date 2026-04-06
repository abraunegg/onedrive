from __future__ import annotations

import os
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


class TestCase0036OverwriteReplaceExistingFileContentValidation(E2ETestCase):
    case_id = "0036"
    name = "overwrite / replace existing file content validation"
    description = (
        "Validate that replacing the contents of an existing local file with the same "
        "name correctly updates remote content without leaving stale content or "
        "metadata confusion"
    )

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0036 config\n"
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
        case_work_dir = context.work_root / "tc0036"
        case_log_dir = context.logs_dir / "tc0036"
        state_dir = context.state_dir / "tc0036"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        local_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"
        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"

        reset_directory(local_root)
        reset_directory(verify_root)

        context.prepare_minimal_config_dir(conf_main, "")
        context.prepare_minimal_config_dir(conf_verify, "")

        self._write_config(conf_main, local_root)
        self._write_config(conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0036_{context.run_id}_{os.getpid()}"
        relative_path = f"{root_name}/replace-me.txt"

        local_file_path = local_root / relative_path
        verify_file_path = verify_root / relative_path

        initial_content = (
            "TC0036 overwrite replace existing file content validation\n"
            "INITIAL VERSION\n"
            "This content must be fully replaced.\n"
        )
        replacement_content = (
            "TC0036 overwrite replace existing file content validation\n"
            "REPLACED VERSION\n"
            "This content must be the only final content present.\n"
        )

        phase1_stdout = case_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = case_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = case_log_dir / "phase2_replace_stdout.log"
        phase2_stderr = case_log_dir / "phase2_replace_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "relative_path": relative_path,
            "main_conf_dir": str(conf_main),
            "verify_conf_dir": str(conf_verify),
            "local_root": str(local_root),
            "verify_root": str(verify_root),
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

        # Phase 2: replace the file contents locally with same filename
        write_text_file(local_file_path, replacement_content)

        details["local_file_exists_after_replace"] = local_file_path.is_file()
        details["local_file_size_after_replace"] = local_file_path.stat().st_size if local_file_path.is_file() else -1

        if not local_file_path.is_file():
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "local file does not exist immediately after content replacement",
                artifacts,
                details,
            )

        phase2_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        context.log(f"Executing Test Case {self.case_id} phase2: {command_to_string(phase2_command)}")
        phase2_result = run_command(phase2_command, cwd=context.repo_root)
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)
        details["phase2_returncode"] = phase2_result.returncode

        if phase2_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"replace propagation phase failed with status {phase2_result.returncode}",
                artifacts,
                details,
            )

        # Phase 3: verify remote truth from a fresh client
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
        details["verified_file_exists"] = verify_file_path.exists()

        verified_content = verify_file_path.read_text(encoding="utf-8") if verify_file_path.is_file() else ""
        details["verified_content"] = verified_content

        expected_manifest = [
            root_name,
            relative_path,
        ]
        details["expected_manifest"] = expected_manifest

        self._write_metadata(metadata_file, details)

        if verify_result.returncode != 0:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if not verify_file_path.is_file():
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"remote verification is missing expected file: {relative_path}",
                artifacts,
                details,
            )

        if verified_content != replacement_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "verified file content did not match the replacement content after remote verification",
                artifacts,
                details,
            )

        if initial_content == verified_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "verified file content still matches the initial content after replacement",
                artifacts,
                details,
            )

        if verify_manifest != expected_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "remote verification manifest did not match the expected single-file structure after content replacement",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)