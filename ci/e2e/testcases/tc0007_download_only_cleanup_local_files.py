from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0007DownloadOnlyCleanupLocalFiles(E2ETestCase):
    case_id = "0007"
    name = "download-only cleanup-local-files"
    description = "Validate that cleanup_local_files removes stale local content in download-only mode"

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(config_path, "# tc0007 config\nbypass_data_preservation = \"true\"\n")

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0007"; case_log_dir = context.logs_dir / "tc0007"; state_dir = context.state_dir / "tc0007"
        reset_directory(case_work_dir); reset_directory(case_log_dir); reset_directory(state_dir); context.ensure_refresh_token_available()
        sync_root = case_work_dir / "syncroot"; seed_conf = case_work_dir / "conf-seed"; cleanup_conf = case_work_dir / "conf-cleanup"; root_name = f"ZZ_E2E_TC0007_{context.run_id}_{os.getpid()}"
        write_text_file(sync_root / root_name / "keep.txt", "keep\n")
        context.bootstrap_config_dir(seed_conf); self._write_config(seed_conf / "config")
        context.bootstrap_config_dir(cleanup_conf); self._write_config(cleanup_conf / "config")
        seed_stdout = case_log_dir / "seed_stdout.log"; seed_stderr = case_log_dir / "seed_stderr.log"; cleanup_stdout = case_log_dir / "cleanup_stdout.log"; cleanup_stderr = case_log_dir / "cleanup_stderr.log"; post_manifest_file = state_dir / "post_cleanup_manifest.txt"; metadata_file = state_dir / "seed_metadata.txt"
        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(seed_conf)]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout); write_text_file(seed_stderr, seed_result.stderr)
        stale = sync_root / root_name / "stale-local.txt"; write_text_file(stale, "stale\n")
        cleanup_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--cleanup-local-files", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(cleanup_conf)]
        cleanup_result = run_command(cleanup_command, cwd=context.repo_root)
        write_text_file(cleanup_stdout, cleanup_result.stdout); write_text_file(cleanup_stderr, cleanup_result.stderr); post_manifest = build_manifest(sync_root); write_manifest(post_manifest_file, post_manifest)
        write_text_file(metadata_file, "\n".join([f"root_name={root_name}", f"seed_returncode={seed_result.returncode}", f"cleanup_returncode={cleanup_result.returncode}"]) + "\n")
        artifacts = [str(seed_stdout), str(seed_stderr), str(cleanup_stdout), str(cleanup_stderr), str(post_manifest_file), str(metadata_file)]
        details = {"seed_returncode": seed_result.returncode, "cleanup_returncode": cleanup_result.returncode, "root_name": root_name}
        if seed_result.returncode != 0: return TestResult.fail_result(self.case_id, self.name, f"Remote seed failed with status {seed_result.returncode}", artifacts, details)
        if cleanup_result.returncode != 0: return TestResult.fail_result(self.case_id, self.name, f"cleanup_local_files processing failed with status {cleanup_result.returncode}", artifacts, details)
        if stale.exists() or f"{root_name}/stale-local.txt" in post_manifest: return TestResult.fail_result(self.case_id, self.name, "Stale local file still exists after cleanup_local_files processing", artifacts, details)
        if f"{root_name}/keep.txt" not in post_manifest: return TestResult.fail_result(self.case_id, self.name, "Expected remote-backed file missing after cleanup_local_files processing", artifacts, details)
        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
