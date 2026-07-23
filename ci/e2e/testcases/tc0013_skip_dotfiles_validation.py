from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0013SkipDotfilesValidation(E2ETestCase):
    case_id = "0013"
    name = "skip_dotfiles validation"
    description = "Validate that skip_dotfiles prevents dotfiles and dot-directories from synchronising"

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(config_path, "# tc0013 config\nbypass_data_preservation = \"true\"\nskip_dotfiles = \"true\"\n")

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0013",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir; case_log_dir = layout.log_dir; state_dir = layout.state_dir
        sync_root = case_work_dir / "syncroot"; confdir = case_work_dir / "conf-main"; verify_root = case_work_dir / "verifyroot"; verify_conf = case_work_dir / "conf-verify"; root_name = f"ZZ_E2E_TC0013_{context.run_id}_{os.getpid()}"
        write_text_file(sync_root / root_name / "visible.txt", "visible\n"); write_text_file(sync_root / root_name / ".hidden.txt", "hidden\n"); write_text_file(sync_root / root_name / ".dotdir" / "inside.txt", "inside\n")
        context.bootstrap_config_dir(confdir); self._write_config(confdir / "config")
        context.bootstrap_config_dir(verify_conf); write_onedrive_config(verify_conf / "config", "# verify\nbypass_data_preservation = \"true\"\n")
        stdout_file = case_log_dir / "skip_dotfiles_stdout.log"; stderr_file = case_log_dir / "skip_dotfiles_stderr.log"; verify_stdout = case_log_dir / "verify_stdout.log"; verify_stderr = case_log_dir / "verify_stderr.log"; remote_manifest_file = state_dir / "remote_verify_manifest.txt"; metadata_file = state_dir / "metadata.txt"
        command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(confdir)]
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout); write_text_file(stderr_file, result.stderr)
        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--syncdir", str(verify_root), "--confdir", str(verify_conf)]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout); write_text_file(verify_stderr, verify_result.stderr); remote_manifest = build_manifest(verify_root); write_manifest(remote_manifest_file, remote_manifest)
        write_text_file(metadata_file, f"root_name={root_name}\nreturncode={result.returncode}\nverify_returncode={verify_result.returncode}\n")
        artifacts = [str(stdout_file), str(stderr_file), str(verify_stdout), str(verify_stderr), str(remote_manifest_file), str(metadata_file)]
        details = {"returncode": result.returncode, "verify_returncode": verify_result.returncode, "root_name": root_name}
        if result.returncode != 0: return self.fail_result(self.case_id, self.name, f"skip_dotfiles validation failed with status {result.returncode}", artifacts, details)
        if verify_result.returncode != 0: return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if f"{root_name}/visible.txt" not in remote_manifest: return self.fail_result(self.case_id, self.name, "Visible file missing after skip_dotfiles processing", artifacts, details)
        for unwanted in [f"{root_name}/.hidden.txt", f"{root_name}/.dotdir", f"{root_name}/.dotdir/inside.txt"]:
            if unwanted in remote_manifest: return self.fail_result(self.case_id, self.name, f"Dotfile content was unexpectedly synchronised: {unwanted}", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
