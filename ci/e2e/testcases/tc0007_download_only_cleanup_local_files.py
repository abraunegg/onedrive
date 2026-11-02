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
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0007",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir; case_log_dir = layout.log_dir; state_dir = layout.state_dir
        sync_root = case_work_dir / "syncroot"; seed_conf = case_work_dir / "conf-seed"; cleanup_conf = case_work_dir / "conf-cleanup"; root_name = f"ZZ_E2E_TC0007_{context.run_id}_{os.getpid()}"
        write_text_file(sync_root / root_name / "keep.txt", "keep\n")
        context.bootstrap_config_dir(seed_conf); self._write_config(seed_conf / "config")
        context.bootstrap_config_dir(cleanup_conf); self._write_config(cleanup_conf / "config")
        seed_stdout = case_log_dir / "seed_stdout.log"; seed_stderr = case_log_dir / "seed_stderr.log"; cleanup_stdout = case_log_dir / "cleanup_stdout.log"; cleanup_stderr = case_log_dir / "cleanup_stderr.log"; post_manifest_file = state_dir / "post_cleanup_manifest.txt"; metadata_file = state_dir / "seed_metadata.txt"
        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(seed_conf)]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout); write_text_file(seed_stderr, seed_result.stderr)
        if seed_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, f"Remote seed failed with status {seed_result.returncode}", [str(seed_stdout), str(seed_stderr)], {"seed_returncode": seed_result.returncode, "root_name": root_name})
        stale = sync_root / root_name / "stale-local.txt"; write_text_file(stale, "stale\n")
        cleanup_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--cleanup-local-files", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(cleanup_conf)]
        cleanup_result = run_command(cleanup_command, cwd=context.repo_root)
        write_text_file(cleanup_stdout, cleanup_result.stdout); write_text_file(cleanup_stderr, cleanup_result.stderr); post_manifest = build_manifest(sync_root); write_manifest(post_manifest_file, post_manifest)
        write_text_file(metadata_file, "\n".join([f"root_name={root_name}", f"seed_returncode={seed_result.returncode}", f"cleanup_returncode={cleanup_result.returncode}"]) + "\n")
        artifacts = [str(seed_stdout), str(seed_stderr), str(cleanup_stdout), str(cleanup_stderr), str(post_manifest_file), str(metadata_file)]
        details = {"seed_returncode": seed_result.returncode, "cleanup_returncode": cleanup_result.returncode, "root_name": root_name}
        if seed_result.returncode != 0: return self.fail_result(self.case_id, self.name, f"Remote seed failed with status {seed_result.returncode}", artifacts, details)
        if cleanup_result.returncode != 0: return self.fail_result(self.case_id, self.name, f"cleanup_local_files processing failed with status {cleanup_result.returncode}", artifacts, details)
        if stale.exists() or f"{root_name}/stale-local.txt" in post_manifest: return self.fail_result(self.case_id, self.name, "Stale local file still exists after cleanup_local_files processing", artifacts, details)
        if f"{root_name}/keep.txt" not in post_manifest: return self.fail_result(self.case_id, self.name, "Expected remote-backed file missing after cleanup_local_files processing", artifacts, details)
        verified_file = sync_root / f"{root_name}/keep.txt"
        if not verified_file.is_file() or verified_file.read_bytes() != "keep\n".encode("utf-8"):
            return self.fail_result(self.case_id, self.name, f"Verified file content mismatch: {f"{root_name}/keep.txt"}", artifacts, details)
        # Second cleanup must use the existing cleanup_conf database.
        # --resync would discard the very reconciliation state under test.
        stale2 = sync_root / root_name / "new-unknown-directory" / "local-only.dat"
        write_text_file(stale2, "stale nested local content\n")
        normal_cleanup_command = [argument for argument in cleanup_command
                                  if argument not in ("--resync", "--resync-auth")]
        normal_result = run_command(normal_cleanup_command, cwd=context.repo_root)
        normal_out = case_log_dir / "normal_cleanup_stdout.log"
        normal_err = case_log_dir / "normal_cleanup_stderr.log"
        write_text_file(normal_out, normal_result.stdout)
        write_text_file(normal_err, normal_result.stderr)
        artifacts.extend([str(normal_out), str(normal_err)])
        details["normal_cleanup_command"] = normal_cleanup_command
        details["normal_cleanup_returncode"] = normal_result.returncode
        if normal_result.returncode != 0:
            return self.fail_result(self.case_id, self.name,
                                    "Normal existing-DB cleanup returned an error", artifacts, details)
        if stale2.exists() or stale2.parent.exists():
            return self.fail_result(self.case_id, self.name,
                                    "Normal existing-DB cleanup retained DB-unknown local data", artifacts, details)
        if not verified_file.is_file() or verified_file.read_bytes() != b"keep\n":
            return self.fail_result(self.case_id, self.name,
                                    "Normal cleanup deleted or changed remote-backed survivor", artifacts, details)
        # Independently confirm neither cleanup pass uploaded DB-unknown content.
        verify_root = case_work_dir / "verifyroot"
        verify_conf = case_work_dir / "conf-verify"
        context.bootstrap_config_dir(verify_conf)
        self._write_config(verify_conf / "config")
        verify_command = [context.onedrive_bin, "--sync", "--download-only", "--resync",
                          "--resync-auth", "--single-directory", root_name,
                          "--syncdir", str(verify_root), "--confdir", str(verify_conf)]
        remote_verify = run_command(verify_command, cwd=context.repo_root)
        remote_out = case_log_dir / "remote_verify_stdout.log"
        remote_err = case_log_dir / "remote_verify_stderr.log"
        write_text_file(remote_out, remote_verify.stdout)
        write_text_file(remote_err, remote_verify.stderr)
        artifacts.extend([str(remote_out), str(remote_err)])
        details["remote_verification_returncode"] = remote_verify.returncode
        if remote_verify.returncode != 0:
            return self.fail_result(self.case_id, self.name, "Remote verifier failed", artifacts, details)
        remotely_kept = verify_root / root_name / "keep.txt"
        if not remotely_kept.is_file() or remotely_kept.read_bytes() != b"keep\n":
            return self.fail_result(self.case_id, self.name,
                                    "Cleanup altered remote-backed data", artifacts, details)
        if ((verify_root / root_name / "stale-local.txt").exists() or
                (verify_root / root_name / "new-unknown-directory").exists()):
            return self.fail_result(self.case_id, self.name,
                                    "Cleanup uploaded local-only content", artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
