from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.docx import (
    append_docx_test_marker,
    docx_contains_marker,
    docx_member_sha256,
    remove_docx_test_marker,
    validate_docx,
)
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_text_file,
)


class CaseFailure(RuntimeError):
    pass


class BusinessSharedFolderTestCase0007DirectSharedOfficeTimestampReplacement(E2ETestCase):
    case_id = "bsftc0007"
    name = "directly shared Office file timestamp-preserving replacement"
    description = (
        "Validate timestamp-preserving replacement of an existing directly shared DOCX represented "
        "as remoteType=file, while transactionally restoring the original shared document afterwards"
    )

    # This is an existing BSFTC0004 fixture. It may be modified only by this testcase and only
    # after an exact local snapshot has been captured. The testcase never deletes, renames or
    # recreates the shared DriveItem. It restores the original logical DOCX content in finally.
    TARGET_RELATIVE = Path(
        "Files Shared With Me/testuser2 testuser2 (testuser2@mynasau3.onmicrosoft.com)/"
        "dummy_file_to_share.docx"
    )
    TARGET_NAME = "dummy_file_to_share.docx"

    MUTATION_MARKER = "ONEDRIVE-E2E-BSFTC0007-DIRECT-SHARED-DOCX-MUTATION"
    GUARD_MARKER = (
        "Online eTag matches database eTag; treating as local modification despite older local timestamp"
    )
    CONFLICT_MARKER = "Skipping uploading this item as a locally modified file"

    def _config_text(self, sync_root: Path) -> str:
        return (
            "# bsftc0007 directly shared Office file timestamp replacement validation\n"
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
        if local_first:
            command.append("--local-first")
        if resync:
            command.extend(["--resync", "--resync-auth"])
        # Directly shared files are enumerated through the Business Shared Files path.
        command.append("--sync-shared-files")
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
    def _sha256_file(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        return digest.hexdigest()

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

    def _capture_direct_shared_file_row(self, config_dir: Path) -> dict[str, object]:
        rows = self._database_rows_by_name(config_dir, self.TARGET_NAME)
        rows = [
            row
            for row in rows
            if row.get("type") == "remote" and row.get("remoteType") == "file"
        ]
        if len(rows) != 1:
            raise CaseFailure(
                f"Expected exactly one remoteType=file database row named {self.TARGET_NAME!r}; "
                f"found {len(rows)}"
            )
        row = rows[0]
        if not row.get("driveId") or not row.get("id"):
            raise CaseFailure("Directly shared file wrapper identity is incomplete")
        if not row.get("remoteDriveId") or not row.get("remoteId"):
            raise CaseFailure("Directly shared file remote target identity is incomplete")
        return row

    @staticmethod
    def _safe_backup_files_for(canonical_path: Path) -> list[Path]:
        return sorted(
            path
            for path in canonical_path.parent.glob(
                f"{canonical_path.stem}-*-safeBackup-????{canonical_path.suffix}"
            )
            if path.is_file()
        )

    def _marker_safe_backups(self, canonical_path: Path) -> list[Path]:
        return [
            path
            for path in self._safe_backup_files_for(canonical_path)
            if docx_contains_marker(path, self.MUTATION_MARKER)
        ]

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

    def _heal_stranded_prior_run(
        self,
        context: E2EContext,
        config_dir: Path,
        sync_root: Path,
        log_dir: Path,
        artifacts: list[str],
        details: dict[str, object],
    ) -> None:
        """
        Recover the only states this testcase can intentionally strand if a CI runner is killed:
        the marker paragraph on the canonical DOCX and/or a marker-bearing safeBackup.

        The mutation is deliberately self-reversible: removing the unique marker paragraph restores
        the original document.xml without requiring a previous-run local snapshot.
        """
        canonical = sync_root / self.TARGET_RELATIVE
        if not canonical.is_file():
            raise CaseFailure(f"Directly shared DOCX is missing during recovery preflight: {canonical}")

        marker_on_canonical = docx_contains_marker(canonical, self.MUTATION_MARKER)
        marker_backups = self._marker_safe_backups(canonical)
        details["recovery_preflight"] = {
            "marker_on_canonical": marker_on_canonical,
            "marker_safe_backups": [str(path.relative_to(sync_root)) for path in marker_backups],
        }

        if not marker_on_canonical and not marker_backups:
            return

        if marker_on_canonical:
            removed = remove_docx_test_marker(canonical, self.MUTATION_MARKER)
            if not removed:
                raise CaseFailure("Expected stranded DOCX marker could not be removed")
            recovery_epoch = max(int(time.time()), int(canonical.stat().st_mtime)) + 120
            os.utime(canonical, (recovery_epoch, recovery_epoch))

        for backup in marker_backups:
            backup.unlink()

        result = self._run_logged(
            context,
            "recovery_preflight_sync",
            self._sync_command(context, config_dir, debug=True),
            log_dir,
            artifacts,
        )
        details["recovery_preflight"]["sync_returncode"] = result.returncode
        if result.returncode != 0:
            raise CaseFailure(
                f"Unable to self-heal stranded BSFTC0007 state; sync returned {result.returncode}"
            )

    def _restore_original(
        self,
        context: E2EContext,
        layout,
        config_dir: Path | None,
        sync_root: Path | None,
        original_snapshot: Path | None,
        baseline_row: dict[str, object] | None,
        baseline_document_hash: str | None,
        artifacts: list[str],
        details: dict[str, object],
    ) -> tuple[bool, str]:
        if config_dir is None or sync_root is None or original_snapshot is None:
            return True, ""
        if not original_snapshot.is_file():
            return False, "Original DOCX rollback snapshot is unavailable"

        cleanup_log_dir = layout.log_dir / "rollback"
        reset_directory(cleanup_log_dir)
        canonical = sync_root / self.TARGET_RELATIVE
        if not canonical.parent.is_dir():
            return False, f"Rollback parent directory is missing: {canonical.parent}"

        rollback_details: dict[str, object] = {
            "snapshot_sha256": self._sha256_file(original_snapshot),
            "snapshot_document_xml_sha256": docx_member_sha256(original_snapshot),
        }
        details["rollback"] = rollback_details

        # Restore the exact Microsoft-settled package captured before the test. Use a deliberately
        # newer local timestamp for this content-restoration upload so rollback never depends on the
        # very older-mtime decision under test.
        shutil.copy2(original_snapshot, canonical)
        rollback_epoch = max(int(time.time()), int(canonical.stat().st_mtime)) + 180
        os.utime(canonical, (rollback_epoch, rollback_epoch))
        rollback_details["restore_upload_epoch"] = rollback_epoch

        marker_backups = self._marker_safe_backups(canonical)
        rollback_details["marker_safe_backups_before_delete"] = [
            str(path.relative_to(sync_root)) for path in marker_backups
        ]
        for backup in marker_backups:
            backup.unlink()

        restore_result = self._run_logged(
            context,
            "rollback_restore_original",
            self._sync_command(context, config_dir, debug=True),
            cleanup_log_dir,
            artifacts,
        )
        rollback_details["restore_returncode"] = restore_result.returncode
        if restore_result.returncode != 0:
            return False, f"Rollback content restore sync failed with status {restore_result.returncode}"

        verify_root, verify_conf, verify_result = self._fresh_verify(
            context,
            layout,
            "rollback-verify",
            artifacts,
        )
        rollback_details["verify_returncode"] = verify_result.returncode
        if verify_result.returncode != 0:
            return False, f"Rollback verification sync failed with status {verify_result.returncode}"

        verify_file = verify_root / self.TARGET_RELATIVE
        rollback_details["verify_file_exists"] = verify_file.is_file()
        if not verify_file.is_file():
            return False, "Original directly shared DOCX is missing after rollback"

        validation_error = validate_docx(
            verify_file,
            forbidden_marker=self.MUTATION_MARKER,
        )
        rollback_details["validation_error"] = validation_error
        if validation_error:
            return False, f"Restored directly shared DOCX is invalid: {validation_error}"

        final_document_hash = docx_member_sha256(verify_file)
        rollback_details["final_document_xml_sha256"] = final_document_hash
        rollback_details["final_file_sha256"] = self._sha256_file(verify_file)
        rollback_details["final_quickxor"] = compute_quickxor_hash_file(verify_file)
        rollback_details["final_size"] = verify_file.stat().st_size
        rollback_details["final_mtime"] = int(verify_file.stat().st_mtime)

        if baseline_document_hash is not None and final_document_hash != baseline_document_hash:
            return (
                False,
                "Rollback verification found different word/document.xml content from the original fixture",
            )

        final_row = self._capture_direct_shared_file_row(verify_conf)
        rollback_details["db_row_after_restore"] = final_row
        if baseline_row is not None:
            for key in ("driveId", "id", "remoteDriveId", "remoteId"):
                if final_row.get(key) != baseline_row.get(key):
                    return False, f"Rollback changed directly shared DriveItem identity field {key}"

        remaining_marker_backups = self._marker_safe_backups(verify_file)
        rollback_details["remaining_marker_safe_backups"] = [
            str(path.relative_to(verify_root)) for path in remaining_marker_backups
        ]
        if remaining_marker_backups:
            return False, "Marker-bearing safeBackup still exists after rollback verification"

        return True, ""

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name=self.case_id,
            ensure_refresh_token=True,
        )

        artifacts: list[str] = []
        details: dict[str, object] = {
            "target_relative": self.TARGET_RELATIVE.as_posix(),
            "fixture_policy": (
                "Use one existing directly shared DOCX in-place; never delete/rename/recreate the shared item; "
                "restore the original logical document content and identity in finally. Microsoft eTag/version "
                "history is expected to advance when the test and rollback uploads occur."
            ),
        }
        metadata_file = layout.state_dir / "metadata.json"
        artifacts.append(str(metadata_file))

        primary_failure = ""
        rollback_failure = ""
        config_dir: Path | None = None
        sync_root: Path | None = None
        original_snapshot: Path | None = None
        baseline_row: dict[str, object] | None = None
        baseline_document_hash: str | None = None

        try:
            sync_root = layout.work_dir / "syncroot"
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
                    f"Directly shared file baseline sync failed with status {baseline_result.returncode}"
                )

            canonical = sync_root / self.TARGET_RELATIVE
            if not canonical.is_file():
                raise CaseFailure(f"Required directly shared DOCX is missing: {canonical}")

            baseline_row = self._capture_direct_shared_file_row(config_dir)
            details["db_row_before_recovery"] = baseline_row

            # If a previous runner was terminated after uploading the deterministic mutation, repair
            # that state before taking the authoritative baseline snapshot for this run.
            self._heal_stranded_prior_run(
                context,
                config_dir,
                sync_root,
                main_log_dir,
                artifacts,
                details,
            )

            if details.get("recovery_preflight", {}).get("marker_on_canonical") or details.get(
                "recovery_preflight", {}
            ).get("marker_safe_backups"):
                # Rebuild clean local/database state after a self-heal before starting the test.
                reset_directory(sync_root)
                reset_directory(config_dir)
                self._prepare_config(context, config_dir, sync_root)
                healed_result = self._run_logged(
                    context,
                    "post_recovery_baseline_resync",
                    self._sync_command(context, config_dir, resync=True),
                    main_log_dir,
                    artifacts,
                )
                details["post_recovery_baseline_returncode"] = healed_result.returncode
                if healed_result.returncode != 0:
                    raise CaseFailure(
                        f"Post-recovery baseline sync failed with status {healed_result.returncode}"
                    )
                canonical = sync_root / self.TARGET_RELATIVE
                baseline_row = self._capture_direct_shared_file_row(config_dir)

            baseline_validation_error = validate_docx(
                canonical,
                forbidden_marker=self.MUTATION_MARKER,
            )
            if baseline_validation_error:
                raise CaseFailure(
                    f"Directly shared DOCX baseline is invalid: {baseline_validation_error}"
                )

            original_snapshot = layout.work_dir / "original-settled-direct-share.docx"
            shutil.copy2(canonical, original_snapshot)
            baseline_document_hash = docx_member_sha256(original_snapshot)
            baseline_quickxor = compute_quickxor_hash_file(original_snapshot)
            baseline_mtime = int(original_snapshot.stat().st_mtime)
            baseline_size = original_snapshot.stat().st_size
            baseline_safe_backups = self._safe_backup_files_for(canonical)
            baseline_safe_backup_relatives = {
                str(path.relative_to(sync_root)) for path in baseline_safe_backups
            }
            details["baseline"] = {
                "db_row": baseline_row,
                "file_sha256": self._sha256_file(original_snapshot),
                "quickxor": baseline_quickxor,
                "document_xml_sha256": baseline_document_hash,
                "size": baseline_size,
                "mtime": baseline_mtime,
                "preexisting_safe_backup_files": sorted(baseline_safe_backup_relatives),
            }

            replacement_source = layout.work_dir / "timestamp-preserving-replacement.docx"
            shutil.copy2(original_snapshot, replacement_source)
            append_docx_test_marker(replacement_source, self.MUTATION_MARKER)
            replacement_epoch = max(1, baseline_mtime - (30 * 24 * 60 * 60))
            os.utime(replacement_source, (replacement_epoch, replacement_epoch))
            shutil.copy2(replacement_source, canonical)

            replacement_validation_error = validate_docx(
                canonical,
                required_marker=self.MUTATION_MARKER,
            )
            if replacement_validation_error:
                raise CaseFailure(
                    f"Timestamp-preserving replacement DOCX is invalid: {replacement_validation_error}"
                )
            if int(canonical.stat().st_mtime) >= baseline_mtime:
                raise CaseFailure("Failed to establish an older timestamp-preserving replacement")

            details["replacement"] = {
                "file_sha256": self._sha256_file(canonical),
                "quickxor": compute_quickxor_hash_file(canonical),
                "document_xml_sha256": docx_member_sha256(canonical),
                "size": canonical.stat().st_size,
                "mtime": int(canonical.stat().st_mtime),
                "replacement_epoch": replacement_epoch,
            }
            if details["replacement"]["document_xml_sha256"] == baseline_document_hash:
                raise CaseFailure("DOCX marker mutation did not change word/document.xml")

            replacement_result = self._run_logged(
                context,
                "DSF-0001_timestamp_preserving_replacement",
                self._sync_command(context, config_dir, debug=True),
                main_log_dir,
                artifacts,
            )
            output = replacement_result.stdout + "\n" + replacement_result.stderr
            safe_backups = self._safe_backup_files_for(canonical)
            safe_backup_relatives = {str(path.relative_to(sync_root)) for path in safe_backups}
            new_safe_backup_relatives = sorted(
                safe_backup_relatives - baseline_safe_backup_relatives
            )
            marker_safe_backups = self._marker_safe_backups(canonical)
            modified_marker = f"Uploading modified file: {self.TARGET_RELATIVE.as_posix()} ... done"

            scenario_details = {
                "returncode": replacement_result.returncode,
                "guard_marker_seen": self.GUARD_MARKER in output,
                "conflict_marker_seen": self.CONFLICT_MARKER in output,
                "modified_upload_seen": modified_marker in output,
                "safe_backup_files": sorted(safe_backup_relatives),
                "new_safe_backup_files": new_safe_backup_relatives,
                "marker_safe_backup_files": [
                    str(path.relative_to(sync_root)) for path in marker_safe_backups
                ],
                "db_row_after_reconciliation": self._capture_direct_shared_file_row(config_dir),
            }
            details["DSF-0001"] = scenario_details

            remote_verify_root, remote_verify_conf, remote_verify_result = self._fresh_verify(
                context,
                layout,
                "replacement-verify",
                artifacts,
            )
            scenario_details["remote_verify_returncode"] = remote_verify_result.returncode
            remote_candidate = remote_verify_root / self.TARGET_RELATIVE
            scenario_details["remote_candidate_exists"] = remote_candidate.is_file()
            if remote_candidate.is_file():
                scenario_details["remote_marker_present"] = docx_contains_marker(
                    remote_candidate,
                    self.MUTATION_MARKER,
                )
                scenario_details["remote_db_row"] = self._capture_direct_shared_file_row(
                    remote_verify_conf
                )

            # Desired regression behavior: a directly shared remoteType=file target should be able to
            # trust an unchanged remote-target baseline exactly as a normal DriveItem does. The current
            # PR is expected to expose whether this remains the outstanding #3868 topology gap.
            if replacement_result.returncode != 0:
                raise CaseFailure(
                    f"DSF-0001 replacement sync failed with status {replacement_result.returncode}"
                )
            if remote_verify_result.returncode != 0:
                raise CaseFailure(
                    f"DSF-0001 independent remote verification failed with status {remote_verify_result.returncode}"
                )
            if not scenario_details["guard_marker_seen"]:
                raise CaseFailure(
                    "DSF-0001 did not exercise the unchanged-eTag older-mtime guard for remoteType=file"
                )
            if scenario_details["conflict_marker_seen"]:
                raise CaseFailure(
                    "DSF-0001 incorrectly entered the newer-online safeBackup conflict path"
                )
            if not scenario_details["modified_upload_seen"]:
                raise CaseFailure("DSF-0001 did not report a successful modified-file upload")
            if new_safe_backup_relatives:
                raise CaseFailure(
                    "DSF-0001 incorrectly created a new safeBackup: "
                    + ", ".join(new_safe_backup_relatives)
                )
            if not remote_candidate.is_file() or not scenario_details.get("remote_marker_present", False):
                raise CaseFailure(
                    "DSF-0001 replacement marker was not independently observable on the canonical shared DOCX"
                )

            after_row = scenario_details["remote_db_row"]
            for key in ("driveId", "id", "remoteDriveId", "remoteId"):
                if after_row.get(key) != baseline_row.get(key):
                    raise CaseFailure(
                        f"DSF-0001 changed directly shared DriveItem identity field {key}"
                    )

        except CaseFailure as exc:
            primary_failure = str(exc)
        except Exception as exc:
            primary_failure = f"Unhandled {type(exc).__name__}: {exc}"
        finally:
            try:
                rollback_ok, rollback_reason = self._restore_original(
                    context,
                    layout,
                    config_dir,
                    sync_root,
                    original_snapshot,
                    baseline_row,
                    baseline_document_hash,
                    artifacts,
                    details,
                )
                if not rollback_ok:
                    rollback_failure = rollback_reason
            except Exception as exc:
                rollback_failure = f"Unhandled rollback {type(exc).__name__}: {exc}"

            write_text_file(
                metadata_file,
                json.dumps(details, indent=2, sort_keys=True, default=str) + "\n",
            )

        failures = [failure for failure in (primary_failure, rollback_failure) if failure]
        if failures:
            return self.fail_result(
                self.case_id,
                self.name,
                "; ".join(failures),
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
