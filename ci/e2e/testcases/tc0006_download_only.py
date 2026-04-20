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
    description = "Validate that download-only populates local content from remote data"

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
        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--syncdir", str(seed_root), "--confdir", str(seed_conf)]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout); write_text_file(seed_stderr, seed_result.stderr)
        download_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--syncdir", str(download_root), "--confdir", str(download_conf)]
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
        return self.pass_result(self.case_id, self.name, artifacts, details)
