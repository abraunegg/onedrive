from __future__ import annotations

import os
import shutil
import sqlite3
from contextlib import closing
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


# Every item table column that a full-record upsert writes, other than the
# 'syncStatus' presence flag. 'deltaLink' is not written by upsert() at all.
REWRITE_AUDIT_COLUMNS = (
    "name", "remoteName", "type", "eTag", "cTag", "mtime", "parentId", "quickXorHash",
    "sha256Hash", "remoteDriveId", "remoteParentId", "remoteId", "remoteType", "size",
    "relocDriveId", "relocParentId",
)
REWRITE_AUDIT_TABLE = "e2e_tc0089_record_rewrite_audit"


class TestCase0089GeneratedChildrenUnchangedRecordPreservation(E2ETestCase):
    """Validate generated /children reconciliation of unchanged and remotely deleted items.

    A generated /delta response (forced /children traversal, --single-directory,
    Shared Folders and National Cloud Deployments) uses 'syncStatus' as a
    mark-and-sweep presence flag. Every tracked item is flagged 'N' before the
    online traversal, flagged 'Y' again when seen online, and anything left 'N'
    is treated as deleted online.

    This testcase protects two properties of that process:
    - unchanged items must not have their full database record rewritten on every
      pass, and their database record must remain identical
    - items deleted online must still be removed locally and from the database,
      while untouched items remain present and unchanged

    Full-record rewrites are observed by adding an audit table and triggers to
    the subject database between client runs. 'AFTER UPDATE OF <columns>' fires
    when any listed column is named in the SET clause of an UPDATE that affects
    the row, even if the stored value does not change. A 'syncStatus'-only UPDATE,
    or an UPDATE that affects no rows, does not fire it. The client's physical
    schema validation only checks the item table columns, so this
    instrumentation does not alter client behaviour.
    """

    case_id = "0089"
    name = "generated children unchanged record preservation and deletion reconciliation"
    description = (
        "Validate that generated /children reconciliation does not rewrite unchanged database records, "
        "and still removes remotely deleted items locally and from the database"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0089", ensure_refresh_token=True)
        failures: list[str] = []
        artifacts: list[str] = []
        details: dict[str, object] = {}
        metadata_file = layout.state_dir / "metadata.txt"

        # GR-0001 forces /children traversal for the account, scoped with sync_list.
        # GR-0002 selects the generated response through --single-directory.
        for mode in ("GR-0001", "GR-0002"):
            if not context.should_run_scenario(self.case_id, mode):
                continue
            scenario_failure = self._run_scenario(context, layout, mode, artifacts, details)
            if scenario_failure:
                failures.append(f"{mode}: {scenario_failure}")

        details["executed_scenarios"] = [key for key in ("GR-0001", "GR-0002") if key in details]
        details["failed_scenarios"] = failures
        self.write_metadata(metadata_file, details)
        artifacts.append(str(metadata_file))
        if not details["executed_scenarios"]:
            return self.fail_result(self.case_id, self.name, "no scenarios selected", artifacts, details)
        if failures:
            return self.fail_result(self.case_id, self.name, "; ".join(failures), artifacts, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)

    def _run_scenario(
        self,
        context: E2EContext,
        layout,
        mode: str,
        artifacts: list[str],
        details: dict[str, object],
    ) -> str | None:
        scenario_work = layout.work_dir / mode
        scenario_logs = layout.log_dir / mode
        scenario_state = layout.state_dir / mode
        for directory in (scenario_work, scenario_logs, scenario_state):
            reset_directory(directory)

        subject_root = scenario_work / "subject-root"
        mutator_root = scenario_work / "mutator-root"
        verify_root = scenario_work / "verify-root"
        conf_subject = scenario_work / "conf-subject"
        conf_mutator = scenario_work / "conf-mutator"
        conf_verify = scenario_work / "conf-verify"
        for root in (subject_root, mutator_root, verify_root):
            reset_directory(root)
        subject_database = conf_subject / "items.sqlite3"

        root_name = f"ZZ_E2E_TC0089_{mode.replace('-', '')}_{context.run_id}_{os.getpid()}"
        # 'Stable' is never touched. Its records, and the untouched file inside
        # 'Mutable', are the negative control for both the rewrite audit and the
        # deletion handling. Ancestors of mutated items are excluded from the strict
        # comparison because OneDrive legitimately changes their eTag.
        stable_files = {
            f"{root_name}/Stable/keep-a.txt": "TC0089 stable top-level file\n",
            f"{root_name}/Stable/Nested/keep-b.txt": "TC0089 stable nested file\n",
            f"{root_name}/Stable/Nested/Deep/keep-c.txt": "TC0089 stable deep file\n",
        }
        mutable_survivor = f"{root_name}/Mutable/keep-d.txt"
        changed_file = f"{root_name}/Mutable/change-me.txt"
        changed_contents_before = "TC0089 content before the online modification\n"
        changed_contents_after = "TC0089 content after the online modification, which must be applied\n"
        deleted_files = {
            f"{root_name}/Mutable/delete-me.txt": "TC0089 file deleted online\n",
            f"{root_name}/Mutable/RemoveTree/Deep/child.txt": "TC0089 file inside a subtree deleted online\n",
        }
        deleted_directories = [f"{root_name}/Mutable/RemoveTree", f"{root_name}/Mutable/EmptyRemoved"]
        deleted_paths = sorted(list(deleted_files) + deleted_directories + [f"{root_name}/Mutable/RemoveTree/Deep"])
        surviving_files = {
            **stable_files,
            mutable_survivor: "TC0089 untouched file beside the online deletions\n",
            changed_file: changed_contents_after,
        }
        expected_final = sorted([
            f"{root_name}/", f"{root_name}/Stable/", f"{root_name}/Stable/Nested/",
            f"{root_name}/Stable/Nested/Deep/", f"{root_name}/Mutable/", *surviving_files,
        ])
        expected_initial = sorted(expected_final + [
            f"{root_name}/Mutable/RemoveTree/", f"{root_name}/Mutable/RemoveTree/Deep/",
            f"{root_name}/Mutable/EmptyRemoved/", *deleted_files,
        ])
        # Records which must remain byte-for-byte identical after the online mutation.
        preserved_records = sorted([
            f"{root_name}/Stable", f"{root_name}/Stable/Nested", f"{root_name}/Stable/Nested/Deep",
            *stable_files, mutable_survivor,
        ])

        if mode == "GR-0001":
            subject_config = (
                f'# tc0089 {mode} subject using forced /children traversal\n'
                f'sync_dir = "{subject_root}"\n'
                'bypass_data_preservation = "false"\n'
                'force_children_scan = "true"\n'
            )
            scope_arguments: list[str] = []
        else:
            subject_config = (
                f'# tc0089 {mode} subject using --single-directory\n'
                f'sync_dir = "{subject_root}"\n'
                'bypass_data_preservation = "false"\n'
            )
            scope_arguments = ["--single-directory", root_name]
        context.prepare_minimal_config_dir(conf_subject, subject_config)
        if mode == "GR-0001":
            write_text_file(conf_subject / "sync_list", f"/{root_name}\n")
        context.prepare_minimal_config_dir(
            conf_mutator,
            f'# tc0089 {mode} independent remote mutator\nsync_dir = "{mutator_root}"\n'
            'bypass_data_preservation = "true"\n',
        )
        context.prepare_minimal_config_dir(
            conf_verify,
            f'# tc0089 {mode} independent remote verifier\nsync_dir = "{verify_root}"\n'
            'bypass_data_preservation = "true"\n',
        )

        for relative, contents in {**stable_files, **deleted_files}.items():
            write_text_file(mutator_root / relative, contents)
        write_text_file(mutator_root / mutable_survivor, surviving_files[mutable_survivor])
        write_text_file(mutator_root / changed_file, changed_contents_before)
        (mutator_root / deleted_directories[1]).mkdir(parents=True, exist_ok=True)

        phase_names = (
            "seed", "subject_initial", "subject_settle", "subject_unchanged",
            "remote_mutation", "remote_verify", "subject_reconcile", "subject_converge",
        )
        phase_files = {
            phase: (scenario_logs / f"{phase}_stdout.log", scenario_logs / f"{phase}_stderr.log")
            for phase in phase_names
        }
        artifacts.extend(str(p) for pair in phase_files.values() for p in pair)
        artifacts.extend(str(scenario_state / name) for name in (
            "subject_initial_manifest.txt", "remote_verify_manifest.txt",
            "subject_final_manifest.txt", "metadata.txt",
        ))
        scenario_details: dict[str, object] = {
            "mode": mode, "root_name": root_name, "subject_database": str(subject_database),
            "deleted_paths": deleted_paths, "preserved_records": preserved_records,
        }
        details[mode] = scenario_details

        def phase_run(phase: str, command: list[str]):
            context.log(f"Executing Test Case {self.case_id} {mode} {phase}: {command_to_string(command)}")
            result = run_command(command, cwd=context.repo_root)
            write_text_file(phase_files[phase][0], result.stdout)
            write_text_file(phase_files[phase][1], result.stderr)
            scenario_details[f"{phase}_returncode"] = result.returncode
            scenario_details[f"{phase}_command"] = command_to_string(command)
            return result

        def fail(reason: str) -> str:
            scenario_details["failure_reason"] = reason
            self.write_metadata(scenario_state / "metadata.txt", scenario_details)
            return reason

        mutator_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--upload-only",
            "--verbose", "--single-directory", root_name, "--confdir", str(conf_mutator),
        ]
        subject_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            *scope_arguments, "--confdir", str(conf_subject),
        ]

        seed = phase_run("seed", mutator_command + ["--resync", "--resync-auth"])
        if seed.returncode != 0 or not (conf_mutator / "items.sqlite3").is_file():
            return fail("mutator seed failed or did not establish an item database")

        initial = phase_run("subject_initial", subject_command + ["--resync", "--resync-auth"])
        if initial.returncode != 0 or not subject_database.is_file():
            return fail("subject initial sync failed or did not establish an item database")
        initial_manifest = build_typed_manifest(subject_root)
        write_manifest(scenario_state / "subject_initial_manifest.txt", initial_manifest)
        if initial_manifest != expected_initial:
            scenario_details["subject_initial_manifest"] = initial_manifest
            return fail("subject did not establish the expected tracked tree")

        self._install_rewrite_audit(subject_database)

        # The first repeat sync is allowed to settle any one-off baseline adjustment
        # following the initial --resync. The second repeat sync is the strict check.
        settle = phase_run("subject_settle", subject_command)
        if settle.returncode != 0:
            return fail("subject settle sync failed")
        before_unchanged = self._snapshot_subtree(subject_database, root_name)
        self._clear_rewrite_audit(subject_database)

        unchanged = phase_run("subject_unchanged", subject_command)
        if unchanged.returncode != 0:
            return fail("subject unchanged sync failed")
        after_unchanged = self._snapshot_subtree(subject_database, root_name)
        unchanged_rewrites = self._read_rewrite_audit(subject_database, after_unchanged)
        scenario_details["unchanged_record_count"] = len(after_unchanged)
        scenario_details["unchanged_full_record_rewrites"] = unchanged_rewrites

        if sorted(after_unchanged) != sorted(before_unchanged):
            return fail("the set of tracked database records changed during a sync with no changes")
        differing = sorted(path for path in after_unchanged if after_unchanged[path] != before_unchanged[path])
        if differing:
            scenario_details["unchanged_differing_records"] = differing
            return fail("database records changed during a sync with no online or local changes")
        if unchanged_rewrites:
            # Without the fix, every tracked record is rewritten with identical values on every pass.
            return fail(f"{len(unchanged_rewrites)} unchanged database record(s) were rewritten during a sync with no changes")
        flagged = sorted(path for path, record in after_unchanged.items() if record["syncStatus"] != "Y")
        if flagged:
            scenario_details["unchanged_records_not_in_sync"] = flagged
            return fail("tracked records were left flagged as out-of-sync after an unchanged sync")

        # Delete a file, a populated subtree and an empty directory online, and
        # modify one file online, through the independent mutator.
        (mutator_root / list(deleted_files)[0]).unlink()
        shutil.rmtree(mutator_root / deleted_directories[0])
        (mutator_root / deleted_directories[1]).rmdir()
        write_text_file(mutator_root / changed_file, changed_contents_after)
        mutation = phase_run("remote_mutation", mutator_command)
        if mutation.returncode != 0:
            return fail("independent mutator failed to apply the online changes")

        remote_verify = phase_run("remote_verify", [
            context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
            "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_verify),
        ])
        if remote_verify.returncode != 0:
            return fail("independent remote verification failed")
        remote_manifest = build_typed_manifest(verify_root)
        write_manifest(scenario_state / "remote_verify_manifest.txt", remote_manifest)
        if remote_manifest != expected_final:
            scenario_details["remote_verify_manifest"] = remote_manifest
            return fail("online changes were not confirmed by an independent verifier before reconciliation")

        self._clear_rewrite_audit(subject_database)
        for phase in ("subject_reconcile", "subject_converge"):
            result = phase_run(phase, subject_command)
            if result.returncode != 0:
                return fail(f"{phase} sync failed")
        final_records = self._snapshot_subtree(subject_database, root_name)
        reconcile_rewrites = self._read_rewrite_audit(subject_database, final_records)
        scenario_details["reconcile_full_record_rewrites"] = reconcile_rewrites

        final_manifest = build_typed_manifest(subject_root)
        write_manifest(scenario_state / "subject_final_manifest.txt", final_manifest)
        scenario_details["subject_final_manifest"] = final_manifest
        if final_manifest != expected_final:
            return fail("online deletions were not applied locally, or surviving local tree differs from expected state")
        for relative, contents in surviving_files.items():
            if (subject_root / relative).read_text(encoding="utf-8") != contents:
                return fail(f"surviving local file content differs from expected: {relative}")
        if any("safeBackup" in p.name or ".partial" in p.name for p in subject_root.rglob("*")):
            return fail("unexpected backup or partial artefact in the subject tree")

        # Items deleted online must have been removed from the database, by identity.
        if any(path not in before_unchanged for path in deleted_paths):
            return fail("not every deleted path was tracked in the database before the online deletion")
        remaining = self._remaining_identities(subject_database, [before_unchanged[path] for path in deleted_paths])
        if remaining:
            scenario_details["deleted_records_still_present"] = remaining
            return fail("records for items deleted online remain in the database")

        # Negative control: untouched records remain present, unchanged and not rewritten.
        missing = [path for path in preserved_records if path not in final_records]
        if missing:
            scenario_details["preserved_records_missing"] = missing
            return fail("records for untouched items were removed from the database")
        changed = [path for path in preserved_records if final_records[path] != after_unchanged[path]]
        if changed:
            scenario_details["preserved_records_changed"] = changed
            return fail("records for untouched items changed during reconciliation of unrelated online changes")
        rewritten = sorted(set(preserved_records) & {entry["path"] for entry in reconcile_rewrites})
        if rewritten:
            scenario_details["preserved_records_rewritten"] = rewritten
            return fail("records for untouched items were rewritten during reconciliation of unrelated online changes")

        # Positive control: the online modification is still written to the database,
        # which also proves that the rewrite audit records full-record updates.
        if final_records.get(changed_file, {}).get("eTag") == after_unchanged.get(changed_file, {}).get("eTag"):
            return fail("the online modification was not recorded in the database")
        if changed_file not in {entry["path"] for entry in reconcile_rewrites}:
            return fail("the rewrite audit did not observe the database update for the online modification")

        flagged = sorted(path for path, record in final_records.items() if record["syncStatus"] != "Y")
        if flagged:
            scenario_details["final_records_not_in_sync"] = flagged
            return fail("tracked records were left flagged as out-of-sync after reconciliation")

        self.write_metadata(scenario_state / "metadata.txt", scenario_details)
        return None

    @staticmethod
    def _install_rewrite_audit(database: Path) -> None:
        # Record every full-record UPDATE, and every INSERT (including INSERT OR REPLACE),
        # that touches the item table. Only the presence flag columns are omitted.
        columns = ", ".join(REWRITE_AUDIT_COLUMNS)
        with closing(sqlite3.connect(str(database))) as connection:
            connection.executescript(
                f"""
                CREATE TABLE IF NOT EXISTS {REWRITE_AUDIT_TABLE} (kind TEXT NOT NULL, driveId TEXT NOT NULL, id TEXT NOT NULL);
                CREATE TRIGGER IF NOT EXISTS {REWRITE_AUDIT_TABLE}_update AFTER UPDATE OF {columns} ON item
                BEGIN
                    INSERT INTO {REWRITE_AUDIT_TABLE} (kind, driveId, id) VALUES ('update', NEW.driveId, NEW.id);
                END;
                CREATE TRIGGER IF NOT EXISTS {REWRITE_AUDIT_TABLE}_insert AFTER INSERT ON item
                BEGIN
                    INSERT INTO {REWRITE_AUDIT_TABLE} (kind, driveId, id) VALUES ('insert', NEW.driveId, NEW.id);
                END;
                """
            )
            connection.commit()

    @staticmethod
    def _clear_rewrite_audit(database: Path) -> None:
        with closing(sqlite3.connect(str(database))) as connection:
            connection.execute(f"DELETE FROM {REWRITE_AUDIT_TABLE}")
            connection.commit()

    @staticmethod
    def _read_rewrite_audit(database: Path, records: dict[str, dict[str, object]]) -> list[dict[str, str]]:
        # Restrict the audit to records beneath the test-owned root.
        paths_by_identity = {(record["driveId"], record["id"]): path for path, record in records.items()}
        with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as connection:
            rows = connection.execute(f"SELECT kind, driveId, id FROM {REWRITE_AUDIT_TABLE} ORDER BY rowid").fetchall()
        return [
            {"kind": str(kind), "path": paths_by_identity[(drive_id, item_id)]}
            for kind, drive_id, item_id in rows
            if (drive_id, item_id) in paths_by_identity
        ]

    @staticmethod
    def _snapshot_subtree(database: Path, root_name: str) -> dict[str, dict[str, object]]:
        # Return every database record beneath (and including) the test-owned root,
        # keyed by its path relative to the sync root, with all column values.
        with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as connection:
            connection.row_factory = sqlite3.Row
            roots = connection.execute(
                "SELECT * FROM item WHERE name = ? AND type = 'dir'", (root_name,),
            ).fetchall()
            if len(roots) != 1:
                raise AssertionError(f"expected exactly one database record for {root_name}, found {len(roots)}")
            records: dict[str, dict[str, object]] = {root_name: dict(roots[0])}
            pending = [(roots[0]["driveId"], roots[0]["id"], root_name)]
            while pending:
                drive_id, item_id, path = pending.pop()
                for child in connection.execute(
                    "SELECT * FROM item WHERE driveId = ? AND parentId = ?", (drive_id, item_id),
                ).fetchall():
                    child_path = f"{path}/{child['name']}"
                    records[child_path] = dict(child)
                    if child["type"] != "file":
                        pending.append((child["driveId"], child["id"], child_path))
        return records

    @staticmethod
    def _remaining_identities(database: Path, records: list[dict[str, object]]) -> list[str]:
        with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as connection:
            return [
                f"{record['driveId']}/{record['id']} ({record['name']})"
                for record in records
                if connection.execute(
                    "SELECT COUNT(*) FROM item WHERE driveId = ? AND id = ?", (record["driveId"], record["id"]),
                ).fetchone()[0]
            ]
