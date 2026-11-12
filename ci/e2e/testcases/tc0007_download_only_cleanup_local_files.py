from __future__ import annotations

import os
import re
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_onedrive_config, write_text_file


class TestCase0007DownloadOnlyCleanupLocalFiles(E2ETestCase):
    case_id = "0007"
    name = "download-only cleanup-local-files"
    description = "Validate that cleanup_local_files removes stale local content in download-only mode"

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(config_path, '# tc0007 config\nbypass_data_preservation = "true"\n')

    @staticmethod
    def _running_bool(output: str, key: str, expected: bool) -> bool:
        return re.search(
            rf"Config option '{re.escape(key)}'\s*=\s*{'true' if expected else 'false'}(?:\s|$)",
            output,
        ) is not None

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0007", ensure_refresh_token=True)
        work_dir, log_dir, state_dir = layout.work_dir, layout.log_dir, layout.state_dir
        sync_root = work_dir / "syncroot"
        seed_conf = work_dir / "conf-seed"
        cleanup_conf = work_dir / "conf-cleanup"
        verify_conf = work_dir / "conf-verify"
        verify_root = work_dir / "verifyroot"
        root_name = f"ZZ_E2E_TC0007_{context.run_id}_{os.getpid()}"
        keep_relative = f"{root_name}/keep.txt"
        stale_relative = f"{root_name}/stale-local.txt"
        empty_dir_relative = f"{root_name}/local-only-empty-directory"
        expected_keep = b"keep\n"

        write_text_file(sync_root / keep_relative, expected_keep.decode("utf-8"))
        context.bootstrap_config_dir(seed_conf)
        self._write_config(seed_conf / "config")
        context.bootstrap_config_dir(cleanup_conf)
        self._write_config(cleanup_conf / "config")
        context.bootstrap_config_dir(verify_conf)
        self._write_config(verify_conf / "config")

        seed_stdout, seed_stderr = log_dir / "seed_stdout.log", log_dir / "seed_stderr.log"
        cleanup_stdout, cleanup_stderr = log_dir / "cleanup_stdout.log", log_dir / "cleanup_stderr.log"
        verify_stdout, verify_stderr = log_dir / "verify_stdout.log", log_dir / "verify_stderr.log"
        manifest_file = state_dir / "post_cleanup_manifest.txt"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "seed_metadata.txt"
        artifacts = [str(p) for p in (
            seed_stdout, seed_stderr, cleanup_stdout, cleanup_stderr,
            verify_stdout, verify_stderr, manifest_file, remote_manifest_file, metadata_file,
        )]
        details = {"root_name": root_name}

        # Retain the original seed invocation.
        seed_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--resync", "--resync-auth", "--single-directory", root_name,
            "--syncdir", str(sync_root),
            "--confdir", str(seed_conf),
        ]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_command"] = command_to_string(seed_command)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            return self.fail_result(self.case_id, self.name,
                                    f"Remote seed failed with status {seed_result.returncode}",
                                    artifacts, details)

        seed_output = seed_result.stdout + "\n" + seed_result.stderr
        if not self._running_bool(seed_output, "download_only", False):
            return self.fail_result(self.case_id, self.name,
                                    "Remote seed did not report effective download_only=false",
                                    artifacts, details)

        stale_path = sync_root / stale_relative
        write_text_file(stale_path, "stale\n")
        local_only_empty_dir = sync_root / empty_dir_relative
        local_only_empty_dir.mkdir(parents=True, exist_ok=False)
        if not local_only_empty_dir.is_dir():
            return self.fail_result(self.case_id, self.name,
                                    "Local-only empty directory fixture could not be established",
                                    artifacts, details)
        if not stale_path.is_file() or stale_path.read_bytes() != b"stale\n":
            return self.fail_result(self.case_id, self.name,
                                    "Local-only stale fixture could not be established",
                                    artifacts, details)

        # Retain the original cleanup invocation, including its fresh config
        # directory and --resync. This test validates the one-shot cleanup path,
        # not existing-DB reconciliation or monitor logging cadence.
        cleanup_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--download-only", "--cleanup-local-files", "--resync", "--resync-auth",
            "--single-directory", root_name, "--syncdir", str(sync_root), "--confdir", str(cleanup_conf),
        ]
        cleanup_result = run_command(cleanup_command, cwd=context.repo_root)
        write_text_file(cleanup_stdout, cleanup_result.stdout)
        write_text_file(cleanup_stderr, cleanup_result.stderr)
        details["cleanup_command"] = command_to_string(cleanup_command)
        details["cleanup_returncode"] = cleanup_result.returncode
        post_manifest = build_manifest(sync_root)
        write_manifest(manifest_file, post_manifest)

        failures: list[str] = []
        if cleanup_result.returncode != 0:
            failures.append(f"cleanup_local_files processing failed with status {cleanup_result.returncode}")
        output = cleanup_result.stdout + "\n" + cleanup_result.stderr
        for key, expected in (("download_only", True), ("cleanup_local_files", True),
                              ("upload_only", False)):
            if not self._running_bool(output, key, expected):
                failures.append(f"Cleanup invocation did not report effective {key}={str(expected).lower()}")
        if local_only_empty_dir.exists() or empty_dir_relative in post_manifest:
            failures.append("Untracked in-scope empty directory still exists after cleanup")
        if stale_path.exists() or stale_relative in post_manifest:
            failures.append("Stale local file still exists after cleanup_local_files processing")
        if keep_relative not in post_manifest:
            failures.append("Expected remote-backed file missing after cleanup_local_files processing")
        keep_path = sync_root / keep_relative
        if not keep_path.is_file() or keep_path.read_bytes() != expected_keep:
            failures.append(f"Retained local file content mismatch: {keep_relative}")

        # Verify the removal arose in the cleanup scan, not just as an incidental
        # consequence of --resync. Both the effective flag and the exact
        # file-specific removal evidence are required.
        removed_pattern = re.compile(r"(?:^|\n)(?:DEBUG:\s+)?Removed local file: (?:\./)?"
                                     + re.escape(stale_relative) + r"(?:\s|$)")
        details["stale_removal_logged"] = removed_pattern.search(output) is not None
        if not details["stale_removal_logged"]:
            failures.append("No evidence that cleanup scan removed the DB-unknown stale file")

        # A directory *evaluation* alone must not be mistaken for removal.
        # Require the option-specific decision, the path-specific attempt and
        # the confirmed removal of this database-unknown empty directory.
        for marker, meaning in (
            ("Evaluating untracked local directory for cleanup due to --download-only --cleanup-local-files operation:", "evaluation"),
            ("Attempting removal of local directory:", "attempt"),
            ("Removed local directory:", "completed removal"),
        ):
            pattern = re.compile(r"(?:^|\n)(?:DEBUG:\s+)?" + re.escape(marker)
                                 + r"\s+(?:\./)?" + re.escape(empty_dir_relative) + r"(?:\s|$)")
            recorded = pattern.search(output) is not None
            details[f"empty_directory_{meaning.replace(' ', '_')}_logged"] = recorded
            if not recorded:
                failures.append(f"No {meaning} log for eligible empty directory: {empty_dir_relative}")

        # Independent read-only-in-effect observer: downloading a fresh copy
        # from Microsoft Graph establishes remote truth. It must not see the
        # locally generated stale file, and must still see the seeded file.
        verify_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--download-only", "--resync", "--resync-auth", "--single-directory",
            root_name, "--syncdir", str(verify_root), "--confdir", str(verify_conf),
        ]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        details["verify_command"] = command_to_string(verify_command)
        details["verify_returncode"] = verify_result.returncode
        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)
        if verify_result.returncode != 0:
            failures.append(f"Independent remote verification failed with status {verify_result.returncode}")
        if (verify_root / empty_dir_relative).exists() or empty_dir_relative in remote_manifest:
            failures.append("Cleanup phase uploaded local-only empty directory to OneDrive")
        if (verify_root / stale_relative).exists() or stale_relative in remote_manifest:
            failures.append("Cleanup phase uploaded the local-only stale file to OneDrive")
        remote_keep = verify_root / keep_relative
        if not remote_keep.is_file() or remote_keep.read_bytes() != expected_keep:
            failures.append("Remote-backed fixture missing or modified on OneDrive")
        details["remote_verify_manifest"] = remote_manifest
        write_text_file(metadata_file, "\n".join(f"{key}={value}" for key, value in details.items()) + "\n")

        if failures:
            return self.fail_result(self.case_id, self.name, "; ".join(failures), artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
