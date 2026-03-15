from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0003DryRunValidation(E2ETestCase):
    case_id = "0003"
    name = "dry-run validation"
    description = "Validate that --dry-run performs no changes locally or remotely"

    def _root_name(self, context: E2EContext) -> str:
        return f"ZZ_E2E_TC0003_{context.run_id}_{os.getpid()}"

    def _write_config(self, config_path: Path) -> None:
        write_text_file(config_path, "# tc0003 config\nbypass_data_preservation = \"true\"\n")

    def _bootstrap_confdir(self, context: E2EContext, confdir: Path) -> Path:
        copied_refresh_token = context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config")
        return copied_refresh_token

    def _create_local_fixture(self, sync_root: Path, root_name: str) -> None:
        reset_directory(sync_root)
        write_text_file(sync_root / root_name / "Upload" / "file1.txt", "tc0003 file1\n")
        write_text_file(sync_root / root_name / "Upload" / "file2.bin", "tc0003 file2\n")
        write_text_file(sync_root / root_name / "Notes" / "draft.md", "# tc0003\n")

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0003"
        case_log_dir = context.logs_dir / "tc0003"
        state_dir = context.state_dir / "tc0003"
        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        seed_confdir = case_work_dir / "conf-seed"
        verify_root = case_work_dir / "verifyroot"
        verify_confdir = case_work_dir / "conf-verify"
        root_name = self._root_name(context)
        self._create_local_fixture(sync_root, root_name)
        copied_refresh_token = self._bootstrap_confdir(context, seed_confdir)
        self._bootstrap_confdir(context, verify_confdir)

        before_manifest = build_manifest(sync_root)
        before_manifest_file = state_dir / "before_manifest.txt"
        after_manifest_file = state_dir / "after_manifest.txt"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"
        stdout_file = case_log_dir / "seed_stdout.log"
        stderr_file = case_log_dir / "seed_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        write_manifest(before_manifest_file, before_manifest)

        command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--dry-run",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(seed_confdir),
        ]
        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

        after_manifest = build_manifest(sync_root)
        write_manifest(after_manifest_file, after_manifest)

        verify_command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(verify_root),
            "--confdir",
            str(verify_confdir),
        ]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        metadata_lines = [
            f"case_id={self.case_id}",
            f"name={self.name}",
            f"root_name={root_name}",
            f"copied_refresh_token={copied_refresh_token}",
            f"command={command_to_string(command)}",
            f"returncode={result.returncode}",
            f"verify_command={command_to_string(verify_command)}",
            f"verify_returncode={verify_result.returncode}",
        ]
        write_text_file(metadata_file, "\n".join(metadata_lines) + "\n")

        artifacts = [
            str(stdout_file),
            str(stderr_file),
            str(verify_stdout),
            str(verify_stderr),
            str(before_manifest_file),
            str(after_manifest_file),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        details = {
            "command": command,
            "returncode": result.returncode,
            "verify_command": verify_command,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
        }

        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote seed failed with status {result.returncode}", artifacts, details)
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if before_manifest != after_manifest:
            return TestResult.fail_result(self.case_id, self.name, "Local filesystem changed during --dry-run", artifacts, details)
        if any(entry == root_name or entry.startswith(root_name + "/") for entry in remote_manifest):
            return TestResult.fail_result(self.case_id, self.name, f"Dry-run unexpectedly synchronised remote content: {root_name}", artifacts, details)

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
