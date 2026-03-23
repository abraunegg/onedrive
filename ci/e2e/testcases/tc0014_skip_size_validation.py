from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0014SkipSizeValidation(E2ETestCase):
    case_id = "0014"
    name = "skip_size validation"
    description = "Validate that skip_size prevents oversized files from synchronising"

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(config_path, "# tc0014 config\nbypass_data_preservation = \"true\"\nenable_logging = \"true\"\nskip_size = \"1\"\n")

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0014"; case_log_dir = context.logs_dir / "tc0014"; state_dir = context.state_dir / "tc0014"
        reset_directory(case_work_dir); reset_directory(case_log_dir); reset_directory(state_dir); context.ensure_refresh_token_available()
        sync_root = case_work_dir / "syncroot"; confdir = case_work_dir / "conf-main"; verify_root = case_work_dir / "verifyroot"; verify_conf = case_work_dir / "conf-verify"; root_name = f"ZZ_E2E_TC0014_{context.run_id}_{os.getpid()}"; app_log_dir = case_log_dir / "app-logs"
        write_text_file(sync_root / root_name / "small.bin", "a" * 16384)
        big_path = sync_root / root_name / "large.bin"; big_path.parent.mkdir(parents=True, exist_ok=True); big_path.write_bytes(b"B" * (2 * 1024 * 1024))
        context.bootstrap_config_dir(confdir); self._write_config(confdir / "config")
        write_text_file(confdir / "config", (confdir / "config").read_text(encoding="utf-8") + f'log_dir = "{app_log_dir}"\n')
        context.bootstrap_config_dir(verify_conf); write_onedrive_config(verify_conf / "config", "# verify\nbypass_data_preservation = \"true\"\n")
        stdout_file = case_log_dir / "skip_size_stdout.log"; stderr_file = case_log_dir / "skip_size_stderr.log"; verify_stdout = case_log_dir / "verify_stdout.log"; verify_stderr = case_log_dir / "verify_stderr.log"; remote_manifest_file = state_dir / "remote_verify_manifest.txt"; metadata_file = state_dir / "metadata.txt"; config_copy = state_dir / "config_used.txt"; verify_config_copy = state_dir / "verify_config_used.txt"
        command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(confdir)]
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout); write_text_file(stderr_file, result.stderr)
        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--syncdir", str(verify_root), "--confdir", str(verify_conf)]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout); write_text_file(verify_stderr, verify_result.stderr); remote_manifest = build_manifest(verify_root); write_manifest(remote_manifest_file, remote_manifest)
        write_text_file(config_copy, (confdir / "config").read_text(encoding="utf-8"))
        write_text_file(verify_config_copy, (verify_conf / "config").read_text(encoding="utf-8"))
        write_text_file(metadata_file, f"root_name={root_name}\nlarge_size={big_path.stat().st_size}\nlarge_size_mb_decimal={big_path.stat().st_size / 1000 / 1000:.3f}\nlarge_size_mib_binary={big_path.stat().st_size / 1024 / 1024:.3f}\nreturncode={result.returncode}\nverify_returncode={verify_result.returncode}\n")
        artifacts = [str(stdout_file), str(stderr_file), str(verify_stdout), str(verify_stderr), str(remote_manifest_file), str(metadata_file), str(config_copy), str(verify_config_copy)]
        if app_log_dir.exists():
            artifacts.append(str(app_log_dir))
        details = {"returncode": result.returncode, "verify_returncode": verify_result.returncode, "root_name": root_name, "large_size": big_path.stat().st_size, "large_size_mb_decimal": round(big_path.stat().st_size / 1000 / 1000, 3), "large_size_mib_binary": round(big_path.stat().st_size / 1024 / 1024, 3), "skip_size": 1}
        if result.returncode != 0: return TestResult.fail_result(self.case_id, self.name, f"skip_size validation failed with status {result.returncode}", artifacts, details)
        if verify_result.returncode != 0: return TestResult.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if f"{root_name}/small.bin" not in remote_manifest: return TestResult.fail_result(self.case_id, self.name, "Small file missing after skip_size processing", artifacts, details)
        if f"{root_name}/large.bin" in remote_manifest: return TestResult.fail_result(self.case_id, self.name, "Large file exceeded configured skip_size threshold but was synchronised; review display-running-config output and debug logs", artifacts, details)
        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
