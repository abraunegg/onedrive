from __future__ import annotations

import os
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0023BypassDataPreservationValidation(E2ETestCase):
    case_id = "0023"
    name = "bypass_data_preservation validation"
    description = "Validate that bypass_data_preservation suppresses safe-backup preservation during resync conflict resolution"

    def _write_config(self, config_path: Path, sync_dir: Path, bypass_data_preservation: bool = False) -> None:
        content = (
            "# tc0023 config\n"
            f'sync_dir = "{sync_dir}"\n'
        )
        if bypass_data_preservation:
            content += 'bypass_data_preservation = "true"\n'
        write_onedrive_config(config_path, content)

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0023"
        case_log_dir = context.logs_dir / "tc0023"
        state_dir = context.state_dir / "tc0023"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        seed_root = case_work_dir / "seedroot"
        local_root = case_work_dir / "localroot"

        conf_seed = case_work_dir / "conf-seed"
        conf_local = case_work_dir / "conf-local"

        root_name = f"ZZ_E2E_TC0023_{context.run_id}_{os.getpid()}"
        relative_file = f"{root_name}/conflict.txt"

        reset_directory(seed_root)
        reset_directory(local_root)

        original_remote_content = "base\n"
        local_conflicting_content = "local conflicting content\n"

        # Seed the remote with the original content
        write_text_file(seed_root / relative_file, original_remote_content)

        context.bootstrap_config_dir(conf_seed)
        self._write_config(conf_seed / "config", seed_root)

        context.bootstrap_config_dir(conf_local)
        self._write_config(conf_local / "config", local_root)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        download_stdout = case_log_dir / "download_stdout.log"
        download_stderr = case_log_dir / "download_stderr.log"
        final_stdout = case_log_dir / "final_sync_stdout.log"
        final_stderr = case_log_dir / "final_sync_stderr.log"
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
            "--download-only",
            "--verbose",
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

        local_file = local_root / relative_file
        if not local_file.is_file():
            artifacts = [
                str(seed_stdout),
                str(seed_stderr),
                str(download_stdout),
                str(download_stderr),
            ]
            details = {
                "seed_returncode": seed_result.returncode,
                "download_returncode": download_result.returncode,
                "root_name": root_name,
            }
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Initial download phase did not create the expected local file",
                artifacts,
                details,
            )

        initial_local_content = local_file.read_text(encoding="utf-8")
        if initial_local_content != original_remote_content:
            artifacts = [
                str(seed_stdout),
                str(seed_stderr),
                str(download_stdout),
                str(download_stderr),
            ]
            details = {
                "seed_returncode": seed_result.returncode,
                "download_returncode": download_result.returncode,
                "root_name": root_name,
                "initial_local_content": initial_local_content,
            }
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Initial download phase did not produce the expected baseline file content",
                artifacts,
                details,
            )

        # Ensure the local conflicting edit has a clearly newer local timestamp.
        # This helps force the resync path to treat the local file as modified
        # relative to the unchanged online copy.
        time.sleep(2)
        write_text_file(local_file, local_conflicting_content)
        os.utime(local_file, None)

        # Re-write the local config to enable bypass behaviour. The final sync
        # must use --resync so the known local DB state is discarded and the
        # client evaluates the local modified file against the existing remote file.
        self._write_config(conf_local / "config", local_root, bypass_data_preservation=True)

        final_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        context.log(f"Executing Test Case {self.case_id} final sync: {command_to_string(final_command)}")
        final_result = run_command(final_command, cwd=context.repo_root)
        write_text_file(final_stdout, final_result.stdout)
        write_text_file(final_stderr, final_result.stderr)

        final_local_content = local_file.read_text(encoding="utf-8") if local_file.is_file() else ""

        safe_backup_files = sorted(
            str(path.relative_to(local_root))
            for path in local_root.rglob("*safeBackup*")
            if path.is_file()
        )

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"seed_root={seed_root}",
                    f"local_root={local_root}",
                    f"seed_confdir={conf_seed}",
                    f"local_confdir={conf_local}",
                    f"seed_returncode={seed_result.returncode}",
                    f"download_returncode={download_result.returncode}",
                    f"final_returncode={final_result.returncode}",
                    f"initial_local_content={initial_local_content!r}",
                    f"local_conflicting_content={local_conflicting_content!r}",
                    f"final_local_content={final_local_content!r}",
                    f"safe_backup_files={safe_backup_files!r}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(download_stdout),
            str(download_stderr),
            str(final_stdout),
            str(final_stderr),
            str(metadata_file),
        ]
        details = {
            "seed_returncode": seed_result.returncode,
            "download_returncode": download_result.returncode,
            "final_returncode": final_result.returncode,
            "root_name": root_name,
            "safe_backup_count": len(safe_backup_files),
        }

        for label, rc in [
            ("seed", seed_result.returncode),
            ("download", download_result.returncode),
            ("final sync", final_result.returncode),
        ]:
            if rc != 0:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} phase failed with status {rc}",
                    artifacts,
                    details,
                )

        # With bypass_data_preservation enabled, the unchanged online version
        # should overwrite the locally modified file during the resync.
        if final_local_content != original_remote_content:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Local content was not overwritten by the remote file when bypass_data_preservation was enabled",
                artifacts,
                details,
            )

        if safe_backup_files:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Safe-backup files were created despite bypass_data_preservation being enabled",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)