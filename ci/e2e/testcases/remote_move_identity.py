"""Identity evidence for TC0032/TC0033/TC0035 remote rename/move scenarios.

Read a test-owned database only when its OneDrive client is stopped.  This is
not a SQLite audit trigger or a concurrent view of application-owned state.
The fresh independent verifier confirms the identities actually held online.
"""
from __future__ import annotations

import sqlite3
from contextlib import closing
from pathlib import Path

from framework.context import E2EContext
from framework.utils import command_to_string
from testcases.monitor_case_base import MonitorModeTestCaseBase


def snapshot_remote_identities(db_path: Path, root_name: str) -> dict[str, tuple[str, str]]:
    """Reconstruct root-relative paths from the stopped client's tracked items."""
    if not db_path.is_file():
        raise RuntimeError(f"No completed OneDrive database to inspect: {db_path}")
    with closing(sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)) as database:
        rows = database.execute(
            "SELECT driveId, id, parentId, name FROM item"
        ).fetchall()

    items = [tuple("" if field is None else str(field) for field in row) for row in rows]
    roots = [row for row in items if row[3] == root_name]
    if len(roots) != 1:
        raise RuntimeError(f"Expected one tracked {root_name!r} root, found {len(roots)}")

    children: dict[tuple[str, str], list[tuple[str, str, str, str]]] = {}
    for row in items:
        children.setdefault((row[0], row[2]), []).append(row)

    result: dict[str, tuple[str, str]] = {}
    visited: set[tuple[str, str]] = set()

    def visit(item: tuple[str, str, str, str], relative: str) -> None:
        key = (item[0], item[1])
        if key in visited or relative in result:
            raise RuntimeError(f"Cyclic or duplicate tracked remote path: {relative}")
        visited.add(key)
        result[relative] = key
        for child in children.get(key, []):
            visit(child, f"{relative}/{child[3]}")

    visit(roots[0], root_name)
    return result


def check_remote_identity_transition(
    before: dict[str, tuple[str, str]],
    after: dict[str, tuple[str, str]],
    verified: dict[str, tuple[str, str]],
    paths: list[tuple[str, str]],
    *,
    preserve_identity: bool,
) -> list[str]:
    """Reject an incorrectly named/represented Graph operation, even at equal final paths."""
    if not paths:
        return ["Identity assertion has no mapped objects"]
    errors: list[str] = []
    for old, new in paths:
        original = before.get(old)
        moved = after.get(new)
        remote = verified.get(new)
        if not original or not moved or not remote:
            errors.append(f"Missing tracked Graph identity: {old} -> {new}")
            continue
        if old in after or old in verified or new in before:
            errors.append(f"Old/new Graph paths did not transition cleanly: {old} -> {new}")
        if moved != remote:
            errors.append(f"Mutator and independent remote verifier disagree on Graph identity: {new}")
        if (original == moved) != preserve_identity:
            errors.append(
                f"Unexpected Graph identity {'replacement' if preserve_identity else 'preservation'}: "
                f"{old} -> {new} ({original} -> {moved})"
            )
    return errors


class MonitoredRemoteMoveCase(MonitorModeTestCaseBase):
    """Reuse established inotify/Graph PATCH evidence without changing the client."""

    def _move_existing_items_online(
        self,
        context: E2EContext,
        *,
        config_dir: Path,
        sync_root: Path,
        root_name: str,
        moves: list[tuple[str, str]],
        stdout_file: Path,
        stderr_file: Path,
        details: dict[str, object],
    ) -> str | None:
        command = [
            context.onedrive_bin, "--display-running-config", "--monitor", "--upload-only",
            "--verbose", "--verbose", "--single-directory", root_name,
            "--confdir", str(config_dir),
        ]
        details["monitor_mutator_command"] = command_to_string(command)
        context.log(f"Executing TC{self.case_id} monitored mutator: {command_to_string(command)}")
        monitor, initially_ready = self._launch_monitor_process(
            context, command, stdout_file, stderr_file, startup_timeout_seconds=300,
        )
        details["monitor_mutator_initial_sync_complete"] = initially_ready
        try:
            if not initially_ready:
                return "Monitor mutator did not complete its initial synchronisation"
            offset = self._prepare_monitor_for_local_mutation(monitor, stdout_file, details)
            if not details.get("monitor_ready_after_initial_sync"):
                return "Monitor mutator was not ready for inotify mutations"
            observed: list[str] = []
            for old, new in moves:
                source = sync_root / old
                destination = sync_root / new
                destination.parent.mkdir(parents=True, exist_ok=True)
                if not source.exists() or destination.exists():
                    return f"Invalid pre-move filesystem state: {old} -> {new}"
                source.rename(destination)
                ok, _segment = self._wait_for_stdout_growth_patterns(
                    stdout_file,
                    start_offset=offset,
                    required_patterns=[
                        f"[M] Local item moved: ./{old} -> ./{new}",
                        f"Moving ./{old} to ./{new}",
                    ],
                    timeout_seconds=180,
                )
                if not ok:
                    return f"Monitor did not confirm the inotify and Graph move transaction: {old} -> {new}"
                observed.append(f"{old} -> {new}")
                if monitor.poll() is not None:
                    return f"Monitor exited during move processing: {old} -> {new}"
            details["monitor_confirmed_move_paths"] = observed
            return None
        finally:
            self._shutdown_monitor_process(monitor, details)
