from __future__ import annotations

import os
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.manifest import build_manifest, write_manifest
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0022LocalFirstValidation(E2ETestCase):
    case_id = "0022"
    name = "local_first validation"
    description = "Validate that local_first treats local content as the source of truth during a conflict"

    def _write_config(self, config_path: Path, sync_dir: Path, local_first: bool = False) -> None:
        content = (
            "# tc0022 config\n"
            f'sync_dir = "{sync_dir}"\n'
        )
        if local_first:
            content += 'local_first = "true"\n'
        write_onedrive_config(config_path, content)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0022",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        seed_root = case_work_dir / "seedroot"
        local_root = case_work_dir / "localroot"
        remote_update_root = case_work_dir / "remoteupdateroot"
        verify_root = case_work_dir / "verifyroot"

        conf_seed = case_work_dir / "conf-seed"
        conf_local = case_work_dir / "conf-local"
        conf_remote = case_work_dir / "conf-remote"
        conf_verify = case_work_dir / "conf-verify"

        root_name = f"ZZ_E2E_TC0022_{context.run_id}_{os.getpid()}"
        relative_file = f"{root_name}/conflict.txt"

        reset_directory(seed_root)
        reset_directory(local_root)
        reset_directory(remote_update_root)
        reset_directory(verify_root)

        write_text_file(seed_root / relative_file, "base\n")
        write_text_file(remote_update_root / relative_file, "remote wins unless local_first applies\n")

        context.bootstrap_config_dir(conf_seed)
        self._write_config(conf_seed / "config", seed_root)

        context.bootstrap_config_dir(conf_local)
        self._write_config(conf_local / "config", local_root)

        context.bootstrap_config_dir(conf_remote)
        self._write_config(conf_remote / "config", remote_update_root)

        context.bootstrap_config_dir(conf_verify)
        self._write_config(conf_verify / "config", verify_root)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        download_stdout = case_log_dir / "download_stdout.log"
        download_stderr = case_log_dir / "download_stderr.log"
        remote_stdout = case_log_dir / "remote_update_stdout.log"
        remote_stderr = case_log_dir / "remote_update_stderr.log"
        final_stdout = case_log_dir / "final_sync_stdout.log"
        final_stderr = case_log_dir / "final_sync_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_seed),
        ]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)

        download_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        context.log(f"Executing Test Case {self.case_id} download: {command_to_string(download_command)}")
        download_result = run_command(download_command, cwd=context.repo_root)
        write_text_file(download_stdout, download_result.stdout)
        write_text_file(download_stderr, download_result.stderr)

        remote_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_remote),
        ]
        context.log(f"Executing Test Case {self.case_id} remote update: {command_to_string(remote_command)}")
        remote_result = run_command(remote_command, cwd=context.repo_root)
        write_text_file(remote_stdout, remote_result.stdout)
        write_text_file(remote_stderr, remote_result.stderr)

        # Ensure the local edit is definitively later than the remote update.
        # This is critical so the final sync actually exercises local_first.
        time.sleep(2)

        local_file = local_root / relative_file
        expected = "local wins because local_first is enabled\n"
        write_text_file(local_file, expected)

        now = time.time()
        os.utime(local_file, (now, now))

        # Reuse the same local DB / delta state, but enable local_first
        self._write_config(conf_local / "config", local_root, local_first=True)

        final_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        context.log(f"Executing Test Case {self.case_id} final sync: {command_to_string(final_command)}")
        final_result = run_command(final_command, cwd=context.repo_root)
        write_text_file(final_stdout, final_result.stdout)
        write_text_file(final_stderr, final_result.stderr)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_verify),
        ]
        context.log(f"Executing Test Case {self.case_id} verify: {command_to_string(verify_command)}")
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        local_content = (local_root / relative_file).read_text(encoding="utf-8") if (local_root / relative_file).is_file() else ""
        remote_content = (verify_root / relative_file).read_text(encoding="utf-8") if (verify_root / relative_file).is_file() else ""

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"seed_root={seed_root}",
                    f"local_root={local_root}",
                    f"remote_update_root={remote_update_root}",
                    f"verify_root={verify_root}",
                    f"seed_confdir={conf_seed}",
                    f"local_confdir={conf_local}",
                    f"remote_confdir={conf_remote}",
                    f"verify_confdir={conf_verify}",
                    f"seed_returncode={seed_result.returncode}",
                    f"download_returncode={download_result.returncode}",
                    f"remote_returncode={remote_result.returncode}",
                    f"final_returncode={final_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"local_content={local_content!r}",
                    f"remote_content={remote_content!r}",
                    f"local_mtime={local_file.stat().st_mtime if local_file.exists() else 0}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(download_stdout),
            str(download_stderr),
            str(remote_stdout),
            str(remote_stderr),
            str(final_stdout),
            str(final_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        details = {
            "seed_returncode": seed_result.returncode,
            "download_returncode": download_result.returncode,
            "remote_returncode": remote_result.returncode,
            "final_returncode": final_result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
        }

        for label, rc in [
            ("seed", seed_result.returncode),
            ("download", download_result.returncode),
            ("remote update", remote_result.returncode),
            ("final sync", final_result.returncode),
            ("verify", verify_result.returncode),
        ]:
            if rc != 0:
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} phase failed with status {rc}",
                    artifacts,
                    details,
                )

        if local_content != expected:
            return self.fail_result(
                self.case_id,
                self.name,
                "Local content was not retained after conflict resolution with local_first enabled",
                artifacts,
                details,
            )

        if remote_content != expected:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote content did not converge to the local source-of-truth content when local_first was enabled",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)