from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0018RecycleBinValidation(E2ETestCase):
    case_id = "0018"
    name = "recycle bin validation"
    description = "Validate online deletion Recycle Bin handling, including collision filename formatting"

    def _write_runtime_base_config(self, config_path: Path, sync_dir: Path) -> None:
        write_onedrive_config(
            config_path,
            "# tc0018 runtime base config\n"
            f'sync_dir = "{sync_dir}"\n',
        )

    def _write_runtime_cleanup_config(self, config_path: Path, sync_dir: Path, recycle_bin_path: Path) -> None:
        write_onedrive_config(
            config_path,
            "# tc0018 runtime cleanup config\n"
            f'sync_dir = "{sync_dir}"\n'
            'cleanup_local_files = "true"\n'
            'download_only = "true"\n'
            'use_recycle_bin = "true"\n'
            f'recycle_bin_path = "{recycle_bin_path}"\n',
        )

    def _write_verify_config(self, config_path: Path, sync_dir: Path) -> None:
        write_onedrive_config(
            config_path,
            "# tc0018 verify config\n"
            f'sync_dir = "{sync_dir}"\n',
        )

    def _seed_recycle_entry(self, recycle_bin_root: Path, filename: str) -> None:
        write_text_file(
            recycle_bin_root / "files" / filename,
            f"pre-existing recycle bin payload for {filename}\n",
        )
        write_text_file(
            recycle_bin_root / "info" / f"{filename}.trashinfo",
            "[Trash Info]\n"
            f"Path=/pre-existing/{filename}\n"
            "DeletionDate=2000-01-01T00:00:00\n",
        )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0018",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        mutator_root = case_work_dir / "mutatorroot"
        verify_root = case_work_dir / "verifyroot"
        recycle_bin_root = case_work_dir / "RecycleBin"

        conf_runtime = case_work_dir / "conf-runtime"
        conf_mutator = case_work_dir / "conf-mutator"
        conf_verify = case_work_dir / "conf-verify"

        root_name = f"ZZ_E2E_TC0018_{context.run_id}_{os.getpid()}"

        reset_directory(sync_root)
        reset_directory(mutator_root)
        reset_directory(verify_root)
        reset_directory(recycle_bin_root)

        # Pre-populate selected Recycle Bin names so the cleanup phase exercises
        # collision numbering at .2, .3 and .4. The extensionless entry verifies
        # that collision numbering does not introduce a trailing dot.
        seeded_recycle_filenames = [
            "collision2.data",
            "collision3.data",
            "collision3.2.data",
            "collision4.data",
            "collision4.2.data",
            "collision4.3.data",
            "extensionless",
        ]
        for filename in seeded_recycle_filenames:
            self._seed_recycle_entry(recycle_bin_root, filename)

        deleted_filenames = [
            "no-collision.data",
            "collision2.data",
            "collision3.data",
            "collision4.data",
            "extensionless",
        ]

        # Create initial local content to seed remotely. retain.txt keeps OldData
        # present online while the individual target files are deleted remotely,
        # ensuring the Recycle Bin code processes file paths rather than moving
        # the parent directory as one item.
        write_text_file(sync_root / root_name / "Keep" / "keep.txt", "keep\n")
        write_text_file(sync_root / root_name / "OldData" / "retain.txt", "retain\n")
        for filename in deleted_filenames:
            write_text_file(sync_root / root_name / "OldData" / filename, f"delete {filename}\n")

        # Shared runtime config for seed -> cleanup
        context.bootstrap_config_dir(conf_runtime)
        self._write_runtime_base_config(conf_runtime / "config", sync_root)

        # A second client view is used to create genuine remote file deletions.
        context.bootstrap_config_dir(conf_mutator)
        self._write_verify_config(conf_mutator / "config", mutator_root)

        # Fresh verify config for clean remote validation
        context.bootstrap_config_dir(conf_verify)
        self._write_verify_config(conf_verify / "config", verify_root)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        mutator_pull_stdout = case_log_dir / "mutator_pull_stdout.log"
        mutator_pull_stderr = case_log_dir / "mutator_pull_stderr.log"
        mutator_delete_stdout = case_log_dir / "mutator_delete_stdout.log"
        mutator_delete_stderr = case_log_dir / "mutator_delete_stderr.log"
        cleanup_stdout = case_log_dir / "cleanup_stdout.log"
        cleanup_stderr = case_log_dir / "cleanup_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"

        recycle_manifest_file = state_dir / "recycle_manifest.txt"
        remote_manifest_file = state_dir / "remote_verify_manifest.txt"
        local_manifest_file = state_dir / "local_manifest_after_cleanup.txt"
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
            str(conf_runtime),
        ]
        context.log(f"Executing Test Case {self.case_id} seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)

        mutator_pull_command = [
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
            str(conf_mutator),
        ]
        context.log(f"Executing Test Case {self.case_id} mutator pull: {command_to_string(mutator_pull_command)}")
        mutator_pull_result = run_command(mutator_pull_command, cwd=context.repo_root)
        write_text_file(mutator_pull_stdout, mutator_pull_result.stdout)
        write_text_file(mutator_pull_stderr, mutator_pull_result.stderr)

        missing_mutator_targets: list[str] = []
        for filename in deleted_filenames:
            target = mutator_root / root_name / "OldData" / filename
            if target.is_file():
                target.unlink()
            else:
                missing_mutator_targets.append(filename)

        mutator_delete_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_mutator),
        ]
        context.log(f"Executing Test Case {self.case_id} mutator delete: {command_to_string(mutator_delete_command)}")
        mutator_delete_result = run_command(mutator_delete_command, cwd=context.repo_root)
        write_text_file(mutator_delete_stdout, mutator_delete_result.stdout)
        write_text_file(mutator_delete_stderr, mutator_delete_result.stderr)

        # Rewrite the same runtime config so cleanup reuses the seed client's DB
        # and delta state when it receives the remote file deletions.
        self._write_runtime_cleanup_config(conf_runtime / "config", sync_root, recycle_bin_root)

        cleanup_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--cleanup-local-files",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_runtime),
        ]
        context.log(f"Executing Test Case {self.case_id} cleanup: {command_to_string(cleanup_command)}")
        cleanup_result = run_command(cleanup_command, cwd=context.repo_root)
        write_text_file(cleanup_stdout, cleanup_result.stdout)
        write_text_file(cleanup_stderr, cleanup_result.stderr)

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

        recycle_manifest = build_manifest(recycle_bin_root)
        remote_manifest = build_manifest(verify_root)
        local_manifest = build_manifest(sync_root)

        write_manifest(recycle_manifest_file, recycle_manifest)
        write_manifest(remote_manifest_file, remote_manifest)
        write_manifest(local_manifest_file, local_manifest)

        expected_recycled_filenames = [
            "no-collision.data",
            "collision2.2.data",
            "collision3.3.data",
            "collision4.4.data",
            "extensionless.2",
        ]
        malformed_collision_entries = [
            entry
            for entry in recycle_manifest
            if "..data" in Path(entry).name
        ]

        write_text_file(
            metadata_file,
            "\n".join(
                [
                    f"case_id={self.case_id}",
                    f"root_name={root_name}",
                    f"sync_root={sync_root}",
                    f"mutator_root={mutator_root}",
                    f"verify_root={verify_root}",
                    f"recycle_bin_root={recycle_bin_root}",
                    f"runtime_confdir={conf_runtime}",
                    f"mutator_confdir={conf_mutator}",
                    f"verify_confdir={conf_verify}",
                    f"seed_returncode={seed_result.returncode}",
                    f"mutator_pull_returncode={mutator_pull_result.returncode}",
                    f"mutator_delete_returncode={mutator_delete_result.returncode}",
                    f"cleanup_returncode={cleanup_result.returncode}",
                    f"verify_returncode={verify_result.returncode}",
                    f"missing_mutator_targets={missing_mutator_targets!r}",
                    f"seeded_recycle_filenames={seeded_recycle_filenames!r}",
                    f"expected_recycled_filenames={expected_recycled_filenames!r}",
                    f"malformed_collision_entries={malformed_collision_entries!r}",
                ]
            )
            + "\n",
        )

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(mutator_pull_stdout),
            str(mutator_pull_stderr),
            str(mutator_delete_stdout),
            str(mutator_delete_stderr),
            str(cleanup_stdout),
            str(cleanup_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(recycle_manifest_file),
            str(remote_manifest_file),
            str(local_manifest_file),
            str(metadata_file),
        ]
        details = {
            "seed_returncode": seed_result.returncode,
            "mutator_pull_returncode": mutator_pull_result.returncode,
            "mutator_delete_returncode": mutator_delete_result.returncode,
            "cleanup_returncode": cleanup_result.returncode,
            "verify_returncode": verify_result.returncode,
            "missing_mutator_targets": missing_mutator_targets,
            "malformed_collision_entries": malformed_collision_entries,
            "root_name": root_name,
        }

        if seed_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote seed failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        if mutator_pull_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote mutation preload failed with status {mutator_pull_result.returncode}",
                artifacts,
                details,
            )

        if missing_mutator_targets:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote mutation preload did not contain expected delete targets: {missing_mutator_targets}",
                artifacts,
                details,
            )

        if mutator_delete_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote file deletion propagation failed with status {mutator_delete_result.returncode}",
                artifacts,
                details,
            )

        if cleanup_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Recycle bin cleanup sync failed with status {cleanup_result.returncode}",
                artifacts,
                details,
            )

        if verify_result.returncode != 0:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote verification failed with status {verify_result.returncode}",
                artifacts,
                details,
            )

        if not (sync_root / root_name / "Keep" / "keep.txt").is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                "Keep file is missing locally after recycle bin processing",
                artifacts,
                details,
            )

        if not (sync_root / root_name / "OldData" / "retain.txt").is_file():
            return self.fail_result(
                self.case_id,
                self.name,
                "OldData retain file is missing locally after recycle bin processing",
                artifacts,
                details,
            )

        remaining_local_targets = [
            filename
            for filename in deleted_filenames
            if (sync_root / root_name / "OldData" / filename).exists()
        ]
        if remaining_local_targets:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Online-deleted files still exist locally after Recycle Bin cleanup: {remaining_local_targets}",
                artifacts,
                details,
            )

        if malformed_collision_entries:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Recycle Bin collision filenames contain an unexpected double dot: {malformed_collision_entries}",
                artifacts,
                details,
            )

        missing_seeded_entries: list[str] = []
        for filename in seeded_recycle_filenames:
            for expected_entry in (f"files/{filename}", f"info/{filename}.trashinfo"):
                if expected_entry not in recycle_manifest:
                    missing_seeded_entries.append(expected_entry)
        if missing_seeded_entries:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Pre-existing Recycle Bin collision entries were not preserved: {missing_seeded_entries}",
                artifacts,
                details,
            )

        missing_recycled_entries: list[str] = []
        for filename in expected_recycled_filenames:
            for expected_entry in (f"files/{filename}", f"info/{filename}.trashinfo"):
                if expected_entry not in recycle_manifest:
                    missing_recycled_entries.append(expected_entry)
        if missing_recycled_entries:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Expected Recycle Bin collision outputs are missing: {missing_recycled_entries}",
                artifacts,
                details,
            )

        expected_remote_retained = [
            f"{root_name}/Keep/keep.txt",
            f"{root_name}/OldData/retain.txt",
        ]
        missing_remote_retained = [
            path for path in expected_remote_retained if path not in remote_manifest
        ]
        if missing_remote_retained:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Expected retained files are missing online after recycle bin processing: {missing_remote_retained}",
                artifacts,
                details,
            )

        remote_deleted_targets = [
            f"{root_name}/OldData/{filename}"
            for filename in deleted_filenames
            if f"{root_name}/OldData/{filename}" in remote_manifest
        ]
        if remote_deleted_targets:
            return self.fail_result(
                self.case_id,
                self.name,
                f"Files intended for online deletion still exist remotely: {remote_deleted_targets}",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
