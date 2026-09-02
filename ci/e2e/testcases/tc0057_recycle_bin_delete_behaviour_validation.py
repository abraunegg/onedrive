from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_text_file,
)
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0057RecycleBinDeleteBehaviourValidation(MonitorModeTestCaseBase):
    case_id = "0057"
    name = "recycle bin delete behaviour validation"
    description = "Validate Recycle Bin delete behaviour, including failed online-delete moves without re-upload"

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(metadata_file, "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n")

    def _prepare_config(
        self,
        context: E2EContext,
        config_dir: Path,
        sync_dir: Path,
        *,
        use_recycle_bin: bool,
        recycle_bin_path: Path,
        extra_config: str = "",
    ) -> None:
        context.prepare_minimal_config_dir(
            config_dir,
            (
                "# tc0057 config\n"
                f'sync_dir = "{sync_dir}"\n'
                f'use_recycle_bin = "{str(use_recycle_bin).lower()}"\n'
                f'recycle_bin_path = "{recycle_bin_path}"\n'
                f"{extra_config}"
            ),
        )

    @staticmethod
    def _rewrite_runtime_config(
        config_dir: Path,
        sync_root: Path,
        *,
        recycle_bin_path: Path | None = None,
        extra_lines: list[str] | None = None,
    ) -> None:
        """Rewrite runtime settings while preserving the cloned DB/token/delta state."""
        config_path = config_dir / "config"
        existing_lines = config_path.read_text(encoding="utf-8").splitlines()
        retained_lines: list[str] = []
        managed_extra_keys = {
            "enable_logging",
            "log_dir",
            "monitor_interval",
            "monitor_fullscan_frequency",
            "disable_websocket_support",
            "bypass_data_preservation",
        }

        for raw_line in existing_lines:
            stripped = raw_line.strip()
            if stripped.startswith("sync_dir") and "=" in stripped:
                continue
            if recycle_bin_path is not None and stripped.startswith("recycle_bin_path") and "=" in stripped:
                continue
            if extra_lines and "=" in stripped:
                key = stripped.split("=", 1)[0].strip()
                if key in managed_extra_keys:
                    continue
            retained_lines.append(raw_line)

        retained_lines.append(f'sync_dir = "{sync_root}"')
        if recycle_bin_path is not None:
            retained_lines.append(f'recycle_bin_path = "{recycle_bin_path}"')
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

    def _contains_path_prefix(self, manifest: list[str], relative_path: str) -> bool:
        return any(entry == relative_path or entry.startswith(relative_path + "/") for entry in manifest)

    def _recycle_bin_has_payload(self, manifest: list[str], filename: str) -> bool:
        return any(entry.endswith(filename) for entry in manifest)

    def _recycle_bin_has_trashinfo(self, manifest: list[str]) -> bool:
        return any(entry.endswith(".trashinfo") for entry in manifest)

    def _run_scenario(
        self,
        context: E2EContext,
        *,
        scenario_id: str,
        scenario_name: str,
        delete_origin: str,
        use_recycle_bin: bool,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
    ) -> tuple[list[str], list[str], dict[str, object]]:
        scenario_work_dir = case_work_dir / scenario_id
        sync_root = scenario_work_dir / "syncroot"
        verify_root = scenario_work_dir / "verifyroot"
        recycle_bin_root = scenario_work_dir / "RecycleBin"
        conf_runtime = scenario_work_dir / "conf-runtime"
        conf_verify = scenario_work_dir / "conf-verify"

        reset_directory(sync_root)
        reset_directory(verify_root)
        reset_directory(recycle_bin_root)

        root_name = f"ZZ_E2E_TC0057_{context.run_id}_{os.getpid()}_{scenario_id}"
        delete_dir_relative = f"{root_name}/DeleteMe"
        keep_file_relative = f"{root_name}/Keep/keep.txt"
        delete_file_relative = f"{delete_dir_relative}/delete-me.txt"

        write_text_file(sync_root / keep_file_relative, f"tc0057 {scenario_id} keep\n")
        write_text_file(sync_root / delete_file_relative, f"tc0057 {scenario_id} delete me\n")

        self._prepare_config(
            context,
            conf_runtime,
            sync_root,
            use_recycle_bin=use_recycle_bin,
            recycle_bin_path=recycle_bin_root,
        )
        self._prepare_config(
            context,
            conf_verify,
            verify_root,
            use_recycle_bin=False,
            recycle_bin_path=recycle_bin_root,
        )

        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id
        scenario_log_dir.mkdir(parents=True, exist_ok=True)
        scenario_state_dir.mkdir(parents=True, exist_ok=True)

        seed_stdout = scenario_log_dir / "seed_stdout.log"
        seed_stderr = scenario_log_dir / "seed_stderr.log"
        delete_stdout = scenario_log_dir / "delete_stdout.log"
        delete_stderr = scenario_log_dir / "delete_stderr.log"
        process_stdout = scenario_log_dir / "process_stdout.log"
        process_stderr = scenario_log_dir / "process_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"
        local_manifest_file = scenario_state_dir / "local_manifest.txt"
        remote_manifest_file = scenario_state_dir / "remote_manifest.txt"
        recycle_manifest_file = scenario_state_dir / "recycle_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(delete_stdout),
            str(delete_stderr),
            str(process_stdout),
            str(process_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(local_manifest_file),
            str(remote_manifest_file),
            str(recycle_manifest_file),
            str(metadata_file),
        ]
        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "delete_origin": delete_origin,
            "use_recycle_bin": use_recycle_bin,
            "root_name": root_name,
            "delete_dir_relative": delete_dir_relative,
            "delete_file_relative": delete_file_relative,
            "keep_file_relative": keep_file_relative,
        }
        failures: list[str] = []

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
        seed_result = self._run_and_capture(context, f"{scenario_id} seed", seed_command, seed_stdout, seed_stderr)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            failures.append(f"{scenario_id}: seed phase failed with status {seed_result.returncode}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        if delete_origin == "online":
            delete_command = [
                context.onedrive_bin,
                "--display-running-config",
                "--verbose",
                "--remove-directory",
                delete_dir_relative,
                "--confdir",
                str(conf_runtime),
            ]
            delete_result = self._run_and_capture(context, f"{scenario_id} online delete", delete_command, delete_stdout, delete_stderr)
            details["delete_returncode"] = delete_result.returncode
            if delete_result.returncode != 0:
                failures.append(f"{scenario_id}: online delete failed with status {delete_result.returncode}")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            process_command = [
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
        elif delete_origin == "local":
            delete_local_path = sync_root / delete_dir_relative
            if not delete_local_path.is_dir():
                failures.append(f"{scenario_id}: expected local delete directory missing before local delete: {delete_local_path}")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            shutil.rmtree(delete_local_path)
            write_text_file(delete_stdout, f"Deleted local path: {delete_local_path}\n")
            write_text_file(delete_stderr, "")
            details["delete_returncode"] = 0

            process_command = [
                context.onedrive_bin,
                "--display-running-config",
                "--sync",
                "--verbose",
                "--single-directory",
                root_name,
                "--confdir",
                str(conf_runtime),
            ]
        else:
            failures.append(f"{scenario_id}: invalid delete_origin: {delete_origin}")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        process_result = self._run_and_capture(context, f"{scenario_id} process delete", process_command, process_stdout, process_stderr)
        details["process_returncode"] = process_result.returncode
        if process_result.returncode != 0:
            failures.append(f"{scenario_id}: delete processing failed with status {process_result.returncode}")

        reset_directory(verify_root)
        self._prepare_config(
            context,
            conf_verify,
            verify_root,
            use_recycle_bin=False,
            recycle_bin_path=recycle_bin_root,
        )
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
        verify_result = self._run_and_capture(context, f"{scenario_id} verify", verify_command, verify_stdout, verify_stderr)
        details["verify_returncode"] = verify_result.returncode
        if verify_result.returncode != 0:
            failures.append(f"{scenario_id}: remote verification failed with status {verify_result.returncode}")

        local_manifest = build_manifest(sync_root)
        remote_manifest = build_manifest(verify_root)
        recycle_manifest = build_manifest(recycle_bin_root)
        write_manifest(local_manifest_file, local_manifest)
        write_manifest(remote_manifest_file, remote_manifest)
        write_manifest(recycle_manifest_file, recycle_manifest)

        local_has_delete_dir = self._contains_path_prefix(local_manifest, delete_dir_relative)
        remote_has_delete_dir = self._contains_path_prefix(remote_manifest, delete_dir_relative)
        local_has_keep_file = keep_file_relative in local_manifest
        remote_has_keep_file = keep_file_relative in remote_manifest
        recycle_has_payload = self._recycle_bin_has_payload(recycle_manifest, "delete-me.txt")
        recycle_has_trashinfo = self._recycle_bin_has_trashinfo(recycle_manifest)

        details.update(
            {
                "local_has_delete_dir": local_has_delete_dir,
                "remote_has_delete_dir": remote_has_delete_dir,
                "local_has_keep_file": local_has_keep_file,
                "remote_has_keep_file": remote_has_keep_file,
                "recycle_has_payload": recycle_has_payload,
                "recycle_has_trashinfo": recycle_has_trashinfo,
                "expected_recycle_bin_payload": delete_origin == "online" and use_recycle_bin,
                "expected_local_delete_propagation": delete_origin == "local",
                "local_manifest_count": len(local_manifest),
                "remote_manifest_count": len(remote_manifest),
                "recycle_manifest_count": len(recycle_manifest),
            }
        )

        if local_has_delete_dir:
            failures.append(f"{scenario_id}: deleted directory still exists locally after delete processing")
        if remote_has_delete_dir:
            failures.append(f"{scenario_id}: deleted directory still exists online after delete processing")
        if not local_has_keep_file:
            failures.append(f"{scenario_id}: keep file missing locally after delete processing")
        if not remote_has_keep_file:
            failures.append(f"{scenario_id}: keep file missing online after delete processing")

        if delete_origin == "online" and use_recycle_bin:
            if not recycle_has_payload:
                failures.append(f"{scenario_id}: online-origin deleted payload was not moved into the configured recycle bin")
            if not recycle_has_trashinfo:
                failures.append(f"{scenario_id}: online-origin delete did not create recycle bin metadata .trashinfo file")
        else:
            if recycle_has_payload or recycle_has_trashinfo:
                if delete_origin == "local" and use_recycle_bin:
                    failures.append(
                        f"{scenario_id}: local-origin delete unexpectedly created configured recycle bin data; "
                        "local deletes are already removed before the client observes them and should be propagated online"
                    )
                else:
                    failures.append(f"{scenario_id}: recycle bin contains deleted data even though use_recycle_bin=false")

        self._write_metadata(metadata_file, details)
        return failures, artifacts, details

    def _run_failed_move_scenario(
        self,
        context: E2EContext,
        *,
        scenario_id: str,
        scenario_name: str,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
    ) -> tuple[list[str], list[str], dict[str, object]]:
        """Validate Issue #3784 using the established multi-client monitor topology."""
        scenario_work_dir = case_work_dir / scenario_id
        sync_root = scenario_work_dir / "syncroot"
        mutator_root = scenario_work_dir / "mutatorroot"
        precheck_root = scenario_work_dir / "precheckroot"
        verify_root = scenario_work_dir / "verifyroot"
        recycle_bin_root = scenario_work_dir / "RecycleBin"

        conf_runtime = scenario_work_dir / "conf-runtime"
        conf_mutator = scenario_work_dir / "conf-mutator"
        conf_precheck = scenario_work_dir / "conf-precheck"
        conf_verify = scenario_work_dir / "conf-verify"

        for path in [sync_root, mutator_root, precheck_root, verify_root, recycle_bin_root]:
            reset_directory(path)

        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id
        scenario_log_dir.mkdir(parents=True, exist_ok=True)
        scenario_state_dir.mkdir(parents=True, exist_ok=True)

        root_name = f"ZZ_E2E_TC0057_{context.run_id}_{os.getpid()}_{scenario_id}"
        delete_dir_relative = f"{root_name}/DeleteMe"
        delete_file_relative = f"{delete_dir_relative}/delete-me.txt"
        keep_file_relative = f"{root_name}/Keep/keep.txt"

        delete_dir_primary = sync_root / delete_dir_relative
        delete_file_primary = sync_root / delete_file_relative
        delete_dir_mutator = mutator_root / delete_dir_relative

        cross_device_base = Path("/dev/shm")
        failure_recycle_bin_root = (
            cross_device_base
            / f"onedrive-e2e-tc0057-{context.e2e_target}-{context.run_id}-{os.getpid()}-{scenario_id}"
        )

        seed_stdout = scenario_log_dir / "seed_stdout.log"
        seed_stderr = scenario_log_dir / "seed_stderr.log"
        mutator_stdout = scenario_log_dir / "mutator_monitor_stdout.log"
        mutator_stderr = scenario_log_dir / "mutator_monitor_stderr.log"
        precheck_stdout = scenario_log_dir / "precheck_stdout.log"
        precheck_stderr = scenario_log_dir / "precheck_stderr.log"
        process_stdout = scenario_log_dir / "process_stdout.log"
        process_stderr = scenario_log_dir / "process_stderr.log"
        followup_stdout = scenario_log_dir / "followup_stdout.log"
        followup_stderr = scenario_log_dir / "followup_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"

        failed_move_local_manifest_file = scenario_state_dir / "failed_move_local_manifest.txt"
        failed_move_recycle_manifest_file = scenario_state_dir / "failed_move_recycle_manifest.txt"
        followup_local_manifest_file = scenario_state_dir / "followup_local_manifest.txt"
        followup_recycle_manifest_file = scenario_state_dir / "followup_recycle_manifest.txt"
        precheck_manifest_file = scenario_state_dir / "precheck_remote_manifest.txt"
        remote_manifest_file = scenario_state_dir / "remote_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts = [
            str(seed_stdout),
            str(seed_stderr),
            str(mutator_stdout),
            str(mutator_stderr),
            str(scenario_log_dir / "app-logs"),
            str(precheck_stdout),
            str(precheck_stderr),
            str(process_stdout),
            str(process_stderr),
            str(followup_stdout),
            str(followup_stderr),
            str(verify_stdout),
            str(verify_stderr),
            str(failed_move_local_manifest_file),
            str(failed_move_recycle_manifest_file),
            str(followup_local_manifest_file),
            str(followup_recycle_manifest_file),
            str(precheck_manifest_file),
            str(remote_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "root_name": root_name,
            "delete_dir_relative": delete_dir_relative,
            "delete_file_relative": delete_file_relative,
            "keep_file_relative": keep_file_relative,
            "sync_root": str(sync_root),
            "mutator_root": str(mutator_root),
            "conf_runtime": str(conf_runtime),
            "conf_mutator": str(conf_mutator),
            "failure_recycle_bin_root": str(failure_recycle_bin_root),
        }
        failures: list[str] = []

        if not cross_device_base.is_dir():
            failures.append(f"{scenario_id}: required cross-filesystem path /dev/shm is not available")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details
        if not os.access(cross_device_base, os.W_OK | os.X_OK):
            failures.append(f"{scenario_id}: required cross-filesystem path /dev/shm is not writable")
            self._write_metadata(metadata_file, details)
            return failures, artifacts, details

        reset_directory(failure_recycle_bin_root)

        try:
            write_text_file(sync_root / keep_file_relative, f"tc0057 {scenario_id} keep\n")
            write_text_file(sync_root / delete_file_relative, f"tc0057 {scenario_id} delete me\n")

            self._prepare_config(
                context,
                conf_runtime,
                sync_root,
                use_recycle_bin=True,
                recycle_bin_path=recycle_bin_root,
            )

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
            seed_result = self._run_and_capture(
                context,
                f"{scenario_id} seed",
                seed_command,
                seed_stdout,
                seed_stderr,
            )
            details["seed_returncode"] = seed_result.returncode
            if seed_result.returncode != 0:
                failures.append(f"{scenario_id}: seed phase failed with status {seed_result.returncode}")
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            # Established harness pattern (TC0079): clone both the complete config
            # directory and the corresponding local tree so the actor starts with
            # the same items.sqlite3, token and delta state as the primary client.
            if conf_mutator.exists():
                shutil.rmtree(conf_mutator)
            if mutator_root.exists():
                shutil.rmtree(mutator_root)
            shutil.copytree(conf_runtime, conf_mutator)
            shutil.copytree(sync_root, mutator_root)

            mutator_app_log_dir = scenario_log_dir / "app-logs"
            self._rewrite_runtime_config(
                conf_mutator,
                mutator_root,
                extra_lines=[
                    'bypass_data_preservation = "true"',
                    'enable_logging = "true"',
                    f'log_dir = "{mutator_app_log_dir}"',
                    'monitor_interval = "300"',
                    'monitor_fullscan_frequency = "0"',
                    'disable_websocket_support = "true"',
                ],
            )

            # The primary remains stale while the actor mutates OneDrive. Only its
            # Recycle Bin destination is changed, preserving its DB/delta state.
            self._rewrite_runtime_config(
                conf_runtime,
                sync_root,
                recycle_bin_path=failure_recycle_bin_root,
            )

            sync_device_id = sync_root.stat().st_dev
            recycle_device_id = failure_recycle_bin_root.stat().st_dev
            details["sync_device_id"] = sync_device_id
            details["recycle_device_id"] = recycle_device_id
            if sync_device_id == recycle_device_id:
                failures.append(
                    f"{scenario_id}: cross-filesystem precondition not met; "
                    f"sync_dir and recycle_bin_path both use st_dev={sync_device_id}"
                )
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            mutator_command = [
                context.onedrive_bin,
                "--display-running-config",
                "--monitor",
                "--upload-only",
                "--verbose",
                "--verbose",
                "--single-directory",
                root_name,
                "--confdir",
                str(conf_mutator),
            ]
            details["mutator_command"] = command_to_string(mutator_command)
            context.log(
                f"Executing Test Case {self.case_id} {scenario_id} mutator monitor: "
                f"{details['mutator_command']}"
            )

            process, initial_sync_complete = self._launch_monitor_process(
                context,
                mutator_command,
                mutator_stdout,
                mutator_stderr,
                startup_timeout_seconds=300,
            )
            details["mutator_initial_sync_complete"] = initial_sync_complete
            mutation_processed = False
            try:
                if not initial_sync_complete:
                    failures.append(f"{scenario_id}: mutator monitor did not complete its initial sync")
                else:
                    mutation_offset = self._prepare_monitor_for_local_mutation(
                        process,
                        mutator_stdout,
                        details,
                    )
                    if not bool(details.get("monitor_ready_after_initial_sync", False)):
                        failures.append(f"{scenario_id}: mutator monitor was not ready for local deletion")
                    elif not delete_dir_mutator.is_dir():
                        failures.append(
                            f"{scenario_id}: mutator target missing before local deletion: {delete_dir_relative}"
                        )
                    else:
                        shutil.rmtree(delete_dir_mutator)
                        delete_pattern_groups = [
                            [f"Deleting item from Microsoft OneDrive: ./{delete_dir_relative}"],
                            [f"Deleting item from Microsoft OneDrive: ./{delete_file_relative}"],
                        ]
                        mutation_processed, matched_group, mutation_segment = (
                            self._wait_for_any_stdout_growth_pattern_group(
                                mutator_stdout,
                                start_offset=mutation_offset,
                                alternative_pattern_groups=delete_pattern_groups,
                                timeout_seconds=180,
                            )
                        )
                        details["mutator_delete_processed"] = mutation_processed
                        details["mutator_delete_pattern_groups"] = delete_pattern_groups
                        details["mutator_delete_matched_group"] = matched_group
                        details["mutator_delete_log_segment_length"] = len(mutation_segment)
                        if mutation_processed:
                            details["mutator_quiet_after_delete"] = self._wait_for_monitor_stdout_quiet(
                                process,
                                mutator_stdout,
                                quiet_seconds=3.0,
                                timeout_seconds=30,
                            )
            finally:
                self._shutdown_monitor_process(process, details)

            if not mutation_processed:
                failures.append(
                    f"{scenario_id}: mutator monitor did not propagate the populated directory deletion"
                )

            if failures:
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            # Confirm the actor really removed DeleteMe online before evaluating the
            # stale primary client. This keeps API/event timing out of the assertion.
            reset_directory(precheck_root)
            self._prepare_config(
                context,
                conf_precheck,
                precheck_root,
                use_recycle_bin=False,
                recycle_bin_path=recycle_bin_root,
            )
            precheck_command = [
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
                str(conf_precheck),
            ]
            precheck_result = self._run_and_capture(
                context,
                f"{scenario_id} verify remote deletion before failure",
                precheck_command,
                precheck_stdout,
                precheck_stderr,
            )
            details["precheck_returncode"] = precheck_result.returncode
            precheck_manifest = build_manifest(precheck_root)
            write_manifest(precheck_manifest_file, precheck_manifest)
            precheck_remote_has_delete_dir = self._contains_path_prefix(precheck_manifest, delete_dir_relative)
            precheck_remote_has_keep_file = keep_file_relative in precheck_manifest
            details["precheck_remote_has_delete_dir"] = precheck_remote_has_delete_dir
            details["precheck_remote_has_keep_file"] = precheck_remote_has_keep_file
            if precheck_result.returncode != 0:
                failures.append(
                    f"{scenario_id}: remote deletion precheck failed with status {precheck_result.returncode}"
                )
            if precheck_remote_has_delete_dir:
                failures.append(f"{scenario_id}: mutator deletion was not present online before failure test")
            if not precheck_remote_has_keep_file:
                failures.append(f"{scenario_id}: keep file missing during remote deletion precheck")
            if failures:
                self._write_metadata(metadata_file, details)
                return failures, artifacts, details

            # The stale primary consumes that genuine online deletion. Because the
            # configured Recycle Bin is cross-filesystem, rename() must fail with EXDEV.
            process_command = [
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
            process_result = self._run_and_capture(
                context,
                f"{scenario_id} process forced Recycle Bin failure",
                process_command,
                process_stdout,
                process_stderr,
            )
            details["process_returncode"] = process_result.returncode

            failed_move_local_manifest = build_manifest(sync_root)
            failed_move_recycle_manifest = build_manifest(failure_recycle_bin_root)
            write_manifest(failed_move_local_manifest_file, failed_move_local_manifest)
            write_manifest(failed_move_recycle_manifest_file, failed_move_recycle_manifest)

            failed_output = process_result.stdout + "\n" + process_result.stderr
            failure_was_reported = (
                "Move of local directory to the configured Recycle Bin failed for" in failed_output
                or "Move of local file to the configured Recycle Bin failed for" in failed_output
                or "Failed to move to the configured Recycle Bin:" in failed_output
            )
            local_retained_after_failure = delete_dir_primary.is_dir() and delete_file_primary.is_file()
            failed_recycle_has_payload = self._recycle_bin_has_payload(
                failed_move_recycle_manifest,
                "delete-me.txt",
            )
            failed_recycle_has_trashinfo = self._recycle_bin_has_trashinfo(
                failed_move_recycle_manifest,
            )
            details.update(
                {
                    "failure_was_reported": failure_was_reported,
                    "local_retained_after_failure": local_retained_after_failure,
                    "failed_recycle_has_payload": failed_recycle_has_payload,
                    "failed_recycle_has_trashinfo": failed_recycle_has_trashinfo,
                }
            )

            if not failure_was_reported:
                failures.append(f"{scenario_id}: forced Recycle Bin move failure was not reported")
            if not local_retained_after_failure:
                failures.append(
                    f"{scenario_id}: failed Recycle Bin move did not retain the local directory and child file"
                )
            if failed_recycle_has_payload:
                failures.append(f"{scenario_id}: failed Recycle Bin move unexpectedly created payload data")
            if failed_recycle_has_trashinfo:
                failures.append(f"{scenario_id}: failed Recycle Bin move incorrectly created .trashinfo metadata")

            # Actual Issue #3784 regression check: use the SAME primary state for a
            # subsequent ordinary bidirectional sync. The broken implementation had
            # already deleted DB identity, allowing the surviving object to be seen as
            # new and uploaded. The fixed implementation must not resurrect it online.
            followup_command = [
                context.onedrive_bin,
                "--display-running-config",
                "--sync",
                "--verbose",
                "--single-directory",
                root_name,
                "--confdir",
                str(conf_runtime),
            ]
            followup_result = self._run_and_capture(
                context,
                f"{scenario_id} follow-up no-reupload check",
                followup_command,
                followup_stdout,
                followup_stderr,
            )
            details["followup_returncode"] = followup_result.returncode

            followup_local_manifest = build_manifest(sync_root)
            followup_recycle_manifest = build_manifest(failure_recycle_bin_root)
            write_manifest(followup_local_manifest_file, followup_local_manifest)
            write_manifest(followup_recycle_manifest_file, followup_recycle_manifest)

            local_retained_after_followup = delete_dir_primary.is_dir() and delete_file_primary.is_file()
            followup_recycle_has_payload = self._recycle_bin_has_payload(
                followup_recycle_manifest,
                "delete-me.txt",
            )
            followup_recycle_has_trashinfo = self._recycle_bin_has_trashinfo(
                followup_recycle_manifest,
            )
            details.update(
                {
                    "local_retained_after_followup": local_retained_after_followup,
                    "followup_recycle_has_payload": followup_recycle_has_payload,
                    "followup_recycle_has_trashinfo": followup_recycle_has_trashinfo,
                }
            )
            if not local_retained_after_followup:
                failures.append(f"{scenario_id}: local object was not retained during follow-up processing")
            if followup_recycle_has_payload:
                failures.append(f"{scenario_id}: follow-up failed move unexpectedly created Recycle Bin payload")
            if followup_recycle_has_trashinfo:
                failures.append(f"{scenario_id}: follow-up failed move incorrectly created .trashinfo metadata")

            # Fresh independent client supplies the authoritative user-visible result:
            # DeleteMe must still be absent online. If it reappears, #3784 reproduced.
            reset_directory(verify_root)
            self._prepare_config(
                context,
                conf_verify,
                verify_root,
                use_recycle_bin=False,
                recycle_bin_path=recycle_bin_root,
            )
            verify_command = [
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
                str(conf_verify),
            ]
            verify_result = self._run_and_capture(
                context,
                f"{scenario_id} verify no re-upload",
                verify_command,
                verify_stdout,
                verify_stderr,
            )
            details["verify_returncode"] = verify_result.returncode
            remote_manifest = build_manifest(verify_root)
            write_manifest(remote_manifest_file, remote_manifest)

            remote_has_delete_dir = self._contains_path_prefix(remote_manifest, delete_dir_relative)
            remote_has_keep_file = keep_file_relative in remote_manifest
            details["remote_has_delete_dir_after_followup"] = remote_has_delete_dir
            details["remote_has_keep_file_after_followup"] = remote_has_keep_file

            if verify_result.returncode != 0:
                failures.append(f"{scenario_id}: remote verification failed with status {verify_result.returncode}")
            if remote_has_delete_dir:
                failures.append(
                    f"{scenario_id}: surviving local object was re-uploaded after failed Recycle Bin move"
                )
            if not remote_has_keep_file:
                failures.append(f"{scenario_id}: keep file missing from authoritative remote verification")

            self._write_metadata(metadata_file, details)
            return failures, artifacts, details
        finally:
            shutil.rmtree(failure_recycle_bin_root, ignore_errors=True)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0057",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        scenarios = [
            {
                "scenario_id": "S01_online_delete_recycle_bin_false",
                "scenario_name": "online delete with use_recycle_bin=false",
                "delete_origin": "online",
                "use_recycle_bin": False,
            },
            {
                "scenario_id": "S02_online_delete_recycle_bin_true",
                "scenario_name": "online delete with use_recycle_bin=true",
                "delete_origin": "online",
                "use_recycle_bin": True,
            },
            {
                "scenario_id": "S03_local_delete_recycle_bin_false",
                "scenario_name": "local delete with use_recycle_bin=false",
                "delete_origin": "local",
                "use_recycle_bin": False,
            },
            {
                "scenario_id": "S04_local_delete_recycle_bin_true",
                "scenario_name": "local delete with use_recycle_bin=true",
                "delete_origin": "local",
                "use_recycle_bin": True,
            },
            {
                "scenario_id": "S05_online_delete_recycle_bin_move_failure",
                "scenario_name": "online delete with failed Recycle Bin move must not re-upload",
                "delete_origin": "online",
                "use_recycle_bin": True,
            },
        ]

        selected_scenarios = [
            scenario
            for scenario in scenarios
            if context.should_run_scenario(self.case_id, str(scenario["scenario_id"]))
        ]

        all_failures: list[str] = []
        all_artifacts: list[str] = []
        details: dict[str, object] = {
            "scenario_count": len(selected_scenarios),
            "selected_scenarios": [scenario["scenario_id"] for scenario in selected_scenarios],
        }

        for scenario in selected_scenarios:
            if str(scenario["scenario_id"]) == "S05_online_delete_recycle_bin_move_failure":
                failures, artifacts, scenario_details = self._run_failed_move_scenario(
                    context,
                    scenario_id=str(scenario["scenario_id"]),
                    scenario_name=str(scenario["scenario_name"]),
                    case_work_dir=case_work_dir,
                    case_log_dir=case_log_dir,
                    state_dir=state_dir,
                )
            else:
                failures, artifacts, scenario_details = self._run_scenario(
                    context,
                    scenario_id=str(scenario["scenario_id"]),
                    scenario_name=str(scenario["scenario_name"]),
                    delete_origin=str(scenario["delete_origin"]),
                    use_recycle_bin=bool(scenario["use_recycle_bin"]),
                    case_work_dir=case_work_dir,
                    case_log_dir=case_log_dir,
                    state_dir=state_dir,
                )
            all_failures.extend(failures)
            all_artifacts.extend(artifacts)
            details[str(scenario["scenario_id"])] = scenario_details

        metadata_file = state_dir / "metadata.txt"
        self._write_metadata(metadata_file, details)
        all_artifacts.append(str(metadata_file))

        if not selected_scenarios:
            return self.fail_result(
                self.case_id,
                self.name,
                "No tc0057 scenarios were selected to run",
                all_artifacts,
                details,
            )

        if all_failures:
            return self.fail_result(
                self.case_id,
                self.name,
                "; ".join(all_failures),
                all_artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, all_artifacts, details)
