from __future__ import annotations

import os
import time
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)


class TestCase0037MtimeOnlyLocalChangeHandling(E2ETestCase):
    case_id = "0037"
    name = "mtime-only local change handling"
    description = (
        "Validate mtime-only local file changes across direct upload, automatic "
        "session upload for files larger than 4 MiB, and forced session upload "
        "behaviour without changing file content"
    )

    def _write_config(self, config_dir: Path, sync_dir: Path, extra_config_lines: list[str] | None = None) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_lines = [
            "# tc0037 config",
            f'sync_dir = "{sync_dir}"',
            'bypass_data_preservation = "true"',
        ]

        if extra_config_lines:
            config_lines.extend(extra_config_lines)

        config_text = "\n".join(config_lines) + "\n"

        write_onedrive_config(config_path, config_text)
        write_onedrive_config(backup_path, config_text)
        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")
        os.chmod(config_path, 0o600)
        os.chmod(backup_path, 0o600)
        os.chmod(hash_path, 0o600)

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _write_file_with_exact_size(self, path: Path, size_bytes: int, header_text: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)

        header_bytes = header_text.encode("utf-8")
        if len(header_bytes) > size_bytes:
            raise ValueError(f"header_text is larger than requested file size for {path}")

        filler_size = size_bytes - len(header_bytes)
        filler_chunk = b"0123456789ABCDEF" * 4096

        with path.open("wb") as handle:
            handle.write(header_bytes)
            while filler_size > 0:
                chunk = filler_chunk[: min(len(filler_chunk), filler_size)]
                handle.write(chunk)
                filler_size -= len(chunk)

    def _run_logged_command(
        self,
        context: E2EContext,
        command: list[str],
        stdout_path: Path,
        stderr_path: Path,
    ):
        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_path, result.stdout)
        write_text_file(stderr_path, result.stderr)
        return result

    def _scenario_uses_session_upload(self, file_size_bytes: int, force_session_upload: bool) -> bool:
        if force_session_upload:
            return True
        return file_size_bytes > (4 * 1024 * 1024)

    def _run_scenario(
        self,
        context: E2EContext,
        case_work_dir: Path,
        case_log_dir: Path,
        state_dir: Path,
        scenario_id: str,
        scenario_name: str,
        file_size_bytes: int,
        force_session_upload: bool,
        artifacts: list[str],
    ) -> tuple[bool, str, dict[str, object]]:
        scenario_work_dir = case_work_dir / scenario_id
        scenario_log_dir = case_log_dir / scenario_id
        scenario_state_dir = state_dir / scenario_id

        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        local_root = scenario_work_dir / "syncroot"
        verify_initial_root = scenario_work_dir / "verify-initial-root"
        verify_final_root = scenario_work_dir / "verify-final-root"

        conf_main = scenario_work_dir / "conf-main"
        conf_verify_initial = scenario_work_dir / "conf-verify-initial"
        conf_verify_final = scenario_work_dir / "conf-verify-final"

        reset_directory(local_root)
        reset_directory(verify_initial_root)
        reset_directory(verify_final_root)

        context.prepare_minimal_config_dir(conf_main, "")
        context.prepare_minimal_config_dir(conf_verify_initial, "")
        context.prepare_minimal_config_dir(conf_verify_final, "")

        extra_config_lines: list[str] = []
        if force_session_upload:
            extra_config_lines.append('force_session_upload = "true"')

        self._write_config(conf_main, local_root, extra_config_lines)
        self._write_config(conf_verify_initial, verify_initial_root)
        self._write_config(conf_verify_final, verify_final_root)

        root_name = f"ZZ_E2E_TC0037_{scenario_id}_{context.run_id}_{os.getpid()}"
        relative_path = f"{root_name}/mtime-only.txt"

        local_file_path = local_root / relative_path
        verify_initial_file_path = verify_initial_root / relative_path
        verify_final_file_path = verify_final_root / relative_path

        expected_manifest = [
            root_name,
            relative_path,
        ]

        uses_session_upload = self._scenario_uses_session_upload(file_size_bytes, force_session_upload)

        phase1_stdout = scenario_log_dir / "phase1_seed_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_seed_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_verify_initial_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_verify_initial_stderr.log"
        phase3_stdout = scenario_log_dir / "phase3_touch_sync_stdout.log"
        phase3_stderr = scenario_log_dir / "phase3_touch_sync_stderr.log"
        phase4_stdout = scenario_log_dir / "phase4_verify_final_stdout.log"
        phase4_stderr = scenario_log_dir / "phase4_verify_final_stderr.log"

        verify_initial_manifest_file = scenario_state_dir / "verify_initial_manifest.txt"
        verify_final_manifest_file = scenario_state_dir / "verify_final_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts.extend(
            [
                str(phase1_stdout),
                str(phase1_stderr),
                str(phase2_stdout),
                str(phase2_stderr),
                str(phase3_stdout),
                str(phase3_stderr),
                str(phase4_stdout),
                str(phase4_stderr),
                str(verify_initial_manifest_file),
                str(verify_final_manifest_file),
                str(metadata_file),
            ]
        )

        details: dict[str, object] = {
            "scenario_id": scenario_id,
            "scenario_name": scenario_name,
            "root_name": root_name,
            "relative_path": relative_path,
            "file_size_bytes": file_size_bytes,
            "force_session_upload": force_session_upload,
            "uses_session_upload": uses_session_upload,
            "main_conf_dir": str(conf_main),
            "verify_initial_conf_dir": str(conf_verify_initial),
            "verify_final_conf_dir": str(conf_verify_final),
            "local_root": str(local_root),
            "verify_initial_root": str(verify_initial_root),
            "verify_final_root": str(verify_final_root),
            "expected_manifest": expected_manifest,
        }

        initial_header = (
            f"TC0037 {scenario_id} {scenario_name}\n"
            "This file content must remain unchanged.\n"
            "Only the local modification timestamp is altered.\n"
        )
        self._write_file_with_exact_size(local_file_path, file_size_bytes, initial_header)

        initial_local_hash = compute_quickxor_hash_file(local_file_path)
        initial_local_size = local_file_path.stat().st_size

        details["initial_local_hash"] = initial_local_hash
        details["initial_local_size"] = initial_local_size

        # Phase 1: seed
        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        phase1_result = self._run_logged_command(context, phase1_command, phase1_stdout, phase1_stderr)
        details["phase1_returncode"] = phase1_result.returncode

        if phase1_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} seed phase failed with status {phase1_result.returncode}",
                details,
            )

        # Phase 2: initial fresh remote verification
        phase2_command = [
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
            str(conf_verify_initial),
        ]
        phase2_result = self._run_logged_command(context, phase2_command, phase2_stdout, phase2_stderr)
        details["phase2_returncode"] = phase2_result.returncode

        verify_initial_manifest = build_manifest(verify_initial_root)
        write_manifest(verify_initial_manifest_file, verify_initial_manifest)
        details["verify_initial_manifest"] = verify_initial_manifest
        details["verify_initial_file_exists"] = verify_initial_file_path.is_file()

        if phase2_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} initial remote verification failed with status {phase2_result.returncode}",
                details,
            )

        if not verify_initial_file_path.is_file():
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} initial remote verification is missing expected file: {relative_path}",
                details,
            )

        baseline_verified_hash = compute_quickxor_hash_file(verify_initial_file_path)
        baseline_verified_size = verify_initial_file_path.stat().st_size
        baseline_verified_mtime = int(verify_initial_file_path.stat().st_mtime)

        details["baseline_verified_hash"] = baseline_verified_hash
        details["baseline_verified_size"] = baseline_verified_size
        details["baseline_verified_mtime"] = baseline_verified_mtime

        if verify_initial_manifest != expected_manifest:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} initial remote verification manifest did not match expected structure",
                details,
            )

        if baseline_verified_hash != initial_local_hash:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} initial remote verification hash did not match seeded local file",
                details,
            )

        if baseline_verified_size != initial_local_size:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} initial remote verification size did not match seeded local file",
                details,
            )

        # Phase 3: touch local file only by explicitly setting a later mtime
        local_hash_before_touch = compute_quickxor_hash_file(local_file_path)
        local_mtime_before_touch = int(local_file_path.stat().st_mtime)

        touched_epoch = max(int(time.time()), local_mtime_before_touch, baseline_verified_mtime) + 120
        os.utime(local_file_path, (touched_epoch, touched_epoch))

        local_hash_after_touch = compute_quickxor_hash_file(local_file_path)
        local_mtime_after_touch = int(local_file_path.stat().st_mtime)

        details["local_hash_before_touch"] = local_hash_before_touch
        details["local_hash_after_touch"] = local_hash_after_touch
        details["local_mtime_before_touch"] = local_mtime_before_touch
        details["local_mtime_after_touch"] = local_mtime_after_touch
        details["touched_epoch"] = touched_epoch

        if local_hash_after_touch != local_hash_before_touch:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} local file hash changed after mtime-only touch",
                details,
            )

        if local_mtime_after_touch <= local_mtime_before_touch:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} local file mtime did not advance after touch",
                details,
            )

        phase3_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        phase3_result = self._run_logged_command(context, phase3_command, phase3_stdout, phase3_stderr)
        details["phase3_returncode"] = phase3_result.returncode

        phase3_combined_output = phase3_result.stdout + "\n" + phase3_result.stderr
        content_unchanged_marker = (
            "The last modified timestamp has changed however the file content has not changed"
        )
        same_hash_marker = "The local item has the same hash value as the item online"
        correcting_timestamp_marker = "correcting online timestamp"

        details["phase3_detected_content_unchanged_marker"] = content_unchanged_marker in phase3_combined_output
        details["phase3_detected_same_hash_marker"] = same_hash_marker in phase3_combined_output
        details["phase3_detected_correcting_timestamp_marker"] = correcting_timestamp_marker in phase3_combined_output

        if phase3_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} mtime-only sync phase failed with status {phase3_result.returncode}",
                details,
            )

        if content_unchanged_marker not in phase3_combined_output:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} did not log the expected content-unchanged timestamp handling marker",
                details,
            )

        if same_hash_marker not in phase3_combined_output:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} did not log the expected same-hash timestamp handling marker",
                details,
            )

        # Phase 4: final fresh remote verification
        phase4_command = [
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
            str(conf_verify_final),
        ]
        phase4_result = self._run_logged_command(context, phase4_command, phase4_stdout, phase4_stderr)
        details["phase4_returncode"] = phase4_result.returncode

        verify_final_manifest = build_manifest(verify_final_root)
        write_manifest(verify_final_manifest_file, verify_final_manifest)
        details["verify_final_manifest"] = verify_final_manifest
        details["verify_final_file_exists"] = verify_final_file_path.is_file()

        if phase4_result.returncode != 0:
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} final remote verification failed with status {phase4_result.returncode}",
                details,
            )

        if not verify_final_file_path.is_file():
            self._write_metadata(metadata_file, details)
            return (
                False,
                f"{scenario_id} final remote verification is missing expected file: {relative_path}",
                details,
            )

        final_verified_hash = compute_quickxor_hash_file(verify_final_file_path)
        final_verified_size = verify_final_file_path.stat().st_size
        final_verified_mtime = int(verify_final_file_path.stat().st_mtime)

        details["final_verified_hash"] = final_verified_hash
        details["final_verified_size"] = final_verified_size
        details["final_verified_mtime"] = final_verified_mtime

        self._write_metadata(metadata_file, details)

        if verify_final_manifest != expected_manifest:
            return (
                False,
                f"{scenario_id} final remote verification manifest did not match expected structure",
                details,
            )

        if final_verified_hash != initial_local_hash:
            return (
                False,
                f"{scenario_id} final verified file hash did not match original file content",
                details,
            )

        if final_verified_size != initial_local_size:
            return (
                False,
                f"{scenario_id} final verified file size did not match original file size",
                details,
            )

        # Scenario-specific timestamp assertions
        if uses_session_upload:
            if abs(final_verified_mtime - touched_epoch) > 2:
                return (
                    False,
                    f"{scenario_id} final remote mtime {final_verified_mtime} did not match touched local timestamp {touched_epoch} within tolerance",
                    details,
                )
        else:
            if final_verified_mtime <= baseline_verified_mtime:
                return (
                    False,
                    f"{scenario_id} final remote mtime {final_verified_mtime} did not advance beyond baseline {baseline_verified_mtime}",
                    details,
                )

            if correcting_timestamp_marker not in phase3_combined_output:
                return (
                    False,
                    f"{scenario_id} did not log the expected online timestamp correction marker for direct upload handling",
                    details,
                )

        return (True, f"{scenario_id} passed", details)

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / "tc0037"
        case_log_dir = context.logs_dir / "tc0037"
        state_dir = context.state_dir / "tc0037"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)
        context.ensure_refresh_token_available()

        artifacts: list[str] = []
        details: dict[str, object] = {}

        scenarios = [
            {
                "scenario_id": "MT-0001",
                "scenario_name": "small file with default upload behaviour",
                "file_size_bytes": 1 * 1024 * 1024,
                "force_session_upload": False,
            },
            {
                "scenario_id": "MT-0002",
                "scenario_name": "large file greater than 4 MiB with automatic session upload behaviour",
                "file_size_bytes": 5 * 1024 * 1024,
                "force_session_upload": False,
            },
            {
                "scenario_id": "MT-0003",
                "scenario_name": "small file with force_session_upload enabled",
                "file_size_bytes": 1 * 1024 * 1024,
                "force_session_upload": True,
            },
            {
                "scenario_id": "MT-0004",
                "scenario_name": "large file greater than 4 MiB with force_session_upload enabled",
                "file_size_bytes": 5 * 1024 * 1024,
                "force_session_upload": True,
            },
        ]

        scenarios = [
            scenario for scenario in scenarios if context.should_run_scenario(self.case_id, scenario["scenario_id"])
        ]

        failed_scenarios: list[str] = []

        for scenario in scenarios:
            passed, message, scenario_details = self._run_scenario(
                context=context,
                case_work_dir=case_work_dir,
                case_log_dir=case_log_dir,
                state_dir=state_dir,
                scenario_id=scenario["scenario_id"],
                scenario_name=scenario["scenario_name"],
                file_size_bytes=scenario["file_size_bytes"],
                force_session_upload=scenario["force_session_upload"],
                artifacts=artifacts,
            )

            details[scenario["scenario_id"]] = scenario_details
            details[f"{scenario['scenario_id']}_passed"] = passed
            details[f"{scenario['scenario_id']}_message"] = message

            if not passed:
                failed_scenarios.append(scenario["scenario_id"])

        details["executed_scenario_ids"] = [scenario["scenario_id"] for scenario in scenarios]
        details["failed_scenario_ids"] = list(failed_scenarios)

        summary_file = state_dir / "scenario-summary.txt"
        write_text_file(
            summary_file,
            "\n".join(
                f"{scenario_id}: passed={details.get(f'{scenario_id}_passed')} message={details.get(f'{scenario_id}_message')!r}"
                for scenario_id in [scenario["scenario_id"] for scenario in scenarios]
            )
            + "\n",
        )
        artifacts.append(str(summary_file))

        metadata_file = state_dir / "metadata.txt"
        self._write_metadata(metadata_file, details)
        artifacts.append(str(metadata_file))

        if failed_scenarios:
            return TestResult.fail_result(
                self.case_id,
                self.name,
                f"{len(failed_scenarios)} of {len(scenarios)} mtime-only scenarios failed: {', '.join(failed_scenarios)}",
                artifacts,
                details,
            )

        return TestResult.pass_result(self.case_id, self.name, artifacts, details)