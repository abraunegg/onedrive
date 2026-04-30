from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0005ForceSyncOverride(E2ETestCase):
    case_id = "0005"
    name = "force-sync override"
    description = "Validate that --force-sync overrides skip_dir for blocked single-directory sync"

    def _write_config(self, config_path: Path, blocked_dir: str) -> None:
        write_onedrive_config(config_path, f"# tc0005 config\nbypass_data_preservation = \"true\"\nskip_dir = \"{blocked_dir}\"\n")

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0005",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        confdir = case_work_dir / "conf-seed"
        verify_root = case_work_dir / "verifyroot"
        verify_confdir = case_work_dir / "conf-verify"

        blocked_dir = f"ZZ_E2E_TC0005_BLOCKED_{context.run_id}_{os.getpid()}"
        write_text_file(sync_root / blocked_dir / "allowed_via_force.txt", "force\n")

        context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config", blocked_dir)
        context.bootstrap_config_dir(verify_confdir)
        write_onedrive_config(verify_confdir / "config", "# tc0005 verify\nbypass_data_preservation = \"true\"\n")

        stdout_file = case_log_dir / "seed_stdout.log"
        stderr_file = case_log_dir / "seed_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "seed_metadata.txt"

        command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            blocked_dir,
            "--force-sync",
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(confdir),
        ]
        result = run_command(command, cwd=context.repo_root, input_text="Y\n")
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

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

        write_text_file(metadata_file, "\n".join([
            f"blocked_dir={blocked_dir}",
            f"command={command_to_string(command)}",
            f"returncode={result.returncode}",
            f"verify_returncode={verify_result.returncode}",
        ]) + "\n")

        artifacts = [str(stdout_file), str(stderr_file), str(verify_stdout), str(verify_stderr), str(remote_manifest_file), str(metadata_file)]
        details = {"command": command, "returncode": result.returncode, "verify_returncode": verify_result.returncode, "blocked_dir": blocked_dir}

        if result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Blocked single-directory sync with --force-sync failed with status {result.returncode}", artifacts, details)
        if verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if f"{blocked_dir}/allowed_via_force.txt" not in remote_manifest:
            return self.fail_result(self.case_id, self.name, f"--force-sync did not synchronise blocked path: {blocked_dir}/allowed_via_force.txt", artifacts, details)

        return self.pass_result(self.case_id, self.name, artifacts, details)
