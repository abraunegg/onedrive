from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0009UploadOnlyNoRemoteDelete(E2ETestCase):
    case_id = "0009"
    name = "upload-only no-remote-delete"
    description = "Validate that no_remote_delete preserves remote content in upload-only mode"

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(config_path, "# tc0009 config\nbypass_data_preservation = \"true\"\n")

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0009",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir; case_log_dir = layout.log_dir; state_dir = layout.state_dir
        sync_root = case_work_dir / "syncroot"; seed_conf = case_work_dir / "conf-seed"; upload_conf = case_work_dir / "conf-upload"; verify_root = case_work_dir / "verifyroot"; verify_conf = case_work_dir / "conf-verify"; root_name = f"ZZ_E2E_TC0009_{context.run_id}_{os.getpid()}"
        keep_file = sync_root / root_name / "keep.txt"; write_text_file(keep_file, "keep remote\n")
        context.bootstrap_config_dir(seed_conf); self._write_config(seed_conf / "config")
        context.bootstrap_config_dir(upload_conf); self._write_config(upload_conf / "config")
        context.bootstrap_config_dir(verify_conf); self._write_config(verify_conf / "config")
        seed_stdout = case_log_dir / "seed_stdout.log"; seed_stderr = case_log_dir / "seed_stderr.log"; upload_stdout = case_log_dir / "upload_only_stdout.log"; upload_stderr = case_log_dir / "upload_only_stderr.log"; verify_stdout = case_log_dir / "verify_stdout.log"; verify_stderr = case_log_dir / "verify_stderr.log"; remote_manifest_file = state_dir / "remote_verify_manifest.txt"; metadata_file = state_dir / "seed_metadata.txt"
        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(seed_conf)]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout); write_text_file(seed_stderr, seed_result.stderr)
        if keep_file.exists(): keep_file.unlink()
        upload_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--upload-only", "--no-remote-delete", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(upload_conf)]
        upload_result = run_command(upload_command, cwd=context.repo_root)
        write_text_file(upload_stdout, upload_result.stdout); write_text_file(upload_stderr, upload_result.stderr)
        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--syncdir", str(verify_root), "--confdir", str(verify_conf)]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout); write_text_file(verify_stderr, verify_result.stderr); remote_manifest = build_manifest(verify_root); write_manifest(remote_manifest_file, remote_manifest)
        write_text_file(metadata_file, "\n".join([f"root_name={root_name}", f"seed_returncode={seed_result.returncode}", f"upload_returncode={upload_result.returncode}", f"verify_returncode={verify_result.returncode}"]) + "\n")
        artifacts = [str(seed_stdout), str(seed_stderr), str(upload_stdout), str(upload_stderr), str(verify_stdout), str(verify_stderr), str(remote_manifest_file), str(metadata_file)]
        details = {"seed_returncode": seed_result.returncode, "upload_returncode": upload_result.returncode, "verify_returncode": verify_result.returncode, "root_name": root_name}
        if seed_result.returncode != 0: return self.fail_result(self.case_id, self.name, f"Remote seed failed with status {seed_result.returncode}", artifacts, details)
        if upload_result.returncode != 0: return self.fail_result(self.case_id, self.name, f"--upload-only --no-remote-delete failed with status {upload_result.returncode}", artifacts, details)
        if verify_result.returncode != 0: return self.fail_result(self.case_id, self.name, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if f"{root_name}/keep.txt" not in remote_manifest: return self.fail_result(self.case_id, self.name, f"Remote file was unexpectedly deleted despite --no-remote-delete: {root_name}/keep.txt", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
