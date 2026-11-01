from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0006DownloadOnly(E2ETestCase):
    case_id = "0006"
    name = "download-only behaviour"
    description = "Validate that download-only downloads remote data and retains local originals after remote delete/recreate"

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(config_path, "# tc0006 config\nbypass_data_preservation = \"true\"\n")

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0006",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir; case_log_dir = layout.log_dir; state_dir = layout.state_dir
        seed_root = case_work_dir / "seedroot"; seed_conf = case_work_dir / "conf-seed"; download_root = case_work_dir / "downloadroot"; download_conf = case_work_dir / "conf-download"; root_name = f"ZZ_E2E_TC0006_{context.run_id}_{os.getpid()}"
        write_text_file(seed_root / root_name / "remote.txt", "remote\n"); write_text_file(seed_root / root_name / "subdir" / "nested.txt", "nested\n")
        context.bootstrap_config_dir(seed_conf); self._write_config(seed_conf / "config")
        context.bootstrap_config_dir(download_conf); self._write_config(download_conf / "config")
        seed_stdout = case_log_dir / "seed_stdout.log"; seed_stderr = case_log_dir / "seed_stderr.log"; dl_stdout = case_log_dir / "download_stdout.log"; dl_stderr = case_log_dir / "download_stderr.log"; local_manifest_file = state_dir / "download_manifest.txt"; metadata_file = state_dir / "seed_metadata.txt"
        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(seed_root), "--confdir", str(seed_conf)]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout); write_text_file(seed_stderr, seed_result.stderr)
        download_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(download_root), "--confdir", str(download_conf)]
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
        # Retention control for TC0032/TC0033/TC0035: a one-shot sync after a
        # local rename is an online DELETE + CREATE, not a same-ID remote move.
        # Plain --download-only must retain the deleted item's local copy while
        # also downloading the new online item. No --cleanup-local-files or
        # --resync is allowed on this observer reconciliation.
        recreated_relative = f"{root_name}/recreated.txt"
        (seed_root / root_name / "remote.txt").rename(seed_root / recreated_relative)
        replace_stdout = case_log_dir / "replace_stdout.log"
        replace_stderr = case_log_dir / "replace_stderr.log"
        replace_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--single-directory", root_name, "--syncdir", str(seed_root),
            "--confdir", str(seed_conf),
        ]
        replace_result = run_command(replace_command, cwd=context.repo_root)
        write_text_file(replace_stdout, replace_result.stdout)
        write_text_file(replace_stderr, replace_result.stderr)
        artifacts.extend([str(replace_stdout), str(replace_stderr)])
        details["remote_delete_recreate_returncode"] = replace_result.returncode
        if replace_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, "Remote delete-and-recreate stimulus failed", artifacts, details)
        if not (
            "Deleting item from Microsoft OneDrive:" in replace_result.stdout
            and "Uploading new file:" in replace_result.stdout
        ):
            return self.fail_result(
                self.case_id, self.name,
                "One-shot remote stimulus did not prove delete-and-recreate (as opposed to a same-ID move)",
                artifacts, details,
            )

        reconcile_stdout = case_log_dir / "reconcile_stdout.log"
        reconcile_stderr = case_log_dir / "reconcile_stderr.log"
        reconcile_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--download-only", "--single-directory", root_name,
            "--syncdir", str(download_root), "--confdir", str(download_conf),
        ]
        reconcile_result = run_command(reconcile_command, cwd=context.repo_root)
        write_text_file(reconcile_stdout, reconcile_result.stdout)
        write_text_file(reconcile_stderr, reconcile_result.stderr)
        artifacts.extend([str(reconcile_stdout), str(reconcile_stderr)])
        details["retention_reconcile_returncode"] = reconcile_result.returncode
        if reconcile_result.returncode != 0:
            return self.fail_result(self.case_id, self.name, "Plain download-only reconciliation failed", artifacts, details)
        old_local = download_root / root_name / "remote.txt"
        new_local = download_root / recreated_relative
        if (not old_local.is_file() or old_local.read_text(encoding="utf-8") != "remote\n"
                or not new_local.is_file() or new_local.read_text(encoding="utf-8") != "remote\n"):
            return self.fail_result(
                self.case_id, self.name,
                "Plain download-only did not retain deleted original AND download recreated remote item",
                artifacts, details,
            )
        # Independent fresh local state establishes the old item really is
        # absent online; a stale local copy cannot make this check pass.
        verify_root = case_work_dir / "verifyroot"
        verify_conf = case_work_dir / "conf-verify"
        context.bootstrap_config_dir(verify_conf)
        self._write_config(verify_conf / "config")
        verify_stdout = case_log_dir / "verify_recreate_stdout.log"
        verify_stderr = case_log_dir / "verify_recreate_stderr.log"
        verify_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--download-only", "--resync", "--resync-auth", "--single-directory",
            root_name, "--syncdir", str(verify_root), "--confdir", str(verify_conf),
        ]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        artifacts.extend([str(verify_stdout), str(verify_stderr)])
        details["remote_truth_returncode"] = verify_result.returncode
        if (verify_result.returncode != 0 or (verify_root / root_name / "remote.txt").exists()
                or not (verify_root / recreated_relative).is_file()
                or (verify_root / recreated_relative).read_text(encoding="utf-8") != "remote\n"):
            return self.fail_result(
                self.case_id, self.name,
                "Independent remote truth did not confirm original deletion and replacement creation",
                artifacts, details,
            )
        details["plain_download_only_delete_recreate_retention"] = "PASS"
        return self.pass_result(self.case_id, self.name, artifacts, details)
