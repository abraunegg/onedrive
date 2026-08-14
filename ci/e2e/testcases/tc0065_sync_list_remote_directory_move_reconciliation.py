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
    sync_list filtering could create the destination directory and overwrite an
    existing directory's database parent before normal changed-item processing
    had a chance to compare the old and new paths.

    The testcase deliberately uses a persistent validator items.sqlite3 across
    the remote mutation.  Reconciliation phases MUST NOT use --resync.

    Coverage matrix:
      S01 - bidirectional validator, remote parent move
      S02 - bidirectional validator, remote same-parent directory rename
      S03 - download-only validator, remote parent move
      S04 - bidirectional monitor validator, remote parent move
      S05 - download-only + cleanup-local-files validator, parent moves followed
            by post-move modification and both whole-directory and files-first
            remote deletion lifecycles

    The remote stimulus is produced by a second client running --upload-only.
    The mutator must itself log a real local move; a delete/recreate stimulus
    would assign a new remote item ID and would not exercise this regression.
    """

    case_id = "0065"
    name = "sync_list remote directory move reconciliation"
    description = (
        "Validate that sync_list preserves existing directory identity across remote "
        "moves/renames in bidirectional and download-only modes, including cleanup "
        "and mixed post-move deletion lifecycles"
    )

    BAD_VALIDATOR_MARKERS = [
        "The file has been deleted locally",
        "Deleted local items to delete on Microsoft OneDrive:",
        "Deleting item from Microsoft OneDrive:",
        "New directories to create on Microsoft OneDrive:",
        "New items to upload to Microsoft OneDrive:",
        "Uploading new file:",
        "Uploading changed file:",
        "OneDrive Client requested to create this directory online:",
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
                    "rename within the same parent without destination pre-creation"
                ),
                movement="same_parent_rename",
                validator_mode="bidirectional",
            ),
            ScenarioSpec(
                scenario_id="S03_download_only_parent_move",
                description=(
                    "Download-only sync_list validator reconciles an existing directory "
                    "move using the normal move path rather than reconstructing children"
                ),
                movement="parent_move",
                validator_mode="download_only",
            ),
            ScenarioSpec(
                scenario_id="S04_monitor_bidirectional_parent_move",
                description=(
                    "Running bidirectional --monitor sync_list validator receives a remote "
                    "directory move and applies the normal move path without destructive "
                    "delete/re-upload feedback"
                ),
                movement="parent_move",
                validator_mode="monitor_bidirectional",
            ),
            ScenarioSpec(
                scenario_id="S05_download_only_cleanup_mixed_lifecycle",
                description=(
                    "Download-only + cleanup-local-files sync_list validator handles two "
                    "directory moves, post-move modification, whole-directory deletion, "
                    "files-first empty-parent retention, and later parent deletion"
                ),
                movement="parent_move",
                validator_mode="download_only_cleanup",
                full_lifecycle=True,
            ),
        ]

    def _config_text(self, sync_root: Path, *, label: str) -> str:
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
    ) -> None:
        context.prepare_minimal_config_dir(
            config_dir,
            self._config_text(sync_root, label=label),
        )
        if sync_list_root_name is not None:
            write_text_file(config_dir / "sync_list", f"/{sync_list_root_name}\n")

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

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
        context.log(
            f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}"
        )
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

    def _destination_precreation_seen(self, output: str, destination_relative: str) -> bool:
        candidates = [
            f"Attempting to create local directory: ./{destination_relative}",
            f"Attempting to create local directory: {destination_relative}",
        ]
        return any(candidate in output for candidate in candidates)

    def _bad_validator_markers(self, output: str) -> list[str]:
        return [marker for marker in self.BAD_VALIDATOR_MARKERS if marker in output]

    def _sync_list_active(self, output: str, root_name: str) -> bool:
        return (
            "Selective sync 'sync_list' configured" in output
            and root_name in output
        )

    def _validator_mode_active(self, output: str, validator_mode: str) -> bool:
        download_only_true = re.search(
            r"Config option 'download_only'\s*=\s*true", output
        ) is not None
        download_only_false = re.search(
            r"Config option 'download_only'\s*=\s*false", output
        ) is not None
        cleanup_true = re.search(
            r"Config option 'cleanup_local_files'\s*=\s*true", output
        ) is not None
        cleanup_false = re.search(
            r"Config option 'cleanup_local_files'\s*=\s*false", output
        ) is not None

        if validator_mode == "download_only":
            return download_only_true and cleanup_false
        if validator_mode == "download_only_cleanup":
            return download_only_true and cleanup_true
        if validator_mode in {"bidirectional", "monitor_bidirectional"}:
            return download_only_false
        return False

    def _mutator_upload_only_active(self, output: str) -> bool:
        return re.search(
            r"Config option 'upload_only'\s*=\s*true", output
        ) is not None

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

    def _mutator_upload_command(
        self,
        context: E2EContext,
        *,
        root_name: str,
        conf_dir: Path,
    ) -> list[str]:
        # Intentionally no --resync.  The mutator must preserve its database so
        # the local rename/move is propagated as a real OneDrive move.
        return [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
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
        # No --single-directory here: sync_list itself must be the filter that
        # selects the testcase tree, otherwise the regression path is bypassed.
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
        # CRITICAL: never add --resync to this command.  The regression requires
        # the validator's pre-move items.sqlite3 state to remain intact.
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

        for path in [mutator_root, validator_root, verify_root]:
            reset_directory(path)

        root_name = f"ZZ_E2E_TC0065_{scenario.scenario_id}_{context.run_id}_{os.getpid()}"
        source_name = "GenerationAlpha"

        if scenario.movement == "same_parent_rename":
            source_relative = f"{root_name}/incoming/{source_name}"
            destination_relative = f"{root_name}/incoming/GenerationAlphaRenamed"
        else:
            source_relative = f"{root_name}/incoming/{source_name}"
            destination_relative = f"{root_name}/moved/{source_name}"

        self._prepare_client_config(
            context, conf_mutator, mutator_root, label=f"{scenario.scenario_id} mutator"
        )
        self._prepare_client_config(
            context,
            conf_validator,
            validator_root,
            label=f"{scenario.scenario_id} validator",
            sync_list_root_name=root_name,
        )
        self._prepare_client_config(
            context, conf_verify, verify_root, label=f"{scenario.scenario_id} verify"
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
            "mutator_move": (
                scenario_logs / "phase3_mutator_move_stdout.log",
                scenario_logs / "phase3_mutator_move_stderr.log",
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
            str(validator_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id,
            "description": scenario.description,
            "root_name": root_name,
            "movement": scenario.movement,
            "validator_mode": scenario.validator_mode,
            "source_relative": source_relative,
            "destination_relative": destination_relative,
            "mutator_root": str(mutator_root),
            "validator_root": str(validator_root),
            "verify_root": str(verify_root),
            "validator_items_db": str(conf_validator / "items.sqlite3"),
            "mutator_items_db": str(conf_mutator / "items.sqlite3"),
            "sync_list": [f"/{root_name}"],
        }

        failures: list[str] = []

        seed_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase1_seed",
            command=self._seed_upload_command(
                context, root_name=root_name, conf_dir=conf_mutator
            ),
            stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1],
            details=details,
        )
        if seed_result.returncode != 0:
            failures.append(f"mutator seed failed with status {seed_result.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

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
        details["sync_list_active_during_initial"] = self._sync_list_active(
            initial_output, root_name
        )
        details["validator_initial_download_only_active"] = self._validator_mode_active(
            initial_output, "download_only"
        )
        details["validator_items_db_exists_after_initial"] = (
            conf_validator / "items.sqlite3"
        ).is_file()

        if not details["sync_list_active_during_initial"]:
            failures.append("validator initial phase did not prove sync_list was active")
        if not details["validator_initial_download_only_active"]:
            failures.append("validator initial phase did not prove download-only preload mode was active")
        if not details["validator_items_db_exists_after_initial"]:
            failures.append("validator initial phase did not preserve items.sqlite3")

        initial_tree_failures = self._tree_matches(
            root=validator_root,
            expected_files=initial_files,
            required_dirs=[
                source_relative,
                f"{source_relative}/Nested",
                f"{source_relative}/Nested/Deep",
                f"{source_relative}/EmptyChild",
                f"{root_name}/moved",
            ],
            forbidden_paths=[destination_relative] if destination_relative != source_relative else [],
        )
        failures.extend(f"initial validator tree: {item}" for item in initial_tree_failures)

        source_path = mutator_root / source_relative
        destination_path = mutator_root / destination_relative
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        if not source_path.is_dir():
            failures.append(f"mutator source directory missing before move: {source_relative}")
        else:
            source_path.rename(destination_path)

        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        move_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase3_mutator_move",
            command=self._mutator_upload_command(
                context, root_name=root_name, conf_dir=conf_mutator
            ),
            stdout_file=phase_files["mutator_move"][0],
            stderr_file=phase_files["mutator_move"][1],
            details=details,
        )
        if move_result.returncode != 0:
            failures.append(f"mutator move propagation failed with status {move_result.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        mutator_move_output = self._combined_output(*phase_files["mutator_move"])
        details["mutator_upload_only_active"] = self._mutator_upload_only_active(
            mutator_move_output
        )
        details["mutator_real_move_logged"] = self._contains_move(
            mutator_move_output, source_relative, destination_relative
        )
        if not details["mutator_upload_only_active"]:
            failures.append("mutator move phase did not prove --upload-only was active")
        if not details["mutator_real_move_logged"]:
            failures.append(
                "mutator did not log a real directory move; stimulus may have degraded to delete/recreate and would not exercise the existing-ID regression"
            )

        reconcile_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase4_validator_reconcile",
            command=self._validator_reconcile_command(
                context,
                conf_dir=conf_validator,
                validator_mode=scenario.validator_mode,
            ),
            stdout_file=phase_files["validator_reconcile"][0],
            stderr_file=phase_files["validator_reconcile"][1],
            details=details,
        )
        if reconcile_result.returncode != 0:
            failures.append(
                f"validator reconciliation failed with status {reconcile_result.returncode}"
            )

        reconcile_output = self._combined_output(*phase_files["validator_reconcile"])
        details["sync_list_active_during_reconcile"] = self._sync_list_active(
            reconcile_output, root_name
        )
        details["validator_mode_active_during_reconcile"] = self._validator_mode_active(
            reconcile_output, scenario.validator_mode
        )
        details["validator_real_move_logged"] = self._contains_move(
            reconcile_output, source_relative, destination_relative
        )
        details["destination_precreation_seen"] = self._destination_precreation_seen(
            reconcile_output, destination_relative
        )
        details["validator_bad_markers"] = self._bad_validator_markers(reconcile_output)

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
        if details["validator_bad_markers"]:
            failures.append(
                "validator logged regression side effects: "
                + ", ".join(details["validator_bad_markers"])
            )

        expected_after_move: dict[str, str] = {}
        for relative, content in initial_files.items():
            if relative.startswith(source_relative + "/"):
                expected_after_move[
                    relative.replace(source_relative, destination_relative, 1)
                ] = content
            else:
                expected_after_move[relative] = content

        moved_tree_failures = self._tree_matches(
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
        failures.extend(f"validator after move: {item}" for item in moved_tree_failures)

        verify_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase5_verify",
            command=self._verify_command(
                context, root_name=root_name, conf_dir=conf_verify
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

        verify_tree_failures = self._tree_matches(
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
        failures.extend(f"remote truth after validator reconcile: {item}" for item in verify_tree_failures)

        self._write_metadata(metadata_file, details)
        return failures, artifacts, details

    def _run_monitor_move_scenario(
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
        validator_app_log_dir = scenario_logs / "app-logs"

        for path in [mutator_root, validator_root, verify_root]:
            reset_directory(path)

        root_name = f"ZZ_E2E_TC0065_{scenario.scenario_id}_{context.run_id}_{os.getpid()}"
        source_name = "GenerationMonitor"
        source_relative = f"{root_name}/incoming/{source_name}"
        destination_relative = f"{root_name}/moved/{source_name}"

        self._prepare_client_config(
            context, conf_mutator, mutator_root, label=f"{scenario.scenario_id} mutator"
        )
        validator_config_text = self._config_text(
            validator_root, label=f"{scenario.scenario_id} validator"
        ) + (
            'enable_logging = "true"\n'
            f'log_dir = "{validator_app_log_dir}"\n'
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "false"\n'
        )
        context.prepare_minimal_config_dir(conf_validator, validator_config_text)
        write_text_file(conf_validator / "sync_list", f"/{root_name}\n")
        self._prepare_client_config(
            context, conf_verify, verify_root, label=f"{scenario.scenario_id} verify"
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
            "monitor": (
                scenario_logs / "phase3_validator_monitor_stdout.log",
                scenario_logs / "phase3_validator_monitor_stderr.log",
            ),
            "mutator_move": (
                scenario_logs / "phase4_mutator_move_stdout.log",
                scenario_logs / "phase4_mutator_move_stderr.log",
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
            str(validator_app_log_dir),
            str(validator_manifest_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id,
            "description": scenario.description,
            "root_name": root_name,
            "source_relative": source_relative,
            "destination_relative": destination_relative,
            "validator_mode": scenario.validator_mode,
            "monitor_interval": 300,
            "monitor_fullscan_frequency": 0,
            "disable_websocket_support": False,
            "sync_list": [f"/{root_name}"],
        }
        failures: list[str] = []

        seed_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase1_seed",
            command=self._seed_upload_command(context, root_name=root_name, conf_dir=conf_mutator),
            stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1],
            details=details,
        )
        if seed_result.returncode != 0:
            failures.append(f"mutator seed failed with status {seed_result.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        preload_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase2_validator_initial",
            command=self._validator_initial_command(context, conf_dir=conf_validator),
            stdout_file=phase_files["validator_initial"][0],
            stderr_file=phase_files["validator_initial"][1],
            details=details,
        )
        if preload_result.returncode != 0:
            failures.append(f"validator preload failed with status {preload_result.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        preload_output = self._combined_output(*phase_files["validator_initial"])
        if not self._sync_list_active(preload_output, root_name):
            failures.append("monitor validator preload did not prove sync_list was active")
        if not self._validator_mode_active(preload_output, "download_only"):
            failures.append("monitor validator preload did not prove download-only mode was active")
        if not (conf_validator / "items.sqlite3").is_file():
            failures.append("monitor validator preload did not preserve items.sqlite3")

        failures.extend(
            f"monitor validator initial tree: {item}"
            for item in self._tree_matches(
                root=validator_root,
                expected_files=initial_files,
                required_dirs=[source_relative, f"{root_name}/moved"],
                forbidden_paths=[destination_relative],
            )
        )
        if failures:
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        monitor_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--monitor",
            "--verbose",
            "--verbose",
            "--confdir",
            str(conf_validator),
        ]
        context.log(
            f"Executing Test Case {self.case_id} {scenario.scenario_id} monitor: "
            f"{command_to_string(monitor_command)}"
        )
        process, initial_sync_complete = self._launch_monitor_process(
            context,
            monitor_command,
            phase_files["monitor"][0],
            phase_files["monitor"][1],
            startup_timeout_seconds=300,
        )
        details["monitor_initial_sync_complete"] = initial_sync_complete

        try:
            if not initial_sync_complete:
                failures.append("validator monitor did not complete its initial sync")
                return failures, artifacts, details

            monitor_full_output = self._combined_output(*phase_files["monitor"])
            if not self._sync_list_active(monitor_full_output, root_name):
                failures.append("running monitor did not prove sync_list was active")
            if not self._validator_mode_active(monitor_full_output, "monitor_bidirectional"):
                failures.append("running monitor did not prove bidirectional mode was active")

            start_offset = self._prepare_monitor_for_local_mutation(
                process,
                phase_files["monitor"][0],
                details,
                quiet_seconds=3.0,
                timeout_seconds=30,
            )
            if not details.get("monitor_ready_after_initial_sync", False):
                failures.append("validator monitor did not become quiet/ready before remote mutation")
                return failures, artifacts, details

            source_path = mutator_root / source_relative
            destination_path = mutator_root / destination_relative
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.rename(destination_path)

            move_result = self._run_phase(
                context=context,
                label=f"{scenario.scenario_id}_phase4_mutator_move",
                command=self._mutator_upload_command(context, root_name=root_name, conf_dir=conf_mutator),
                stdout_file=phase_files["mutator_move"][0],
                stderr_file=phase_files["mutator_move"][1],
                details=details,
            )
            if move_result.returncode != 0:
                failures.append(f"mutator monitor stimulus failed with status {move_result.returncode}")
                return failures, artifacts, details

            mutator_output = self._combined_output(*phase_files["mutator_move"])
            if not self._mutator_upload_only_active(mutator_output):
                failures.append("monitor mutator did not prove --upload-only was active")
            if not self._contains_move(mutator_output, source_relative, destination_relative):
                failures.append(
                    "monitor mutator did not log a real directory move; stimulus would not exercise existing-ID reconciliation"
                )

            deadline = time.time() + 180
            monitor_segment = ""
            while time.time() < deadline:
                monitor_segment = self._read_monitor_output_from_offsets(
                    phase_files["monitor"][0], start_offset
                )
                moved = self._contains_move(
                    monitor_segment, source_relative, destination_relative
                )
                destination_ready = (validator_root / destination_relative).is_dir()
                source_gone = not (validator_root / source_relative).exists()
                if moved and destination_ready and source_gone:
                    # Let immediate follow-up reconciliation/logging settle so
                    # negative assertions see the complete move transaction.
                    time.sleep(3.0)
                    monitor_segment = self._read_monitor_output_from_offsets(
                        phase_files["monitor"][0], start_offset
                    )
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.5)

            details["monitor_real_move_logged"] = self._contains_move(
                monitor_segment, source_relative, destination_relative
            )
            details["monitor_destination_precreation_seen"] = self._destination_precreation_seen(
                monitor_segment, destination_relative
            )
            details["monitor_bad_markers"] = self._bad_validator_markers(monitor_segment)

            if not details["monitor_real_move_logged"]:
                failures.append("monitor validator did not log the real incoming -> moved directory move")
            if details["monitor_destination_precreation_seen"]:
                failures.append("monitor validator pre-created the destination before move handling")
            if details["monitor_bad_markers"]:
                failures.append(
                    "monitor validator logged destructive regression side effects: "
                    + ", ".join(details["monitor_bad_markers"])
                )

            expected_after_move = {
                (
                    relative.replace(source_relative, destination_relative, 1)
                    if relative.startswith(source_relative + "/")
                    else relative
                ): content
                for relative, content in initial_files.items()
            }
            failures.extend(
                f"monitor validator after move: {item}"
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
        finally:
            self._shutdown_monitor_process(process, details)
            self._write_metadata(metadata_file, details)

        verify_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase5_verify",
            command=self._verify_command(context, root_name=root_name, conf_dir=conf_verify),
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
            details=details,
        )
        if verify_result.returncode != 0:
            failures.append(f"monitor remote truth verification failed with status {verify_result.returncode}")

        expected_after_move = {
            (
                relative.replace(source_relative, destination_relative, 1)
                if relative.startswith(source_relative + "/")
                else relative
            ): content
            for relative, content in initial_files.items()
        }
        failures.extend(
            f"monitor remote truth: {item}"
            for item in self._tree_matches(
                root=verify_root,
                expected_files=expected_after_move,
                required_dirs=[destination_relative],
                forbidden_paths=[source_relative],
            )
        )

        validator_manifest = build_manifest(validator_root)
        verify_manifest = build_manifest(verify_root)
        write_manifest(validator_manifest_file, validator_manifest)
        write_manifest(verify_manifest_file, verify_manifest)
        details["validator_manifest"] = validator_manifest
        details["verify_manifest"] = verify_manifest
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

        for path in [mutator_root, validator_root, verify_root]:
            reset_directory(path)

        root_name = f"ZZ_E2E_TC0065_{scenario.scenario_id}_{context.run_id}_{os.getpid()}"
        whole_name = "GenerationWholeDelete"
        files_first_name = "GenerationFilesFirst"
        whole_source = f"{root_name}/incoming/{whole_name}"
        files_first_source = f"{root_name}/incoming/{files_first_name}"
        whole_destination = f"{root_name}/moved/{whole_name}"
        files_first_destination = f"{root_name}/moved/{files_first_name}"

        self._prepare_client_config(
            context, conf_mutator, mutator_root, label=f"{scenario.scenario_id} mutator"
        )
        self._prepare_client_config(
            context,
            conf_validator,
            validator_root,
            label=f"{scenario.scenario_id} validator",
            sync_list_root_name=root_name,
        )
        self._prepare_client_config(
            context, conf_verify, verify_root, label=f"{scenario.scenario_id} verify"
        )

        initial_files = {
            f"{whole_source}/file0.txt": "whole file0 initial\n",
            f"{whole_source}/file1.txt": "whole file1 initial\n",
            f"{whole_source}/Nested/child.txt": "whole nested initial\n",
            f"{files_first_source}/file0.txt": "files-first file0 initial\n",
            f"{files_first_source}/file1.txt": "files-first file1 initial\n",
            f"{files_first_source}/Nested/child.txt": "files-first nested initial\n",
            f"{root_name}/moved/anchor.txt": "TC0065 lifecycle destination anchor\n",
        }
        for relative, content in initial_files.items():
            write_text_file(mutator_root / relative, content)

        phase_names = [
            "phase1_seed",
            "phase2_validator_initial",
            "phase3_mutator_move",
            "phase4_validator_move_reconcile",
            "phase5_mutator_postmove_modify",
            "phase6_validator_postmove_modify_reconcile",
            "phase7_mutator_mixed_delete",
            "phase8_validator_mixed_delete_reconcile",
            "phase9_mutator_empty_parent_delete",
            "phase10_validator_empty_parent_reconcile",
            "phase11_remote_truth_verify",
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
            command=self._seed_upload_command(context, root_name=root_name, conf_dir=conf_mutator),
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

        # Move both existing directory IDs as one remote mutation batch.
        (mutator_root / whole_source).rename(mutator_root / whole_destination)
        (mutator_root / files_first_source).rename(mutator_root / files_first_destination)

        move_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase3_mutator_move",
            command=self._mutator_upload_command(context, root_name=root_name, conf_dir=conf_mutator),
            stdout_file=phase_files["phase3_mutator_move"][0],
            stderr_file=phase_files["phase3_mutator_move"][1],
            details=details,
        )
        if move_result.returncode != 0:
            failures.append(f"mutator move phase failed with status {move_result.returncode}")
        move_output = self._combined_output(*phase_files["phase3_mutator_move"])
        if not self._mutator_upload_only_active(move_output):
            failures.append("mutator move phase did not prove --upload-only was active")
        for source, destination in [
            (whole_source, whole_destination),
            (files_first_source, files_first_destination),
        ]:
            if not self._contains_move(move_output, source, destination):
                failures.append(
                    f"mutator did not log real directory move required for valid stimulus: {source} -> {destination}"
                )

        move_reconcile = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase4_validator_move_reconcile",
            command=self._validator_reconcile_command(
                context, conf_dir=conf_validator, validator_mode=scenario.validator_mode
            ),
            stdout_file=phase_files["phase4_validator_move_reconcile"][0],
            stderr_file=phase_files["phase4_validator_move_reconcile"][1],
            details=details,
        )
        if move_reconcile.returncode != 0:
            failures.append(f"validator move reconcile failed with status {move_reconcile.returncode}")

        move_reconcile_output = self._combined_output(*phase_files["phase4_validator_move_reconcile"])
        if not self._sync_list_active(move_reconcile_output, root_name):
            failures.append("validator move reconcile did not prove sync_list was active")
        if not self._validator_mode_active(move_reconcile_output, scenario.validator_mode):
            failures.append(
                f"validator move reconcile did not prove requested mode was active: {scenario.validator_mode}"
            )
        for source, destination in [
            (whole_source, whole_destination),
            (files_first_source, files_first_destination),
        ]:
            if not self._contains_move(move_reconcile_output, source, destination):
                failures.append(f"validator did not log real move: {source} -> {destination}")
            if self._destination_precreation_seen(move_reconcile_output, destination):
                failures.append(f"validator pre-created move destination: {destination}")

        move_bad_markers = self._bad_validator_markers(move_reconcile_output)
        if move_bad_markers:
            failures.append(
                "validator move reconcile logged regression side effects: "
                + ", ".join(move_bad_markers)
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

        # Post-move modifications prove child paths continue to resolve beneath
        # the moved parent after the DB update.
        whole_modified_relative = f"{whole_destination}/file0.txt"
        files_first_modified_relative = f"{files_first_destination}/Nested/child.txt"
        whole_modified_content = "whole file0 post-move modified\n"
        files_first_modified_content = "files-first nested post-move modified\n"
        write_text_file(mutator_root / whole_modified_relative, whole_modified_content)
        write_text_file(mutator_root / files_first_modified_relative, files_first_modified_content)

        modify_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase5_mutator_postmove_modify",
            command=self._mutator_upload_command(context, root_name=root_name, conf_dir=conf_mutator),
            stdout_file=phase_files["phase5_mutator_postmove_modify"][0],
            stderr_file=phase_files["phase5_mutator_postmove_modify"][1],
            details=details,
        )
        if modify_result.returncode != 0:
            failures.append(f"mutator post-move modify failed with status {modify_result.returncode}")

        modify_reconcile = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase6_validator_postmove_modify_reconcile",
            command=self._validator_reconcile_command(
                context, conf_dir=conf_validator, validator_mode=scenario.validator_mode
            ),
            stdout_file=phase_files["phase6_validator_postmove_modify_reconcile"][0],
            stderr_file=phase_files["phase6_validator_postmove_modify_reconcile"][1],
            details=details,
        )
        if modify_reconcile.returncode != 0:
            failures.append(
                f"validator post-move modify reconcile failed with status {modify_reconcile.returncode}"
            )
        modify_reconcile_output = self._combined_output(*phase_files["phase6_validator_postmove_modify_reconcile"])
        modify_bad_markers = self._bad_validator_markers(modify_reconcile_output)
        if modify_bad_markers:
            failures.append(
                "validator post-move modify reconcile logged regression side effects: "
                + ", ".join(modify_bad_markers)
            )
        if not (validator_root / whole_modified_relative).is_file() or (
            validator_root / whole_modified_relative
        ).read_text(encoding="utf-8", errors="replace") != whole_modified_content:
            failures.append("validator did not receive modified whole-delete generation content")
        if not (validator_root / files_first_modified_relative).is_file() or (
            validator_root / files_first_modified_relative
        ).read_text(encoding="utf-8", errors="replace") != files_first_modified_content:
            failures.append("validator did not receive modified files-first generation content")

        # Mixed deletion phase: remove GenerationWholeDelete entirely; remove all
        # children under GenerationFilesFirst while retaining its empty parent.
        shutil.rmtree(mutator_root / whole_destination)
        files_first_dir = mutator_root / files_first_destination
        for child in list(files_first_dir.iterdir()):
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()

        delete_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase7_mutator_mixed_delete",
            command=self._mutator_upload_command(context, root_name=root_name, conf_dir=conf_mutator),
            stdout_file=phase_files["phase7_mutator_mixed_delete"][0],
            stderr_file=phase_files["phase7_mutator_mixed_delete"][1],
            details=details,
        )
        if delete_result.returncode != 0:
            failures.append(f"mutator mixed delete failed with status {delete_result.returncode}")

        delete_reconcile = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase8_validator_mixed_delete_reconcile",
            command=self._validator_reconcile_command(
                context, conf_dir=conf_validator, validator_mode=scenario.validator_mode
            ),
            stdout_file=phase_files["phase8_validator_mixed_delete_reconcile"][0],
            stderr_file=phase_files["phase8_validator_mixed_delete_reconcile"][1],
            details=details,
        )
        if delete_reconcile.returncode != 0:
            failures.append(
                f"validator mixed delete reconcile failed with status {delete_reconcile.returncode}"
            )

        if (validator_root / whole_destination).exists():
            failures.append("whole-directory remote deletion was not removed locally")
        if not (validator_root / files_first_destination).is_dir():
            failures.append("files-first empty parent was not retained after child deletions")
        elif any((validator_root / files_first_destination).iterdir()):
            failures.append("files-first parent retained unexpected children after remote child deletions")

        # Final files-first parent deletion.
        (mutator_root / files_first_destination).rmdir()
        empty_parent_delete_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase9_mutator_empty_parent_delete",
            command=self._mutator_upload_command(context, root_name=root_name, conf_dir=conf_mutator),
            stdout_file=phase_files["phase9_mutator_empty_parent_delete"][0],
            stderr_file=phase_files["phase9_mutator_empty_parent_delete"][1],
            details=details,
        )
        if empty_parent_delete_result.returncode != 0:
            failures.append(
                f"mutator empty-parent delete failed with status {empty_parent_delete_result.returncode}"
            )

        empty_parent_reconcile = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase10_validator_empty_parent_reconcile",
            command=self._validator_reconcile_command(
                context, conf_dir=conf_validator, validator_mode=scenario.validator_mode
            ),
            stdout_file=phase_files["phase10_validator_empty_parent_reconcile"][0],
            stderr_file=phase_files["phase10_validator_empty_parent_reconcile"][1],
            details=details,
        )
        if empty_parent_reconcile.returncode != 0:
            failures.append(
                f"validator empty-parent reconcile failed with status {empty_parent_reconcile.returncode}"
            )
        if (validator_root / files_first_destination).exists():
            failures.append("files-first empty parent remained after remote parent deletion")

        verify_result = self._run_phase(
            context=context,
            label=f"{scenario.scenario_id}_phase11_verify",
            command=self._verify_command(context, root_name=root_name, conf_dir=conf_verify),
            stdout_file=phase_files["phase11_remote_truth_verify"][0],
            stderr_file=phase_files["phase11_remote_truth_verify"][1],
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

        for forbidden in [
            whole_source,
            files_first_source,
            whole_destination,
            files_first_destination,
        ]:
            if (verify_root / forbidden).exists():
                failures.append(f"remote truth unexpectedly retains terminal generation path: {forbidden}")

        anchor_relative = f"{root_name}/moved/anchor.txt"
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

            if scenario.validator_mode == "monitor_bidirectional":
                scenario_failures, artifacts, details = self._run_monitor_move_scenario(
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
                failures.append(
                    f"{scenario.scenario_id}: " + "; ".join(scenario_failures)
                )
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
