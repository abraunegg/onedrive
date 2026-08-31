from __future__ import annotations

import hashlib
import os
import re
import shutil
import sqlite3
import time
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    run_command,
    write_text_file,
)
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0079DisplaySyncStatusValidation(MonitorModeTestCaseBase):
    """Validate the read-only, bidirectional --display-sync-status assessment."""

    case_id = "0079"
    name = "display sync status validation"
    description = (
        "Validate clean, local-only, remote-only and mixed --display-sync-status results, "
        "including filtering, deletion tombstones, transfer-size reporting and read-only state"
    )

    EXCLUDED_SUFFIX = ".tc0079-excluded"
    MALFORMED_TOMBSTONE_WARNING = (
        "WARNING: Excluding malformed OneDrive JSON item from client-side filtering"
    )

    @staticmethod
    def _sha256_file(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def _snapshot_tree(self, root: Path) -> list[tuple[str, str, int, int, str]]:
        """Capture path/type/size/mtime/content state while intentionally ignoring atime."""
        snapshot: list[tuple[str, str, int, int, str]] = []
        if not root.exists():
            return snapshot

        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root).as_posix()
            stat_result = path.stat()
            if path.is_dir():
                snapshot.append((relative, "dir", 0, stat_result.st_mtime_ns, ""))
            elif path.is_file():
                snapshot.append(
                    (
                        relative,
                        "file",
                        stat_result.st_size,
                        stat_result.st_mtime_ns,
                        self._sha256_file(path),
                    )
                )
            else:
                snapshot.append((relative, "other", 0, stat_result.st_mtime_ns, ""))
        return snapshot

    @staticmethod
    def _read_nonempty_delta_links(database_path: Path) -> list[tuple[str, str, str]]:
        if not database_path.is_file():
            return []
        with sqlite3.connect(database_path) as connection:
            rows = connection.execute(
                "SELECT driveId, id, deltaLink FROM item "
                "WHERE deltaLink IS NOT NULL AND deltaLink != '' ORDER BY driveId, id"
            ).fetchall()
        return [(str(drive_id), str(item_id), str(delta_link)) for drive_id, item_id, delta_link in rows]

    @staticmethod
    def _rewrite_runtime_config(
        config_dir: Path,
        sync_root: Path,
        *,
        remove_skip_file: bool = False,
        extra_lines: list[str] | None = None,
    ) -> None:
        """Rewrite only runtime test settings while preserving target-specific base config."""
        config_path = config_dir / "config"
        existing_lines = config_path.read_text(encoding="utf-8").splitlines()
        retained_lines: list[str] = []

        for raw_line in existing_lines:
            stripped = raw_line.strip()
            if stripped.startswith("sync_dir") and "=" in stripped:
                continue
            if remove_skip_file and stripped.startswith("skip_file") and "=" in stripped:
                continue
            retained_lines.append(raw_line)

        retained_lines.append(f'sync_dir = "{sync_root}"')
        if extra_lines:
            retained_lines.extend(extra_lines)
        config_text = "\n".join(retained_lines) + "\n"
        config_path.write_text(config_text, encoding="utf-8")
        os.chmod(config_path, 0o600)

        backup_path = config_dir / ".config.backup"
        backup_path.write_text(config_text, encoding="utf-8")
        os.chmod(backup_path, 0o600)

        hash_path = config_dir / ".config.hash"
        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")
        os.chmod(hash_path, 0o600)

    @staticmethod
    def _contains_metric(output: str, label: str, expected_value: str) -> bool:
        # Normal runs emit the metric directly; the automatic diagnostic rerun can
        # route the same line through DEBUG logging. Validate the metric rather than
        # treating that logger prefix as a semantic difference.
        pattern = rf"^(?:DEBUG:\s*)?\s*{re.escape(label)}:\s+{re.escape(expected_value)}\s*$"
        return re.search(pattern, output, flags=re.MULTILINE) is not None

    def _run_and_capture(
        self,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
    ):
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def _run_status_and_validate_read_only(
        self,
        context: E2EContext,
        *,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        sync_root: Path,
        live_database: Path,
        dry_run_database: Path,
    ):
        if not live_database.is_file():
            raise RuntimeError(f"Live database missing before {label}: {live_database}")

        database_hash_before = self._sha256_file(live_database)
        tree_before = self._snapshot_tree(sync_root)

        result = self._run_and_capture(
            context,
            label,
            command,
            stdout_file,
            stderr_file,
        )

        database_hash_after = self._sha256_file(live_database)
        tree_after = self._snapshot_tree(sync_root)

        read_only_ok = (
            database_hash_before == database_hash_after
            and tree_before == tree_after
            and not dry_run_database.exists()
            and not Path(str(dry_run_database) + "-wal").exists()
            and not Path(str(dry_run_database) + "-shm").exists()
        )

        return result, {
            "database_hash_before": database_hash_before,
            "database_hash_after": database_hash_after,
            "tree_state_unchanged": tree_before == tree_after,
            "dry_run_database_removed": not dry_run_database.exists(),
            "read_only_ok": read_only_ok,
        }

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0079",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        main_root = case_work_dir / "mainroot"
        actor_root = case_work_dir / "actorroot"
        conf_main = case_work_dir / "conf-main"
        conf_indeterminate = case_work_dir / "conf-indeterminate"
        conf_actor = case_work_dir / "conf-actor"

        root_name = f"ZZ_E2E_TC0079_{context.run_id}_{os.getpid()}"
        root_path = main_root / root_name

        local_modify_relative = f"{root_name}/local-modify-same-size.txt"
        local_timestamp_relative = f"{root_name}/local-timestamp-only.txt"
        local_delete_relative = f"{root_name}/local-delete.txt"
        remote_delete_relative = f"{root_name}/remote-delete.txt"
        remote_rename_old_relative = f"{root_name}/remote-rename-original.txt"
        remote_rename_new_relative = f"{root_name}/remote-renamed.txt"
        remote_modify_relative = f"{root_name}/remote-modify.txt"
        stable_relative = f"{root_name}/stable.txt"

        local_new_relative = f"{root_name}/local-new-90-bytes.txt"
        local_new_directory_relative = f"{root_name}/local-new-directory"
        local_excluded_relative = f"{root_name}/local-ignored{self.EXCLUDED_SUFFIX}"
        mixed_local_relative = f"{root_name}/mixed-local-77-bytes.txt"

        remote_zero_relative = f"{root_name}/remote-new-zero-byte.txt"
        remote_large_relative = f"{root_name}/remote-new-2048-bytes.bin"
        remote_new_directory_relative = f"{root_name}/remote-new-directory"
        remote_excluded_relative = f"{root_name}/remote-ignored{self.EXCLUDED_SUFFIX}"

        # Keep all sizes deterministic so transfer-size output can be asserted exactly.
        local_modify_initial = "A" * 128
        local_modify_changed = "B" * 128
        local_timestamp_content = "T" * 64
        remote_modify_initial = "R" * 64
        remote_modify_changed = "M" * 96

        context.prepare_minimal_config_dir(
            conf_main,
            (
                "# tc0079 main\n"
                f'sync_dir = "{main_root}"\n'
                'bypass_data_preservation = "true"\n'
                f'skip_file = "*{self.EXCLUDED_SUFFIX}"\n'
            ),
        )

        # Seed a tracked baseline which later phases can independently disturb.
        write_text_file(main_root / local_modify_relative, local_modify_initial)
        write_text_file(main_root / local_timestamp_relative, local_timestamp_content)
        write_text_file(main_root / local_delete_relative, "local delete baseline\n")
        write_text_file(main_root / remote_delete_relative, "remote delete baseline\n")
        write_text_file(main_root / remote_rename_old_relative, "remote rename baseline\n")
        write_text_file(main_root / remote_modify_relative, remote_modify_initial)
        write_text_file(main_root / stable_relative, "stable baseline\n")

        seed_stdout = case_log_dir / "ds0000_seed_stdout.log"
        seed_stderr = case_log_dir / "ds0000_seed_stderr.log"
        clean_stdout = case_log_dir / "ds0001_clean_status_stdout.log"
        clean_stderr = case_log_dir / "ds0001_clean_status_stderr.log"
        indeterminate_stdout = case_log_dir / "ds0001b_indeterminate_status_stdout.log"
        indeterminate_stderr = case_log_dir / "ds0001b_indeterminate_status_stderr.log"
        local_stdout = case_log_dir / "ds0002_local_dirty_status_stdout.log"
        local_stderr = case_log_dir / "ds0002_local_dirty_status_stderr.log"
        reconcile_stdout = case_log_dir / "ds0002_reconcile_stdout.log"
        reconcile_stderr = case_log_dir / "ds0002_reconcile_stderr.log"
        clean2_stdout = case_log_dir / "ds0002_post_reconcile_clean_stdout.log"
        clean2_stderr = case_log_dir / "ds0002_post_reconcile_clean_stderr.log"
        cursor_seed_stdout = case_log_dir / "ds0002b_delta_cursor_seed_stdout.log"
        cursor_seed_stderr = case_log_dir / "ds0002b_delta_cursor_seed_stderr.log"
        actor_stdout = case_log_dir / "ds0003_actor_monitor_stdout.log"
        actor_stderr = case_log_dir / "ds0003_actor_monitor_stderr.log"
        actor_app_log_dir = case_log_dir / "app-logs"
        remote_stdout = case_log_dir / "ds0003_remote_dirty_status_stdout.log"
        remote_stderr = case_log_dir / "ds0003_remote_dirty_status_stderr.log"
        delta_remote_stdout = case_log_dir / "ds0003b_delta_tombstone_status_stdout.log"
        delta_remote_stderr = case_log_dir / "ds0003b_delta_tombstone_status_stderr.log"
        mixed_stdout = case_log_dir / "ds0004_mixed_status_stdout.log"
        mixed_stderr = case_log_dir / "ds0004_mixed_status_stderr.log"

        baseline_manifest_file = state_dir / "baseline_manifest.txt"
        actor_manifest_file = state_dir / "actor_manifest.txt"
        final_main_manifest_file = state_dir / "final_main_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(clean_stdout),
            str(clean_stderr),
            str(indeterminate_stdout),
            str(indeterminate_stderr),
            str(local_stdout),
            str(local_stderr),
            str(reconcile_stdout),
            str(reconcile_stderr),
            str(clean2_stdout),
            str(clean2_stderr),
            str(cursor_seed_stdout),
            str(cursor_seed_stderr),
            str(actor_stdout),
            str(actor_stderr),
            str(actor_app_log_dir),
            str(remote_stdout),
            str(remote_stderr),
            str(delta_remote_stdout),
            str(delta_remote_stderr),
            str(mixed_stdout),
            str(mixed_stderr),
            str(baseline_manifest_file),
            str(actor_manifest_file),
            str(final_main_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "main_root": str(main_root),
            "actor_root": str(actor_root),
            "conf_main": str(conf_main),
            "conf_indeterminate": str(conf_indeterminate),
            "conf_actor": str(conf_actor),
        }
        failures: list[str] = []

        seed_command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        seed_result = self._run_and_capture(
            context,
            "DS-0000 seed baseline",
            seed_command,
            seed_stdout,
            seed_stderr,
        )
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Seed phase failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        baseline_manifest = build_manifest(main_root)
        write_manifest(baseline_manifest_file, baseline_manifest)

        live_database = conf_main / "items.sqlite3"
        dry_run_database = conf_main / "items-dryrun.sqlite3"
        status_command = [
            context.onedrive_bin,
            "--display-sync-status",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]

        # DS-0001: clean status and read-only invariants.
        clean_result, clean_read_only = self._run_status_and_validate_read_only(
            context,
            label="DS-0001 clean status",
            command=status_command,
            stdout_file=clean_stdout,
            stderr_file=clean_stderr,
            sync_root=main_root,
            live_database=live_database,
            dry_run_database=dry_run_database,
        )
        clean_output = f"{clean_result.stdout}\n{clean_result.stderr}"
        details["ds0001_returncode"] = clean_result.returncode
        details["ds0001_read_only"] = clean_read_only

        if clean_result.returncode != 0:
            failures.append(f"DS-0001: status command exited with {clean_result.returncode}")
        if "Overall status: IN SYNC" not in clean_output:
            failures.append("DS-0001: clean baseline did not report 'Overall status: IN SYNC'")
        if "No pending remote changes detected." not in clean_output:
            failures.append("DS-0001: clean baseline did not report a clean remote direction")
        if "No pending local changes detected." not in clean_output:
            failures.append("DS-0001: clean baseline did not report a clean local direction")
        if not clean_read_only["read_only_ok"]:
            failures.append("DS-0001: --display-sync-status modified live DB/local state or left temporary DB files")

        # DS-0001B: full-scope force_children_scan still cannot use the normal /delta
        # status path. Exercise the conservative INDETERMINATE result using an isolated
        # copy of client state without --single-directory. Scoped --single-directory
        # assessment is validated separately through its authoritative current-state tree.
        if conf_indeterminate.exists():
            shutil.rmtree(conf_indeterminate)
        shutil.copytree(conf_main, conf_indeterminate)
        self._rewrite_runtime_config(
            conf_indeterminate,
            main_root,
            extra_lines=['force_children_scan = "true"'],
        )
        indeterminate_database = conf_indeterminate / "items.sqlite3"
        indeterminate_dry_run_database = conf_indeterminate / "items-dryrun.sqlite3"
        indeterminate_command = [
            context.onedrive_bin,
            "--display-sync-status",
            "--verbose",
            "--confdir",
            str(conf_indeterminate),
        ]
        indeterminate_result, indeterminate_read_only = self._run_status_and_validate_read_only(
            context,
            label="DS-0001B incomplete remote traversal status",
            command=indeterminate_command,
            stdout_file=indeterminate_stdout,
            stderr_file=indeterminate_stderr,
            sync_root=main_root,
            live_database=indeterminate_database,
            dry_run_database=indeterminate_dry_run_database,
        )
        indeterminate_output = f"{indeterminate_result.stdout}\n{indeterminate_result.stderr}"
        details["ds0001b_returncode"] = indeterminate_result.returncode
        details["ds0001b_read_only"] = indeterminate_read_only
        if indeterminate_result.returncode != 0:
            failures.append(f"DS-0001B: status command exited with {indeterminate_result.returncode}")
        if "Overall status: INDETERMINATE" not in indeterminate_output:
            failures.append("DS-0001B: incomplete remote traversal did not report 'Overall status: INDETERMINATE'")
        if "generated /children traversal rather than /delta" not in indeterminate_output:
            failures.append("DS-0001B: INDETERMINATE result did not explain the generated /children limitation")
        if not indeterminate_read_only["read_only_ok"]:
            failures.append("DS-0001B: indeterminate status assessment was not read-only")

        # DS-0002: local-only divergence, including filter and timestamp/hash pathways.
        time.sleep(1.1)
        write_text_file(main_root / local_modify_relative, local_modify_changed)
        write_text_file(main_root / local_new_relative, "N" * 90)
        (main_root / local_new_directory_relative).mkdir(parents=True, exist_ok=True)
        write_text_file(main_root / local_excluded_relative, "X" * 55)
        (main_root / local_delete_relative).unlink()

        timestamp_path = main_root / local_timestamp_relative
        timestamp_stat = timestamp_path.stat()
        os.utime(
            timestamp_path,
            ns=(timestamp_stat.st_atime_ns, timestamp_stat.st_mtime_ns + 2_000_000_000),
        )

        local_result, local_read_only = self._run_status_and_validate_read_only(
            context,
            label="DS-0002 local-only dirty status",
            command=status_command,
            stdout_file=local_stdout,
            stderr_file=local_stderr,
            sync_root=main_root,
            live_database=live_database,
            dry_run_database=dry_run_database,
        )
        local_output = f"{local_result.stdout}\n{local_result.stderr}"
        details["ds0002_returncode"] = local_result.returncode
        details["ds0002_read_only"] = local_read_only

        expected_local_metrics = {
            "Pending local items": "5",
            "New local files": "1",
            "New local directories": "1",
            "Modified local files": "1",
            "Timestamp-only differences": "1",
            "Locally deleted/missing": "1",
            "Files requiring upload": "2",
            "Directories to create online": "1",
            "Remote deletions requested": "1",
            "Approximate upload data": "218 bytes",
        }

        if local_result.returncode != 0:
            failures.append(f"DS-0002: status command exited with {local_result.returncode}")
        if "Overall status: NOT IN SYNC" not in local_output:
            failures.append("DS-0002: local divergence did not report 'Overall status: NOT IN SYNC'")
        if "No pending remote changes detected." not in local_output:
            failures.append("DS-0002: local-only divergence unexpectedly reported remote pending state")
        for label, value in expected_local_metrics.items():
            if not self._contains_metric(local_output, label, value):
                failures.append(f"DS-0002: expected metric missing: {label}: {value}")
        if local_excluded_relative not in build_manifest(main_root):
            failures.append("DS-0002: local excluded fixture disappeared during read-only status assessment")
        if not local_read_only["read_only_ok"]:
            failures.append("DS-0002: --display-sync-status modified live DB/local state or left temporary DB files")

        # Reconcile local changes so a second clean baseline can be established before
        # creating a stale second client for remote-side changes.
        reconcile_command = [
            context.onedrive_bin,
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        reconcile_result = self._run_and_capture(
            context,
            "DS-0002 reconcile local changes",
            reconcile_command,
            reconcile_stdout,
            reconcile_stderr,
        )
        details["ds0002_reconcile_returncode"] = reconcile_result.returncode
        if reconcile_result.returncode != 0:
            failures.append(f"DS-0002: reconciliation sync failed with {reconcile_result.returncode}")

        clean2_result, clean2_read_only = self._run_status_and_validate_read_only(
            context,
            label="DS-0002 post-reconcile clean status",
            command=status_command,
            stdout_file=clean2_stdout,
            stderr_file=clean2_stderr,
            sync_root=main_root,
            live_database=live_database,
            dry_run_database=dry_run_database,
        )
        clean2_output = f"{clean2_result.stdout}\n{clean2_result.stderr}"
        details["ds0002_clean_returncode"] = clean2_result.returncode
        details["ds0002_clean_read_only"] = clean2_read_only
        if clean2_result.returncode != 0 or "Overall status: IN SYNC" not in clean2_output:
            failures.append("DS-0002: reconciled local state did not return to 'Overall status: IN SYNC'")
        if not clean2_read_only["read_only_ok"]:
            failures.append("DS-0002: post-reconcile status assessment was not read-only")

        # DS-0002B: establish a real persisted default-drive delta checkpoint on the
        # same evaluated client. A narrow sync_list keeps the normal /delta pass scoped
        # to this testcase tree without introducing another validator client. This lets
        # DS-0003B exercise the genuine Graph deletion-tombstone path independently of
        # the --single-directory current-state traversal.
        write_text_file(conf_main / "sync_list", f"/{root_name}\n")
        cursor_seed_command = [
            context.onedrive_bin,
            "--sync",
            "--download-only",
            "--verbose",
            "--confdir",
            str(conf_main),
        ]
        cursor_seed_result = self._run_and_capture(
            context,
            "DS-0002B establish delta cursor",
            cursor_seed_command,
            cursor_seed_stdout,
            cursor_seed_stderr,
        )
        details["ds0002b_cursor_seed_returncode"] = cursor_seed_result.returncode
        delta_links_before_actor = self._read_nonempty_delta_links(live_database)
        details["ds0002b_delta_links"] = delta_links_before_actor
        if cursor_seed_result.returncode != 0:
            failures.append(f"DS-0002B: delta cursor seed sync failed with {cursor_seed_result.returncode}")
        if not delta_links_before_actor:
            failures.append("DS-0002B: normal /delta seed did not persist a non-empty delta cursor")

        # Snapshot the now-current client state. This independent mutator client makes
        # remote changes while the primary client deliberately remains stale. Keep the
        # established E2E topology: one mutator client, one client under evaluation.
        if conf_actor.exists():
            shutil.rmtree(conf_actor)
        if actor_root.exists():
            shutil.rmtree(actor_root)
        shutil.copytree(conf_main, conf_actor)
        shutil.copytree(main_root, actor_root)

        # The mutator must not inherit the primary skip_file rule, otherwise it could not
        # deliberately create a remote item which the primary status query must exclude.
        # Monitor settings mirror the proven TC0065 mutator topology: local rename events
        # are translated into a real Graph move of the existing DriveItem ID rather than
        # a one-shot sync degrading the rename into delete + new upload.
        self._rewrite_runtime_config(
            conf_actor,
            actor_root,
            remove_skip_file=True,
            extra_lines=[
                'enable_logging = "true"',
                f'log_dir = "{actor_app_log_dir}"',
                'monitor_interval = "300"',
                'monitor_fullscan_frequency = "0"',
                'disable_websocket_support = "true"',
            ],
        )
        actor_excluded_local = actor_root / local_excluded_relative
        actor_excluded_local.unlink(missing_ok=True)

        actor_monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--upload-only",
            "--verbose",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_actor),
        ]
        context.log(
            f"Executing Test Case {self.case_id} DS-0003 mutator monitor: "
            f"{command_to_string(actor_monitor_command)}"
        )
        actor_process, actor_initial_sync_complete = self._launch_monitor_process(
            context,
            actor_monitor_command,
            actor_stdout,
            actor_stderr,
            startup_timeout_seconds=300,
        )
        details["ds0003_actor_initial_sync_complete"] = actor_initial_sync_complete
        details["ds0003_actor_monitor_command"] = command_to_string(actor_monitor_command)

        actor_mutations_processed = False
        actor_mutation_segment = ""
        try:
            if actor_initial_sync_complete:
                mutation_start_offset = self._prepare_monitor_for_local_mutation(
                    actor_process,
                    actor_stdout,
                    details,
                    quiet_seconds=3.0,
                    timeout_seconds=30,
                )

                if details.get("monitor_ready_after_initial_sync", False):
                    time.sleep(1.1)
                    (actor_root / remote_rename_old_relative).rename(actor_root / remote_rename_new_relative)
                    (actor_root / remote_delete_relative).unlink()
                    write_text_file(actor_root / remote_modify_relative, remote_modify_changed)
                    write_text_file(actor_root / remote_zero_relative, "")
                    write_text_file(actor_root / remote_large_relative, "L" * 2048)
                    (actor_root / remote_new_directory_relative).mkdir(parents=True, exist_ok=True)
                    write_text_file(actor_root / remote_excluded_relative, "E" * 333)

                    required_actor_patterns = [
                        f"[M] Local item moved: ./{remote_rename_old_relative} -> ./{remote_rename_new_relative}",
                        f"Moving ./{remote_rename_old_relative} to ./{remote_rename_new_relative}",
                        f"Deleting item from Microsoft OneDrive: {remote_delete_relative}",
                        f"Uploading modified file: {remote_modify_relative} ... done",
                        f"Uploading new file: {remote_zero_relative} ... done",
                        f"Uploading new file: {remote_large_relative} ... done",
                        f"Uploading new file: {remote_excluded_relative} ... done",
                        "Successfully created the remote directory",
                    ]
                    actor_mutations_processed, actor_mutation_segment = self._wait_for_stdout_growth_patterns(
                        actor_stdout,
                        start_offset=mutation_start_offset,
                        required_patterns=required_actor_patterns,
                        timeout_seconds=180,
                    )
                    details["ds0003_actor_required_patterns"] = required_actor_patterns
                    details["ds0003_actor_mutations_processed"] = actor_mutations_processed
                    details["ds0003_actor_mutation_log_segment_length"] = len(actor_mutation_segment)
                    actor_rename_degraded = (
                        self._monitor_output_contains(
                            actor_mutation_segment,
                            f"Deleting item from Microsoft OneDrive: {remote_rename_old_relative}",
                        )
                        or self._monitor_output_contains(
                            actor_mutation_segment,
                            f"Uploading new file: {remote_rename_new_relative}",
                        )
                    )
                    details["ds0003_actor_rename_degraded_to_delete_upload"] = actor_rename_degraded
        finally:
            self._shutdown_monitor_process(actor_process, details)

        actor_manifest = build_manifest(actor_root)
        write_manifest(actor_manifest_file, actor_manifest)
        if not actor_initial_sync_complete:
            failures.append("DS-0003: mutator monitor did not complete its initial sync")
        elif not details.get("monitor_ready_after_initial_sync", False):
            failures.append("DS-0003: mutator monitor was not ready for local mutations")
        elif not actor_mutations_processed:
            failures.append("DS-0003: mutator monitor did not propagate all required remote changes")
        elif details.get("ds0003_actor_rename_degraded_to_delete_upload", False):
            failures.append("DS-0003: mutator rename degraded into delete + new upload instead of a real remote move")

        # DS-0003: remote-only --single-directory status. Expected transfer bytes are
        # 2048 + 96 + 0; deletion is identified by authoritative current-state absence
        # and rename is identified by the preserved DriveItem identity.
        remote_result, remote_read_only = self._run_status_and_validate_read_only(
            context,
            label="DS-0003 remote-only dirty status",
            command=status_command,
            stdout_file=remote_stdout,
            stderr_file=remote_stderr,
            sync_root=main_root,
            live_database=live_database,
            dry_run_database=dry_run_database,
        )
        remote_output = f"{remote_result.stdout}\n{remote_result.stderr}"
        details["ds0003_returncode"] = remote_result.returncode
        details["ds0003_read_only"] = remote_read_only

        expected_remote_metrics = {
            "Pending remote items": "6",
            "Deleted items": "1",
            "New files": "2",
            "New directories": "1",
            "Files requiring download": "3",
            "Moved or renamed items": "1",
            "Approximate download data": "2.09 KB (2144 bytes)",
        }

        if remote_result.returncode != 0:
            failures.append(f"DS-0003: status command exited with {remote_result.returncode}")
        if "Overall status: NOT IN SYNC" not in remote_output:
            failures.append("DS-0003: remote divergence did not report 'Overall status: NOT IN SYNC'")
        if "No pending local changes detected." not in remote_output:
            failures.append("DS-0003: remote-only divergence unexpectedly reported local pending state")
        for label, value in expected_remote_metrics.items():
            if not self._contains_metric(remote_output, label, value):
                failures.append(f"DS-0003: expected metric missing: {label}: {value}")
        if self.MALFORMED_TOMBSTONE_WARNING in remote_output:
            failures.append("DS-0003: remote deletion tombstone triggered the historical malformed-JSON warning")
        if not remote_read_only["read_only_ok"]:
            failures.append("DS-0003: --display-sync-status modified live DB/local state or left temporary DB files")

        delta_links_after_scoped_status = self._read_nonempty_delta_links(live_database)
        details["ds0003_delta_links_after_scoped_status"] = delta_links_after_scoped_status
        if delta_links_after_scoped_status != delta_links_before_actor:
            failures.append("DS-0003: --single-directory status changed the persisted delta cursor")

        # DS-0003B: use the same evaluated client and its persisted pre-mutation delta
        # cursor, but omit --single-directory so Graph returns the genuine incremental
        # deletion tombstone. sync_list keeps the assessment limited to the TC0079 tree.
        delta_status_command = [
            context.onedrive_bin,
            "--display-sync-status",
            "--verbose",
            "--confdir",
            str(conf_main),
        ]
        delta_remote_result, delta_remote_read_only = self._run_status_and_validate_read_only(
            context,
            label="DS-0003B incremental delta tombstone status",
            command=delta_status_command,
            stdout_file=delta_remote_stdout,
            stderr_file=delta_remote_stderr,
            sync_root=main_root,
            live_database=live_database,
            dry_run_database=dry_run_database,
        )
        delta_remote_output = f"{delta_remote_result.stdout}\n{delta_remote_result.stderr}"
        details["ds0003b_returncode"] = delta_remote_result.returncode
        details["ds0003b_read_only"] = delta_remote_read_only
        delta_links_after_delta_status = self._read_nonempty_delta_links(live_database)
        details["ds0003b_delta_links_after_status"] = delta_links_after_delta_status

        if delta_remote_result.returncode != 0:
            failures.append(f"DS-0003B: delta status command exited with {delta_remote_result.returncode}")
        if "Overall status: NOT IN SYNC" not in delta_remote_output:
            failures.append("DS-0003B: incremental delta divergence did not report 'Overall status: NOT IN SYNC'")
        for label, value in expected_remote_metrics.items():
            if not self._contains_metric(delta_remote_output, label, value):
                failures.append(f"DS-0003B: expected incremental delta metric missing: {label}: {value}")
        if self.MALFORMED_TOMBSTONE_WARNING in delta_remote_output:
            failures.append("DS-0003B: genuine Graph deletion tombstone triggered the historical malformed-JSON warning")
        if delta_links_after_delta_status != delta_links_before_actor:
            failures.append("DS-0003B: --display-sync-status advanced or changed the persisted delta cursor")
        if not delta_remote_read_only["read_only_ok"]:
            failures.append("DS-0003B: incremental delta status assessment was not read-only")

        # DS-0004: add one local change without reconciling the remote changes. The
        # same authoritative scoped remote state must still be visible on a repeated
        # read-only query while the local direction becomes dirty as well.
        write_text_file(main_root / mixed_local_relative, "Z" * 77)
        mixed_result, mixed_read_only = self._run_status_and_validate_read_only(
            context,
            label="DS-0004 mixed local and remote status",
            command=status_command,
            stdout_file=mixed_stdout,
            stderr_file=mixed_stderr,
            sync_root=main_root,
            live_database=live_database,
            dry_run_database=dry_run_database,
        )
        mixed_output = f"{mixed_result.stdout}\n{mixed_result.stderr}"
        details["ds0004_returncode"] = mixed_result.returncode
        details["ds0004_read_only"] = mixed_read_only

        if mixed_result.returncode != 0:
            failures.append(f"DS-0004: status command exited with {mixed_result.returncode}")
        if "Overall status: NOT IN SYNC" not in mixed_output:
            failures.append("DS-0004: mixed divergence did not report 'Overall status: NOT IN SYNC'")
        for label, value in expected_remote_metrics.items():
            if not self._contains_metric(mixed_output, label, value):
                failures.append(
                    f"DS-0004: remote metric did not persist across repeated status query: {label}: {value}"
                )
        expected_mixed_local_metrics = {
            "Pending local items": "1",
            "New local files": "1",
            "Files requiring upload": "1",
            "Approximate upload data": "77 bytes",
        }
        for label, value in expected_mixed_local_metrics.items():
            if not self._contains_metric(mixed_output, label, value):
                failures.append(f"DS-0004: expected local metric missing: {label}: {value}")
        if "When remote changes are also pending" not in mixed_output:
            failures.append("DS-0004: mixed status did not emit the remote/local reconciliation qualification note")
        if self.MALFORMED_TOMBSTONE_WARNING in mixed_output:
            failures.append("DS-0004: repeated deletion tombstone query triggered malformed-JSON warning")
        if not mixed_read_only["read_only_ok"]:
            failures.append("DS-0004: --display-sync-status modified live DB/local state or left temporary DB files")

        final_main_manifest = build_manifest(main_root)
        write_manifest(final_main_manifest_file, final_main_manifest)

        details.update(
            {
                "expected_local_metrics": expected_local_metrics,
                "expected_remote_metrics": expected_remote_metrics,
                "expected_mixed_local_metrics": expected_mixed_local_metrics,
                "baseline_manifest_count": len(baseline_manifest),
                "actor_manifest_count": len(actor_manifest),
                "final_main_manifest_count": len(final_main_manifest),
                "failures": failures,
            }
        )
        self._write_metadata(metadata_file, details)

        if failures:
            return self.fail_result(
                self.case_id,
                self.name,
                "; ".join(failures),
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
