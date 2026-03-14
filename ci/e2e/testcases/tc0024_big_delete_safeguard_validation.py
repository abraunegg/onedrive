from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import reset_directory, run_command, write_text_file


class TestCase0024BigDeleteSafeguardValidation(E2ETestCase):
    case_id = "0024"
    name = "big delete safeguard validation"
    description = "Validate classify_as_big_delete protection and forced acknowledgement via --force"

    def _write_config(self, config_path: Path) -> None:
        write_text_file(config_path, "# tc0024 config\n" 'bypass_data_preservation = "true"\n' 'classify_as_big_delete = "3"\n')

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0024"
        case_log_dir = context.logs_dir / "tc0024"
        state_dir = context.state_dir / "tc0024"
        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        seed_root = case_work_dir / "seedroot"
        local_root = case_work_dir / "localroot"
        verify_root = case_work_dir / "verifyroot"
        conf_seed = case_work_dir / "conf-seed"
        conf_download = case_work_dir / "conf-download"
        conf_blocked = case_work_dir / "conf-blocked"
        conf_forced = case_work_dir / "conf-forced"
        conf_verify = case_work_dir / "conf-verify"
        root_name = f"ZZ_E2E_TC0024_{context.run_id}_{os.getpid()}"

        for idx in range(1, 6):
            write_text_file(seed_root / root_name / "BigDelete" / f"file{idx}.txt", f"file {idx}\n")
        write_text_file(seed_root / root_name / "Keep" / "keep.txt", "keep\n")

        context.bootstrap_config_dir(conf_seed)
        self._write_config(conf_seed / "config")
        context.bootstrap_config_dir(conf_download)
        self._write_config(conf_download / "config")
        context.bootstrap_config_dir(conf_blocked)
        self._write_config(conf_blocked / "config")
        context.bootstrap_config_dir(conf_forced)
        self._write_config(conf_forced / "config")
        context.bootstrap_config_dir(conf_verify)
        self._write_config(conf_verify / "config")

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        download_stdout = case_log_dir / "download_stdout.log"
        download_stderr = case_log_dir / "download_stderr.log"
        blocked_stdout = case_log_dir / "blocked_stdout.log"
        blocked_stderr = case_log_dir / "blocked_stderr.log"
        forced_stdout = case_log_dir / "forced_stdout.log"
        forced_stderr = case_log_dir / "forced_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--upload-only", "--verbose", "--verbose", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(seed_root), "--confdir", str(conf_seed)]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)

        download_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--verbose", "--download-only", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(local_root), "--confdir", str(conf_download)]
        download_result = run_command(download_command, cwd=context.repo_root)
        write_text_file(download_stdout, download_result.stdout)
        write_text_file(download_stderr, download_result.stderr)

        target = local_root / root_name / "BigDelete"
        if not target.exists():
            write_text_file(metadata_file, f"case_id={self.case_id}\nroot_name={root_name}\nseed_returncode={seed_result.returncode}\ndownload_returncode={download_result.returncode}\nblocked_returncode=-1\nforced_returncode=-1\nverify_returncode=-1\n")
            artifacts = [str(seed_stdout), str(seed_stderr), str(download_stdout), str(download_stderr), str(metadata_file)]
            details = {"seed_returncode": seed_result.returncode, "download_returncode": download_result.returncode, "root_name": root_name}
            return TestResult.fail_result(self.case_id, self.name, "Expected BigDelete path was not downloaded before delete phase", artifacts, details)

        shutil.rmtree(target)

        blocked_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--verbose", "--single-directory", root_name, "--syncdir", str(local_root), "--confdir", str(conf_blocked)]
        blocked_result = run_command(blocked_command, cwd=context.repo_root)
        write_text_file(blocked_stdout, blocked_result.stdout)
        write_text_file(blocked_stderr, blocked_result.stderr)

        forced_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--verbose", "--force", "--single-directory", root_name, "--syncdir", str(local_root), "--confdir", str(conf_forced)]
        forced_result = run_command(forced_command, cwd=context.repo_root)
        write_text_file(forced_stdout, forced_result.stdout)
        write_text_file(forced_stderr, forced_result.stderr)

        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--verbose", "--download-only", "--resync", "--resync-auth", "--single-directory", root_name, "--syncdir", str(verify_root), "--confdir", str(conf_verify)]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        blocked_output = (blocked_result.stdout + "\n" + blocked_result.stderr).lower()
        write_text_file(metadata_file, f"case_id={self.case_id}\nroot_name={root_name}\nseed_returncode={seed_result.returncode}\ndownload_returncode={download_result.returncode}\nblocked_returncode={blocked_result.returncode}\nforced_returncode={forced_result.returncode}\nverify_returncode={verify_result.returncode}\n")

        artifacts = [str(seed_stdout), str(seed_stderr), str(download_stdout), str(download_stderr), str(blocked_stdout), str(blocked_stderr), str(forced_stdout), str(forced_stderr), str(verify_stdout), str(verify_stderr), str(remote_manifest_file), str(metadata_file)]
        details = {"seed_returncode": seed_result.returncode, "download_returncode": download_result.returncode, "blocked_returncode": blocked_result.returncode, "forced_returncode": forced_result.returncode, "verify_returncode": verify_result.returncode, "root_name": root_name}

        for label, rc in [("seed", seed_result.returncode), ("download", download_result.returncode), ("forced sync", forced_result.returncode), ("verify", verify_result.returncode)]:
            if rc != 0:
                return TestResult.fail_result(self.case_id, self.name, f"{label} phase failed with status {rc}", artifacts, details)

        if blocked_result.returncode == 0 and "big delete" not in blocked_output:
            return TestResult.fail_result(self.case_id, self.name, "Big delete safeguard did not trigger before forced acknowledgement", artifacts, details)
        if "big delete" not in blocked_output and "--force" not in blocked_output:
            return TestResult.fail_result(self.case_id, self.name, "Blocked sync did not emit a big delete safeguard warning", artifacts, details)
        if any(entry == f"{root_name}/BigDelete" or entry.startswith(f"{root_name}/BigDelete/") for entry in remote_manifest):
            return TestResult.fail_result(self.case_id, self.name, "BigDelete content still exists online after acknowledged forced delete", artifacts, details)
        if f"{root_name}/Keep/keep.txt" not in remote_manifest:
            return TestResult.fail_result(self.case_id, self.name, "Keep content disappeared during big delete safeguard processing", artifacts, details)

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)
