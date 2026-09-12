from __future__ import annotations

import json
import os
import shutil
import sqlite3
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_text_file,
)
from framework.xlsx import (
    REVISION_0,
    REVISION_1,
    REVISION_2,
    create_random_xlsx,
    mutate_xlsx_revision,
    validate_xlsx,
)
from testcases_business_shared_folders.shared_folder_common import case_sync_root


class CaseFailure(RuntimeError):
    pass


class BusinessSharedFolderTestCase0006SharePointTimestampReplacement(E2ETestCase):
    case_id = "bsftc0006"
    name = "SharePoint-backed Business Shared Folder timestamp-preserving replacement"
    description = (
        "Validate timestamp-preserving XLSX replacement and genuine remote-conflict handling "
        "inside the preserved SharePoint-backed Business Shared Folder topology without modifying "
        "any pre-existing fixture object"
    )

    # EXTREME fixture-safety constraint:
    # - This existing path may be used as a parent only.
    # - No pre-existing object below or above it may be modified, renamed, replaced, or deleted.
    # - The testcase owns only RESERVED_TEST_DIR and must remove it again before returning.
    FIXTURE_PARENT_RELATIVE = Path("Data/BSF_CORE/DATASET_B/nested/upload-target")
    RESERVED_TEST_DIR = "ZZ_E2E_BSFTC0006"

    SESSION_THRESHOLD_BYTES = 4 * 1024 * 1024
    SMALL_XLSX_PAYLOAD_ROWS = 80
    LARGE_XLSX_PAYLOAD_ROWS = 240

    SMALL_FILENAME = "timestamp-preserving-small.xlsx"
    LARGE_FILENAME = "timestamp-preserving-session.xlsx"
    CONFLICT_FILENAME = "genuine-remote-conflict.xlsx"

    GUARD_MARKER = (
        "Online eTag matches database eTag; treating as local modification despite older local timestamp"
    )
    CONFLICT_MARKER = "Skipping uploading this item as a locally modified file"

    def _config_text(self, sync_root: Path) -> str:
        return (
            "# bsftc0006 Business Shared Folder timestamp replacement validation\n"
            f'sync_dir = "{sync_root}"\n'
            'sync_business_shared_items = "true"\n'
            'threads = "2"\n'
        )

    def _prepare_config(self, context: E2EContext, config_dir: Path, sync_root: Path) -> None:
        context.prepare_minimal_config_dir(config_dir, self._config_text(sync_root))

    def _sync_command(
        self,
        context: E2EContext,
        config_dir: Path,
        *,
        resync: bool = False,
        download_only: bool = False,
        upload_only: bool = False,
        local_first: bool = False,
        debug: bool = False,
    ) -> list[str]:
        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
        ]
        if debug:
            command.append("--verbose")
        if download_only:
            command.append("--download-only")
        if upload_only:
            command.append("--upload-only")
        if local_first:
            command.append("--local-first")
        if resync:
            command.extend(["--resync", "--resync-auth"])
        command.extend(["--confdir", str(config_dir)])
        return command

    def _run_logged(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        log_dir: Path,
        artifacts: list[str],
    ):
        stdout_file = log_dir / f"{label}_stdout.log"
        stderr_file = log_dir / f"{label}_stderr.log"
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        artifacts.extend([str(stdout_file), str(stderr_file)])
        return result

    @staticmethod
    def _safe_backup_files_for(canonical_path: Path) -> list[Path]:
        return sorted(
            path
            for path in canonical_path.parent.glob(
                f"{canonical_path.stem}-*-safeBackup-????{canonical_path.suffix}"
            )
            if path.is_file()
        )

    @staticmethod
    def _rewrite_cloned_config(config_dir: Path, sync_root: Path) -> None:
        config_path = config_dir / "config"
        existing_lines = config_path.read_text(encoding="utf-8").splitlines()
        retained_lines: list[str] = []

        for raw_line in existing_lines:
            stripped = raw_line.strip()
            if stripped.startswith("sync_dir") and "=" in stripped:
                continue
            retained_lines.append(raw_line)

        retained_lines.append(f'sync_dir = "{sync_root}"')
        config_text = "\n".join(retained_lines) + "\n"

        config_path.write_text(config_text, encoding="utf-8")
        os.chmod(config_path, 0o600)

        backup_path = config_dir / ".config.backup"
        backup_path.write_text(config_text, encoding="utf-8")
        os.chmod(backup_path, 0o600)

        hash_path = config_dir / ".config.hash"
        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")
        os.chmod(hash_path, 0o600)

    def _clone_client_state(
        self,
        source_root: Path,
        source_config: Path,
        destination_root: Path,
        destination_config: Path,
    ) -> None:
        if destination_root.exists():
            shutil.rmtree(destination_root)
        if destination_config.exists():
            shutil.rmtree(destination_config)

        shutil.copytree(source_root, destination_root, copy_function=shutil.copy2)
        shutil.copytree(source_config, destination_config, copy_function=shutil.copy2)
        self._rewrite_cloned_config(destination_config, destination_root)

    @staticmethod
    def _database_rows_by_name(config_dir: Path, name: str) -> list[dict[str, object]]:
        database_path = config_dir / "items.sqlite3"
        if not database_path.is_file():
            raise CaseFailure(f"OneDrive database does not exist: {database_path}")

        connection = sqlite3.connect(f"file:{database_path}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        try:
            rows = connection.execute(
                """
                SELECT driveId, id, name, type, eTag, cTag, mtime, parentId,
                       remoteDriveId, remoteParentId, remoteId, remoteType, size
                FROM item
                WHERE name = ?
                ORDER BY driveId, id
                """,
                (name,),
            ).fetchall()
        finally:
            connection.close()

        return [dict(row) for row in rows]

    def _capture_unique_item_row(
        self,
        config_dir: Path,
        name: str,
        *,
        expected_type: str | None = None,
    ) -> dict[str, object]:
        rows = self._database_rows_by_name(config_dir, name)
        if expected_type is not None:
            rows = [row for row in rows if row.get("type") == expected_type]
        if len(rows) != 1:
            qualifier = f" with type={expected_type!r}" if expected_type is not None else ""
            raise CaseFailure(
                f"Expected exactly one database row named {name!r}{qualifier}; found {len(rows)}"
            )
        return rows[0]

    def _fresh_verify(
        self,
        context: E2EContext,
        layout,
        label: str,
        artifacts: list[str],
    ) -> tuple[Path, Path, object]:
        sync_root = layout.work_dir / f"{label}-syncroot"
        config_dir = layout.work_dir / f"{label}-conf"
        log_dir = layout.log_dir / label
        reset_directory(sync_root)
        reset_directory(config_dir)
        reset_directory(log_dir)
        self._prepare_config(context, config_dir, sync_root)

        result = self._run_logged(
            context,
            f"{label}_resync",
            self._sync_command(
                context,
                config_dir,
                resync=True,
                download_only=True,
            ),
            log_dir,
            artifacts,
        )
        return sync_root, config_dir, result

    def _clean_reserved_remote_subtree(
        self,
        context: E2EContext,
        layout,
        label: str,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        """
        Remove only this testcase's reserved subtree and independently prove it is gone.

        This helper deliberately starts from a fresh client state so cleanup does not depend
        on the primary testcase database being healthy. It never removes or alters anything
        outside FIXTURE_PARENT_RELATIVE / RESERVED_TEST_DIR.
        """
        cleanup_root = layout.work_dir / f"cleanup-{label}-syncroot"
        cleanup_conf = layout.work_dir / f"cleanup-{label}-conf"
        cleanup_log_dir = layout.log_dir / f"cleanup-{label}"
        verify_root = layout.work_dir / f"cleanup-{label}-verify-syncroot"
        verify_conf = layout.work_dir / f"cleanup-{label}-verify-conf"
        verify_log_dir = layout.log_dir / f"cleanup-{label}-verify"

        for path in (
            cleanup_root,
            cleanup_conf,
            cleanup_log_dir,
            verify_root,
            verify_conf,
            verify_log_dir,
        ):
            reset_directory(path)

        self._prepare_config(context, cleanup_conf, cleanup_root)
        cleanup_details: dict[str, object] = {
            "label": label,
            "reserved_relative_path": str(self.FIXTURE_PARENT_RELATIVE / self.RESERVED_TEST_DIR),
        }

        initial = self._run_logged(
            context,
            f"cleanup_{label}_discover",
            self._sync_command(context, cleanup_conf, resync=True),
            cleanup_log_dir,
            artifacts,
        )
        cleanup_details["discover_returncode"] = initial.returncode
        if initial.returncode != 0:
            return False, f"cleanup discovery sync failed with status {initial.returncode}", cleanup_details

        reserved_path = cleanup_root / self.FIXTURE_PARENT_RELATIVE / self.RESERVED_TEST_DIR
        cleanup_details["reserved_found_before_cleanup"] = reserved_path.exists()

        if reserved_path.exists():
            if not reserved_path.is_dir():
                return (
                    False,
                    f"reserved cleanup path exists but is not a directory: {reserved_path}",
                    cleanup_details,
                )

            shutil.rmtree(reserved_path)
            delete_result = self._run_logged(
                context,
                f"cleanup_{label}_delete",
                self._sync_command(context, cleanup_conf, debug=True),
                cleanup_log_dir,
                artifacts,
            )
            cleanup_details["delete_returncode"] = delete_result.returncode
            if delete_result.returncode != 0:
                return (
                    False,
                    f"cleanup delete sync failed with status {delete_result.returncode}",
                    cleanup_details,
                )

        self._prepare_config(context, verify_conf, verify_root)
        verify_result = self._run_logged(
            context,
            f"cleanup_{label}_verify",
            self._sync_command(
                context,
                verify_conf,
                resync=True,
                download_only=True,
            ),
            verify_log_dir,
            artifacts,
        )
        cleanup_details["verify_returncode"] = verify_result.returncode
        if verify_result.returncode != 0:
            return False, f"cleanup verification sync failed with status {verify_result.returncode}", cleanup_details

        verify_reserved = verify_root / self.FIXTURE_PARENT_RELATIVE / self.RESERVED_TEST_DIR
        cleanup_details["reserved_present_after_cleanup"] = verify_reserved.exists()
        if verify_reserved.exists():
            return (
                False,
                "reserved BSFTC0006 subtree still exists after cleanup verification",
                cleanup_details,
            )

        return True, "", cleanup_details

    def _create_replacement(
        self,
        canonical_path: Path,
        work_dir: Path,
        *,
        old_revision: str,
        new_revision: str,
        replacement_epoch: int,
    ) -> tuple[Path, str]:
        replacement_source = work_dir / f"{canonical_path.name}.{new_revision}.source"
        shutil.copy2(canonical_path, replacement_source)
        mutate_xlsx_revision(replacement_source, old_revision, new_revision)
        os.utime(replacement_source, (replacement_epoch, replacement_epoch))
        shutil.copy2(replacement_source, canonical_path)
        replacement_hash = compute_quickxor_hash_file(canonical_path)
        return replacement_source, replacement_hash

    def _exercise_timestamp_preserving_replacement(
        self,
        context: E2EContext,
        config_dir: Path,
        sync_root: Path,
        work_dir: Path,
        log_dir: Path,
        relative_file: Path,
        artifacts: list[str],
        details: dict[str, object],
        scenario_id: str,
    ) -> None:
        canonical = sync_root / relative_file
        if not canonical.is_file():
            raise CaseFailure(f"{scenario_id}: seeded XLSX is missing: {canonical}")

        validation_error = validate_xlsx(canonical, REVISION_0)
        if validation_error:
            raise CaseFailure(f"{scenario_id}: seeded XLSX failed validation: {validation_error}")

        baseline_hash = compute_quickxor_hash_file(canonical)
        baseline_mtime = int(canonical.stat().st_mtime)
        baseline_size = canonical.stat().st_size
        replacement_epoch = max(1, baseline_mtime - 3600)

        replacement_source, replacement_hash = self._create_replacement(
            canonical,
            work_dir,
            old_revision=REVISION_0,
            new_revision=REVISION_1,
            replacement_epoch=replacement_epoch,
        )
        artifacts.append(str(replacement_source))

        scenario_details = {
            "baseline_hash": baseline_hash,
            "baseline_mtime": baseline_mtime,
            "baseline_size": baseline_size,
            "replacement_hash": replacement_hash,
            "replacement_mtime": int(canonical.stat().st_mtime),
            "replacement_source": str(replacement_source),
            "db_row_before_upload": self._capture_unique_item_row(config_dir, canonical.name),
        }
        details[scenario_id] = scenario_details

        if replacement_hash == baseline_hash:
            raise CaseFailure(f"{scenario_id}: XLSX replacement did not change content")
        if int(canonical.stat().st_mtime) >= baseline_mtime:
            raise CaseFailure(f"{scenario_id}: failed to establish an older replacement mtime")

        result = self._run_logged(
            context,
            f"{scenario_id}_replacement",
            self._sync_command(context, config_dir, debug=True),
            log_dir,
            artifacts,
        )
        scenario_details["replacement_returncode"] = result.returncode
        output = result.stdout + "\n" + result.stderr
        relative_text = relative_file.as_posix()
        modified_marker = f"Uploading modified file: {relative_text} ... done"
        safe_backups = self._safe_backup_files_for(canonical)

        scenario_details["guard_marker_seen"] = self.GUARD_MARKER in output
        scenario_details["conflict_marker_seen"] = self.CONFLICT_MARKER in output
        scenario_details["modified_upload_seen"] = modified_marker in output
        scenario_details["safe_backup_files"] = [
            str(path.relative_to(sync_root)) for path in safe_backups
        ]
        scenario_details["db_row_after_upload"] = self._capture_unique_item_row(config_dir, canonical.name)

        if result.returncode != 0:
            raise CaseFailure(f"{scenario_id}: replacement sync failed with status {result.returncode}")
        if modified_marker not in output:
            raise CaseFailure(f"{scenario_id}: successful modified-file upload was not observed")
        if self.CONFLICT_MARKER in output:
            raise CaseFailure(f"{scenario_id}: incorrectly entered the newer-online conflict path")
        if safe_backups:
            raise CaseFailure(f"{scenario_id}: incorrectly created a safeBackup")
        if self.GUARD_MARKER not in output:
            raise CaseFailure(
                f"{scenario_id}: unchanged-eTag older-mtime guard was not exercised"
            )

        post_validation_error = validate_xlsx(canonical, REVISION_1)
        if post_validation_error:
            raise CaseFailure(
                f"{scenario_id}: canonical XLSX did not retain revision 1 after upload/reconciliation: "
                f"{post_validation_error}"
            )

        noop_result = self._run_logged(
            context,
            f"{scenario_id}_noop",
            self._sync_command(context, config_dir, debug=True),
            log_dir,
            artifacts,
        )
        scenario_details["noop_returncode"] = noop_result.returncode
        noop_output = noop_result.stdout + "\n" + noop_result.stderr
        scenario_details["noop_reupload_seen"] = modified_marker in noop_output

        if noop_result.returncode != 0:
            raise CaseFailure(f"{scenario_id}: no-op stability sync failed with status {noop_result.returncode}")
        if modified_marker in noop_output:
            raise CaseFailure(f"{scenario_id}: no-op sync attempted to upload the XLSX again")

    def _exercise_genuine_remote_conflict(
        self,
        context: E2EContext,
        layout,
        config_dir: Path,
        sync_root: Path,
        relative_file: Path,
        artifacts: list[str],
        details: dict[str, object],
    ) -> None:
        scenario_id = "SF-0003"
        canonical = sync_root / relative_file
        if not canonical.is_file():
            raise CaseFailure(f"{scenario_id}: seeded conflict XLSX is missing")

        baseline_validation_error = validate_xlsx(canonical, REVISION_0)
        if baseline_validation_error:
            raise CaseFailure(
                f"{scenario_id}: seeded conflict XLSX failed validation: {baseline_validation_error}"
            )

        baseline_mtime = int(canonical.stat().st_mtime)
        baseline_hash = compute_quickxor_hash_file(canonical)

        mutator_root = layout.work_dir / "sf0003-mutator-syncroot"
        mutator_conf = layout.work_dir / "sf0003-mutator-conf"
        mutator_log_dir = layout.log_dir / "SF-0003-mutator"
        reset_directory(mutator_log_dir)
        self._clone_client_state(sync_root, config_dir, mutator_root, mutator_conf)

        mutator_file = mutator_root / relative_file
        mutate_xlsx_revision(mutator_file, REVISION_0, REVISION_1)
        newer_epoch = max(int(time.time()), baseline_mtime) + 120
        os.utime(mutator_file, (newer_epoch, newer_epoch))

        mutator_result = self._run_logged(
            context,
            "SF-0003_mutator_upload",
            self._sync_command(
                context,
                mutator_conf,
                upload_only=True,
                debug=True,
            ),
            mutator_log_dir,
            artifacts,
        )
        if mutator_result.returncode != 0:
            raise CaseFailure(
                f"{scenario_id}: independent mutator upload failed with status {mutator_result.returncode}"
            )

        verify_root, verify_conf, verify_result = self._fresh_verify(
            context,
            layout,
            "sf0003-remote-change-verify",
            artifacts,
        )
        if verify_result.returncode != 0:
            raise CaseFailure(
                f"{scenario_id}: independent remote-change verification failed with status "
                f"{verify_result.returncode}"
            )

        verified_remote_file = verify_root / relative_file
        remote_validation_error = validate_xlsx(verified_remote_file, REVISION_1)
        if remote_validation_error:
            raise CaseFailure(
                f"{scenario_id}: remote mutation was not independently observed: {remote_validation_error}"
            )

        stale_db_row = self._capture_unique_item_row(config_dir, canonical.name)
        mutator_db_row = self._capture_unique_item_row(mutator_conf, canonical.name)
        verifier_db_row = self._capture_unique_item_row(verify_conf, canonical.name)

        replacement_source = layout.work_dir / "SF-0003-local-replacement-source.xlsx"
        shutil.copy2(canonical, replacement_source)
        mutate_xlsx_revision(replacement_source, REVISION_0, REVISION_2)
        older_epoch = max(1, baseline_mtime - 3600)
        os.utime(replacement_source, (older_epoch, older_epoch))
        shutil.copy2(replacement_source, canonical)
        artifacts.append(str(replacement_source))

        replacement_hash = compute_quickxor_hash_file(canonical)
        if replacement_hash == baseline_hash:
            raise CaseFailure(f"{scenario_id}: stale local replacement did not change content")
        if int(canonical.stat().st_mtime) >= baseline_mtime:
            raise CaseFailure(f"{scenario_id}: failed to establish an older stale local replacement")

        conflict_log_dir = layout.log_dir / "SF-0003-conflict"
        reset_directory(conflict_log_dir)
        conflict_result = self._run_logged(
            context,
            "SF-0003_local_first_conflict",
            self._sync_command(
                context,
                config_dir,
                local_first=True,
                debug=True,
            ),
            conflict_log_dir,
            artifacts,
        )
        conflict_output = conflict_result.stdout + "\n" + conflict_result.stderr
        safe_backups = self._safe_backup_files_for(canonical)

        scenario_details = {
            "baseline_hash": baseline_hash,
            "baseline_mtime": baseline_mtime,
            "stale_db_row_before_conflict": stale_db_row,
            "mutator_db_row_after_remote_change": mutator_db_row,
            "verifier_db_row_after_remote_change": verifier_db_row,
            "conflict_returncode": conflict_result.returncode,
            "guard_marker_seen": self.GUARD_MARKER in conflict_output,
            "conflict_marker_seen": self.CONFLICT_MARKER in conflict_output,
            "safe_backup_files": [str(path.relative_to(sync_root)) for path in safe_backups],
        }
        details[scenario_id] = scenario_details

        if conflict_result.returncode != 0:
            raise CaseFailure(
                f"{scenario_id}: local-first conflict sync failed with status {conflict_result.returncode}"
            )
        if self.GUARD_MARKER in conflict_output:
            raise CaseFailure(
                f"{scenario_id}: unchanged-eTag guard fired despite a genuine independent online change"
            )
        if self.CONFLICT_MARKER not in conflict_output:
            raise CaseFailure(
                f"{scenario_id}: guarded modified-upload branch did not enter the expected newer-online conflict path"
            )
        if len(safe_backups) != 1:
            raise CaseFailure(
                f"{scenario_id}: expected exactly one local safeBackup; found {len(safe_backups)}"
            )

        canonical_validation_error = validate_xlsx(canonical, REVISION_1)
        if canonical_validation_error:
            raise CaseFailure(
                f"{scenario_id}: canonical file did not retain the genuine remote revision: "
                f"{canonical_validation_error}"
            )

        backup_validation_error = validate_xlsx(safe_backups[0], REVISION_2)
        if backup_validation_error:
            raise CaseFailure(
                f"{scenario_id}: safeBackup did not preserve the stale local replacement: "
                f"{backup_validation_error}"
            )

        final_verify_root, _, final_verify_result = self._fresh_verify(
            context,
            layout,
            "sf0003-final-verify",
            artifacts,
        )
        if final_verify_result.returncode != 0:
            raise CaseFailure(
                f"{scenario_id}: final independent verification failed with status "
                f"{final_verify_result.returncode}"
            )

        remote_canonical = final_verify_root / relative_file
        remote_canonical_error = validate_xlsx(remote_canonical, REVISION_1)
        if remote_canonical_error:
            raise CaseFailure(
                f"{scenario_id}: remote canonical revision was not preserved: {remote_canonical_error}"
            )

        remote_backup = final_verify_root / safe_backups[0].relative_to(sync_root)
        remote_backup_error = validate_xlsx(remote_backup, REVISION_2)
        if remote_backup_error:
            raise CaseFailure(
                f"{scenario_id}: preserved safeBackup was not independently observable online: "
                f"{remote_backup_error}"
            )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name=self.case_id,
            ensure_refresh_token=True,
        )

        artifacts: list[str] = []
        details: dict[str, object] = {
            "fixture_parent_relative": str(self.FIXTURE_PARENT_RELATIVE),
            "reserved_test_dir": self.RESERVED_TEST_DIR,
            "fixture_constraint": (
                "No pre-existing fixture object may be modified, renamed, replaced, or deleted. "
                "Only the reserved BSFTC0006 child subtree may be created and removed."
            ),
        }
        metadata_file = layout.state_dir / "metadata.json"
        artifacts.append(str(metadata_file))

        primary_failure = ""
        final_cleanup_failure = ""

        try:
            preclean_ok, preclean_reason, preclean_details = self._clean_reserved_remote_subtree(
                context,
                layout,
                "preflight",
                artifacts,
            )
            details["preflight_cleanup"] = preclean_details
            if not preclean_ok:
                raise CaseFailure(f"Unable to establish pristine pre-test state: {preclean_reason}")

            sync_root = case_sync_root(self.case_id)
            config_dir = layout.work_dir / "conf-main"
            main_log_dir = layout.log_dir / "main"
            reset_directory(sync_root)
            reset_directory(config_dir)
            reset_directory(main_log_dir)
            self._prepare_config(context, config_dir, sync_root)

            baseline_result = self._run_logged(
                context,
                "baseline_resync",
                self._sync_command(context, config_dir, resync=True),
                main_log_dir,
                artifacts,
            )
            details["baseline_returncode"] = baseline_result.returncode
            if baseline_result.returncode != 0:
                raise CaseFailure(
                    f"baseline Business Shared Folder sync failed with status {baseline_result.returncode}"
                )

            fixture_parent = sync_root / self.FIXTURE_PARENT_RELATIVE
            if not fixture_parent.is_dir():
                raise CaseFailure(
                    f"Required preserved SharePoint-backed upload target is missing: {fixture_parent}"
                )

            # Prove that the selected immutable fixture is anchored by a remote shared folder.
            anchor_row = self._capture_unique_item_row(config_dir, "BSF_CORE", expected_type="remote")
            details["sharepoint_backed_anchor_row"] = anchor_row
            if not anchor_row.get("remoteDriveId") or not anchor_row.get("remoteId"):
                raise CaseFailure(
                    "BSF_CORE database row is not a usable remote Business Shared Folder anchor"
                )

            test_root = fixture_parent / self.RESERVED_TEST_DIR
            if test_root.exists():
                raise CaseFailure(
                    "Reserved BSFTC0006 path unexpectedly exists after preflight cleanup"
                )
            test_root.mkdir()

            small_relative = self.FIXTURE_PARENT_RELATIVE / self.RESERVED_TEST_DIR / self.SMALL_FILENAME
            large_relative = self.FIXTURE_PARENT_RELATIVE / self.RESERVED_TEST_DIR / self.LARGE_FILENAME
            conflict_relative = self.FIXTURE_PARENT_RELATIVE / self.RESERVED_TEST_DIR / self.CONFLICT_FILENAME

            small_path = sync_root / small_relative
            large_path = sync_root / large_relative
            conflict_path = sync_root / conflict_relative

            small_generated = create_random_xlsx(
                small_path,
                f"{context.run_id}:{self.case_id}:small",
                payload_rows=self.SMALL_XLSX_PAYLOAD_ROWS,
                title="BSFTC0006 small timestamp-preserving replacement",
            )
            large_generated = create_random_xlsx(
                large_path,
                f"{context.run_id}:{self.case_id}:large",
                payload_rows=self.LARGE_XLSX_PAYLOAD_ROWS,
                title="BSFTC0006 session timestamp-preserving replacement",
            )
            conflict_generated = create_random_xlsx(
                conflict_path,
                f"{context.run_id}:{self.case_id}:conflict",
                payload_rows=self.SMALL_XLSX_PAYLOAD_ROWS,
                title="BSFTC0006 genuine remote conflict",
            )

            details["generated_sizes"] = {
                "small": int(small_generated["size_bytes"]),
                "large": int(large_generated["size_bytes"]),
                "conflict": int(conflict_generated["size_bytes"]),
            }
            if int(small_generated["size_bytes"]) > self.SESSION_THRESHOLD_BYTES:
                raise CaseFailure("small XLSX unexpectedly exceeded the 4 MiB session threshold")
            if int(large_generated["size_bytes"]) <= self.SESSION_THRESHOLD_BYTES:
                raise CaseFailure("large XLSX did not exceed the 4 MiB session threshold")

            seed_result = self._run_logged(
                context,
                "seed_test_owned_subtree",
                self._sync_command(context, config_dir, debug=True),
                main_log_dir,
                artifacts,
            )
            details["seed_returncode"] = seed_result.returncode
            if seed_result.returncode != 0:
                raise CaseFailure(
                    f"test-owned XLSX seed upload failed with status {seed_result.returncode}"
                )

            for seeded_path in (small_path, large_path, conflict_path):
                error = validate_xlsx(seeded_path, REVISION_0)
                if error:
                    raise CaseFailure(
                        f"seeded XLSX was invalid after SharePoint reconciliation ({seeded_path.name}): {error}"
                    )

            details["seed_db_rows"] = {
                self.SMALL_FILENAME: self._capture_unique_item_row(config_dir, self.SMALL_FILENAME),
                self.LARGE_FILENAME: self._capture_unique_item_row(config_dir, self.LARGE_FILENAME),
                self.CONFLICT_FILENAME: self._capture_unique_item_row(config_dir, self.CONFLICT_FILENAME),
            }

            replacement_work_dir = layout.work_dir / "replacement-sources"
            reset_directory(replacement_work_dir)

            self._exercise_timestamp_preserving_replacement(
                context,
                config_dir,
                sync_root,
                replacement_work_dir,
                main_log_dir,
                small_relative,
                artifacts,
                details,
                "SF-0001",
            )
            self._exercise_timestamp_preserving_replacement(
                context,
                config_dir,
                sync_root,
                replacement_work_dir,
                main_log_dir,
                large_relative,
                artifacts,
                details,
                "SF-0002",
            )

            verify_root, _, verify_result = self._fresh_verify(
                context,
                layout,
                "post-replacement-verify",
                artifacts,
            )
            if verify_result.returncode != 0:
                raise CaseFailure(
                    f"post-replacement independent verification failed with status {verify_result.returncode}"
                )
            for relative_file in (small_relative, large_relative):
                error = validate_xlsx(verify_root / relative_file, REVISION_1)
                if error:
                    raise CaseFailure(
                        f"remote replacement revision was not independently observed for "
                        f"{relative_file.name}: {error}"
                    )

            self._exercise_genuine_remote_conflict(
                context,
                layout,
                config_dir,
                sync_root,
                conflict_relative,
                artifacts,
                details,
            )

        except CaseFailure as exc:
            primary_failure = str(exc)
        except Exception as exc:
            primary_failure = f"Unhandled {type(exc).__name__}: {exc}"
        finally:
            try:
                cleanup_ok, cleanup_reason, cleanup_details = self._clean_reserved_remote_subtree(
                    context,
                    layout,
                    "final",
                    artifacts,
                )
                details["final_cleanup"] = cleanup_details
                if not cleanup_ok:
                    final_cleanup_failure = cleanup_reason
            except Exception as exc:
                final_cleanup_failure = (
                    f"Unhandled cleanup {type(exc).__name__}: {exc}"
                )

            write_text_file(
                metadata_file,
                json.dumps(details, indent=2, sort_keys=True, default=str) + "\n",
            )

        failures = [failure for failure in (primary_failure, final_cleanup_failure) if failure]
        if failures:
            return self.fail_result(
                self.case_id,
                self.name,
                "; ".join(failures),
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
