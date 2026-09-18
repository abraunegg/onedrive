from __future__ import annotations

import hashlib
import os
import re
import shutil
import sqlite3
from contextlib import closing
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0081HistoricalDatabaseUpgradeValidation(E2ETestCase):
    case_id = "0081"
    name = "historical database upgrade and schema integrity validation"
    description = (
        "Validate a genuine v2.5.5 item database through current-client upgrade, "
        "restore-and-upgrade, physical-schema mismatch rejection, and --resync recovery"
    )

    LEGACY_TAG = "v2.5.5"
    LEGACY_REPOSITORY_URL = "https://github.com/abraunegg/onedrive.git"
    LEGACY_DATABASE_VERSION = 16
    LEGACY_ITEM_COLUMN_COUNT = 18
    EXIT_RESYNC_REQUIRED = 78

    def _run_logged(
        self,
        *,
        context: E2EContext,
        command: list[str],
        label: str,
        stdout_file: Path,
        stderr_file: Path,
        cwd: Path | None = None,
    ):
        context.log(
            f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}"
        )
        result = run_command(command, cwd=cwd or context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def _legacy_cache_root(self, context: E2EContext) -> Path:
        runner_temp = Path(os.environ.get("RUNNER_TEMP", "/tmp"))
        return runner_temp / "onedrive-e2e-legacy-build" / self.LEGACY_TAG

    def _ensure_legacy_binary(
        self,
        *,
        context: E2EContext,
        case_log_dir: Path,
        details: dict[str, object],
        artifacts: list[str],
    ) -> tuple[Path | None, str]:
        cache_root = self._legacy_cache_root(context)
        source_dir = cache_root / "source"
        prefix_dir = cache_root / "prefix"
        legacy_bin = prefix_dir / "bin" / "onedrive"

        details["legacy_tag"] = self.LEGACY_TAG
        details["legacy_repository_url"] = self.LEGACY_REPOSITORY_URL
        details["legacy_cache_root"] = str(cache_root)
        details["legacy_binary"] = str(legacy_bin)

        version_stdout = case_log_dir / "legacy_cached_version_stdout.log"
        version_stderr = case_log_dir / "legacy_cached_version_stderr.log"
        artifacts.extend([str(version_stdout), str(version_stderr)])

        if legacy_bin.is_file():
            version_result = self._run_logged(
                context=context,
                command=[str(legacy_bin), "--version"],
                label="legacy cached binary version check",
                stdout_file=version_stdout,
                stderr_file=version_stderr,
            )
            combined = f"{version_result.stdout}\n{version_result.stderr}"
            if version_result.returncode == 0 and self.LEGACY_TAG in combined:
                details["legacy_build_reused"] = True
                details["legacy_version_output"] = combined.strip()
                return legacy_bin, ""

        details["legacy_build_reused"] = False

        if cache_root.exists():
            shutil.rmtree(cache_root, ignore_errors=True)
        cache_root.mkdir(parents=True, exist_ok=True)

        # Build the historical client from an isolated shallow clone of the
        # exact release tag. Do not depend on the current GitHub Actions
        # workspace retaining usable .git metadata: the E2E harness only needs
        # the tagged historical source tree, not a worktree relationship with
        # the current checkout.
        build_steps: list[tuple[str, list[str], Path]] = [
            (
                "legacy clone",
                [
                    "git",
                    "clone",
                    "--depth",
                    "1",
                    "--branch",
                    self.LEGACY_TAG,
                    "--single-branch",
                    self.LEGACY_REPOSITORY_URL,
                    str(source_dir),
                ],
                cache_root,
            ),
            (
                "legacy configure",
                ["./configure", f"--prefix={prefix_dir}"],
                source_dir,
            ),
            (
                "legacy make",
                ["make", f"-j{max(1, min(4, os.cpu_count() or 2))}"],
                source_dir,
            ),
            (
                "legacy install",
                ["make", "install"],
                source_dir,
            ),
        ]

        for index, (label, command, cwd) in enumerate(build_steps, start=1):
            stdout_file = case_log_dir / f"legacy_build_{index:02d}_{label.replace(' ', '_')}_stdout.log"
            stderr_file = case_log_dir / f"legacy_build_{index:02d}_{label.replace(' ', '_')}_stderr.log"
            artifacts.extend([str(stdout_file), str(stderr_file)])

            result = self._run_logged(
                context=context,
                command=command,
                label=label,
                stdout_file=stdout_file,
                stderr_file=stderr_file,
                cwd=cwd,
            )
            details[f"{label.replace(' ', '_')}_returncode"] = result.returncode
            if result.returncode != 0:
                return None, f"{label} failed with status {result.returncode}"

        if not legacy_bin.is_file():
            return None, f"legacy build completed but binary was not installed at {legacy_bin}"

        version_result = self._run_logged(
            context=context,
            command=[str(legacy_bin), "--version"],
            label="legacy built binary version check",
            stdout_file=version_stdout,
            stderr_file=version_stderr,
        )
        combined = f"{version_result.stdout}\n{version_result.stderr}"
        details["legacy_version_output"] = combined.strip()
        if version_result.returncode != 0:
            return None, f"legacy binary version check failed with status {version_result.returncode}"
        if self.LEGACY_TAG not in combined:
            return None, (
                f"legacy build did not report expected version {self.LEGACY_TAG}: "
                f"{combined.strip()}"
            )

        return legacy_bin, ""

    @staticmethod
    def _snapshot_tree(root: Path) -> dict[str, dict[str, object]]:
        if not root.is_dir():
            return {}

        snapshot: dict[str, dict[str, object]] = {
            root.name: {"kind": "dir"},
        }

        for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
            relative = path.relative_to(root.parent).as_posix()
            if path.is_dir():
                snapshot[relative] = {"kind": "dir"}
                continue

            if path.is_file():
                data = path.read_bytes()
                snapshot[relative] = {
                    "kind": "file",
                    "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }

        return snapshot

    @staticmethod
    def _database_state(db_path: Path) -> dict[str, object]:
        if not db_path.is_file():
            raise RuntimeError(f"database does not exist: {db_path}")

        with closing(sqlite3.connect(str(db_path))) as connection:
            user_version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            integrity_rows = [
                str(row[0])
                for row in connection.execute("PRAGMA integrity_check").fetchall()
            ]
            columns = [
                {
                    "cid": int(row[0]),
                    "name": str(row[1]),
                    "type": str(row[2]),
                    "notnull": int(row[3]),
                    "default": row[4],
                    "pk": int(row[5]),
                }
                for row in connection.execute("PRAGMA table_info(item)").fetchall()
            ]

        return {
            "path": str(db_path),
            "user_version": user_version,
            "integrity": integrity_rows,
            "column_count": len(columns),
            "columns": columns,
            "column_names": [column["name"] for column in columns],
        }

    @staticmethod
    def _database_identity_map(db_path: Path, root_name: str) -> dict[str, dict[str, str]]:
        with closing(sqlite3.connect(str(db_path))) as connection:
            rows = connection.execute(
                "SELECT driveId, id, name, type, parentId FROM item"
            ).fetchall()

        normalised = [
            {
                "driveId": "" if row[0] is None else str(row[0]),
                "id": "" if row[1] is None else str(row[1]),
                "name": "" if row[2] is None else str(row[2]),
                "type": "" if row[3] is None else str(row[3]),
                "parentId": "" if row[4] is None else str(row[4]),
            }
            for row in rows
        ]

        roots = [row for row in normalised if row["name"] == root_name]
        if len(roots) != 1:
            raise RuntimeError(
                f"expected exactly one database row named {root_name!r}, found {len(roots)}"
            )

        children: dict[tuple[str, str], list[dict[str, str]]] = {}
        for row in normalised:
            children.setdefault((row["driveId"], row["parentId"]), []).append(row)

        identities: dict[str, dict[str, str]] = {}
        visited: set[tuple[str, str]] = set()

        def visit(row: dict[str, str], relative: str) -> None:
            key = (row["driveId"], row["id"])
            if key in visited:
                raise RuntimeError(f"database identity cycle detected at {relative}")
            visited.add(key)

            identities[relative] = {
                "driveId": row["driveId"],
                "id": row["id"],
                "type": row["type"],
                "parentId": row["parentId"],
            }

            for child in sorted(
                children.get((row["driveId"], row["id"]), []),
                key=lambda candidate: candidate["name"],
            ):
                visit(child, f"{relative}/{child['name']}")

        visit(roots[0], root_name)
        return identities

    @staticmethod
    def _identity_core(identity_map: dict[str, dict[str, str]]) -> dict[str, tuple[str, str, str]]:
        return {
            path: (values["driveId"], values["id"], values["type"])
            for path, values in identity_map.items()
        }

    @staticmethod
    def _backup_database(source: Path, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            destination.unlink()

        with closing(sqlite3.connect(str(source))) as source_connection:
            with closing(sqlite3.connect(str(destination))) as destination_connection:
                source_connection.backup(destination_connection)

    @staticmethod
    def _restore_database(source: Path, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        for candidate in [
            destination,
            Path(f"{destination}-wal"),
            Path(f"{destination}-shm"),
        ]:
            candidate.unlink(missing_ok=True)
        shutil.copy2(source, destination)

    @staticmethod
    def _set_database_user_version(db_path: Path, user_version: int) -> None:
        with closing(sqlite3.connect(str(db_path))) as connection:
            connection.execute(f"PRAGMA user_version = {int(user_version)}")
            connection.commit()

    @staticmethod
    def _current_database_version(context: E2EContext) -> int:
        source = context.repo_root / "src" / "itemdb.d"
        content = source.read_text(encoding="utf-8", errors="replace")
        match = re.search(r"itemDatabaseVersion\s*=\s*(\d+)\s*;", content)
        if not match:
            raise RuntimeError("unable to determine current itemDatabaseVersion from src/itemdb.d")
        return int(match.group(1))

    @staticmethod
    def _write_fixture_initial(root: Path, context: E2EContext) -> None:
        (root / "Alpha").mkdir(parents=True, exist_ok=True)
        (root / "Beta" / "Nested").mkdir(parents=True, exist_ok=True)
        (root / "Gamma" / "Empty").mkdir(parents=True, exist_ok=True)

        write_text_file(
            root / "root-file.txt",
            "TC0081 historical database upgrade validation\ninitial root payload\n",
        )
        write_text_file(
            root / "Alpha" / "original-name.txt",
            "TC0081 file that will be renamed before the historical checkpoint\n",
        )
        write_text_file(
            root / "Alpha" / "to-delete.txt",
            "TC0081 file that will be deleted before the historical checkpoint\n",
        )
        write_text_file(
            root / "Beta" / "Nested" / "nested.txt",
            "TC0081 nested payload before modification\n",
        )
        (root / "zero-byte.dat").touch()

        seed = f"TC0081:{context.run_id}:{root.name}".encode("utf-8")
        payload = bytearray()
        counter = 0
        while len(payload) < 16384:
            payload.extend(hashlib.sha256(seed + counter.to_bytes(4, "big")).digest())
            counter += 1
        (root / "Alpha" / "fabricated.bin").write_bytes(bytes(payload[:16384]))

    @staticmethod
    def _mutate_fixture_before_checkpoint(root: Path) -> None:
        (root / "Alpha" / "original-name.txt").rename(root / "Alpha" / "renamed.txt")
        (root / "Alpha" / "to-delete.txt").unlink()
        write_text_file(
            root / "Beta" / "Nested" / "nested.txt",
            "TC0081 nested payload after historical-client modification\n",
        )
        write_text_file(
            root / "Beta" / "new-after-seed.txt",
            "TC0081 new file created after the initial historical sync\n",
        )

    def _validate_database_shape(
        self,
        *,
        state: dict[str, object],
        expected_version: int,
        expected_columns: int,
        label: str,
    ) -> str:
        if state["user_version"] != expected_version:
            return (
                f"{label} database user_version mismatch: expected {expected_version}, "
                f"got {state['user_version']}"
            )
        if state["column_count"] != expected_columns:
            return (
                f"{label} item table column count mismatch: expected {expected_columns}, "
                f"got {state['column_count']}"
            )
        if state["integrity"] != ["ok"]:
            return f"{label} database integrity_check failed: {state['integrity']}"
        return ""

    def _verify_remote_tree(
        self,
        *,
        context: E2EContext,
        binary: str,
        label: str,
        root_name: str,
        verify_root: Path,
        verify_conf: Path,
        expected_snapshot: dict[str, dict[str, object]],
        stdout_file: Path,
        stderr_file: Path,
    ) -> tuple[str, dict[str, dict[str, str]] | None, int]:
        reset_directory(verify_root)

        command = [
            binary,
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(verify_conf),
        ]
        result = self._run_logged(
            context=context,
            command=command,
            label=label,
            stdout_file=stdout_file,
            stderr_file=stderr_file,
        )
        if result.returncode != 0:
            return f"{label} failed with status {result.returncode}", None, result.returncode

        actual_snapshot = self._snapshot_tree(verify_root / root_name)
        if actual_snapshot != expected_snapshot:
            return f"{label} remote tree did not match the historical checkpoint tree", None, result.returncode

        verify_db = verify_conf / "items.sqlite3"
        try:
            identities = self._database_identity_map(verify_db, root_name)
        except Exception as exc:
            return f"{label} could not read verification database identities: {exc}", None, result.returncode

        return "", identities, result.returncode

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0081",
            ensure_refresh_token=False,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        context.ensure_refresh_token_available()

        main_root = case_work_dir / "syncroot-main"
        legacy_verify_root = case_work_dir / "syncroot-legacy-verify"
        current_verify_root = case_work_dir / "syncroot-current-verify"
        conf_main = case_work_dir / "conf-main"
        conf_legacy_verify = case_work_dir / "conf-legacy-verify"
        conf_current_verify = case_work_dir / "conf-current-verify"

        reset_directory(main_root)
        reset_directory(legacy_verify_root)
        reset_directory(current_verify_root)

        config_text_main = f'sync_dir = "{main_root}"\n'
        config_text_legacy_verify = f'sync_dir = "{legacy_verify_root}"\n'
        config_text_current_verify = f'sync_dir = "{current_verify_root}"\n'

        context.prepare_minimal_config_dir(conf_main, config_text_main)
        context.prepare_minimal_config_dir(conf_legacy_verify, config_text_legacy_verify)
        context.prepare_minimal_config_dir(conf_current_verify, config_text_current_verify)

        root_name = f"ZZ_E2E_TC0081_{context.run_id}_{os.getpid()}"
        fixture_root = main_root / root_name

        metadata_file = state_dir / "metadata.txt"
        legacy_backup = state_dir / "items-v2.5.5-checkpoint.sqlite3"

        artifacts: list[str] = [
            str(metadata_file),
            str(legacy_backup),
        ]
        details: dict[str, object] = {
            "root_name": root_name,
            "main_root": str(main_root),
            "main_conf": str(conf_main),
            "legacy_verify_root": str(legacy_verify_root),
            "legacy_verify_conf": str(conf_legacy_verify),
            "current_verify_root": str(current_verify_root),
            "current_verify_conf": str(conf_current_verify),
        }

        current_database_version = self._current_database_version(context)
        details["current_database_version_from_source"] = current_database_version

        legacy_bin, build_error = self._ensure_legacy_binary(
            context=context,
            case_log_dir=case_log_dir,
            details=details,
            artifacts=artifacts,
        )
        if build_error or legacy_bin is None:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=build_error or "legacy v2.5.5 binary build failed",
                artifacts=artifacts,
                details=details,
            )

        # ------------------------------------------------------------------
        # DB-0001: create an authentic, evolved v2.5.5 synchronisation state.
        # ------------------------------------------------------------------
        self._write_fixture_initial(fixture_root, context)

        legacy_seed_stdout = case_log_dir / "db0001_legacy_seed_stdout.log"
        legacy_seed_stderr = case_log_dir / "db0001_legacy_seed_stderr.log"
        artifacts.extend([str(legacy_seed_stdout), str(legacy_seed_stderr)])
        legacy_seed_command = [
            str(legacy_bin),
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        legacy_seed = self._run_logged(
            context=context,
            command=legacy_seed_command,
            label="DB-0001 legacy initial sync",
            stdout_file=legacy_seed_stdout,
            stderr_file=legacy_seed_stderr,
        )
        details["db0001_seed_returncode"] = legacy_seed.returncode
        if legacy_seed.returncode != 0:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0001 legacy initial sync failed with status {legacy_seed.returncode}",
                artifacts=artifacts,
                details=details,
            )

        self._mutate_fixture_before_checkpoint(fixture_root)

        legacy_mutation_stdout = case_log_dir / "db0001_legacy_mutation_stdout.log"
        legacy_mutation_stderr = case_log_dir / "db0001_legacy_mutation_stderr.log"
        artifacts.extend([str(legacy_mutation_stdout), str(legacy_mutation_stderr)])
        legacy_mutation = self._run_logged(
            context=context,
            command=legacy_seed_command,
            label="DB-0001 legacy mutation sync",
            stdout_file=legacy_mutation_stdout,
            stderr_file=legacy_mutation_stderr,
        )
        details["db0001_mutation_returncode"] = legacy_mutation.returncode
        if legacy_mutation.returncode != 0:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0001 legacy mutation sync failed with status {legacy_mutation.returncode}",
                artifacts=artifacts,
                details=details,
            )

        legacy_settle_stdout = case_log_dir / "db0001_legacy_settle_stdout.log"
        legacy_settle_stderr = case_log_dir / "db0001_legacy_settle_stderr.log"
        artifacts.extend([str(legacy_settle_stdout), str(legacy_settle_stderr)])
        legacy_settle = self._run_logged(
            context=context,
            command=legacy_seed_command,
            label="DB-0001 legacy no-change checkpoint sync",
            stdout_file=legacy_settle_stdout,
            stderr_file=legacy_settle_stderr,
        )
        details["db0001_settle_returncode"] = legacy_settle.returncode
        if legacy_settle.returncode != 0:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0001 legacy checkpoint sync failed with status {legacy_settle.returncode}",
                artifacts=artifacts,
                details=details,
            )

        main_db = conf_main / "items.sqlite3"
        try:
            legacy_db_state = self._database_state(main_db)
            legacy_identity_map = self._database_identity_map(main_db, root_name)
        except Exception as exc:
            details["db0001_database_exception"] = str(exc)
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0001 could not inspect historical database: {exc}",
                artifacts=artifacts,
                details=details,
            )

        details["db0001_database_state"] = legacy_db_state
        legacy_shape_error = self._validate_database_shape(
            state=legacy_db_state,
            expected_version=self.LEGACY_DATABASE_VERSION,
            expected_columns=self.LEGACY_ITEM_COLUMN_COUNT,
            label="DB-0001 historical",
        )
        if legacy_shape_error:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=legacy_shape_error,
                artifacts=artifacts,
                details=details,
            )

        expected_snapshot = self._snapshot_tree(fixture_root)
        details["db0001_checkpoint_snapshot"] = expected_snapshot
        details["db0001_identity_paths"] = sorted(legacy_identity_map)

        if not expected_snapshot:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0001 historical checkpoint tree is unexpectedly empty",
                artifacts=artifacts,
                details=details,
            )

        try:
            self._backup_database(main_db, legacy_backup)
            backup_state = self._database_state(legacy_backup)
        except Exception as exc:
            details["db0001_backup_exception"] = str(exc)
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0001 failed to create SQLite checkpoint backup: {exc}",
                artifacts=artifacts,
                details=details,
            )

        details["db0001_backup_state"] = backup_state
        backup_shape_error = self._validate_database_shape(
            state=backup_state,
            expected_version=self.LEGACY_DATABASE_VERSION,
            expected_columns=self.LEGACY_ITEM_COLUMN_COUNT,
            label="DB-0001 backup",
        )
        if backup_shape_error:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=backup_shape_error,
                artifacts=artifacts,
                details=details,
            )

        legacy_verify_stdout = case_log_dir / "db0001_legacy_verify_stdout.log"
        legacy_verify_stderr = case_log_dir / "db0001_legacy_verify_stderr.log"
        artifacts.extend([str(legacy_verify_stdout), str(legacy_verify_stderr)])
        legacy_verify_error, legacy_remote_identities, legacy_verify_rc = self._verify_remote_tree(
            context=context,
            binary=str(legacy_bin),
            label="DB-0001 legacy fresh-client remote verification",
            root_name=root_name,
            verify_root=legacy_verify_root,
            verify_conf=conf_legacy_verify,
            expected_snapshot=expected_snapshot,
            stdout_file=legacy_verify_stdout,
            stderr_file=legacy_verify_stderr,
        )
        details["db0001_verify_returncode"] = legacy_verify_rc
        if legacy_verify_error or legacy_remote_identities is None:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=legacy_verify_error or "DB-0001 legacy remote verification failed",
                artifacts=artifacts,
                details=details,
            )

        if self._identity_core(legacy_remote_identities) != self._identity_core(legacy_identity_map):
            details["db0001_main_identities"] = legacy_identity_map
            details["db0001_verify_identities"] = legacy_remote_identities
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0001 historical main and fresh verification clients disagree on remote item identities",
                artifacts=artifacts,
                details=details,
            )

        # ------------------------------------------------------------------
        # DB-0002: upgrade the authentic v2.5.5 DB using the current binary.
        # ------------------------------------------------------------------
        upgrade_stdout = case_log_dir / "db0002_current_upgrade_stdout.log"
        upgrade_stderr = case_log_dir / "db0002_current_upgrade_stderr.log"
        artifacts.extend([str(upgrade_stdout), str(upgrade_stderr)])
        current_sync_command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        upgrade = self._run_logged(
            context=context,
            command=current_sync_command,
            label="DB-0002 current-client historical database upgrade",
            stdout_file=upgrade_stdout,
            stderr_file=upgrade_stderr,
        )
        details["db0002_upgrade_returncode"] = upgrade.returncode
        if upgrade.returncode != 0:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0002 current-client upgrade failed with status {upgrade.returncode}",
                artifacts=artifacts,
                details=details,
            )

        upgrade_output = f"{upgrade.stdout}\n{upgrade.stderr}"
        upgrade_marker = "The item database is incompatible, re-creating database table structures"
        details["db0002_upgrade_marker_seen"] = upgrade_marker in upgrade_output
        if upgrade_marker not in upgrade_output:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0002 did not prove the historical database incompatibility/recreation path",
                artifacts=artifacts,
                details=details,
            )

        try:
            upgraded_db_state = self._database_state(main_db)
            upgraded_identity_map = self._database_identity_map(main_db, root_name)
        except Exception as exc:
            details["db0002_database_exception"] = str(exc)
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0002 could not inspect upgraded database: {exc}",
                artifacts=artifacts,
                details=details,
            )

        details["db0002_database_state"] = upgraded_db_state
        if upgraded_db_state["user_version"] != current_database_version:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=(
                    "DB-0002 upgraded database version does not match current source: "
                    f"expected {current_database_version}, got {upgraded_db_state['user_version']}"
                ),
                artifacts=artifacts,
                details=details,
            )
        if upgraded_db_state["integrity"] != ["ok"]:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0002 upgraded database integrity_check failed: {upgraded_db_state['integrity']}",
                artifacts=artifacts,
                details=details,
            )
        if upgraded_db_state["column_count"] <= self.LEGACY_ITEM_COLUMN_COUNT:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=(
                    "DB-0002 upgraded database did not advance beyond the legacy 18-column schema: "
                    f"got {upgraded_db_state['column_count']} columns"
                ),
                artifacts=artifacts,
                details=details,
            )
        if not {"relocDriveId", "relocParentId"}.issubset(set(upgraded_db_state["column_names"])):
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0002 upgraded database is missing expected relocation columns",
                artifacts=artifacts,
                details=details,
            )

        if self._snapshot_tree(fixture_root) != expected_snapshot:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0002 current-client upgrade changed the local checkpoint tree",
                artifacts=artifacts,
                details=details,
            )

        if self._identity_core(upgraded_identity_map) != self._identity_core(legacy_identity_map):
            details["db0002_legacy_identities"] = legacy_identity_map
            details["db0002_upgraded_identities"] = upgraded_identity_map
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0002 current-client upgrade changed one or more remote item identities",
                artifacts=artifacts,
                details=details,
            )

        current_verify1_stdout = case_log_dir / "db0002_current_verify_stdout.log"
        current_verify1_stderr = case_log_dir / "db0002_current_verify_stderr.log"
        artifacts.extend([str(current_verify1_stdout), str(current_verify1_stderr)])
        verify_error, verify_identities, verify_rc = self._verify_remote_tree(
            context=context,
            binary=context.onedrive_bin,
            label="DB-0002 current fresh-client remote verification",
            root_name=root_name,
            verify_root=current_verify_root,
            verify_conf=conf_current_verify,
            expected_snapshot=expected_snapshot,
            stdout_file=current_verify1_stdout,
            stderr_file=current_verify1_stderr,
        )
        details["db0002_verify_returncode"] = verify_rc
        if verify_error or verify_identities is None:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=verify_error or "DB-0002 current remote verification failed",
                artifacts=artifacts,
                details=details,
            )
        if self._identity_core(verify_identities) != self._identity_core(legacy_identity_map):
            details["db0002_verify_identities"] = verify_identities
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0002 fresh current verifier observed changed remote identities after upgrade",
                artifacts=artifacts,
                details=details,
            )

        # ------------------------------------------------------------------
        # DB-0003: restore the exact old DB and prove upgrade is repeatable.
        # ------------------------------------------------------------------
        self._restore_database(legacy_backup, main_db)
        restored_old_state = self._database_state(main_db)
        details["db0003_restored_legacy_state"] = restored_old_state
        restored_error = self._validate_database_shape(
            state=restored_old_state,
            expected_version=self.LEGACY_DATABASE_VERSION,
            expected_columns=self.LEGACY_ITEM_COLUMN_COUNT,
            label="DB-0003 restored historical",
        )
        if restored_error:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=restored_error,
                artifacts=artifacts,
                details=details,
            )

        restore_upgrade_stdout = case_log_dir / "db0003_restored_upgrade_stdout.log"
        restore_upgrade_stderr = case_log_dir / "db0003_restored_upgrade_stderr.log"
        artifacts.extend([str(restore_upgrade_stdout), str(restore_upgrade_stderr)])
        restore_upgrade = self._run_logged(
            context=context,
            command=current_sync_command,
            label="DB-0003 restored historical database upgrade",
            stdout_file=restore_upgrade_stdout,
            stderr_file=restore_upgrade_stderr,
        )
        details["db0003_upgrade_returncode"] = restore_upgrade.returncode
        if restore_upgrade.returncode != 0:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0003 restored historical DB upgrade failed with status {restore_upgrade.returncode}",
                artifacts=artifacts,
                details=details,
            )
        if upgrade_marker not in f"{restore_upgrade.stdout}\n{restore_upgrade.stderr}":
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0003 restored historical DB did not re-enter the incompatibility/recreation path",
                artifacts=artifacts,
                details=details,
            )

        restored_upgraded_state = self._database_state(main_db)
        restored_upgraded_identities = self._database_identity_map(main_db, root_name)
        details["db0003_upgraded_database_state"] = restored_upgraded_state
        if restored_upgraded_state["user_version"] != current_database_version:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0003 restored historical DB did not upgrade to the current database version",
                artifacts=artifacts,
                details=details,
            )
        if restored_upgraded_state["integrity"] != ["ok"]:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0003 upgraded database integrity_check failed: {restored_upgraded_state['integrity']}",
                artifacts=artifacts,
                details=details,
            )
        if self._snapshot_tree(fixture_root) != expected_snapshot:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0003 restored historical DB upgrade changed the local checkpoint tree",
                artifacts=artifacts,
                details=details,
            )
        if self._identity_core(restored_upgraded_identities) != self._identity_core(legacy_identity_map):
            details["db0003_upgraded_identities"] = restored_upgraded_identities
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0003 restored historical DB upgrade changed one or more remote item identities",
                artifacts=artifacts,
                details=details,
            )

        current_verify2_stdout = case_log_dir / "db0003_current_verify_stdout.log"
        current_verify2_stderr = case_log_dir / "db0003_current_verify_stderr.log"
        artifacts.extend([str(current_verify2_stdout), str(current_verify2_stderr)])
        verify_error, verify_identities, verify_rc = self._verify_remote_tree(
            context=context,
            binary=context.onedrive_bin,
            label="DB-0003 current fresh-client remote verification",
            root_name=root_name,
            verify_root=current_verify_root,
            verify_conf=conf_current_verify,
            expected_snapshot=expected_snapshot,
            stdout_file=current_verify2_stdout,
            stderr_file=current_verify2_stderr,
        )
        details["db0003_verify_returncode"] = verify_rc
        if verify_error or verify_identities is None:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=verify_error or "DB-0003 current remote verification failed",
                artifacts=artifacts,
                details=details,
            )
        if self._identity_core(verify_identities) != self._identity_core(legacy_identity_map):
            details["db0003_verify_identities"] = verify_identities
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0003 remote identities changed after restored historical DB upgrade",
                artifacts=artifacts,
                details=details,
            )

        # ------------------------------------------------------------------
        # DB-0004: same-version marker + historical physical schema must fail
        # closed with EXIT_RESYNC_REQUIRED before reconciliation can continue.
        # ------------------------------------------------------------------
        self._restore_database(legacy_backup, main_db)
        self._set_database_user_version(main_db, current_database_version)
        mismatched_state = self._database_state(main_db)
        details["db0004_mismatched_database_state"] = mismatched_state

        if mismatched_state["user_version"] != current_database_version:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 failed to set historical DB user_version to the current version",
                artifacts=artifacts,
                details=details,
            )
        if mismatched_state["column_count"] != self.LEGACY_ITEM_COLUMN_COUNT:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 historical physical schema was unexpectedly changed before validation",
                artifacts=artifacts,
                details=details,
            )
        if mismatched_state["integrity"] != ["ok"]:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0004 intentionally mismatched DB is not SQLite-integral: {mismatched_state['integrity']}",
                artifacts=artifacts,
                details=details,
            )

        pre_failure_snapshot = self._snapshot_tree(fixture_root)
        schema_failure_stdout = case_log_dir / "db0004_schema_failure_stdout.log"
        schema_failure_stderr = case_log_dir / "db0004_schema_failure_stderr.log"
        artifacts.extend([str(schema_failure_stdout), str(schema_failure_stderr)])
        schema_failure = self._run_logged(
            context=context,
            command=current_sync_command,
            label="DB-0004 current same-version physical-schema mismatch",
            stdout_file=schema_failure_stdout,
            stderr_file=schema_failure_stderr,
        )
        details["db0004_failure_returncode"] = schema_failure.returncode

        failure_output = f"{schema_failure.stdout}\n{schema_failure.stderr}"
        required_failure_markers = [
            "FATAL: The local item database schema does not match the schema expected by this version of the application.",
            "Database schema mismatch:",
            "A --resync is required to rebuild the local item database.",
        ]
        details["db0004_required_failure_markers"] = required_failure_markers
        details["db0004_failure_markers_seen"] = {
            marker: marker in failure_output
            for marker in required_failure_markers
        }

        if schema_failure.returncode != self.EXIT_RESYNC_REQUIRED:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=(
                    "DB-0004 schema mismatch did not exit with EXIT_RESYNC_REQUIRED: "
                    f"expected {self.EXIT_RESYNC_REQUIRED}, got {schema_failure.returncode}"
                ),
                artifacts=artifacts,
                details=details,
            )
        missing_markers = [marker for marker in required_failure_markers if marker not in failure_output]
        if missing_markers:
            details["db0004_missing_failure_markers"] = missing_markers
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 schema mismatch did not emit the expected controlled failure diagnostics",
                artifacts=artifacts,
                details=details,
            )

        post_failure_state = self._database_state(main_db)
        details["db0004_post_failure_database_state"] = post_failure_state
        if post_failure_state["user_version"] != current_database_version or post_failure_state["column_count"] != self.LEGACY_ITEM_COLUMN_COUNT:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 controlled schema failure unexpectedly rewrote the mismatched database",
                artifacts=artifacts,
                details=details,
            )
        if self._snapshot_tree(fixture_root) != pre_failure_snapshot:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 controlled schema failure changed the local filesystem tree",
                artifacts=artifacts,
                details=details,
            )

        current_verify3_stdout = case_log_dir / "db0004_post_failure_verify_stdout.log"
        current_verify3_stderr = case_log_dir / "db0004_post_failure_verify_stderr.log"
        artifacts.extend([str(current_verify3_stdout), str(current_verify3_stderr)])
        verify_error, verify_identities, verify_rc = self._verify_remote_tree(
            context=context,
            binary=context.onedrive_bin,
            label="DB-0004 post-failure remote verification",
            root_name=root_name,
            verify_root=current_verify_root,
            verify_conf=conf_current_verify,
            expected_snapshot=expected_snapshot,
            stdout_file=current_verify3_stdout,
            stderr_file=current_verify3_stderr,
        )
        details["db0004_post_failure_verify_returncode"] = verify_rc
        if verify_error or verify_identities is None:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=verify_error or "DB-0004 post-failure remote verification failed",
                artifacts=artifacts,
                details=details,
            )
        if self._identity_core(verify_identities) != self._identity_core(legacy_identity_map):
            details["db0004_post_failure_verify_identities"] = verify_identities
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 controlled schema failure altered remote item identities",
                artifacts=artifacts,
                details=details,
            )

        recovery_stdout = case_log_dir / "db0004_resync_recovery_stdout.log"
        recovery_stderr = case_log_dir / "db0004_resync_recovery_stderr.log"
        artifacts.extend([str(recovery_stdout), str(recovery_stderr)])
        recovery_command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        recovery = self._run_logged(
            context=context,
            command=recovery_command,
            label="DB-0004 required resync recovery",
            stdout_file=recovery_stdout,
            stderr_file=recovery_stderr,
        )
        details["db0004_recovery_returncode"] = recovery.returncode
        if recovery.returncode != 0:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0004 required --resync recovery failed with status {recovery.returncode}",
                artifacts=artifacts,
                details=details,
            )

        recovery_state = self._database_state(main_db)
        recovery_identities = self._database_identity_map(main_db, root_name)
        details["db0004_recovery_database_state"] = recovery_state
        if recovery_state["user_version"] != current_database_version:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 --resync recovery did not recreate the current database version",
                artifacts=artifacts,
                details=details,
            )
        if recovery_state["column_count"] <= self.LEGACY_ITEM_COLUMN_COUNT:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 --resync recovery did not rebuild the historical physical schema",
                artifacts=artifacts,
                details=details,
            )
        if recovery_state["integrity"] != ["ok"]:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=f"DB-0004 recovery database integrity_check failed: {recovery_state['integrity']}",
                artifacts=artifacts,
                details=details,
            )
        if self._snapshot_tree(fixture_root) != expected_snapshot:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 --resync recovery changed the local checkpoint tree",
                artifacts=artifacts,
                details=details,
            )
        if self._identity_core(recovery_identities) != self._identity_core(legacy_identity_map):
            details["db0004_recovery_identities"] = recovery_identities
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 --resync recovery changed one or more remote item identities",
                artifacts=artifacts,
                details=details,
            )

        current_verify4_stdout = case_log_dir / "db0004_recovery_verify_stdout.log"
        current_verify4_stderr = case_log_dir / "db0004_recovery_verify_stderr.log"
        artifacts.extend([str(current_verify4_stdout), str(current_verify4_stderr)])
        verify_error, verify_identities, verify_rc = self._verify_remote_tree(
            context=context,
            binary=context.onedrive_bin,
            label="DB-0004 recovery fresh-client remote verification",
            root_name=root_name,
            verify_root=current_verify_root,
            verify_conf=conf_current_verify,
            expected_snapshot=expected_snapshot,
            stdout_file=current_verify4_stdout,
            stderr_file=current_verify4_stderr,
        )
        details["db0004_recovery_verify_returncode"] = verify_rc
        if verify_error or verify_identities is None:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason=verify_error or "DB-0004 recovery remote verification failed",
                artifacts=artifacts,
                details=details,
            )
        if self._identity_core(verify_identities) != self._identity_core(legacy_identity_map):
            details["db0004_recovery_verify_identities"] = verify_identities
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                reason="DB-0004 recovered remote identities differ from the historical checkpoint",
                artifacts=artifacts,
                details=details,
            )

        details["historical_identity_count"] = len(legacy_identity_map)
        details["final_identity_count"] = len(recovery_identities)
        details["final_database_version"] = recovery_state["user_version"]
        details["final_item_column_count"] = recovery_state["column_count"]
        details["db0001_passed"] = True
        details["db0002_passed"] = True
        details["db0003_passed"] = True
        details["db0004_passed"] = True
        self.write_metadata(metadata_file, details)

        return self.pass_result(
            artifacts=artifacts,
            details=details,
        )
