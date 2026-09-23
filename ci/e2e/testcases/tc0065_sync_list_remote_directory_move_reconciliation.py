from __future__ import annotations

import os
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.xlsx import REVISION_0, REVISION_1, create_random_xlsx_pair, mutate_xlsx_pair_revision, validate_xlsx_pair, large_xlsx_relative, unlink_xlsx_pair
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


@dataclass(frozen=True)
class ScenarioSpec:
    scenario_id: str
    description: str
    movement: str
    validator_mode: str
    full_lifecycle: bool = False


class TestCase0065SyncListRemoteDirectoryMoveReconciliation(MonitorModeTestCaseBase):
    """
    Test Case 0065: sync_list remote directory move reconciliation

    Regression coverage for the selective-sync directory-move defect where
    sync_list filtering could create a destination directory and overwrite an
    existing directory's database parent before normal changed-item processing
    compared the old and new paths.

    IMPORTANT TEST-STIMULUS RULE
    ----------------------------
    A standalone --sync after a local directory rename/move is not a valid
    remote-move stimulus for this testcase.  It can be processed as a local
    delete followed by creation/upload, yielding a new remote item ID.  That
    does not exercise the existing-ID reconciliation path fixed by this PR.

    The established E2E pattern used by TC0060/TC0061 is therefore used here:
      * seed the mutator normally;
      * keep its items.sqlite3;
      * run the mutator in --monitor mode;
      * perform the local rename/move while monitor is active;
      * require both the [M] Local item moved and Moving old -> new markers;
      * reject delete/re-upload side effects from the mutator move transaction.

    The mutator additionally runs --upload-only, matching the controlled
    reproduction topology used for Issue #3767 while retaining the monitor
    move mechanism already used by the E2E harness.

    The sync_list validator is preloaded before the remote move and keeps the
    same items.sqlite3 for reconciliation.  Reconciliation MUST NOT use
    --resync.

    Coverage matrix:
      S01 - bidirectional sync_list validator, remote parent move
      S02 - bidirectional sync_list validator, remote same-parent rename
      S03 - download-only sync_list validator, remote parent move
      S04 - monitor startup reconciliation using existing sync_list DB state
      S05 - download-only + cleanup-local-files validator, two directory moves,
            post-move modification, whole-directory deletion, files-first
            deletion with retained empty parent, then empty-parent deletion
      S06 - nested remote parent+child rename, download-only + cleanup + sync_list
      S07 - nested remote parent+child rename, bidirectional + sync_list
    """

    case_id = "0065"
    name = "sync_list remote directory move reconciliation"
    description = (
        "Validate that sync_list preserves existing directory identity across remote "
        "moves/renames in bidirectional, download-only and monitor reconciliation modes, "
        "including post-move modification and cleanup deletion lifecycles"
    )

    XLSX_PAYLOAD_ROWS = 32

    BAD_VALIDATOR_MOVE_MARKERS = [
        "The file has been deleted locally",
        "Deleted local items to delete on Microsoft OneDrive:",
        "Deleting item from Microsoft OneDrive:",
        "New directories to create on Microsoft OneDrive:",
        "New items to upload to Microsoft OneDrive:",
        "Uploading new file:",
        "Uploading changed file:",
        "Uploading modified file:",
        "OneDrive Client requested to create this directory online:",
    ]

    BAD_MUTATOR_MOVE_MARKERS = [
        "Trying to delete this item as requested:",
        "The local item has been deleted:",
        "Deleted local items to delete on Microsoft OneDrive:",
        "Deleting item from Microsoft OneDrive:",
        "New directories to create on Microsoft OneDrive:",
        "New items to upload to Microsoft OneDrive:",
        "Uploading new file:",
    ]

    def _scenarios(self) -> list[ScenarioSpec]:
        return [
            ScenarioSpec(
                scenario_id="S01_bidirectional_parent_move",
                description=(
                    "Bidirectional sync_list validator reconciles an existing directory "
                    "moved from incoming/ to moved/ without delete/re-upload side effects"
                ),
                movement="parent_move",
                validator_mode="bidirectional",
            ),
            ScenarioSpec(
                scenario_id="S02_bidirectional_same_parent_rename",
                description=(
                    "Bidirectional sync_list validator reconciles an existing directory "
                    "rename within the same parent while preserving the remote item ID"
                ),
                movement="same_parent_rename",
                validator_mode="bidirectional",
            ),
            ScenarioSpec(
                scenario_id="S03_download_only_parent_move",
                description=(
                    "Download-only sync_list validator reconciles an existing directory "
                    "move through the normal move path rather than reconstructing children"
                ),
                movement="parent_move",
                validator_mode="download_only",
            ),
            ScenarioSpec(
                scenario_id="S04_monitor_reconcile_parent_move",
                description=(
                    "A sync_list validator with existing DB/local state starts --monitor "
                    "after the remote move and reconciles the existing directory during "
                    "the monitor initial sync without delete/re-upload side effects"
                ),
                movement="parent_move",
                validator_mode="monitor_bidirectional",
            ),
            ScenarioSpec(
                scenario_id="S05_download_only_cleanup_mixed_lifecycle",
                description=(
                    "Download-only + cleanup-local-files sync_list validator handles two "
                    "real remote directory moves, post-move modifications, whole-directory "
                    "deletion, files-first empty-parent retention, and later parent deletion"
                ),
                movement="parent_move",
                validator_mode="download_only_cleanup",
                full_lifecycle=True,
            ),
            ScenarioSpec(
                scenario_id="S06_download_only_cleanup_nested_rename",
                description=(
                    "An inactive download-only + cleanup-local-files sync_list observer "
                    "reconciles a parent and nested child both renamed remotely before one sync"
                ),
                movement="nested_rename",
                validator_mode="download_only_cleanup",
            ),
            ScenarioSpec(
                scenario_id="S07_bidirectional_nested_rename",
                description=(
                    "An inactive bidirectional sync_list observer reconciles a parent and "
                    "nested child both renamed remotely before one sync"
                ),
                movement="nested_rename",
                validator_mode="bidirectional",
            ),
        ]

    def _simple_config_text(self, sync_root: Path, *, label: str, preserve_data: bool = False) -> str:
        return (
            f"# tc0065 {label} config\n"
            f'sync_dir = "{sync_root}"\n'
            f'bypass_data_preservation = "{str(not preserve_data).lower()}"\n'
        )

    def _prepare_client_config(
        self,
        context: E2EContext,
        config_dir: Path,
        sync_root: Path,
        *,
        label: str,
        sync_list_root_name: str | None = None,
        monitor_app_log_dir: Path | None = None,
        preserve_data: bool = False,
    ) -> None:
        if monitor_app_log_dir is None:
            config_text = self._simple_config_text(sync_root, label=label, preserve_data=preserve_data)
        else:
            config_text = self._build_config_text(sync_root, monitor_app_log_dir)

        context.prepare_minimal_config_dir(config_dir, config_text)
        if sync_list_root_name is not None:
            write_text_file(config_dir / "sync_list", f"/{sync_list_root_name}\n")

    def _run_phase(
        self,
        *,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
        details: dict[str, object],
    ):
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        details[f"{label}_returncode"] = result.returncode
        details[f"{label}_command"] = command_to_string(command)
        return result

    def _combined_output(self, stdout_file: Path, stderr_file: Path) -> str:
        stdout = stdout_file.read_text(encoding="utf-8", errors="replace") if stdout_file.exists() else ""
        stderr = stderr_file.read_text(encoding="utf-8", errors="replace") if stderr_file.exists() else ""
        return stdout + "\n" + stderr

    def _contains_move(self, output: str, source_relative: str, destination_relative: str) -> bool:
        pattern = re.compile(
            r"Moving\s+(?:\./)?"
            + re.escape(source_relative)
            + r"\s+to\s+(?:\./)?"
            + re.escape(destination_relative)
        )
        return pattern.search(output) is not None

    def _contains_monitor_move_pair(
        self,
        output: str,
        source_relative: str,
        destination_relative: str,
    ) -> bool:
        inotify_marker = (
            f"[M] Local item moved: ./{source_relative} -> ./{destination_relative}"
        )
        return inotify_marker in output and self._contains_move(
            output, source_relative, destination_relative
        )

    def _destination_precreation_seen(self, output: str, destination_relative: str) -> bool:
        candidates = [
            f"Attempting to create local directory: ./{destination_relative}",
            f"Attempting to create local directory: {destination_relative}",
        ]
        return any(candidate in output for candidate in candidates)

    def _bad_validator_move_markers(self, output: str) -> list[str]:
        return [marker for marker in self.BAD_VALIDATOR_MOVE_MARKERS if marker in output]

    def _bad_mutator_move_markers(self, output: str) -> list[str]:
        return [marker for marker in self.BAD_MUTATOR_MOVE_MARKERS if marker in output]

    def _sync_list_active(self, output: str, root_name: str) -> bool:
        return "Selective sync 'sync_list' configured" in output and root_name in output

    def _validator_mode_active(self, output: str, validator_mode: str) -> bool:
        download_only_true = re.search(r"Config option 'download_only'\s*=\s*true", output) is not None
        download_only_false = re.search(r"Config option 'download_only'\s*=\s*false", output) is not None
        cleanup_true = re.search(r"Config option 'cleanup_local_files'\s*=\s*true", output) is not None
        cleanup_false = re.search(r"Config option 'cleanup_local_files'\s*=\s*false", output) is not None

        if validator_mode == "download_only":
            return download_only_true and cleanup_false
        if validator_mode == "download_only_cleanup":
            return download_only_true and cleanup_true
        if validator_mode in {"bidirectional", "monitor_bidirectional"}:
            return download_only_false
        return False

    def _mutator_upload_only_active(self, output: str) -> bool:
        return re.search(r"Config option 'upload_only'\s*=\s*true", output) is not None

    def _file_map(self, root: Path) -> dict[str, str]:
        if not root.exists():
            return {}
        result: dict[str, str] = {}
        for path in sorted(root.rglob("*")):
            if path.is_file():
                result[path.relative_to(root).as_posix()] = path.read_text(
                    encoding="utf-8", errors="replace"
                )
        return result

    def _tree_matches(
        self,
        *,
        root: Path,
        expected_files: dict[str, str],
        required_dirs: list[str],
        forbidden_paths: list[str],
    ) -> list[str]:
        failures: list[str] = []

        for relative, expected_content in expected_files.items():
            path = root / relative
            if not path.is_file():
                failures.append(f"missing expected file: {relative}")
                continue
            actual = path.read_text(encoding="utf-8", errors="replace")
            if actual != expected_content:
                failures.append(f"content mismatch: {relative}")

        for relative in required_dirs:
            if not (root / relative).is_dir():
                failures.append(f"missing expected directory: {relative}")

        for relative in forbidden_paths:
            if (root / relative).exists():
                failures.append(f"forbidden stale path still exists: {relative}")

        return failures

    def _seed_upload_command(
        self,
        context: E2EContext,
        *,
        root_name: str,
        conf_dir: Path,
    ) -> list[str]:
        # Creation is a valid one-shot upload-only operation.  Only the later
        # rename/move must be generated by monitor/inotify.
        return [
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
            str(conf_dir),
        ]

    def _mutator_monitor_command(
        self,
        context: E2EContext,
        *,
        root_name: str,
        conf_dir: Path,
    ) -> list[str]:
        # This is the critical TC0060/TC0061-style stimulus path.  The mutator
        # keeps its DB and monitor/inotify processes the local move as a real
        # move of the existing remote item ID.  --upload-only matches the
        # controlled Issue #3767 reproduction topology.
        return [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--upload-only",
            "--verbose",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_dir),
        ]

    def _validator_initial_command(
        self,
        context: E2EContext,
        *,
        conf_dir: Path,
    ) -> list[str]:
        # Deliberately no --single-directory: sync_list itself must select the
        # testcase tree, otherwise checkJSONAgainstClientSideFiltering() is not
        # the active filtering path.
        return [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--confdir",
            str(conf_dir),
        ]

    def _validator_reconcile_command(
        self,
        context: E2EContext,
        *,
        conf_dir: Path,
        validator_mode: str,
    ) -> list[str]:
        # CRITICAL: never add --resync here.  The regression requires the
        # validator's pre-move items.sqlite3 state to remain intact.
        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
        ]
        if validator_mode in {"download_only", "download_only_cleanup"}:
            command.append("--download-only")
        if validator_mode == "download_only_cleanup":
            command.append("--cleanup-local-files")
        command.extend(["--confdir", str(conf_dir)])
        return command

    def _validator_monitor_command(
        self,
        context: E2EContext,
        *,
        conf_dir: Path,
    ) -> list[str]:
        # No --single-directory: sync_list must remain the selector.
        # No --resync: existing DB state is the essence of the regression.
        return [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--verbose",
            "--confdir",
            str(conf_dir),
        ]

    def _verify_command(
        self,
        context: E2EContext,
        *,
        root_name: str,
        conf_dir: Path,
    ) -> list[str]:
        return [
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
            str(conf_dir),
        ]

    def _create_common_fixture(
        self,
        mutator_root: Path,
        *,
        root_name: str,
        source_name: str,
    ) -> dict[str, str]:
        files = {
            f"{root_name}/incoming/{source_name}/top-level.txt": "TC0065 top-level payload\n",
            f"{root_name}/incoming/{source_name}/Nested/child.txt": "TC0065 nested child payload\n",
            f"{root_name}/incoming/{source_name}/Nested/Deep/grandchild.txt": "TC0065 deep child payload\n",
            f"{root_name}/incoming/{source_name}/sibling.txt": "TC0065 sibling payload\n",
            f"{root_name}/moved/anchor.txt": "TC0065 destination parent anchor\n",
        }
        for relative, content in files.items():
            write_text_file(mutator_root / relative, content)
        xlsx_relative = f"{root_name}/incoming/{source_name}/top-level.xlsx"
        create_random_xlsx_pair(
            mutator_root / xlsx_relative,
            f"{root_name}:{source_name}:xlsx",
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0065 sync_list moved-directory workbook",
        )
        (mutator_root / root_name / "incoming" / source_name / "EmptyChild").mkdir(
            parents=True, exist_ok=True
        )
        return files

    def _launch_ready_mutator_monitor(
        self,
        *,
        context: E2EContext,
        root_name: str,
        conf_mutator: Path,
        monitor_stdout: Path,
        monitor_stderr: Path,
        details: dict[str, object],
    ):
        monitor_command = self._mutator_monitor_command(
            context,
            root_name=root_name,
            conf_dir=conf_mutator,
        )
        context.log(
            f"Executing Test Case {self.case_id} mutator monitor: "
            f"{command_to_string(monitor_command)}"
        )
        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            monitor_stdout,
            monitor_stderr,
            startup_timeout_seconds=300,
        )
        details["mutator_monitor_initial_sync_complete"] = initial_sync_complete
        details["mutator_monitor_command"] = command_to_string(monitor_command)
        return process, initial_sync_complete

    def _run_mutator_move_transaction(
        self,
        *,
        process,
        monitor_stdout: Path,
        details: dict[str, object],
        moves: list[tuple[Path, Path, str, str]],
        detail_prefix: str,
    ) -> tuple[bool, str]:
        start_offset = self._prepare_monitor_for_local_mutation(
            process,
            monitor_stdout,
            details,
            quiet_seconds=3.0,
            timeout_seconds=30,
        )
        if not details.get("monitor_ready_after_initial_sync", False):
            return False, ""

        required_patterns: list[str] = []
        completion_patterns: list[str] = []
        for source_path, destination_path, source_relative, destination_relative in moves:
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.rename(destination_path)
            required_patterns.extend(
                [
                    f"[M] Local item moved: ./{source_relative} -> ./{destination_relative}",
                    f"Moving ./{source_relative} to ./{destination_relative}",
                ]
            )

            # The human-readable "Moving old -> new" marker is emitted before
            # the Graph GET/PATCH transaction has completed.  Do not let the
            # validator race the mutator by treating that marker as proof that
            # the move is already visible online.  The debug DB-save record is
            # emitted only after the successful PATCH response has been parsed,
            # so waiting for the moved directory's saved Item record provides
            # deterministic evidence that each remote move transaction finished.
            completion_patterns.append(
                f'"{destination_path.name}", "", dir,'
            )

        processed, segment = self._wait_for_stdout_growth_patterns(
            monitor_stdout,
            start_offset=start_offset,
            required_patterns=required_patterns + completion_patterns,
            timeout_seconds=180,
        )
        details[f"{detail_prefix}_required_patterns"] = required_patterns
        details[f"{detail_prefix}_completion_patterns"] = completion_patterns
        details[f"{detail_prefix}_processed"] = processed
        details[f"{detail_prefix}_bad_markers"] = self._bad_mutator_move_markers(segment)
        details[f"{detail_prefix}_log_segment_length"] = len(segment)
        return processed, segment

    def _reconcile_validator(
        self,
        *,
        context: E2EContext,
        scenario: ScenarioSpec,
        conf_validator: Path,
        stdout_file: Path,
        stderr_file: Path,
        details: dict[str, object],
    ) -> tuple[int, str]:
        if scenario.validator_mode != "monitor_bidirectional":
            result = self._run_phase(
                context=context,
                label=f"{scenario.scenario_id}_validator_reconcile",
                command=self._validator_reconcile_command(
                    context,
                    conf_dir=conf_validator,
                    validator_mode=scenario.validator_mode,
                ),
                stdout_file=stdout_file,
                stderr_file=stderr_file,
                details=details,
            )
            return result.returncode, self._combined_output(stdout_file, stderr_file)

        monitor_command = self._validator_monitor_command(
            context,
            conf_dir=conf_validator,
        )
        context.log(
            f"Executing Test Case {self.case_id} {scenario.scenario_id} validator monitor: "
            f"{command_to_string(monitor_command)}"
        )
        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            stdout_file,
            stderr_file,
            startup_timeout_seconds=300,
        )
        details["validator_monitor_initial_sync_complete"] = initial_sync_complete
        details["validator_monitor_command"] = command_to_string(monitor_command)
        try:
            # The remote move already exists when monitor starts.  Its initial
            # sync is therefore the reconciliation event under test.
            output = self._combined_output(stdout_file, stderr_file)
        finally:
            self._shutdown_monitor_process(process, details)
        output = self._combined_output(stdout_file, stderr_file)
        return (0 if initial_sync_complete else 1), output

    def _run_basic_move_scenario(
        self,
        context: E2EContext,
        scenario: ScenarioSpec,
        *,
        scenario_work: Path,
        scenario_logs: Path,
        scenario_state: Path,
    ) -> tuple[list[str], list[str], dict[str, object]]:
        mutator_root = scenario_work / "mutator-root"
        validator_root = scenario_work / "validator-root"
        verify_root = scenario_work / "verify-root"
        conf_mutator = scenario_work / "conf-mutator"
        conf_validator = scenario_work / "conf-validator"
        conf_verify = scenario_work / "conf-verify"
        mutator_app_logs = scenario_logs / "app-logs"
        validator_app_logs = scenario_logs / "validator-app-logs"

        for path in [mutator_root, validator_root, verify_root]:
            reset_directory(path)

        root_name = f"ZZ_E2E_TC0065_{scenario.scenario_id}_{context.run_id}_{os.getpid()}"
        source_name = "GenerationAlpha"
        source_relative = f"{root_name}/incoming/{source_name}"
        if scenario.movement == "same_parent_rename":
            destination_relative = f"{root_name}/incoming/GenerationAlphaRenamed"
        else:
            destination_relative = f"{root_name}/moved/{source_name}"

        self._prepare_client_config(
            context,
            conf_mutator,
            mutator_root,
            label=f"{scenario.scenario_id} mutator",
            monitor_app_log_dir=mutator_app_logs,
        )
        self._prepare_client_config(
            context,
            conf_validator,
            validator_root,
            label=f"{scenario.scenario_id} validator",
            sync_list_root_name=root_name,
            monitor_app_log_dir=(
                validator_app_logs if scenario.validator_mode == "monitor_bidirectional" else None
            ),
        )
        self._prepare_client_config(
            context,
            conf_verify,
            verify_root,
            label=f"{scenario.scenario_id} verify",
        )

        initial_files = self._create_common_fixture(
            mutator_root,
            root_name=root_name,
            source_name=source_name,
        )
        xlsx_source_relative = f"{source_relative}/top-level.xlsx"
        xlsx_destination_relative = xlsx_source_relative.replace(source_relative, destination_relative, 1)

        phase_files = {
            "seed": (
                scenario_logs / "phase1_mutator_seed_stdout.log",
                scenario_logs / "phase1_mutator_seed_stderr.log",
            ),
            "validator_initial": (
                scenario_logs / "phase2_validator_initial_stdout.log",
                scenario_logs / "phase2_validator_initial_stderr.log",
            ),
            "mutator_monitor": (
                scenario_logs / "phase3_mutator_monitor_stdout.log",
                scenario_logs / "phase3_mutator_monitor_stderr.log",
            ),
            "validator_reconcile": (
                scenario_logs / "phase4_validator_reconcile_stdout.log",
                scenario_logs / "phase4_validator_reconcile_stderr.log",
            ),
            "verify": (
                scenario_logs / "phase5_remote_truth_verify_stdout.log",
                scenario_logs / "phase5_remote_truth_verify_stderr.log",
            ),
        }

        validator_manifest_file = scenario_state / "validator_manifest.txt"
        verify_manifest_file = scenario_state / "remote_truth_manifest.txt"
        metadata_file = scenario_state / "metadata.txt"
        artifacts = [
            *(str(path) for pair in phase_files.values() for path in pair),
            str(conf_validator / "sync_list"),
            str(mutator_app_logs),
            str(validator_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]
        if scenario.validator_mode == "monitor_bidirectional":
            artifacts.append(str(validator_app_logs))

        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id,
            "description": scenario.description,
            "root_name": root_name,
            "movement": scenario.movement,
            "validator_mode": scenario.validator_mode,
            "source_relative": source_relative,
            "destination_relative": destination_relative,
            "xlsx_source_relative": xlsx_source_relative,
            "xlsx_destination_relative": xlsx_destination_relative,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "mutator_items_db": str(conf_mutator / "items.sqlite3"),
            "validator_items_db": str(conf_validator / "items.sqlite3"),
            "sync_list": [f"/{root_name}"],
        }
        failures: list[str] = []

        seed_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase1_seed",
            command=self._seed_upload_command(
                context,
                root_name=root_name,
                conf_dir=conf_mutator,
            ),
            stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1],
            details=details,
        )
        if seed_result.returncode != 0:
            failures.append(f"mutator seed failed with status {seed_result.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details
        details["mutator_items_db_exists_after_seed"] = (conf_mutator / "items.sqlite3").is_file()
        if not details["mutator_items_db_exists_after_seed"]:
            failures.append("mutator seed did not preserve items.sqlite3")

        initial_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase2_validator_initial",
            command=self._validator_initial_command(context, conf_dir=conf_validator),
            stdout_file=phase_files["validator_initial"][0],
            stderr_file=phase_files["validator_initial"][1],
            details=details,
        )
        if initial_result.returncode != 0:
            failures.append(
                f"validator initial sync_list download failed with status {initial_result.returncode}"
            )
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        initial_output = self._combined_output(*phase_files["validator_initial"])
        details["sync_list_active_during_initial"] = self._sync_list_active(initial_output, root_name)
        details["validator_initial_download_only_active"] = self._validator_mode_active(
            initial_output, "download_only"
        )
        details["validator_items_db_exists_after_initial"] = (conf_validator / "items.sqlite3").is_file()
        if not details["sync_list_active_during_initial"]:
            failures.append("validator initial phase did not prove sync_list was active")
        if not details["validator_initial_download_only_active"]:
            failures.append("validator initial phase did not prove download-only preload mode was active")
        if not details["validator_items_db_exists_after_initial"]:
            failures.append("validator initial phase did not preserve items.sqlite3")

        failures.extend(
            f"initial validator tree: {item}"
            for item in self._tree_matches(
                root=validator_root,
                expected_files=initial_files,
                required_dirs=[
                    source_relative,
                    f"{source_relative}/Nested",
                    f"{source_relative}/Nested/Deep",
                    f"{source_relative}/EmptyChild",
                    f"{root_name}/moved",
                ],
                forbidden_paths=[destination_relative],
            )
        )
        initial_xlsx_error = validate_xlsx_pair(validator_root / xlsx_source_relative, REVISION_0)
        details["validator_initial_xlsx_validation_error"] = initial_xlsx_error
        if initial_xlsx_error:
            failures.append(f"initial validator XLSX invalid: {initial_xlsx_error}")

        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        process, mutator_monitor_ready = self._launch_ready_mutator_monitor(
            context=context,
            root_name=root_name,
            conf_mutator=conf_mutator,
            monitor_stdout=phase_files["mutator_monitor"][0],
            monitor_stderr=phase_files["mutator_monitor"][1],
            details=details,
        )
        try:
            if not mutator_monitor_ready:
                failures.append("mutator monitor did not complete its initial sync")
            else:
                monitor_initial_output = self._combined_output(*phase_files["mutator_monitor"])
                if not self._mutator_upload_only_active(monitor_initial_output):
                    failures.append("mutator monitor did not prove --upload-only was active")

                source_path = mutator_root / source_relative
                destination_path = mutator_root / destination_relative
                if not source_path.is_dir():
                    failures.append(f"mutator source directory missing before move: {source_relative}")
                else:
                    processed, move_segment = self._run_mutator_move_transaction(
                        process=process,
                        monitor_stdout=phase_files["mutator_monitor"][0],
                        details=details,
                        moves=[
                            (
                                source_path,
                                destination_path,
                                source_relative,
                                destination_relative,
                            )
                        ],
                        detail_prefix="mutator_move",
                    )
                    if not processed:
                        failures.append(
                            "mutator monitor did not log the established [M] Local item moved + Moving old -> new transaction"
                        )
                    if details.get("mutator_move_bad_markers"):
                        failures.append(
                            "mutator monitor degraded the move into delete/re-upload side effects: "
                            + ", ".join(details["mutator_move_bad_markers"])
                        )
                    details["mutator_real_move_logged"] = self._contains_monitor_move_pair(
                        move_segment,
                        source_relative,
                        destination_relative,
                    )
        finally:
            self._shutdown_monitor_process(process, details)

        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        reconcile_returncode, reconcile_output = self._reconcile_validator(
            context=context,
            scenario=scenario,
            conf_validator=conf_validator,
            stdout_file=phase_files["validator_reconcile"][0],
            stderr_file=phase_files["validator_reconcile"][1],
            details=details,
        )
        if reconcile_returncode != 0:
            failures.append("validator reconciliation did not complete successfully")

        details["sync_list_active_during_reconcile"] = self._sync_list_active(
            reconcile_output, root_name
        )
        details["validator_mode_active_during_reconcile"] = self._validator_mode_active(
            reconcile_output, scenario.validator_mode
        )
        details["validator_real_move_logged"] = self._contains_move(
            reconcile_output,
            source_relative,
            destination_relative,
        )
        details["destination_precreation_seen"] = self._destination_precreation_seen(
            reconcile_output,
            destination_relative,
        )
        details["validator_bad_move_markers"] = self._bad_validator_move_markers(
            reconcile_output
        )

        if not details["sync_list_active_during_reconcile"]:
            failures.append("validator reconciliation did not prove sync_list was active")
        if not details["validator_mode_active_during_reconcile"]:
            failures.append(
                f"validator reconciliation did not prove requested mode was active: {scenario.validator_mode}"
            )
        if not details["validator_real_move_logged"]:
            failures.append(
                "validator did not reconcile the existing directory through the real Moving old -> new path"
            )
        if details["destination_precreation_seen"]:
            failures.append(
                "validator pre-created the moved/renamed destination directory before normal move handling"
            )
        if details["validator_bad_move_markers"]:
            failures.append(
                "validator logged move-regression side effects: "
                + ", ".join(details["validator_bad_move_markers"])
            )

        expected_after_move: dict[str, str] = {}
        for relative, content in initial_files.items():
            if relative.startswith(source_relative + "/"):
                expected_after_move[
                    relative.replace(source_relative, destination_relative, 1)
                ] = content
            else:
                expected_after_move[relative] = content

        failures.extend(
            f"validator after move: {item}"
            for item in self._tree_matches(
                root=validator_root,
                expected_files=expected_after_move,
                required_dirs=[
                    destination_relative,
                    f"{destination_relative}/Nested",
                    f"{destination_relative}/Nested/Deep",
                    f"{destination_relative}/EmptyChild",
                ],
                forbidden_paths=[source_relative],
            )
        )
        validator_xlsx_error = validate_xlsx_pair(validator_root / xlsx_destination_relative, REVISION_0)
        details["validator_moved_xlsx_validation_error"] = validator_xlsx_error
        if validator_xlsx_error:
            failures.append(f"validator moved XLSX invalid: {validator_xlsx_error}")

        verify_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase5_verify",
            command=self._verify_command(
                context,
                root_name=root_name,
                conf_dir=conf_verify,
            ),
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
            details=details,
        )
        if verify_result.returncode != 0:
            failures.append(f"remote truth verification failed with status {verify_result.returncode}")

        validator_manifest = build_manifest(validator_root)
        verify_manifest = build_manifest(verify_root)
        write_manifest(validator_manifest_file, validator_manifest)
        write_manifest(verify_manifest_file, verify_manifest)
        details["validator_manifest"] = validator_manifest
        details["verify_manifest"] = verify_manifest

        failures.extend(
            f"remote truth after validator reconcile: {item}"
            for item in self._tree_matches(
                root=verify_root,
                expected_files=expected_after_move,
                required_dirs=[
                    destination_relative,
                    f"{destination_relative}/Nested",
                    f"{destination_relative}/Nested/Deep",
                    f"{destination_relative}/EmptyChild",
                ],
                forbidden_paths=[source_relative],
            )
        )
        verify_xlsx_error = validate_xlsx_pair(verify_root / xlsx_destination_relative, REVISION_0)
        details["verify_moved_xlsx_validation_error"] = verify_xlsx_error
        if verify_xlsx_error:
            failures.append(f"remote truth moved XLSX invalid: {verify_xlsx_error}")

        self._write_metadata(metadata_file, details)
        return failures, artifacts, details

    @staticmethod
    def _remap_nested_path(relative: str, renames: list[tuple[str, str]]) -> str:
        """Apply parent then child rename to a path, including directory-manifest suffixes."""
        for source, destination in renames:
            if relative == source or relative.startswith(source + "/"):
                relative = destination + relative[len(source):]
        return relative

    @staticmethod
    def _nested_bad_rename_errors(output: str) -> list[str]:
        return [
            line.strip()
            for line in output.splitlines()
            if ("safeRename" in line and re.search(r"fail|error", line, re.IGNORECASE))
            or re.search(r"(?:unable|failed) to (?:move|rename) local", line, re.IGNORECASE)
        ]

    @staticmethod
    def _nested_safe_backups(root: Path) -> list[str]:
        return sorted(
            path.relative_to(root).as_posix()
            for path in root.rglob("*")
            if path.is_file() and "-safeBackup-" in path.name
        )

    def _run_nested_rename_scenario(
        self,
        context: E2EContext,
        scenario: ScenarioSpec,
        *,
        scenario_work: Path,
        scenario_logs: Path,
        scenario_state: Path,
    ) -> tuple[list[str], list[str], dict[str, object]]:
        """Discussion #3886: BOTH existing-ID remote renames precede observer sync."""
        mutator_root = scenario_work / "mutator-root"
        validator_root = scenario_work / "validator-root"
        before_verify_root = scenario_work / "before-verify-root"
        verify_root = scenario_work / "verify-root"
        conf_mutator = scenario_work / "conf-mutator"
        conf_validator = scenario_work / "conf-validator"
        conf_before_verify = scenario_work / "conf-before-verify"
        conf_verify = scenario_work / "conf-verify"
        mutator_app_logs = scenario_logs / "app-logs"
        for root in (mutator_root, validator_root, before_verify_root, verify_root):
            reset_directory(root)

        root_name = f"ZZ_E2E_TC0065_{scenario.scenario_id}_{context.run_id}_{os.getpid()}"
        parent_source = f"{root_name}/incoming/GenerationAlpha"
        parent_destination = f"{root_name}/incoming/GenerationAlphaRenamed"
        child_source = f"{parent_destination}/Nested"
        child_destination = f"{parent_destination}/NestedRenamed"
        # For the observer, both original paths remain in its old database until
        # BOTH online moves are complete. These two operations are not siblings.
        renames = [(parent_source, parent_destination), (child_source, child_destination)]
        original_child = f"{parent_source}/Nested"
        xlsx_source = f"{parent_source}/top-level.xlsx"
        xlsx_destination = f"{parent_destination}/top-level.xlsx"

        self._prepare_client_config(
            context, conf_mutator, mutator_root,
            label=f"{scenario.scenario_id} mutator", monitor_app_log_dir=mutator_app_logs,
        )
        self._prepare_client_config(
            context, conf_validator, validator_root,
            label=f"{scenario.scenario_id} observer", sync_list_root_name=root_name,
            preserve_data=True,
        )
        for config_dir, root, label in (
            (conf_before_verify, before_verify_root, "before-verify"),
            (conf_verify, verify_root, "final-verify"),
        ):
            self._prepare_client_config(
                context, config_dir, root, label=f"{scenario.scenario_id} {label}"
            )

        initial_files = self._create_common_fixture(
            mutator_root, root_name=root_name, source_name="GenerationAlpha"
        )
        initial_manifest = build_typed_manifest(mutator_root / root_name)
        # Typed manifests are relative to the testcase root, unlike mutation paths.
        root_relative_renames = [
            (source[len(root_name) + 1:], destination[len(root_name) + 1:])
            for source, destination in renames
        ]
        expected_manifest = sorted(
            self._remap_nested_path(path, root_relative_renames) for path in initial_manifest
        )
        expected_files = {
            self._remap_nested_path(path, renames): content for path, content in initial_files.items()
        }
        required_dirs = [
            parent_destination,
            child_destination,
            f"{child_destination}/Deep",
            f"{parent_destination}/EmptyChild",
            f"{root_name}/moved",
        ]
        forbidden_paths = [
            parent_source,
            original_child,
            child_source,
        ]

        phase_names = (
            "seed", "validator_initial", "mutator_monitor", "before_verify",
            "validator_reconcile", "validator_converge", "verify",
        )
        phase_files = {
            phase: (
                scenario_logs / f"{phase}_stdout.log",
                scenario_logs / f"{phase}_stderr.log",
            ) for phase in phase_names
        }
        manifest_paths = {
            label: scenario_state / f"{label}_manifest.txt"
            for label in ("initial", "before_verify", "validator", "verify")
        }
        metadata_file = scenario_state / "metadata.txt"
        artifacts = [
            *(str(path) for pair in phase_files.values() for path in pair),
            *(str(path) for path in manifest_paths.values()),
            str(conf_validator / "sync_list"),
            str(mutator_app_logs),
            str(metadata_file),
        ]
        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id,
            "validator_mode": scenario.validator_mode,
            "root_name": root_name,
            "renames_in_order": renames,
            "initial_observer_path": original_child,
            "xlsx_source": xlsx_source,
            "xlsx_destination": xlsx_destination,
            "expected_manifest": expected_manifest,
            "sync_list": [f"/{root_name}"],
            "observer_data_preservation_enabled": True,
            "observer_remains_inactive_during_both_mutations": True,
        }
        failures: list[str] = []

        def check_tree(label: str, root: Path, *, original: bool = False) -> None:
            if original:
                expected = initial_files
                required = [
                    parent_source, original_child, f"{original_child}/Deep",
                    f"{parent_source}/EmptyChild", f"{root_name}/moved",
                ]
                forbidden = [parent_destination]
                typed_expected = initial_manifest
            else:
                expected, required, forbidden = expected_files, required_dirs, forbidden_paths
                typed_expected = expected_manifest
            failures.extend(
                f"{label}: {error}"
                for error in self._tree_matches(
                    root=root, expected_files=expected,
                    required_dirs=required, forbidden_paths=forbidden,
                )
            )
            manifest = build_typed_manifest(root / root_name)
            if label in manifest_paths:
                write_manifest(manifest_paths[label], manifest)
            details[f"{label}_manifest"] = manifest
            if manifest != typed_expected:
                failures.append(
                    f"{label}: exact typed manifest mismatch: missing "
                    f"{sorted(set(typed_expected) - set(manifest))}; "
                    f"extra {sorted(set(manifest) - set(typed_expected))}"
                )
            xlsx_path = root / (xlsx_source if original else xlsx_destination)
            xlsx_error = validate_xlsx_pair(xlsx_path, REVISION_0)
            details[f"{label}_xlsx_validation_error"] = xlsx_error
            if xlsx_error:
                failures.append(f"{label}: XLSX pair failed structural/revision validation: {xlsx_error}")
            backups = self._nested_safe_backups(root / root_name)
            details[f"{label}_safe_backups"] = backups
            if backups:
                failures.append(f"{label}: unexpected safeBackup files: {backups}")

        # Seed the mutator, then load the observer's original filesystem and DB.
        seed = self._run_phase(
            context=context, label=f"{scenario.scenario_id}_seed",
            command=self._seed_upload_command(
                context, root_name=root_name, conf_dir=conf_mutator
            ), stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1], details=details,
        )
        if seed.returncode != 0:
            failures.append(f"mutator seed failed with status {seed.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        initial = self._run_phase(
            context=context, label=f"{scenario.scenario_id}_observer_initial",
            command=self._validator_initial_command(context, conf_dir=conf_validator),
            stdout_file=phase_files["validator_initial"][0],
            stderr_file=phase_files["validator_initial"][1], details=details,
        )
        initial_output = self._combined_output(*phase_files["validator_initial"])
        if initial.returncode != 0:
            failures.append(f"observer initial sync failed with status {initial.returncode}")
        if not self._sync_list_active(initial_output, root_name):
            failures.append("observer initial sync did not prove sync_list was active")
        if not self._validator_mode_active(initial_output, "download_only"):
            failures.append("observer initial sync did not prove download-only preload")
        if 'bypass_data_preservation = "false"' not in (conf_validator / "config").read_text(encoding="utf-8"):
            failures.append("observer config unexpectedly disables safeBackup preservation")
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details
        check_tree("initial", validator_root, original=True)
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        # Keep the observer's original items.sqlite3. The application owns it;
        # this rename regression checks database existence, application move logs,
        # local hierarchy and fresh independent remote truth, not raw SQLite rows.
        for label, config_dir in (
            ("mutator", conf_mutator), ("observer", conf_validator),
        ):
            exists = (config_dir / "items.sqlite3").is_file()
            details[f"{label}_items_db_exists_after_seed"] = exists
            if not exists:
                failures.append(f"{label} did not establish items.sqlite3 during seed")
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        # CRITICAL: The observer has exited. The separate mutator uses inotify
        # with --monitor --upload-only, and each actual Graph move must finish
        # before the next nested rename starts. Neither observer syncs here.
        process, ready = self._launch_ready_mutator_monitor(
            context=context, root_name=root_name, conf_mutator=conf_mutator,
            monitor_stdout=phase_files["mutator_monitor"][0],
            monitor_stderr=phase_files["mutator_monitor"][1], details=details,
        )
        try:
            if not ready:
                failures.append("mutator monitor did not complete its initial sync")
            elif not self._mutator_upload_only_active(
                self._combined_output(*phase_files["mutator_monitor"])
            ):
                failures.append("mutator monitor did not prove --upload-only was active")
            else:
                for label, source, destination in (
                    ("parent", parent_source, parent_destination),
                    ("child", child_source, child_destination),
                ):
                    if not (mutator_root / source).is_dir() or (mutator_root / destination).exists():
                        failures.append(f"mutator {label} source/destination state invalid before move")
                        break
                    completed, segment = self._run_mutator_move_transaction(
                        process=process,
                        monitor_stdout=phase_files["mutator_monitor"][0],
                        details=details,
                        moves=[(mutator_root / source, mutator_root / destination, source, destination)],
                        detail_prefix=f"mutator_nested_{label}",
                    )
                    details[f"mutator_nested_{label}_existing_item_move_logged"] = (
                        self._contains_monitor_move_pair(segment, source, destination)
                    )
                    if not completed or not details[f"mutator_nested_{label}_existing_item_move_logged"]:
                        failures.append(f"mutator failed to prove completed existing-ID {label} rename")
                    if details[f"mutator_nested_{label}_bad_markers"]:
                        failures.append(
                            f"mutator {label} rename degraded into delete/re-upload: "
                            + repr(details[f"mutator_nested_{label}_bad_markers"])
                        )
                    if failures:
                        break
        finally:
            self._shutdown_monitor_process(process, details)
            details["mutator_monitor_returncode"] = process.returncode
        if details["mutator_monitor_returncode"] not in {0, 130}:
            failures.append(f"mutator monitor unexpected exit: {details['mutator_monitor_returncode']}")
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details
        check_tree("mutator_after", mutator_root)
        details["mutator_items_db_exists_after_renames"] = (
            conf_mutator / "items.sqlite3"
        ).is_file()
        if not details["mutator_items_db_exists_after_renames"]:
            failures.append("mutator lost items.sqlite3 during nested renames")
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        # Independently prove BOTH renames are already online, before the
        # inactive observer receives any remote changes. New confdir and --resync
        # here are solely for this independent verifier, never the observer.
        before_verify = self._run_phase(
            context=context, label=f"{scenario.scenario_id}_before_verify",
            command=self._verify_command(
                context, root_name=root_name, conf_dir=conf_before_verify
            ), stdout_file=phase_files["before_verify"][0],
            stderr_file=phase_files["before_verify"][1], details=details,
        )
        if before_verify.returncode != 0:
            failures.append(f"pre-observer remote verification failed: {before_verify.returncode}")
        else:
            check_tree("before_verify", before_verify_root)
            details["before_verify_items_db_exists"] = (
                conf_before_verify / "items.sqlite3"
            ).is_file()
            if not details["before_verify_items_db_exists"]:
                failures.append("pre-observer independent verifier did not establish items.sqlite3")
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        # The FIRST observer sync must reconcile both pending remote renames.
        reconcile_code, reconcile_output = self._reconcile_validator(
            context=context, scenario=scenario, conf_validator=conf_validator,
            stdout_file=phase_files["validator_reconcile"][0],
            stderr_file=phase_files["validator_reconcile"][1], details=details,
        )
        if reconcile_code != 0:
            failures.append(f"observer first reconciliation failed: {reconcile_code}")
        if not self._sync_list_active(reconcile_output, root_name):
            failures.append("observer first reconciliation did not prove sync_list was active")
        if not self._validator_mode_active(reconcile_output, scenario.validator_mode):
            failures.append("observer first reconciliation did not prove requested mode")
        if not self._contains_move(reconcile_output, parent_source, parent_destination):
            failures.append("observer did not log the existing-ID parent move")
        # Depending on Graph delta ordering, the child may be reported under
        # its original parent or its already-renamed parent. Require the final
        # child destination and an actual move in either permitted ordering.
        child_sources = (original_child, child_source)
        details["observer_child_move_source_variants"] = child_sources
        if not any(
            self._contains_move(reconcile_output, source, child_destination)
            for source in child_sources
        ):
            failures.append("observer did not log the existing-ID nested-child move")
        for destination in (parent_destination, child_destination):
            if self._destination_precreation_seen(reconcile_output, destination):
                failures.append(f"observer pre-created known rename destination: {destination}")
        bad_markers = self._bad_validator_move_markers(reconcile_output)
        details["observer_first_bad_markers"] = bad_markers
        if bad_markers:
            failures.append(f"observer first reconciliation logged destructive feedback: {bad_markers}")
        rename_errors = self._nested_bad_rename_errors(reconcile_output)
        details["observer_first_rename_errors"] = rename_errors
        if rename_errors:
            failures.append(f"observer first reconciliation logged rename errors: {rename_errors}")
        if "-safeBackup-" in reconcile_output:
            failures.append("observer first reconciliation logged an unexpected safeBackup")
        check_tree("validator", validator_root)
        details["observer_items_db_exists_after_first"] = (
            conf_validator / "items.sqlite3"
        ).is_file()
        if not details["observer_items_db_exists_after_first"]:
            failures.append("observer lost its existing items.sqlite3 on first reconciliation")
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        # A second ordinary observer pass must be inert: no latent stale-path
        # re-uploads or delete/recreate feedback from stale database state.
        converge = self._run_phase(
            context=context, label=f"{scenario.scenario_id}_observer_converge",
            command=self._validator_reconcile_command(
                context, conf_dir=conf_validator, validator_mode=scenario.validator_mode,
            ), stdout_file=phase_files["validator_converge"][0],
            stderr_file=phase_files["validator_converge"][1], details=details,
        )
        converge_output = self._combined_output(*phase_files["validator_converge"])
        if converge.returncode != 0:
            failures.append(f"observer convergence pass failed: {converge.returncode}")
        if not self._sync_list_active(converge_output, root_name):
            failures.append("observer convergence pass did not prove sync_list was active")
        if not self._validator_mode_active(converge_output, scenario.validator_mode):
            failures.append("observer convergence pass did not prove requested mode")
        late_bad = self._bad_validator_move_markers(converge_output)
        details["observer_converge_bad_markers"] = late_bad
        if late_bad or "-safeBackup-" in converge_output:
            failures.append(f"observer convergence pass logged unwanted side effects: {late_bad}")
        late_errors = self._nested_bad_rename_errors(converge_output)
        details["observer_converge_rename_errors"] = late_errors
        if late_errors:
            failures.append(f"observer convergence pass logged rename errors: {late_errors}")
        check_tree("validator", validator_root)
        details["observer_items_db_exists_after_converge"] = (
            conf_validator / "items.sqlite3"
        ).is_file()
        if not details["observer_items_db_exists_after_converge"]:
            failures.append("observer lost its existing items.sqlite3 on convergence pass")
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        # Fresh independent client after observer convergence: no stale paths
        # recreated remotely, missing descendants or extra content.
        verify = self._run_phase(
            context=context, label=f"{scenario.scenario_id}_verify",
            command=self._verify_command(
                context, root_name=root_name, conf_dir=conf_verify,
            ), stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1], details=details,
        )
        if verify.returncode != 0:
            failures.append(f"final remote verification failed: {verify.returncode}")
        else:
            check_tree("verify", verify_root)
            details["verify_items_db_exists"] = (conf_verify / "items.sqlite3").is_file()
            if not details["verify_items_db_exists"]:
                failures.append("final independent verifier did not establish items.sqlite3")
        self._write_metadata(metadata_file, details)
        return failures, artifacts, details

    def _run_full_lifecycle_scenario(
        self,
        context: E2EContext,
        scenario: ScenarioSpec,
        *,
        scenario_work: Path,
        scenario_logs: Path,
        scenario_state: Path,
    ) -> tuple[list[str], list[str], dict[str, object]]:
        mutator_root = scenario_work / "mutator-root"
        validator_root = scenario_work / "validator-root"
        verify_root = scenario_work / "verify-root"
        conf_mutator = scenario_work / "conf-mutator"
        conf_validator = scenario_work / "conf-validator"
        conf_verify = scenario_work / "conf-verify"
        mutator_app_logs = scenario_logs / "app-logs"

        for path in [mutator_root, validator_root, verify_root]:
            reset_directory(path)

        root_name = f"ZZ_E2E_TC0065_{scenario.scenario_id}_{context.run_id}_{os.getpid()}"
        whole_name = "GenerationWholeDelete"
        files_first_name = "GenerationFilesFirst"
        whole_source = f"{root_name}/incoming/{whole_name}"
        files_first_source = f"{root_name}/incoming/{files_first_name}"
        whole_destination = f"{root_name}/moved/{whole_name}"
        files_first_destination = f"{root_name}/moved/{files_first_name}"
        anchor_relative = f"{root_name}/moved/anchor.txt"

        self._prepare_client_config(
            context,
            conf_mutator,
            mutator_root,
            label=f"{scenario.scenario_id} mutator",
            monitor_app_log_dir=mutator_app_logs,
        )
        self._prepare_client_config(
            context,
            conf_validator,
            validator_root,
            label=f"{scenario.scenario_id} validator",
            sync_list_root_name=root_name,
        )
        self._prepare_client_config(
            context,
            conf_verify,
            verify_root,
            label=f"{scenario.scenario_id} verify",
        )

        initial_files = {
            f"{whole_source}/file0.txt": "whole file0 initial\n",
            f"{whole_source}/file1.txt": "whole file1 initial\n",
            f"{whole_source}/Nested/child.txt": "whole nested initial\n",
            f"{files_first_source}/file0.txt": "files-first file0 initial\n",
            f"{files_first_source}/file1.txt": "files-first file1 initial\n",
            f"{files_first_source}/Nested/child.txt": "files-first nested initial\n",
            anchor_relative: "TC0065 lifecycle destination anchor\n",
        }
        for relative, content in initial_files.items():
            write_text_file(mutator_root / relative, content)
        whole_xlsx_source = f"{whole_source}/workbook.xlsx"
        files_first_xlsx_source = f"{files_first_source}/workbook.xlsx"
        whole_xlsx_destination = f"{whole_destination}/workbook.xlsx"
        files_first_xlsx_destination = f"{files_first_destination}/workbook.xlsx"
        create_random_xlsx_pair(
            mutator_root / whole_xlsx_source,
            f"{root_name}:whole:xlsx",
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0065 whole-directory lifecycle workbook",
        )
        create_random_xlsx_pair(
            mutator_root / files_first_xlsx_source,
            f"{root_name}:files-first:xlsx",
            revision=REVISION_0,
            payload_rows=self.XLSX_PAYLOAD_ROWS,
            title="TC0065 files-first lifecycle workbook",
        )

        phase_names = [
            "phase1_seed",
            "phase2_validator_initial",
            "phase3_mutator_monitor",
            "phase4_validator_move_reconcile",
            "phase5_validator_postmove_modify_reconcile",
            "phase6_validator_mixed_delete_reconcile",
            "phase7_validator_empty_parent_reconcile",
            "phase8_remote_truth_verify",
        ]
        phase_files = {
            name: (
                scenario_logs / f"{name}_stdout.log",
                scenario_logs / f"{name}_stderr.log",
            )
            for name in phase_names
        }

        validator_manifest_file = scenario_state / "validator_manifest_final.txt"
        verify_manifest_file = scenario_state / "remote_truth_manifest_final.txt"
        metadata_file = scenario_state / "metadata.txt"
        artifacts = [
            *(str(path) for pair in phase_files.values() for path in pair),
            str(conf_validator / "sync_list"),
            str(mutator_app_logs),
            str(validator_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]
        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id,
            "description": scenario.description,
            "root_name": root_name,
            "validator_mode": scenario.validator_mode,
            "whole_source": whole_source,
            "whole_destination": whole_destination,
            "files_first_source": files_first_source,
            "files_first_destination": files_first_destination,
            "whole_xlsx_source": whole_xlsx_source,
            "whole_xlsx_destination": whole_xlsx_destination,
            "files_first_xlsx_source": files_first_xlsx_source,
            "files_first_xlsx_destination": files_first_xlsx_destination,
            "xlsx_payload_rows": self.XLSX_PAYLOAD_ROWS,
            "sync_list": [f"/{root_name}"],
        }
        failures: list[str] = []

        seed_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase1_seed",
            command=self._seed_upload_command(
                context,
                root_name=root_name,
                conf_dir=conf_mutator,
            ),
            stdout_file=phase_files["phase1_seed"][0],
            stderr_file=phase_files["phase1_seed"][1],
            details=details,
        )
        if seed_result.returncode != 0:
            failures.append(f"seed failed with status {seed_result.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        initial_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase2_validator_initial",
            command=self._validator_initial_command(context, conf_dir=conf_validator),
            stdout_file=phase_files["phase2_validator_initial"][0],
            stderr_file=phase_files["phase2_validator_initial"][1],
            details=details,
        )
        if initial_result.returncode != 0:
            failures.append(f"validator initial failed with status {initial_result.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        initial_output = self._combined_output(*phase_files["phase2_validator_initial"])
        if not self._sync_list_active(initial_output, root_name):
            failures.append("validator initial phase did not prove sync_list was active")
        if not self._validator_mode_active(initial_output, "download_only"):
            failures.append("validator initial phase did not prove download-only preload mode was active")
        if not (conf_validator / "items.sqlite3").is_file():
            failures.append("validator initial phase did not preserve items.sqlite3")
        failures.extend(
            f"initial validator tree: {item}"
            for item in self._tree_matches(
                root=validator_root,
                expected_files=initial_files,
                required_dirs=[whole_source, files_first_source, f"{root_name}/moved"],
                forbidden_paths=[whole_destination, files_first_destination],
            )
        )
        for label, relative in (("whole", whole_xlsx_source), ("files_first", files_first_xlsx_source)):
            error = validate_xlsx_pair(validator_root / relative, REVISION_0)
            details[f"validator_initial_{label}_xlsx_validation_error"] = error
            if error:
                failures.append(f"initial validator {label} XLSX invalid: {error}")
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        process, mutator_monitor_ready = self._launch_ready_mutator_monitor(
            context=context,
            root_name=root_name,
            conf_mutator=conf_mutator,
            monitor_stdout=phase_files["phase3_mutator_monitor"][0],
            monitor_stderr=phase_files["phase3_mutator_monitor"][1],
            details=details,
        )

        try:
            if not mutator_monitor_ready:
                failures.append("mutator monitor did not complete its initial sync")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            monitor_initial_output = self._combined_output(*phase_files["phase3_mutator_monitor"])
            if not self._mutator_upload_only_active(monitor_initial_output):
                failures.append("mutator monitor did not prove --upload-only was active")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            # Phase 3: move both DB-known directories in one tight monitor batch.
            move_processed, move_segment = self._run_mutator_move_transaction(
                process=process,
                monitor_stdout=phase_files["phase3_mutator_monitor"][0],
                details=details,
                moves=[
                    (
                        mutator_root / whole_source,
                        mutator_root / whole_destination,
                        whole_source,
                        whole_destination,
                    ),
                    (
                        mutator_root / files_first_source,
                        mutator_root / files_first_destination,
                        files_first_source,
                        files_first_destination,
                    ),
                ],
                detail_prefix="mutator_move_batch",
            )
            if not move_processed:
                failures.append("mutator monitor did not process both real directory moves")
            if details.get("mutator_move_batch_bad_markers"):
                failures.append(
                    "mutator move batch degraded into delete/re-upload side effects: "
                    + ", ".join(details["mutator_move_batch_bad_markers"])
                )
            if failures:
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            move_reconcile = self._run_phase(
                context=context,
                label=f"{scenario.scenario_id}_phase4_validator_move_reconcile",
                command=self._validator_reconcile_command(
                    context,
                    conf_dir=conf_validator,
                    validator_mode=scenario.validator_mode,
                ),
                stdout_file=phase_files["phase4_validator_move_reconcile"][0],
                stderr_file=phase_files["phase4_validator_move_reconcile"][1],
                details=details,
            )
            if move_reconcile.returncode != 0:
                failures.append(f"validator move reconcile failed with status {move_reconcile.returncode}")

            move_output = self._combined_output(*phase_files["phase4_validator_move_reconcile"])
            if not self._sync_list_active(move_output, root_name):
                failures.append("validator move reconcile did not prove sync_list was active")
            if not self._validator_mode_active(move_output, scenario.validator_mode):
                failures.append(
                    f"validator move reconcile did not prove requested mode was active: {scenario.validator_mode}"
                )
            for source, destination in [
                (whole_source, whole_destination),
                (files_first_source, files_first_destination),
            ]:
                if not self._contains_move(move_output, source, destination):
                    failures.append(f"validator did not log real move: {source} -> {destination}")
                if self._destination_precreation_seen(move_output, destination):
                    failures.append(f"validator pre-created move destination: {destination}")
            move_bad = self._bad_validator_move_markers(move_output)
            if move_bad:
                failures.append(
                    "validator move reconcile logged regression side effects: "
                    + ", ".join(move_bad)
                )

            expected_after_move = {
                relative.replace(whole_source, whole_destination, 1)
                .replace(files_first_source, files_first_destination, 1): content
                for relative, content in initial_files.items()
            }
            failures.extend(
                f"validator after move: {item}"
                for item in self._tree_matches(
                    root=validator_root,
                    expected_files=expected_after_move,
                    required_dirs=[whole_destination, files_first_destination],
                    forbidden_paths=[whole_source, files_first_source],
                )
            )
            for label, relative in (("whole", whole_xlsx_destination), ("files_first", files_first_xlsx_destination)):
                error = validate_xlsx_pair(validator_root / relative, REVISION_0)
                details[f"validator_moved_{label}_xlsx_validation_error"] = error
                if error:
                    failures.append(f"validator moved {label} XLSX invalid: {error}")
            if failures:
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            # Phase 5: modify children after the parent moves while the same
            # upload-only monitor remains active.  TC0042-style upload markers
            # prove the changed content was propagated from the moved paths.
            modify_start = self._prepare_monitor_for_local_mutation(
                process,
                phase_files["phase3_mutator_monitor"][0],
                details,
            )
            time.sleep(1.5)
            whole_modified_relative = f"{whole_destination}/file0.txt"
            files_first_modified_relative = f"{files_first_destination}/Nested/child.txt"
            whole_modified_content = "whole file0 post-move modified\n"
            files_first_modified_content = "files-first nested post-move modified\n"
            write_text_file(mutator_root / whole_modified_relative, whole_modified_content)
            write_text_file(mutator_root / files_first_modified_relative, files_first_modified_content)
            mutate_xlsx_pair_revision(
                mutator_root / files_first_xlsx_destination,
                REVISION_0,
                REVISION_1,
            )

            modify_patterns = [
                f"Uploading modified file: ./{whole_modified_relative} ... done",
                f"Uploading modified file: ./{files_first_modified_relative} ... done",
                f"Uploading modified file: ./{files_first_xlsx_destination} ... done",
                f"Uploading modified file: ./{large_xlsx_relative(files_first_xlsx_destination)} ... done",
            ]
            modify_processed, modify_segment = self._wait_for_stdout_growth_patterns(
                phase_files["phase3_mutator_monitor"][0],
                start_offset=modify_start,
                required_patterns=modify_patterns,
                timeout_seconds=180,
            )
            details["mutator_postmove_modify_processed"] = modify_processed
            details["mutator_postmove_modify_patterns"] = modify_patterns
            details["mutator_postmove_modify_log_segment_length"] = len(modify_segment)
            if not modify_processed:
                failures.append("mutator monitor did not propagate both post-move modifications")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            modify_reconcile = self._run_phase(
                context=context,
                label=f"{scenario.scenario_id}_phase5_validator_postmove_modify_reconcile",
                command=self._validator_reconcile_command(
                    context,
                    conf_dir=conf_validator,
                    validator_mode=scenario.validator_mode,
                ),
                stdout_file=phase_files["phase5_validator_postmove_modify_reconcile"][0],
                stderr_file=phase_files["phase5_validator_postmove_modify_reconcile"][1],
                details=details,
            )
            if modify_reconcile.returncode != 0:
                failures.append(
                    f"validator post-move modification reconcile failed with status {modify_reconcile.returncode}"
                )
            expected_after_move[whole_modified_relative] = whole_modified_content
            expected_after_move[files_first_modified_relative] = files_first_modified_content
            failures.extend(
                f"validator after post-move modify: {item}"
                for item in self._tree_matches(
                    root=validator_root,
                    expected_files=expected_after_move,
                    required_dirs=[whole_destination, files_first_destination],
                    forbidden_paths=[whole_source, files_first_source],
                )
            )
            whole_xlsx_error = validate_xlsx_pair(validator_root / whole_xlsx_destination, REVISION_0)
            files_first_xlsx_error = validate_xlsx_pair(validator_root / files_first_xlsx_destination, REVISION_1)
            details["validator_postmodify_whole_xlsx_validation_error"] = whole_xlsx_error
            details["validator_postmodify_files_first_xlsx_validation_error"] = files_first_xlsx_error
            if whole_xlsx_error:
                failures.append(f"validator whole XLSX changed unexpectedly after post-move modification: {whole_xlsx_error}")
            if files_first_xlsx_error:
                failures.append(f"validator files-first XLSX did not receive post-move revision: {files_first_xlsx_error}")
            if failures:
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            # Phase 6: mixed deletion.  Exercise the two established monitor
            # deletion shapes using the same waiting rules as the existing
            # harness rather than imposing a new combined timing contract.
            #
            #  * TC0047: populated directory removal may collapse at different
            #    levels, so accept any one marker from that subtree.
            #  * TC0043: individual file removals wait for their exact remote
            #    deletion marker.
            #
            # The files-first generation keeps its parent directory in place.
            whole_delete_start = self._prepare_monitor_for_local_mutation(
                process,
                phase_files["phase3_mutator_monitor"][0],
                details,
            )
            shutil.rmtree(mutator_root / whole_destination)
            whole_delete_groups = [
                [f"Deleting item from Microsoft OneDrive: ./{whole_destination}"],
                [f"Deleting item from Microsoft OneDrive: ./{whole_destination}/file0.txt"],
                [f"Deleting item from Microsoft OneDrive: ./{whole_destination}/file1.txt"],
                [f"Deleting item from Microsoft OneDrive: ./{whole_destination}/Nested"],
                [f"Deleting item from Microsoft OneDrive: ./{whole_destination}/Nested/child.txt"],
            ]
            whole_delete_processed, whole_delete_group, whole_delete_segment = (
                self._wait_for_any_stdout_growth_pattern_group(
                    phase_files["phase3_mutator_monitor"][0],
                    start_offset=whole_delete_start,
                    alternative_pattern_groups=whole_delete_groups,
                    timeout_seconds=180,
                )
            )
            details["mutator_whole_delete_processed"] = whole_delete_processed
            details["mutator_whole_delete_pattern_groups"] = whole_delete_groups
            details["mutator_whole_delete_matched_group"] = whole_delete_group
            details["mutator_whole_delete_log_segment_length"] = len(whole_delete_segment)
            if not whole_delete_processed:
                failures.append("mutator monitor did not propagate the populated whole-directory deletion")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            files_first_parent = mutator_root / files_first_destination
            files_first_file_results: dict[str, bool] = {}
            for child_name in ["file0.txt", "file1.txt"]:
                child_relative = f"{files_first_destination}/{child_name}"
                child_path = mutator_root / child_relative
                child_delete_start = self._prepare_monitor_for_local_mutation(
                    process,
                    phase_files["phase3_mutator_monitor"][0],
                    details,
                )
                child_path.unlink()
                child_processed, child_segment = self._wait_for_stdout_growth_patterns(
                    phase_files["phase3_mutator_monitor"][0],
                    start_offset=child_delete_start,
                    required_patterns=[f"Deleting item from Microsoft OneDrive: ./{child_relative}"],
                    timeout_seconds=180,
                )
                files_first_file_results[child_relative] = child_processed
                details[f"mutator_files_first_{child_name}_delete_log_segment_length"] = len(child_segment)
                if not child_processed:
                    failures.append(
                        f"mutator monitor did not propagate files-first child deletion: {child_relative}"
                    )
                    self._write_metadata(metadata_file, details)
                    return failures, artifacts, details

            xlsx_delete_start = self._prepare_monitor_for_local_mutation(
                process,
                phase_files["phase3_mutator_monitor"][0],
                details,
            )
            unlink_xlsx_pair(mutator_root / files_first_xlsx_destination)
            xlsx_delete_patterns = [
                f"Deleting item from Microsoft OneDrive: ./{files_first_xlsx_destination}",
                f"Deleting item from Microsoft OneDrive: ./{large_xlsx_relative(files_first_xlsx_destination)}",
            ]
            xlsx_delete_processed, xlsx_delete_segment = self._wait_for_stdout_growth_patterns(
                phase_files["phase3_mutator_monitor"][0],
                start_offset=xlsx_delete_start,
                required_patterns=xlsx_delete_patterns,
                timeout_seconds=180,
            )
            for relative in (files_first_xlsx_destination, large_xlsx_relative(files_first_xlsx_destination)):
                files_first_file_results[relative] = xlsx_delete_processed
            details["mutator_files_first_xlsx_delete_patterns"] = xlsx_delete_patterns
            details["mutator_files_first_xlsx_delete_log_segment_length"] = len(xlsx_delete_segment)
            if not xlsx_delete_processed:
                failures.append("mutator monitor did not propagate both files-first XLSX deletions")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            nested_relative = f"{files_first_destination}/Nested"
            nested_delete_start = self._prepare_monitor_for_local_mutation(
                process,
                phase_files["phase3_mutator_monitor"][0],
                details,
            )
            shutil.rmtree(mutator_root / nested_relative)
            nested_delete_groups = [
                [f"Deleting item from Microsoft OneDrive: ./{nested_relative}"],
                [f"Deleting item from Microsoft OneDrive: ./{nested_relative}/child.txt"],
            ]
            nested_delete_processed, nested_delete_group, nested_delete_segment = (
                self._wait_for_any_stdout_growth_pattern_group(
                    phase_files["phase3_mutator_monitor"][0],
                    start_offset=nested_delete_start,
                    alternative_pattern_groups=nested_delete_groups,
                    timeout_seconds=180,
                )
            )
            details["mutator_files_first_file_delete_results"] = files_first_file_results
            details["mutator_files_first_nested_delete_processed"] = nested_delete_processed
            details["mutator_files_first_nested_delete_pattern_groups"] = nested_delete_groups
            details["mutator_files_first_nested_delete_matched_group"] = nested_delete_group
            details["mutator_files_first_nested_delete_log_segment_length"] = len(nested_delete_segment)
            if not nested_delete_processed:
                failures.append("mutator monitor did not propagate the files-first nested-directory deletion")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            if not files_first_parent.is_dir() or any(files_first_parent.iterdir()):
                failures.append("mutator files-first parent was not retained locally as an empty directory")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            delete_reconcile = self._run_phase(
                context=context,
                label=f"{scenario.scenario_id}_phase6_validator_mixed_delete_reconcile",
                command=self._validator_reconcile_command(
                    context,
                    conf_dir=conf_validator,
                    validator_mode=scenario.validator_mode,
                ),
                stdout_file=phase_files["phase6_validator_mixed_delete_reconcile"][0],
                stderr_file=phase_files["phase6_validator_mixed_delete_reconcile"][1],
                details=details,
            )
            if delete_reconcile.returncode != 0:
                failures.append(
                    f"validator mixed delete reconcile failed with status {delete_reconcile.returncode}"
                )
            if (validator_root / whole_destination).exists():
                failures.append("whole-directory remote deletion was not removed locally")
            validator_files_first_parent = validator_root / files_first_destination
            if not validator_files_first_parent.is_dir():
                failures.append("files-first empty parent was not retained after remote child deletions")
            elif any(validator_files_first_parent.iterdir()):
                failures.append("files-first parent retained unexpected children after remote child deletions")
            if failures:
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            # Phase 7: remove the retained empty parent while monitor remains
            # active, then let download-only + cleanup-local-files converge it.
            parent_delete_start = self._prepare_monitor_for_local_mutation(
                process,
                phase_files["phase3_mutator_monitor"][0],
                details,
            )
            files_first_parent.rmdir()
            parent_delete_pattern = [
                f"Deleting item from Microsoft OneDrive: ./{files_first_destination}"
            ]
            parent_delete_processed, parent_delete_segment = self._wait_for_stdout_growth_patterns(
                phase_files["phase3_mutator_monitor"][0],
                start_offset=parent_delete_start,
                required_patterns=parent_delete_pattern,
                timeout_seconds=180,
            )
            details["mutator_empty_parent_delete_processed"] = parent_delete_processed
            details["mutator_empty_parent_delete_log_segment_length"] = len(parent_delete_segment)
            if not parent_delete_processed:
                failures.append("mutator monitor did not propagate the empty-parent deletion")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            parent_reconcile = self._run_phase(
                context=context,
                label=f"{scenario.scenario_id}_phase7_validator_empty_parent_reconcile",
                command=self._validator_reconcile_command(
                    context,
                    conf_dir=conf_validator,
                    validator_mode=scenario.validator_mode,
                ),
                stdout_file=phase_files["phase7_validator_empty_parent_reconcile"][0],
                stderr_file=phase_files["phase7_validator_empty_parent_reconcile"][1],
                details=details,
            )
            if parent_reconcile.returncode != 0:
                failures.append(
                    f"validator empty-parent reconcile failed with status {parent_reconcile.returncode}"
                )
            if (validator_root / files_first_destination).exists():
                failures.append("files-first empty parent remained after remote parent deletion")
        finally:
            self._shutdown_monitor_process(process, details)

        verify_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase8_verify",
            command=self._verify_command(
                context,
                root_name=root_name,
                conf_dir=conf_verify,
            ),
            stdout_file=phase_files["phase8_remote_truth_verify"][0],
            stderr_file=phase_files["phase8_remote_truth_verify"][1],
            details=details,
        )
        if verify_result.returncode != 0:
            failures.append(f"remote truth verification failed with status {verify_result.returncode}")

        validator_manifest = build_manifest(validator_root)
        verify_manifest = build_manifest(verify_root)
        write_manifest(validator_manifest_file, validator_manifest)
        write_manifest(verify_manifest_file, verify_manifest)
        details["validator_manifest"] = validator_manifest
        details["verify_manifest"] = verify_manifest

        for forbidden in [whole_source, files_first_source, whole_destination, files_first_destination]:
            if (verify_root / forbidden).exists():
                failures.append(f"remote truth unexpectedly retains terminal generation path: {forbidden}")

        if not (validator_root / anchor_relative).is_file():
            failures.append("validator lost destination anchor during mixed lifecycle")
        if not (verify_root / anchor_relative).is_file():
            failures.append("remote truth lost destination anchor during mixed lifecycle")

        details["validator_final_files"] = self._file_map(validator_root)
        details["verify_final_files"] = self._file_map(verify_root)
        self._write_metadata(metadata_file, details)
        return failures, artifacts, details

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0065",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        scenarios = [
            scenario
            for scenario in self._scenarios()
            if context.should_run_scenario(self.case_id, scenario.scenario_id)
        ]

        failures: list[str] = []
        all_artifacts: list[str] = []
        scenario_details: dict[str, object] = {}

        for scenario in scenarios:
            context.log(
                f"Running Test Case {self.case_id} scenario {scenario.scenario_id}: "
                f"{scenario.description}"
            )

            scenario_work = case_work_dir / scenario.scenario_id
            scenario_logs = case_log_dir / scenario.scenario_id
            scenario_state = state_dir / scenario.scenario_id
            reset_directory(scenario_work)
            reset_directory(scenario_logs)
            reset_directory(scenario_state)

            if scenario.movement == "nested_rename":
                scenario_failures, artifacts, details = self._run_nested_rename_scenario(
                    context,
                    scenario,
                    scenario_work=scenario_work,
                    scenario_logs=scenario_logs,
                    scenario_state=scenario_state,
                )
            elif scenario.full_lifecycle:
                scenario_failures, artifacts, details = self._run_full_lifecycle_scenario(
                    context,
                    scenario,
                    scenario_work=scenario_work,
                    scenario_logs=scenario_logs,
                    scenario_state=scenario_state,
                )
            else:
                scenario_failures, artifacts, details = self._run_basic_move_scenario(
                    context,
                    scenario,
                    scenario_work=scenario_work,
                    scenario_logs=scenario_logs,
                    scenario_state=scenario_state,
                )

            all_artifacts.extend(artifacts)
            scenario_details[scenario.scenario_id] = details

            if scenario_failures:
                failures.append(f"{scenario.scenario_id}: " + "; ".join(scenario_failures))
                context.log(
                    f"Scenario {scenario.scenario_id} FAILED: "
                    + "; ".join(scenario_failures)
                )
            else:
                context.log(f"Scenario {scenario.scenario_id} PASSED")

        details = {
            "scenario_count": len(scenarios),
            "executed_scenario_ids": [scenario.scenario_id for scenario in scenarios],
            "failed_scenarios": len(failures),
            "scenario_details": scenario_details,
        }

        if failures:
            details["failures"] = failures
            return self.fail_result(
                self.case_id,
                self.name,
                f"{len(failures)} of {len(scenarios)} TC0065 scenarios failed: "
                + " | ".join(failures),
                all_artifacts,
                details,
            )

        return self.pass_result(
            self.case_id,
            self.name,
            all_artifacts,
            details,
        )
