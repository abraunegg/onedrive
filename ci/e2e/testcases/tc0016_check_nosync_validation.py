from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0016CheckNosyncValidation(E2ETestCase):
    case_id = "0016"
    name = "check_nosync validation"
    description = "Validate that check_nosync prevents directories containing .nosync from synchronising"

    def _write_config(self, config_path: Path) -> None:
        write_text_file(config_path, "# tc0016 config\nbypass_data_preservation = \"true\"\ncheck_nosync = \"true\"\n")

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0016"; case_log_dir = context.logs_dir / "tc0016"; state_dir = context.state_dir / "tc0016"
        reset_directory(case_work_dir); reset_directory(case_log_dir); reset_directory(state_dir); context.ensure_refresh_token_available()
        sync_root = case_work_dir / "syncroot"; confdir = case_work_dir / "conf-main"; verify_root = case_work_dir / "verifyroot"; verify_conf = case_work_dir / "conf-verify"; root_name = f"ZZ_E2E_TC0016_{context.run_id}_{os.getpid()}"
        write_text_file(sync_root / root_name / "Allowed" / "ok.txt", "ok\n"); write_text_file(sync_root / root_name / "Blocked" / ".nosync", ""); write_text_file(sync_root / root_name / "Blocked" / "blocked.txt", "blocked\n")
        context.bootstrap_config_dir(confdir); self._write_config(confdir / "config")
        context.bootstrap_config_dir(verify_conf); write_text_file(verify_conf / "config", "# verify\nbypass_data_preservation = \"true\"\n")
        stdout_file = case_log_dir / "check_nosync_stdout.log"; stderr_file = case_log_dir / "check_nosync_stderr.log"; verify_stdout = case_log_dir / "verify_stdout.log"; verify_stderr = case_log_dir / "verify_stderr.log"; remote_manifest_file = state_dir / "remote_verify_manifest.txt"; metadata_file = state_dir / "metadata.txt"
        command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(confdir)]
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout); write_text_file(stderr_file, result.stderr)
        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--syncdir", str(verify_root), "--confdir", str(verify_conf)]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout); write_text_file(verify_stderr, verify_result.stderr); remote_manifest = build_manifest(verify_root); write_manifest(remote_manifest_file, remote_manifest)
        write_text_file(metadata_file, f"root_name={root_name}\nreturncode={result.returncode}\nverify_returncode={verify_result.returncode}\n")
        artifacts = [str(stdout_file), str(stderr_file), str(verify_stdout), str(verify_stderr), str(remote_manifest_file), str(metadata_file)]
        details = {"returncode": result.returncode, "verify_returncode": verify_result.returncode, "root_name": root_name}
        if result.returncode != 0: return TestResult.fail_result(self.case_id, self.name, f"check_nosync validation failed with status {result.returncode}", artifacts, details)
        if verify_result.returncode != 0: return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if f"{root_name}/Allowed/ok.txt" not in remote_manifest: return TestResult.fail_result(self.case_id, self.name, "Allowed content missing after check_nosync processing", artifacts, details)
        for unwanted in [f"{root_name}/Blocked", f"{root_name}/Blocked/.nosync", f"{root_name}/Blocked/blocked.txt"]:
            if unwanted in remote_manifest: return TestResult.fail_result(self.case_id, self.name, f".nosync directory content was unexpectedly synchronised: {unwanted}", artifacts, details)
        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
