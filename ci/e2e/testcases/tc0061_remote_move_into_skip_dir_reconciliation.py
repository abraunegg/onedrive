from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file


class TestCase0061RemoteMoveIntoSkipDirReconciliation(E2ETestCase):
    case_id = "0061"
    name = "remote move into skip_dir reconciliation"
    description = (
        "Validate that items remotely moved from an included path into a skipped directory "
        "are removed from the old local path, are not downloaded into the skipped path, "
        "and remain present online at the skipped destination"
    )

    def _build_skip_config_text(self, sync_dir: Path, skipped_relative: str) -> str:
        return (
            "# tc0061 skip_dir client config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            f'skip_dir = "{skipped_relative}"\n'
            'skip_dir_strict_match = "true"\n'
        )

    def _build_unfiltered_config_text(self, sync_dir: Path) -> str:
        return (
            "# tc0061 unfiltered mutator / verifier config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
        )

    def _run_phase(
        self,
        *,
        context: E2EContext,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        artifacts: list[str],
        details: dict[str, object],
        detail_key: str,
    ):
        context.log(f"Executing Test Case {self.case_id} {detail_key}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        artifacts.extend([str(stdout_file), str(stderr_file)])
        details[f"{detail_key}_returncode"] = result.returncode
        return result

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0061",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        skip_sync_root = case_work_dir / "skip-client-syncroot"
        mutator_sync_root = case_work_dir / "mutator-syncroot"
        verify_sync_root = case_work_dir / "verify-syncroot"
        skip_conf = case_work_dir / "conf-skip-client"
        mutator_conf = case_work_dir / "conf-mutator"
        verify_conf = case_work_dir / "conf-verify"

        root_name = f"ZZ_E2E_TC0061_{context.run_id}_{os.getpid()}"
        dcim_relative = f"{root_name}/Pictures/DCIM"
        archive_relative = f"{root_name}/Pictures/Archive"
        archive_2025_relative = f"{archive_relative}/2025"
        skipped_relative = f"{root_name}/Pictures/Archive"

        source_files = {
            f"{dcim_relative}/photo-001.txt": "TC0061 photo 001\n",
            f"{dcim_relative}/photo-002.txt": "TC0061 photo 002\n",
            f"{dcim_relative}/nested/photo-003.txt": "TC0061 nested photo 003\n",
        }
        moved_files = {
            path.replace(dcim_relative, archive_2025_relative, 1): content
            for path, content in source_files.items()
        }

        context.prepare_minimal_config_dir(
            skip_conf,
            self._build_skip_config_text(skip_sync_root, skipped_relative),
        )
        context.prepare_minimal_config_dir(
            mutator_conf,
            self._build_unfiltered_config_text(mutator_sync_root),
        )
        context.prepare_minimal_config_dir(
            verify_conf,
            self._build_unfiltered_config_text(verify_sync_root),
        )

        for relative_path, content in source_files.items():
            write_text_file(skip_sync_root / relative_path, content)

        artifacts: list[str] = []
        details: dict[str, object] = {
            "root_name": root_name,
            "dcim_relative": dcim_relative,
            "archive_relative": archive_relative,
            "archive_2025_relative": archive_2025_relative,
            "skipped_relative": skipped_relative,
            "source_files": sorted(source_files),
            "moved_files": sorted(moved_files),
            "skip_sync_root": str(skip_sync_root),
            "mutator_sync_root": str(mutator_sync_root),
            "verify_sync_root": str(verify_sync_root),
        }

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        mutator_download_stdout = case_log_dir / "mutator_download_stdout.log"
        mutator_download_stderr = case_log_dir / "mutator_download_stderr.log"
        mutator_upload_stdout = case_log_dir / "mutator_upload_stdout.log"
        mutator_upload_stderr = case_log_dir / "mutator_upload_stderr.log"
        reconcile_stdout = case_log_dir / "reconcile_stdout.log"
        reconcile_stderr = case_log_dir / "reconcile_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        local_manifest_file = state_dir / "skip_client_manifest.txt"
        verify_manifest_file = state_dir / "remote_verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"
        artifacts.extend([str(local_manifest_file), str(verify_manifest_file), str(metadata_file)])

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(skip_sync_root),
            "--confdir",
            str(skip_conf),
        ]
        seed_result = self._run_phase(
            context=context,
            command=seed_command,
            stdout_file=seed_stdout,
            stderr_file=seed_stderr,
            artifacts=artifacts,
            details=details,
            detail_key="seed",
        )
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Seed sync failed with status {seed_result.returncode}", artifacts, details)

        mutator_download_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(mutator_sync_root),
            "--confdir",
            str(mutator_conf),
        ]
        mutator_download_result = self._run_phase(
            context=context,
            command=mutator_download_command,
            stdout_file=mutator_download_stdout,
            stderr_file=mutator_download_stderr,
            artifacts=artifacts,
            details=details,
            detail_key="mutator_download",
        )
        if mutator_download_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Mutator download failed with status {mutator_download_result.returncode}", artifacts, details)

        for source_relative, _content in source_files.items():
            source_path = mutator_sync_root / source_relative
            destination_relative = source_relative.replace(dcim_relative, archive_2025_relative, 1)
            destination_path = mutator_sync_root / destination_relative
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.rename(destination_path)

        dcim_mutator_path = mutator_sync_root / dcim_relative
        if dcim_mutator_path.exists():
            shutil.rmtree(dcim_mutator_path)

        mutator_upload_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(mutator_sync_root),
            "--confdir",
            str(mutator_conf),
        ]
        mutator_upload_result = self._run_phase(
            context=context,
            command=mutator_upload_command,
            stdout_file=mutator_upload_stdout,
            stderr_file=mutator_upload_stderr,
            artifacts=artifacts,
            details=details,
            detail_key="mutator_upload",
        )
        if mutator_upload_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"Mutator upload failed with status {mutator_upload_result.returncode}", artifacts, details)

        reconcile_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--syncdir",
            str(skip_sync_root),
            "--confdir",
            str(skip_conf),
        ]
        reconcile_result = self._run_phase(
            context=context,
            command=reconcile_command,
            stdout_file=reconcile_stdout,
            stderr_file=reconcile_stderr,
            artifacts=artifacts,
            details=details,
            detail_key="reconcile",
        )

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--syncdir",
            str(verify_sync_root),
            "--confdir",
            str(verify_conf),
        ]
        verify_result = self._run_phase(
            context=context,
            command=verify_command,
            stdout_file=verify_stdout,
            stderr_file=verify_stderr,
            artifacts=artifacts,
            details=details,
            detail_key="verify",
        )

        local_manifest = build_manifest(skip_sync_root)
        verify_manifest = build_manifest(verify_sync_root)
        write_manifest(local_manifest_file, local_manifest)
        write_manifest(verify_manifest_file, verify_manifest)

        details["local_manifest"] = local_manifest
        details["verify_manifest"] = verify_manifest
        details["local_dcim_exists"] = (skip_sync_root / dcim_relative).exists()
        details["local_archive_exists"] = (skip_sync_root / archive_relative).exists()
        details["verify_dcim_exists"] = (verify_sync_root / dcim_relative).exists()
        details["verify_archive_2025_exists"] = (verify_sync_root / archive_2025_relative).exists()
        self._write_metadata(metadata_file, details)

        failures: list[str] = []
        if reconcile_result.returncode != 0:
            failures.append(f"Reconcile sync failed with status {reconcile_result.returncode}")
        if verify_result.returncode != 0:
            failures.append(f"Remote verification failed with status {verify_result.returncode}")

        for source_relative in source_files:
            if source_relative in local_manifest or (skip_sync_root / source_relative).exists():
                failures.append(f"Skipped client still contains old included source path after remote move: {source_relative}")
            if source_relative in verify_manifest or (verify_sync_root / source_relative).exists():
                failures.append(f"Remote verification still contains old included source path after move: {source_relative}")

        for moved_relative, expected_content in moved_files.items():
            local_moved_path = skip_sync_root / moved_relative
            verify_moved_path = verify_sync_root / moved_relative
            if local_moved_path.exists():
                failures.append(f"Skipped client downloaded skipped destination unexpectedly: {moved_relative}")
            if not verify_moved_path.is_file():
                failures.append(f"Remote verification is missing moved skipped destination: {moved_relative}")
            elif verify_moved_path.read_text(encoding="utf-8", errors="replace") != expected_content:
                failures.append(f"Remote verification content mismatch for moved skipped destination: {moved_relative}")

        if failures:
            return self.fail_result(self.case_id, self.name, "; ".join(failures), artifacts, details)

        return self.pass_result(self.case_id, self.name, artifacts, details)

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )
