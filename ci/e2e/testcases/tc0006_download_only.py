from __future__ import annotations

import os
import json
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0006DownloadOnly(E2ETestCase):
    case_id = "0006"
    name = "download-only behaviour"
    description = "Validate that download-only populates local content from remote data"

    def _write_config(self, config_path: Path, sync_dir: Path) -> None:
        # All invocations using this config must retain the same sync_dir.
        # Otherwise the app's resync-required check exits before remote deletion.
        write_onedrive_config(
            config_path,
            '# tc0006 config\nbypass_data_preservation = "true"\n'
            + f"sync_dir = {json.dumps(str(sync_dir))}\n",
        )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0006",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir; case_log_dir = layout.log_dir; state_dir = layout.state_dir
        seed_root = case_work_dir / "seedroot"; seed_conf = case_work_dir / "conf-seed"; download_root = case_work_dir / "downloadroot"; download_conf = case_work_dir / "conf-download"; root_name = f"ZZ_E2E_TC0006_{context.run_id}_{os.getpid()}"
        write_text_file(seed_root / root_name / "remote.txt", "remote\n"); write_text_file(seed_root / root_name / "subdir" / "nested.txt", "nested\n")
        context.bootstrap_config_dir(seed_conf); self._write_config(seed_conf / "config", seed_root)
        context.bootstrap_config_dir(download_conf); self._write_config(download_conf / "config", download_root)
        seed_stdout = case_log_dir / "seed_stdout.log"; seed_stderr = case_log_dir / "seed_stderr.log"; dl_stdout = case_log_dir / "download_stdout.log"; dl_stderr = case_log_dir / "download_stderr.log"; local_manifest_file = state_dir / "download_manifest.txt"; metadata_file = state_dir / "seed_metadata.txt"
        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--confdir", str(seed_conf)]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout); write_text_file(seed_stderr, seed_result.stderr)
        download_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--single-directory", root_name, "--confdir", str(download_conf)]
        if seed_result.returncode != 0:
            return self.fail_result(
                self.case_id, self.name,
                f"Remote seed failed with status {seed_result.returncode}",
                [str(seed_stdout), str(seed_stderr)],
                {"seed_returncode": seed_result.returncode, "root_name": root_name},
            )
        download_result = run_command(download_command, cwd=context.repo_root)
        write_text_file(dl_stdout, download_result.stdout); write_text_file(dl_stderr, download_result.stderr); local_manifest = build_manifest(download_root); write_manifest(local_manifest_file, local_manifest)
        write_text_file(metadata_file, "\n".join([f"root_name={root_name}", f"seed_command={command_to_string(seed_command)}", f"seed_returncode={seed_result.returncode}", f"download_command={command_to_string(download_command)}", f"download_returncode={download_result.returncode}"]) + "\n")
        artifacts = [str(seed_stdout), str(seed_stderr), str(dl_stdout), str(dl_stderr), str(local_manifest_file), str(metadata_file)]
        details = {"seed_returncode": seed_result.returncode, "download_returncode": download_result.returncode, "root_name": root_name}
        if seed_result.returncode != 0: return self.fail_result(self.case_id, self.name, f"Remote seed failed with status {seed_result.returncode}", artifacts, details)
        if download_result.returncode != 0: return self.fail_result(self.case_id, self.name, f"--download-only failed with status {download_result.returncode}", artifacts, details)
        wanted = [root_name, f"{root_name}/remote.txt", f"{root_name}/subdir", f"{root_name}/subdir/nested.txt"]
        missing = [w for w in wanted if w not in local_manifest]
        if missing: return self.fail_result(self.case_id, self.name, "Downloaded manifest missing expected content: " + ", ".join(missing), artifacts, details)
        for relative, expected_content in (
            (f"{root_name}/remote.txt", "remote\n"),
            (f"{root_name}/subdir/nested.txt", "nested\n"),
        ):
            actual_path = download_root / relative
            if not actual_path.is_file() or actual_path.read_text(encoding="utf-8") != expected_content:
                return self.fail_result(self.case_id, self.name, f"Downloaded file content mismatch: {relative}", artifacts, details)
        # Actual remote-delete control for --download-only. An online tombstone
        # is not permitted to remove the established local file when cleanup
        # was not requested, independent of --sync versus --monitor.
        deleted_relative = f"{root_name}/remote.txt"
        seed_deleted_path = seed_root / deleted_relative
        seed_deleted_path.unlink()
        remote_delete_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--single-directory", root_name,
            "--confdir", str(seed_conf),
        ]
        remote_delete_result = run_command(remote_delete_command, cwd=context.repo_root)
        remote_delete_stdout = case_log_dir / "remote_delete_stdout.log"
        remote_delete_stderr = case_log_dir / "remote_delete_stderr.log"
        write_text_file(remote_delete_stdout, remote_delete_result.stdout)
        write_text_file(remote_delete_stderr, remote_delete_result.stderr)
        artifacts.extend((str(remote_delete_stdout), str(remote_delete_stderr)))
        details["remote_delete_mutator_returncode"] = remote_delete_result.returncode
        if remote_delete_result.returncode != 0:
            return self.fail_result(self.case_id, self.name,
                f"Remote delete mutator failed with status {remote_delete_result.returncode}",
                artifacts, details)

        # Confirm that the source was actually deleted online. A successful
        # mutator exit alone does not prove that a Graph deletion took place.
        remote_verify_root = case_work_dir / "verifyroot"
        remote_verify_conf = case_work_dir / "conf-verify"
        context.bootstrap_config_dir(remote_verify_conf)
        self._write_config(remote_verify_conf / "config", remote_verify_root)
        remote_verify_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--download-only", "--resync", "--resync-auth",
            "--single-directory", root_name,
            "--confdir", str(remote_verify_conf),
        ]
        remote_verify_result = run_command(remote_verify_command, cwd=context.repo_root)
        verify_stdout = case_log_dir / "remote_verify_stdout.log"
        verify_stderr = case_log_dir / "remote_verify_stderr.log"
        write_text_file(verify_stdout, remote_verify_result.stdout)
        write_text_file(verify_stderr, remote_verify_result.stderr)
        artifacts.extend((str(verify_stdout), str(verify_stderr)))
        details["remote_verify_returncode"] = remote_verify_result.returncode
        if remote_verify_result.returncode != 0:
            return self.fail_result(self.case_id, self.name,
                f"Independent remote delete verification failed with status {remote_verify_result.returncode}",
                artifacts, details)
        if (remote_verify_root / deleted_relative).exists():
            return self.fail_result(self.case_id, self.name,
                "Remote delete was not observed by independent download-only client",
                artifacts, details)
        if not (remote_verify_root / root_name / "subdir" / "nested.txt").is_file():
            return self.fail_result(self.case_id, self.name,
                "Remote control file missing after mutator delete",
                artifacts, details)

        # Existing-DB download-only reconciliation must observe the remote
        # deletion but retain local content unchanged (no cleanup option).
        reconcile_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--download-only", "--single-directory", root_name,
            "--confdir", str(download_conf),
        ]
        reconcile_result = run_command(reconcile_command, cwd=context.repo_root)
        reconcile_stdout = case_log_dir / "no_cleanup_reconcile_stdout.log"
        reconcile_stderr = case_log_dir / "no_cleanup_reconcile_stderr.log"
        write_text_file(reconcile_stdout, reconcile_result.stdout)
        write_text_file(reconcile_stderr, reconcile_result.stderr)
        artifacts.extend((str(reconcile_stdout), str(reconcile_stderr)))
        details["no_cleanup_reconcile_returncode"] = reconcile_result.returncode
        if reconcile_result.returncode != 0:
            return self.fail_result(self.case_id, self.name,
                f"--download-only remote deletion reconciliation failed: {reconcile_result.returncode}",
                artifacts, details)
        from re import search, escape
        effective = reconcile_result.stdout + "\n" + reconcile_result.stderr
        for opt in ("download_only",):
            if search(rf"Config option '{escape(opt)}'\s*=\s*true", effective) is None:
                return self.fail_result(self.case_id, self.name,
                    f"Remote deletion reconciliation did not enable {opt}", artifacts, details)
        if search(r"Config option 'cleanup_local_files'\s*=\s*false", effective) is None:
            return self.fail_result(self.case_id, self.name,
                "No-cleanup control had cleanup_local_files enabled", artifacts, details)
        if not (download_root / deleted_relative).is_file() or (download_root / deleted_relative).read_bytes() != b"remote\n":
            return self.fail_result(self.case_id, self.name,
                "--download-only deleted or modified a local file after its online deletion",
                artifacts, details)
        if (download_root / root_name / "subdir" / "nested.txt").read_bytes() != b"nested\n":
            return self.fail_result(self.case_id, self.name,
                "Untouched in-scope file was changed during download-only reconciliation",
                artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
