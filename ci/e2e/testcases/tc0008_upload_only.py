from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0008UploadOnly(E2ETestCase):
    case_id = "0008"
    name = "upload-only behaviour"
    description = "Validate that upload-only pushes local content remotely"

    def _write_config(self, config_path: Path) -> None:
        write_text_file(config_path, "# tc0008 config\nbypass_data_preservation = \"true\"\n")

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0008"; case_log_dir = context.logs_dir / "tc0008"; state_dir = context.state_dir / "tc0008"
        reset_directory(case_work_dir); reset_directory(case_log_dir); reset_directory(state_dir); context.ensure_refresh_token_available()
        upload_root = case_work_dir / "uploadroot"; upload_conf = case_work_dir / "conf-upload"; verify_root = case_work_dir / "verifyroot"; verify_conf = case_work_dir / "conf-verify"; root_name = f"ZZ_E2E_TC0008_{context.run_id}_{os.getpid()}"
        write_text_file(upload_root / root_name / "upload.txt", "upload only\n")
        context.bootstrap_config_dir(upload_conf); self._write_config(upload_conf / "config")
        context.bootstrap_config_dir(verify_conf); self._write_config(verify_conf / "config")
        stdout_file = case_log_dir / "upload_only_stdout.log"; stderr_file = case_log_dir / "upload_only_stderr.log"; verify_stdout = case_log_dir / "verify_stdout.log"; verify_stderr = case_log_dir / "verify_stderr.log"; remote_manifest_file = state_dir / "remote_verify_manifest.txt"; metadata_file = state_dir / "upload_metadata.txt"
        command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--upload-only", "--resync", "--resync-auth", "--syncdir", str(upload_root), "--confdir", str(upload_conf)]
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout); write_text_file(stderr_file, result.stderr)
        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--syncdir", str(verify_root), "--confdir", str(verify_conf)]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout); write_text_file(verify_stderr, verify_result.stderr); remote_manifest = build_manifest(verify_root); write_manifest(remote_manifest_file, remote_manifest)
        write_text_file(metadata_file, "\n".join([f"root_name={root_name}", f"returncode={result.returncode}", f"verify_returncode={verify_result.returncode}"]) + "\n")
        artifacts = [str(stdout_file), str(stderr_file), str(verify_stdout), str(verify_stderr), str(remote_manifest_file), str(metadata_file)]
        details = {"returncode": result.returncode, "verify_returncode": verify_result.returncode, "root_name": root_name}
        if result.returncode != 0: return TestResult.fail_result(self.case_id, self.name, f"--upload-only failed with status {result.returncode}", artifacts, details)
        if verify_result.returncode != 0: return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if f"{root_name}/upload.txt" not in remote_manifest: return TestResult.fail_result(self.case_id, self.name, f"Upload-only did not synchronise expected remote file: {root_name}/upload.txt", artifacts, details)
        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
