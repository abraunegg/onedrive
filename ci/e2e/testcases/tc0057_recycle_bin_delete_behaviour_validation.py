from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0057RecycleBinDeleteBehaviourValidation(E2ETestCase):
    case_id = "0057"
    name = "recycle bin delete behaviour validation"
    description = "Validate use_recycle_bin behaviour for online-origin and local-origin deletes"

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

        if use_recycle_bin:
            if not recycle_has_payload:
                failures.append(f"{scenario_id}: deleted payload was not moved into the configured recycle bin")
            if not recycle_has_trashinfo:
                failures.append(f"{scenario_id}: recycle bin metadata .trashinfo file was not created")
        else:
            if recycle_has_payload or recycle_has_trashinfo:
                failures.append(f"{scenario_id}: recycle bin contains deleted data even though use_recycle_bin=false")

        self._write_metadata(metadata_file, details)
        return failures, artifacts, details

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
