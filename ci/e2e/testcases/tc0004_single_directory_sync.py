from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0004SingleDirectorySync(E2ETestCase):
    case_id = "0004"
    name = "single-directory synchronisation"
    description = "Validate that only the nominated subtree is synchronised"

    def _write_config(self, config_path: Path) -> None:
        write_text_file(config_path, "# tc0004 config\nbypass_data_preservation = \"true\"\n")

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0004"
        case_log_dir = context.logs_dir / "tc0004"
        state_dir = context.state_dir / "tc0004"
        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        sync_root = case_work_dir / "syncroot"
        confdir = case_work_dir / "conf-main"
        verify_root = case_work_dir / "verifyroot"
        verify_confdir = case_work_dir / "conf-verify"

        target_dir = f"ZZ_E2E_TC0004_TARGET_{context.run_id}_{os.getpid()}"
        other_dir = f"ZZ_E2E_TC0004_OTHER_{context.run_id}_{os.getpid()}"

        write_text_file(sync_root / target_dir / "keep.txt", "target\n")
        write_text_file(sync_root / target_dir / "nested" / "inside.md", "nested\n")
        write_text_file(sync_root / other_dir / "skip.txt", "other\n")

        context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config")
        context.bootstrap_config_dir(verify_confdir)
        self._write_config(verify_confdir / "config")

        stdout_file = case_log_dir / "single_directory_stdout.log"
        stderr_file = case_log_dir / "single_directory_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        local_manifest_file = state_dir / "local_after_manifest.txt"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "single_directory_metadata.txt"

        command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            target_dir,
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(confdir),
        ]
        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        write_manifest(local_manifest_file, build_manifest(sync_root))

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

        metadata = [
            f"case_id={self.case_id}",
            f"target_dir={target_dir}",
            f"other_dir={other_dir}",
            f"command={command_to_string(command)}",
            f"returncode={result.returncode}",
            f"verify_command={command_to_string(verify_command)}",
            f"verify_returncode={verify_result.returncode}",
        ]
        write_text_file(metadata_file, "\n".join(metadata) + "\n")

        artifacts = [
            str(stdout_file),
            str(stderr_file),
            str(verify_stdout),
            str(verify_stderr),
            str(local_manifest_file),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        details = {
            "command": command,
            "returncode": result.returncode,
            "verify_returncode": verify_result.returncode,
            "target_dir": target_dir,
            "other_dir": other_dir,
        }

        if result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"--single-directory sync failed with status {result.returncode}", artifacts, details)
        if verify_result.returncode != 0:
            return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if not any(e == target_dir or e.startswith(target_dir + "/") for e in remote_manifest):
            return TestResult.fail_result(self.case_id, self.name, f"Target directory was not synchronised: {target_dir}", artifacts, details)
        if any(e == other_dir or e.startswith(other_dir + "/") for e in remote_manifest):
            return TestResult.fail_result(self.case_id, self.name, f"Non-target directory was unexpectedly synchronised: {other_dir}", artifacts, details)

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
