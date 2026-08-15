from __future__ import annotations

import os
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
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
    """

    case_id = "0065"
    name = "sync_list remote directory move reconciliation"
    description = (
        "Validate that sync_list preserves existing directory identity across remote "
        "moves/renames in bidirectional, download-only and monitor reconciliation modes, "
        "including post-move modification and cleanup deletion lifecycles"
    )

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
        ]

    def _simple_config_text(self, sync_root: Path, *, label: str) -> str:
        return (
            f"# tc0065 {label} config\n"
            f'sync_dir = "{sync_root}"\n'
            'bypass_data_preservation = "true"\n'
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
    ) -> None:
        if monitor_app_log_dir is None:
            config_text = self._simple_config_text(sync_root, label=label)
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
        for source_path, destination_path, source_relative, destination_relative in moves:
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.rename(destination_path)
            required_patterns.extend(
                [
                    f"[M] Local item moved: ./{source_relative} -> ./{destination_relative}",
                    f"Moving ./{source_relative} to ./{destination_relative}",
                ]
            )

        processed, segment = self._wait_for_stdout_growth_patterns(
            monitor_stdout,
            start_offset=start_offset,
            required_patterns=required_patterns,
            timeout_seconds=180,
        )
        details[f"{detail_prefix}_required_patterns"] = required_patterns
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

            modify_patterns = [
                f"Uploading modified file: {whole_modified_relative} ... done",
                f"Uploading modified file: {files_first_modified_relative} ... done",
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
                [f"Deleting item from Microsoft OneDrive: {whole_destination}"],
                [f"Deleting item from Microsoft OneDrive: {whole_destination}/file0.txt"],
                [f"Deleting item from Microsoft OneDrive: {whole_destination}/file1.txt"],
                [f"Deleting item from Microsoft OneDrive: {whole_destination}/Nested"],
                [f"Deleting item from Microsoft OneDrive: {whole_destination}/Nested/child.txt"],
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
                    required_patterns=[f"Deleting item from Microsoft OneDrive: {child_relative}"],
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

            nested_relative = f"{files_first_destination}/Nested"
            nested_delete_start = self._prepare_monitor_for_local_mutation(
                process,
                phase_files["phase3_mutator_monitor"][0],
                details,
            )
            shutil.rmtree(mutator_root / nested_relative)
            nested_delete_groups = [
                [f"Deleting item from Microsoft OneDrive: {nested_relative}"],
                [f"Deleting item from Microsoft OneDrive: {nested_relative}/child.txt"],
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
                f"Deleting item from Microsoft OneDrive: {files_first_destination}"
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

            if scenario.full_lifecycle:
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
