from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0024BigDeleteSafeguardValidation(E2ETestCase):
    case_id = "0024"
    name = "big delete safeguard validation"
    description = "Validate classify_as_big_delete protection and forced acknowledgement via --force"

    def _write_config(self, config_path: Path, sync_dir: Path) -> None:
        write_text_file(
            config_path,
            "# tc0024 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            'classify_as_big_delete = "3"\n',
        )

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
        conf_local = case_work_dir / "conf-local"
        conf_verify = case_work_dir / "conf-verify"

        root_name = f"ZZ_E2E_TC0024_{context.run_id}_{os.getpid()}"
        delete_files = [f"Delete0{idx}.txt" for idx in range(1, 6)]

        reset_directory(seed_root)
        reset_directory(local_root)
        reset_directory(verify_root)

        # Seed multiple top-level delete candidates.
        for filename in delete_files:
            write_text_file(seed_root / root_name / filename, f"{filename}\n")
        write_text_file(seed_root / root_name / "Keep" / "keep.txt", "keep\n")

        context.bootstrap_config_dir(conf_seed)
        self._write_config(conf_seed / "config", seed_root)

        context.bootstrap_config_dir(conf_local)
        self._write_config(conf_local / "config", local_root)

        context.bootstrap_config_dir(conf_verify)
        self._write_config(conf_verify / "config", verify_root)

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
        blocked_verify_manifest_file = state_dir / "blocked_verify_manifest.txt"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
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

        # Confirm the delete candidates were downloaded locally.
        missing_local = [
            filename
            for filename in delete_files
            if not (local_root / root_name / filename).is_file()
        ]
        if missing_local:
            write_text_file(
                metadata_file,
                "\n".join(
                    [
                        f"case_id={self.case_id}",
                        f"root_name={root_name}",
                        f"seed_returncode={seed_result.returncode}",
                        f"download_returncode={download_result.returncode}",
                        f"missing_local={missing_local!r}",
                    ]
                )
                + "\n",
            )
            artifacts = [
                str(seed_stdout),
                str(seed_stderr),
                str(download_stdout),
                str(download_stderr),
                str(metadata_file),
            ]
            details = {
                "seed_returncode": seed_result.returncode,
                "download_returncode": download_result.returncode,
                "root_name": root_name,
            }
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Expected delete candidate files were not downloaded before delete phase",
                artifacts,
                details,
            )

        # Delete multiple top-level files so the safeguard sees > threshold candidates.
        for filename in delete_files:
            candidate = local_root / root_name / filename
            if candidate.exists():
                candidate.unlink()

        blocked_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        context.log(f"Executing Test Case {self.case_id} blocked sync: {command_to_string(blocked_command)}")
        blocked_result = run_command(blocked_command, cwd=context.repo_root)
        write_text_file(blocked_stdout, blocked_result.stdout)
        write_text_file(blocked_stderr, blocked_result.stderr)

        blocked_output = (blocked_result.stdout + "\n" + blocked_result.stderr).lower()

        # Verify after blocked sync using a fresh config to ensure the remote side
        # was not modified before acknowledgement.
        reset_directory(verify_root)
        blocked_verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_verify),
        ]
        context.log(f"Executing Test Case {self.case_id} blocked verify: {command_to_string(blocked_verify_command)}")
        blocked_verify_result = run_command(blocked_verify_command, cwd=context.repo_root)

        # Reuse the same files for the final verify logs to avoid adding extra artifacts.
        write_text_file(verify_stdout, blocked_verify_result.stdout)
        write_text_file(verify_stderr, blocked_verify_result.stderr)

        blocked_remote_manifest = build_manifest(verify_root)
        write_manifest(blocked_verify_manifest_file, blocked_remote_manifest)

        forced_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--force",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_local),
        ]
        context.log(f"Executing Test Case {self.case_id} forced sync: {command_to_string(forced_command)}")
        forced_result = run_command(forced_command, cwd=context.repo_root)
        write_text_file(forced_stdout, forced_result.stdout)
        write_text_file(forced_stderr, forced_result.stderr)

        # Final clean verify after --force.
        reset_directory(verify_root)
        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
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

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"seed_root={seed_root}",
                    f"local_root={local_root}",
                    f"verify_root={verify_root}",
                    f"seed_confdir={conf_seed}",
                    f"local_confdir={conf_local}",
                    f"verify_confdir={conf_verify}",
                    f"seed_returncode={seed_result.returncode}",
                    f"download_returncode={download_result.returncode}",
                    f"blocked_returncode={blocked_result.returncode}",
                    f"blocked_verify_returncode={blocked_verify_result.returncode}",
                    f"forced_returncode={forced_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"delete_files={delete_files!r}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(download_stdout),
            str(download_stderr),
            str(blocked_stdout),
            str(blocked_stderr),
            str(forced_stdout),
            str(forced_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(blocked_verify_manifest_file),
            str(remote_manifest_file),
            str(metadata_file),
        ]
        details = {
            "seed_returncode": seed_result.returncode,
            "download_returncode": download_result.returncode,
            "blocked_returncode": blocked_result.returncode,
            "blocked_verify_returncode": blocked_verify_result.returncode,
            "forced_returncode": forced_result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
        }

        for label, rc in [
            ("seed", seed_result.returncode),
            ("download", download_result.returncode),
            ("blocked verify", blocked_verify_result.returncode),
            ("forced sync", forced_result.returncode),
            ("verify", verify_result.returncode),
        ]:
            if rc != 0:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} phase failed with status {rc}",
                    artifacts,
                    details,
                )

        # Blocked sync must emit the safeguard warning / acknowledgement requirement.
        if "big delete" not in blocked_output and "--force" not in blocked_output:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Blocked sync did not emit a big delete safeguard warning",
                artifacts,
                details,
            )

        # Before --force, the remote delete candidates must still exist.
        for filename in delete_files:
            if f"{root_name}/{filename}" not in blocked_remote_manifest:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    "Remote delete candidates were modified before forced acknowledgement",
                    artifacts,
                    details,
                )

        # After --force, the delete candidates must be gone remotely.
        for filename in delete_files:
            if f"{root_name}/{filename}" in remote_manifest:
                return TestResult.fail_result(
                    self.case_id,
                    self.name,
                    f"{filename} still exists online after acknowledged forced delete",
                    artifacts,
                    details,
                )

        if f"{root_name}/Keep/keep.txt" not in remote_manifest:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                "Keep content disappeared during big delete safeguard processing",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)